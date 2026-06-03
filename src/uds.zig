//! Task 7: Control-plane Unix domain socket.
//!
//! The daemon binds /var/run/btunnel.sock (AF_UNIX, SOCK_DGRAM), receives
//! plaintext command datagrams from ptctl, tokenizes them, rebuilds the policy
//! tree, and injects it into the data plane via policy's atomic swap interface
//! (lock-free RCU).
//!
//! A datagram socket is used deliberately: each datagram is exactly one command
//! (one `recvfrom` == one message), so there is no stream framing, no partial
//! reads, and no per-connection fd to accept/track/leak. The control plane may
//! allocate; the data plane must not — so the policy tree is double-buffered in
//! fixed storage owned by `Control` and swapped wholesale, with no allocator.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const policy = @import("policy.zig");

pub const SOCKET_PATH = "/var/run/btunnel.sock";

/// Upper bound on installed policy rules. The control plane keeps two fixed
/// buffers of this size (double-buffered RCU), so memory is allocation-free and
/// bounded. Generous for a hub-and-spoke mesh (peers cap at config.MAX_PEERS).
pub const MAX_POLICY_ENTRIES = 256;

/// Per-tick datagram budget: `handle()` processes at most this many commands per
/// reactor wake-up so a local control flood cannot starve the data plane. The
/// control fd is level-triggered, so epoll re-notifies while datagrams remain.
const MAX_CMDS_PER_TICK = 64;

const RX_BUF = 4096;

pub const ControlError = error{
    Unsupported,
    SocketFailed,
    BindFailed,
    PathTooLong,
    TooManyEntries,
};

pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    InvalidValue,
};

/// Control command.
pub const Command = union(enum) {
    policy_add: policy.PolicyEntry,
    policy_show,
    save,
};

fn nextValue(it: *std.mem.TokenIterator(u8, .scalar)) ParseError![]const u8 {
    return it.next() orelse ParseError.MissingArgument;
}

/// Tokenize a line of plaintext command into a Command.
/// e.g. `policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3`
pub fn parseCommand(line: []const u8) ParseError!Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = it.next() orelse return ParseError.UnknownCommand;

    if (std.mem.eql(u8, verb, "save")) return .save;

    if (!std.mem.eql(u8, verb, "policy")) return ParseError.UnknownCommand;

    const sub = it.next() orelse return ParseError.MissingArgument;
    if (std.mem.eql(u8, sub, "show")) return .policy_show;
    if (!std.mem.eql(u8, sub, "add")) return ParseError.UnknownCommand;

    var entry = policy.PolicyEntry{
        .src = undefined,
        .dst = undefined,
        .action = .drop,
    };
    var have_src = false;
    var have_dst = false;

    while (it.next()) |flag| {
        if (std.mem.eql(u8, flag, "--src")) {
            entry.src = policy.parseCidr(try nextValue(&it)) catch return ParseError.InvalidValue;
            have_src = true;
        } else if (std.mem.eql(u8, flag, "--dst")) {
            entry.dst = policy.parseCidr(try nextValue(&it)) catch return ParseError.InvalidValue;
            have_dst = true;
        } else if (std.mem.eql(u8, flag, "--action")) {
            const v = try nextValue(&it);
            entry.action = if (std.mem.eql(u8, v, "forward"))
                .forward
            else if (std.mem.eql(u8, v, "drop"))
                .drop
            else
                return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--target")) {
            entry.target = std.fmt.parseInt(u32, try nextValue(&it), 10) catch return ParseError.InvalidValue;
        } else {
            return ParseError.UnknownCommand;
        }
    }

    if (!have_src or !have_dst) return ParseError.MissingArgument;
    return .{ .policy_add = entry };
}

/// Open a non-blocking AF_UNIX datagram socket bound to `path`. A stale socket
/// file at `path` is unlinked first (filesystem sockets only). On any failure
/// after the socket is created, the fd is closed (no leak).
fn openDgramSocket(path: []const u8) ControlError!linux.fd_t {
    if (path.len + 1 > 108) return error.PathTooLong; // sockaddr_un.path is 108 bytes incl. NUL

    const src = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(src) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(src);
    errdefer _ = linux.close(fd);

    // Best-effort removal of a stale socket from a previous run.
    var pathz: [108]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    _ = linux.unlink(@ptrCast(&pathz));

    var addr = linux.sockaddr.un{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const alen: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);

    const brc = linux.bind(fd, @ptrCast(&addr), alen);
    if (linux.errno(brc) != .SUCCESS) return error.BindFailed;

    return fd;
}

/// Control-plane listener. Owns the AF_UNIX datagram socket and the live policy
/// tree storage.
///
/// LIFETIME: `Control` must be pinned at a stable address for the daemon's
/// lifetime. `trees[i].entries` alias into `self.bufs[i]`, and the data plane's
/// `ActiveTree` is pointed at `&self.trees[cur]`; copying or moving a Control
/// after `bindInPlace` would dangle those slices. Construct as `var c: Control =
/// undefined; try c.bindInPlace(...)` and never move it.
///
/// HOT-SWAP: a policy update is built in the non-current buffer and installed
/// with a single atomic `ActiveTree.swap`. Because the reactor is strictly
/// single-threaded — data pumps and `handle()` never run concurrently — no
/// reader can retain the old tree across a control tick, so the previous buffer
/// is always safe to overwrite on the next update. No allocator, no deferred
/// reclamation list.
pub const Control = struct {
    fd: linux.fd_t = -1,
    active: *policy.ActiveTree = undefined,
    /// Double-buffered policy storage; only the non-current buffer is ever
    /// written, so the data plane never observes a half-built tree.
    bufs: [2][MAX_POLICY_ENTRIES]policy.PolicyEntry = undefined,
    trees: [2]policy.PolicyTree = undefined,
    cur: usize = 0,
    count: usize = 0,
    rxbuf: [RX_BUF]u8 = undefined,

    /// Bind the control socket and install `initial` as the starting policy
    /// tree (swapped into `active`). See the struct-level LIFETIME note: `self`
    /// must not be moved after this returns.
    pub fn bindInPlace(
        self: *Control,
        path: []const u8,
        active: *policy.ActiveTree,
        initial: []const policy.PolicyEntry,
    ) ControlError!void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        if (initial.len > MAX_POLICY_ENTRIES) return error.TooManyEntries;

        // Bind the socket first: if it fails we must not have published `active`
        // into this (now-discarded) Control's storage.
        self.fd = try openDgramSocket(path);

        self.cur = 0;
        self.count = initial.len;
        @memcpy(self.bufs[0][0..initial.len], initial);
        self.trees[0] = .{ .entries = self.bufs[0][0..initial.len] };
        self.active = active;
        _ = active.swap(&self.trees[0]);
    }

    pub fn deinit(self: *Control) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    /// Append one rule and atomically publish the new tree (double-buffered RCU).
    fn applyAdd(self: *Control, entry: policy.PolicyEntry) ControlError!void {
        if (self.count >= MAX_POLICY_ENTRIES) return error.TooManyEntries;
        const next: usize = 1 - self.cur;
        @memcpy(self.bufs[next][0..self.count], self.bufs[self.cur][0..self.count]);
        self.bufs[next][self.count] = entry;
        const new_count = self.count + 1;
        self.trees[next] = .{ .entries = self.bufs[next][0..new_count] };
        _ = self.active.swap(&self.trees[next]);
        self.cur = next;
        self.count = new_count;
    }

    /// Apply a single command line. Malformed commands and a full policy table
    /// are silently ignored (fire-and-forget control protocol; no reply channel
    /// yet). `policy show` / `save` are accepted but currently no-ops.
    fn applyLine(self: *Control, line: []const u8) void {
        const cmd = parseCommand(line) catch return;
        switch (cmd) {
            .policy_add => |e| self.applyAdd(e) catch return,
            .policy_show, .save => {},
        }
    }

    /// Drain pending control datagrams; call when the control fd is readable.
    /// Each datagram is one or more newline-separated command lines. Bounds the
    /// work per call (the loop counter also caps EINTR retries, so a signal storm
    /// cannot livelock). Oversized datagrams are dropped whole via MSG_TRUNC so a
    /// truncated stream can never apply a valid-looking prefix.
    pub fn handle(self: *Control) void {
        var iters: usize = 0;
        while (iters < MAX_CMDS_PER_TICK) : (iters += 1) {
            const rc = linux.recvfrom(self.fd, &self.rxbuf, self.rxbuf.len, linux.MSG.TRUNC, null, null);
            const e = linux.errno(rc);
            if (e == .INTR) continue; // counter-bounded retry
            if (e == .AGAIN) return; // no more datagrams queued
            if (e != .SUCCESS) return; // transient error: yield this round
            if (rc == 0) continue;
            if (rc > self.rxbuf.len) continue; // MSG_TRUNC: oversized datagram -> drop whole
            const datagram = self.rxbuf[0..rc];
            var it = std.mem.splitScalar(u8, datagram, '\n');
            while (it.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                self.applyLine(line);
            }
        }
    }
};

test "parseCommand: policy add" {
    const cmd = try parseCommand("policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3");
    const e = cmd.policy_add;
    try std.testing.expectEqual(@as(u32, 0xC0A8_0200), e.dst.network);
    try std.testing.expectEqual(policy.Action.forward, e.action);
    try std.testing.expectEqual(@as(u32, 3), e.target);
}

test "parseCommand: show / save / errors" {
    try std.testing.expect(try parseCommand("policy show") == .policy_show);
    try std.testing.expect(try parseCommand("save") == .save);
    try std.testing.expectError(ParseError.UnknownCommand, parseCommand("bogus"));
    try std.testing.expectError(ParseError.MissingArgument, parseCommand("policy add --src 10.0.0.0/24"));
}

/// Send one command datagram to a bound control socket at `path`.
fn sendCommand(path: []const u8, msg: []const u8) !void {
    const src = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(src) == .SUCCESS);
    const cfd: linux.fd_t = @intCast(src);
    defer _ = linux.close(cfd);

    var addr = linux.sockaddr.un{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const alen: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);

    const wrc = linux.sendto(cfd, msg.ptr, msg.len, 0, @ptrCast(&addr), alen);
    try std.testing.expect(linux.errno(wrc) == .SUCCESS);
}

fn unlinkPath(path: []const u8) void {
    var pz: [108]u8 = undefined;
    @memcpy(pz[0..path.len], path);
    pz[path.len] = 0;
    _ = linux.unlink(@ptrCast(&pz));
}

test "control: policy add datagram hot-swaps the active tree" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-add-{d}.sock", .{linux.getpid()});

    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var ctl: Control = undefined;
    try ctl.bindInPlace(path, &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);

    // No route before the command lands.
    try std.testing.expect(active.load().match(0xC0A8_0905) == null); // 192.168.9.5

    try sendCommand(path, "policy add --src 0.0.0.0/0 --dst 192.168.9.0/24 --action forward --target 5\n");
    ctl.handle();

    const hit = active.load().match(0xC0A8_0905) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(policy.Action.forward, hit.action);
    try std.testing.expectEqual(@as(u32, 5), hit.target);

    // A second rule is published over the first via the double-buffer swap.
    try sendCommand(path, "policy add --src 0.0.0.0/0 --dst 10.0.0.0/8 --action drop\n");
    ctl.handle();
    try std.testing.expectEqual(@as(usize, 2), ctl.count);
    try std.testing.expectEqual(policy.Action.drop, active.load().match(0x0A00_0001).?.action);
    // The earlier rule survives the swap.
    try std.testing.expectEqual(@as(u32, 5), active.load().match(0xC0A8_0905).?.target);
}

test "control: malformed datagram leaves the tree unchanged" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-bad-{d}.sock", .{linux.getpid()});

    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var ctl: Control = undefined;
    try ctl.bindInPlace(path, &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);

    try sendCommand(path, "bogus garbage line\npolicy add --src 10.0.0.0/24\n");
    ctl.handle();

    try std.testing.expectEqual(@as(usize, 0), ctl.count);
    try std.testing.expect(active.load().match(0xC0A8_0905) == null);
}
