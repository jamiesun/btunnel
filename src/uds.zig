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
const peer = @import("peer.zig");
const stats = @import("stats.zig");

pub const SOCKET_PATH = "/var/run/btunnel.sock";

/// Default snapshot file `save` serializes the live policy tree to (as replayable
/// `policy add` command lines). Deliberately NOT config.json: the config schema
/// carries no policy section in v1, so the operator-driven policy state is
/// persisted as a separate, replayable command snapshot instead of being merged
/// back into the daemon's startup config.
pub const SAVE_PATH = "/var/run/btunnel.policy";

/// Upper bound on installed policy rules. The control plane keeps two fixed
/// buffers of this size (double-buffered RCU), so memory is allocation-free and
/// bounded. Generous for a hub-and-spoke mesh (peers cap at config.MAX_PEERS).
pub const MAX_POLICY_ENTRIES = 256;

/// Per-tick datagram budget: `handle()` processes at most this many commands per
/// reactor wake-up so a local control flood cannot starve the data plane. The
/// control fd is level-triggered, so epoll re-notifies while datagrams remain.
const MAX_CMDS_PER_TICK = 64;

const RX_BUF = 4096;

/// Worst-case length of one serialized `policy add` line, e.g.
/// `policy add --src 255.255.255.255/32 --dst 255.255.255.255/32 --action forward --target 4294967295\n`.
const MAX_RULE_LINE = 112;

/// Size of the reply/snapshot buffer. Large enough to serialize a full policy
/// table (`MAX_POLICY_ENTRIES` rules) without ever truncating, so `policy show`
/// and `save` are always complete and the `save` ack count is always accurate.
pub const MAX_REPLY = MAX_POLICY_ENTRIES * MAX_RULE_LINE;

/// Header bytes of `sockaddr_un` preceding `path` (i.e. `@sizeOf(sa_family_t)`).
/// Used both as the bind addrlen for Linux abstract autobind and as the
/// threshold that distinguishes an addressable (bound) client from an anonymous
/// one in `recvfrom`'s returned source length.
const ADDR_HDR = @offsetOf(linux.sockaddr.un, "path");

pub const ControlError = error{
    Unsupported,
    SocketFailed,
    BindFailed,
    PathTooLong,
    TooManyEntries,
};

/// Errors surfaced to the ptctl client.
pub const ClientError = error{
    Unsupported,
    SocketFailed,
    BindFailed,
    PathTooLong,
    /// The daemon socket is absent or not listening (operator-facing: daemon down).
    DaemonUnavailable,
    SendFailed,
    /// The daemon accepted the request but sent no reply within the timeout.
    NoResponse,
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
    status,
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
    if (std.mem.eql(u8, verb, "status")) return .status;

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

/// Fill a filesystem `sockaddr_un` from `path`, returning the address and the
/// exact addrlen (`offsetof(path) + len + NUL`). Errors if the path cannot fit.
fn fillUnixAddr(path: []const u8) ControlError!struct { addr: linux.sockaddr.un, alen: linux.socklen_t } {
    if (path.len + 1 > 108) return error.PathTooLong; // sockaddr_un.path is 108 bytes incl. NUL
    var addr = linux.sockaddr.un{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const alen: linux.socklen_t = @intCast(ADDR_HDR + path.len + 1);
    return .{ .addr = addr, .alen = alen };
}

/// Open a non-blocking AF_UNIX datagram socket bound to `path`. A stale socket
/// file at `path` is unlinked first (filesystem sockets only). On any failure
/// after the socket is created, the fd is closed (no leak).
fn openDgramSocket(path: []const u8) ControlError!linux.fd_t {
    const a = try fillUnixAddr(path);

    const src = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(src) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(src);
    errdefer _ = linux.close(fd);

    // Best-effort removal of a stale socket from a previous run.
    _ = linux.unlink(@ptrCast(&a.addr.path));

    const brc = linux.bind(fd, @ptrCast(&a.addr), a.alen);
    if (linux.errno(brc) != .SUCCESS) return error.BindFailed;

    return fd;
}

// --- ptctl client -----------------------------------------------------------

/// Fire-and-forget delivery of one command line to the daemon socket at `path`.
/// Used for `policy add`, which expects no reply. A missing/closed socket maps
/// to `DaemonUnavailable` so the operator sees a clear "daemon down" signal.
pub fn send(path: []const u8, line: []const u8) ClientError!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const a = fillUnixAddr(path) catch |e| return switch (e) {
        error.PathTooLong => error.PathTooLong,
        else => error.SocketFailed,
    };

    const src = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(src) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(src);
    defer _ = linux.close(fd);

    const rc = linux.sendto(fd, line.ptr, line.len, 0, @ptrCast(&a.addr), a.alen);
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .CONNREFUSED, .CONNRESET => error.DaemonUnavailable,
        else => error.SendFailed,
    };
}

/// Send one command and wait up to `timeout_ms` for the daemon's reply,
/// returning the reply bytes written into `out`. Used for `policy show` / `save`.
///
/// The client socket is given a unique source address via Linux abstract
/// autobind (`bind` with only the family set, addrlen == `ADDR_HDR`), so the
/// daemon's `recvfrom` captures a routable return address and `sendto`s the
/// reply back to exactly this socket. A timeout (no datagram) maps to
/// `NoResponse`.
pub fn request(path: []const u8, line: []const u8, out: []u8, timeout_ms: i32) ClientError![]u8 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const a = fillUnixAddr(path) catch |e| return switch (e) {
        error.PathTooLong => error.PathTooLong,
        else => error.SocketFailed,
    };

    const src = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(src) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(src);
    defer _ = linux.close(fd);

    // Abstract autobind: a zero-length path with addrlen == family size makes the
    // kernel assign a unique anonymous address so the daemon can reply to us.
    var bind_addr = linux.sockaddr.un{ .path = undefined };
    bind_addr.family = linux.AF.UNIX;
    const brc = linux.bind(fd, @ptrCast(&bind_addr), ADDR_HDR);
    if (linux.errno(brc) != .SUCCESS) return error.BindFailed;

    const wrc = linux.sendto(fd, line.ptr, line.len, 0, @ptrCast(&a.addr), a.alen);
    switch (linux.errno(wrc)) {
        .SUCCESS => {},
        .NOENT, .CONNREFUSED, .CONNRESET => return error.DaemonUnavailable,
        else => return error.SendFailed,
    }

    // Bounded wait: track an absolute monotonic deadline so EINTR retries cannot
    // extend the timeout, and require POLLIN (an ERR/HUP/NVAL-only wake is not a
    // reply). The socket is non-blocking, so recvfrom never stalls past poll.
    const deadline = monotonicMillis() +| timeout_ms;
    var pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    while (true) {
        const remaining = deadline -| monotonicMillis();
        const prc = linux.poll(@ptrCast(&pfd), 1, @intCast(remaining));
        switch (linux.errno(prc)) {
            .SUCCESS => {},
            .INTR => {
                if (monotonicMillis() >= deadline) return error.NoResponse;
                continue;
            },
            else => return error.NoResponse,
        }
        if (prc == 0) return error.NoResponse; // timed out
        if (pfd.revents & linux.POLL.IN == 0) return error.NoResponse; // ERR/HUP/NVAL: no reply
        break;
    }

    const rrc = linux.recvfrom(fd, out.ptr, out.len, 0, null, null);
    if (linux.errno(rrc) != .SUCCESS) return error.NoResponse;
    return out[0..rrc];
}

/// Monotonic clock in milliseconds; saturates to 0 on the (practically
/// impossible) clock_gettime failure so callers still make forward progress.
fn monotonicMillis() i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// --- policy serialization (control-plane reply / snapshot) ------------------

/// Format a host-order CIDR as `a.b.c.d/prefix` into `buf`.
fn formatCidr(c: policy.Cidr, buf: []u8) []const u8 {
    const n = c.network;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}/{d}", .{
        (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, c.prefix,
    }) catch buf[0..0];
}

/// Format one policy entry as a replayable `policy add ...` command line
/// (newline-terminated) into `buf`.
fn formatEntry(e: policy.PolicyEntry, buf: []u8) []const u8 {
    var sb: [20]u8 = undefined;
    var db: [20]u8 = undefined;
    const s = formatCidr(e.src, &sb);
    const d = formatCidr(e.dst, &db);
    return switch (e.action) {
        .forward => std.fmt.bufPrint(buf, "policy add --src {s} --dst {s} --action forward --target {d}\n", .{ s, d, e.target }) catch buf[0..0],
        .drop => std.fmt.bufPrint(buf, "policy add --src {s} --dst {s} --action drop\n", .{ s, d }) catch buf[0..0],
    };
}


/// Static daemon identity surfaced by `ptctl status`. Passed in from `main` so
/// the control plane never imports `build_options` or other executable-context
/// modules (keeps `uds` unit-testable and reusable).
pub const DaemonMeta = struct {
    version: []const u8 = "?",
    mode: []const u8 = "?",
    listen_port: u16 = 0,
    tun_name: []const u8 = "?",
    local_id: u32 = 0,
};

/// Render a human-readable status report into `out` from the daemon meta, the
/// peer registry, and the data-plane counters. Pure formatting (no I/O) so it is
/// unit-testable. Sensitive material (PSKs, derived keys) is NEVER printed.
pub fn formatStatus(
    out: []u8,
    meta: DaemonMeta,
    registry: *const peer.PeerRegistry,
    counters: *const stats.Counters,
) []const u8 {
    var len: usize = 0;
    const W = struct {
        fn p(buf: []u8, off: *usize, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(buf[off.*..], fmt, args) catch return;
            off.* += s.len;
        }
    };

    W.p(out, &len, "btunnel v{s} [running]\n", .{meta.version});
    W.p(out, &len, "mode={s} local_id={d} udp_port={d} tun={s} peers={d}\n", .{
        meta.mode, meta.local_id, meta.listen_port, meta.tun_name, registry.len,
    });

    W.p(out, &len, "peers:\n", .{});
    var i: usize = 0;
    while (i < registry.len) : (i += 1) {
        const pr = &registry.peers[i];
        const a: u32 = std.mem.bigToNative(u32, pr.endpoint.addr);
        const port: u16 = std.mem.bigToNative(u16, pr.endpoint.port);
        const src: u32 = pr.allowed_src.network;
        W.p(out, &len, "  id={d} endpoint={d}.{d}.{d}.{d}:{d} allowed_src={d}.{d}.{d}.{d}/{d} last_seen_wall_ns={d}\n", .{
            pr.id,
            (a >> 24) & 0xff,   (a >> 16) & 0xff,   (a >> 8) & 0xff,   a & 0xff,   port,
            (src >> 24) & 0xff, (src >> 16) & 0xff, (src >> 8) & 0xff, src & 0xff, pr.allowed_src.prefix,
            pr.last_seen_wall_ns,
        });
    }

    const c = counters;
    W.p(out, &len, "traffic:\n", .{});
    W.p(out, &len, "  tun_rx packets={d} bytes={d}\n", .{ c.tun_rx_packets, c.tun_rx_bytes });
    W.p(out, &len, "  udp_tx packets={d} bytes={d}\n", .{ c.udp_tx_packets, c.udp_tx_bytes });
    W.p(out, &len, "  udp_rx packets={d} bytes={d}\n", .{ c.udp_rx_packets, c.udp_rx_bytes });
    W.p(out, &len, "  tun_tx packets={d} bytes={d}\n", .{ c.tun_tx_packets, c.tun_tx_bytes });
    W.p(out, &len, "  relay  packets={d} bytes={d}\n", .{ c.relay_packets, c.relay_bytes });
    W.p(out, &len, "  endpoint_learned={d}\n", .{c.udp_endpoint_learned});
    W.p(out, &len, "drops:\n", .{});
    W.p(out, &len, "  tun: not_ipv4={d} no_route={d} drop_rule={d} local_loop={d} unknown_target={d} oversized={d} egress_err={d} send_err={d}\n", .{
        c.drop_tun_not_ipv4,      c.drop_tun_no_route,  c.drop_tun_drop_rule, c.drop_tun_local_loop,
        c.drop_tun_unknown_target, c.drop_tun_oversized, c.drop_tun_egress_err, c.drop_tun_send_err,
    });
    W.p(out, &len, "  udp: unknown_peer={d} auth_or_invalid={d} not_ipv4={d} spoof={d} no_route={d} drop_rule={d} unknown_target={d} no_reflect={d} oversized={d} send_err={d}\n", .{
        c.drop_udp_unknown_peer, c.drop_udp_auth_or_invalid, c.drop_udp_not_ipv4,       c.drop_udp_spoof,
        c.drop_udp_no_route,     c.drop_udp_drop_rule,       c.drop_udp_unknown_target, c.drop_udp_no_reflect,
        c.drop_udp_oversized,    c.drop_udp_send_err,
    });

    return out[0..len];
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
    /// Reply/snapshot scratch (control plane only): `policy show` dumps here and
    /// `save` serializes here before the atomic file write. Sized to hold a full
    /// policy table so output is never silently truncated.
    txbuf: [MAX_REPLY]u8 = undefined,
    /// Filesystem path `save` persists the snapshot to (copied in at bind time).
    save_path_buf: [108]u8 = undefined,
    save_path_len: usize = 0,
    /// Optional status sources (issue #24), wired by `bindStatus`. When any is
    /// unset, `status` replies "status unavailable" rather than dereferencing a
    /// null — so a `Control` built without status wiring (e.g. in unit tests)
    /// stays safe.
    status_meta: ?DaemonMeta = null,
    status_registry: ?*const peer.PeerRegistry = null,
    status_counters: ?*const stats.Counters = null,

    /// Bind the control socket and install `initial` as the starting policy
    /// tree (swapped into `active`). `save_path` is the file `save` snapshots to.
    /// See the struct-level LIFETIME note: `self` must not be moved after this
    /// returns.
    pub fn bindInPlace(
        self: *Control,
        path: []const u8,
        save_path: []const u8,
        active: *policy.ActiveTree,
        initial: []const policy.PolicyEntry,
    ) ControlError!void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        if (initial.len > MAX_POLICY_ENTRIES) return error.TooManyEntries;
        if (save_path.len > self.save_path_buf.len) return error.PathTooLong; // 108-byte sockaddr_un budget

        // Bind the socket first: if it fails we must not have published `active`
        // into this (now-discarded) Control's storage.
        self.fd = try openDgramSocket(path);

        @memcpy(self.save_path_buf[0..save_path.len], save_path);
        self.save_path_len = save_path.len;

        self.cur = 0;
        self.count = initial.len;
        @memcpy(self.bufs[0][0..initial.len], initial);
        self.trees[0] = .{ .entries = self.bufs[0][0..initial.len] };
        self.active = active;
        _ = active.swap(&self.trees[0]);

        // `Control` is constructed via `= undefined`, so field defaults do NOT
        // apply. Explicitly clear the optional status sources; `bindStatus`
        // wires them later. Without this they hold garbage and the unbound
        // `status` path treats them as non-null and dereferences junk.
        self.status_meta = null;
        self.status_registry = null;
        self.status_counters = null;
    }

    /// Wire the optional status sources for `ptctl status` (issue #24). Call
    /// after `bindInPlace`. The pointers must outlive the Control (they live in
    /// `main`'s frame alongside it).
    pub fn bindStatus(
        self: *Control,
        meta: DaemonMeta,
        registry: *const peer.PeerRegistry,
        counters: *const stats.Counters,
    ) void {
        self.status_meta = meta;
        self.status_registry = registry;
        self.status_counters = counters;
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

    /// Serialize the live policy tree into `txbuf` as replayable `policy add`
    /// lines. Stops at a line boundary if `txbuf` would overflow (never emits a
    /// partial line); an empty tree yields a single comment line.
    fn dumpRules(self: *Control) []const u8 {
        var len: usize = 0;
        for (self.bufs[self.cur][0..self.count]) |e| {
            var line: [128]u8 = undefined;
            const s = formatEntry(e, &line);
            if (len + s.len > self.txbuf.len) break; // bounded: drop the overflow tail
            @memcpy(self.txbuf[len..][0..s.len], s);
            len += s.len;
        }
        if (len == 0) {
            const empty = "# no policy rules\n";
            @memcpy(self.txbuf[0..empty.len], empty);
            return self.txbuf[0..empty.len];
        }
        return self.txbuf[0..len];
    }

    /// Atomically write `data` to the snapshot path via a sibling temp file +
    /// fsync + rename. Returns false on any syscall failure or short write (the
    /// old snapshot, if any, is left intact). On success the snapshot is durable:
    /// the temp file is fsync'd before rename so a crash cannot leave a truncated
    /// snapshot under the final name.
    fn writeSnapshot(self: *Control, data: []const u8) bool {
        const sp = self.save_path_buf[0..self.save_path_len];
        var finalz: [113]u8 = undefined;
        var tmpz: [113]u8 = undefined;
        @memcpy(finalz[0..sp.len], sp);
        finalz[sp.len] = 0;
        @memcpy(tmpz[0..sp.len], sp);
        @memcpy(tmpz[sp.len..][0..4], ".tmp");
        tmpz[sp.len + 4] = 0;

        const orc = linux.open(@ptrCast(&tmpz), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(orc) != .SUCCESS) return false;
        const wfd: linux.fd_t = @intCast(orc);

        var off: usize = 0;
        while (off < data.len) {
            const rc = linux.write(wfd, data[off..].ptr, data.len - off);
            const e = linux.errno(rc);
            if (e == .INTR) continue;
            // A short write (rc == 0) before completion is a failure, not EOF:
            // never publish a partial snapshot.
            if (e != .SUCCESS or rc == 0) {
                _ = linux.close(wfd);
                _ = linux.unlink(@ptrCast(&tmpz));
                return false;
            }
            off += rc;
        }

        // Durability: flush file contents before the rename publishes the name.
        if (linux.errno(linux.fsync(wfd)) != .SUCCESS) {
            _ = linux.close(wfd);
            _ = linux.unlink(@ptrCast(&tmpz));
            return false;
        }
        if (linux.errno(linux.close(wfd)) != .SUCCESS) {
            _ = linux.unlink(@ptrCast(&tmpz));
            return false;
        }

        if (linux.errno(linux.rename(@ptrCast(&tmpz), @ptrCast(&finalz))) != .SUCCESS) {
            _ = linux.unlink(@ptrCast(&tmpz));
            return false;
        }
        return true;
    }

    /// Best-effort reply to an addressable client. Non-blocking; a full client
    /// buffer or vanished client just drops the reply (never stalls the loop).
    fn reply(self: *Control, src: *const linux.sockaddr.un, slen: linux.socklen_t, msg: []const u8) void {
        _ = linux.sendto(self.fd, msg.ptr, msg.len, linux.MSG.DONTWAIT, @ptrCast(src), slen);
    }

    /// Apply one command line; reply to `src` for query/persist commands when the
    /// client is addressable (bound source). `policy add` never replies.
    fn applyLine(self: *Control, line: []const u8, src: *const linux.sockaddr.un, slen: linux.socklen_t) void {
        const cmd = parseCommand(line) catch return;
        const addressable = slen > ADDR_HDR;
        switch (cmd) {
            .policy_add => |e| self.applyAdd(e) catch return,
            .policy_show => {
                const dump = self.dumpRules();
                if (addressable) self.reply(src, slen, dump);
            },
            .save => {
                const dump = self.dumpRules();
                const ok = self.writeSnapshot(dump);
                if (addressable) {
                    var ack: [160]u8 = undefined;
                    const msg = if (ok)
                        std.fmt.bufPrint(&ack, "saved {d} rule(s) to {s}\n", .{ self.count, self.save_path_buf[0..self.save_path_len] }) catch "saved\n"
                    else
                        "save failed\n";
                    self.reply(src, slen, msg);
                }
            },
            .status => {
                if (!addressable) return;
                const msg = if (self.status_meta != null and self.status_registry != null and self.status_counters != null)
                    formatStatus(&self.txbuf, self.status_meta.?, self.status_registry.?, self.status_counters.?)
                else
                    "status unavailable\n";
                self.reply(src, slen, msg);
            },
        }
    }

    /// Drain pending control datagrams; call when the control fd is readable.
    /// Each datagram is one or more newline-separated command lines. Bounds the
    /// work per call (the loop counter also caps EINTR retries, so a signal storm
    /// cannot livelock). Oversized datagrams are dropped whole via MSG_TRUNC so a
    /// truncated stream can never apply a valid-looking prefix. `policy show` /
    /// `save` reply to the datagram's source via the same socket.
    pub fn handle(self: *Control) void {
        var iters: usize = 0;
        while (iters < MAX_CMDS_PER_TICK) : (iters += 1) {
            var src: linux.sockaddr.un = undefined;
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr.un);
            const rc = linux.recvfrom(self.fd, &self.rxbuf, self.rxbuf.len, linux.MSG.TRUNC, @ptrCast(&src), &slen);
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
                self.applyLine(line, &src, slen);
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

test "parseCommand: show / save / status / errors" {
    try std.testing.expect(try parseCommand("policy show") == .policy_show);
    try std.testing.expect(try parseCommand("save") == .save);
    try std.testing.expect(try parseCommand("status") == .status);
    try std.testing.expectError(ParseError.UnknownCommand, parseCommand("bogus"));
    try std.testing.expectError(ParseError.MissingArgument, parseCommand("policy add --src 10.0.0.0/24"));
}

test "formatStatus: renders meta, peers, and counters; never prints secrets" {
    var reg = peer.PeerRegistry.init(1);
    const psk: @import("crypto.zig").Key = [_]u8{0xAB} ** 32;
    const ep = try @import("config.zig").parseEndpoint("203.0.113.7:51820");
    _ = try reg.add(psk, 2, ep, try @import("config.zig").parseCidr("10.0.0.2/32"), 1_700_000_000_000_000_000);

    var c = stats.Counters{};
    c.tun_rx_packets = 5;
    c.udp_tx_bytes = 1234;
    c.drop_udp_spoof = 2;

    const meta = DaemonMeta{
        .version = "9.9.9",
        .mode = "raw_direct",
        .listen_port = 51820,
        .tun_name = "btun0",
        .local_id = 1,
    };

    var buf: [4096]u8 = undefined;
    const s = formatStatus(&buf, meta, &reg, &c);

    try std.testing.expect(std.mem.indexOf(u8, s, "btunnel v9.9.9 [running]") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "local_id=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "id=2 endpoint=203.0.113.7:51820 allowed_src=10.0.0.2/32") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "tun_rx packets=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "udp_tx packets=0 bytes=1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "spoof=2") != null);
    // The PSK byte 0xAB must never appear in the rendered status.
    try std.testing.expect(std.mem.indexOf(u8, s, &[_]u8{0xAB}) == null);
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
    try ctl.bindInPlace(path, "/tmp/btunnel-add.policy", &active, &.{});
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
    try ctl.bindInPlace(path, "/tmp/btunnel-bad.policy", &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);

    try sendCommand(path, "bogus garbage line\npolicy add --src 10.0.0.0/24\n");
    ctl.handle();

    try std.testing.expectEqual(@as(usize, 0), ctl.count);
    try std.testing.expect(active.load().match(0xC0A8_0905) == null);
}

test "control: policy show replies with replayable rules to an addressable client" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-show-{d}.sock", .{linux.getpid()});

    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var ctl: Control = undefined;
    try ctl.bindInPlace(path, "/tmp/btunnel-show.policy", &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);

    try sendCommand(path, "policy add --src 0.0.0.0/0 --dst 192.168.9.0/24 --action forward --target 5\n");
    ctl.handle();

    // Addressable client: abstract autobind gives the daemon a return address.
    const cs = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(cs) == .SUCCESS);
    const cfd: linux.fd_t = @intCast(cs);
    defer _ = linux.close(cfd);
    var ba = linux.sockaddr.un{ .path = undefined };
    ba.family = linux.AF.UNIX;
    try std.testing.expect(linux.errno(linux.bind(cfd, @ptrCast(&ba), ADDR_HDR)) == .SUCCESS);

    var sa = linux.sockaddr.un{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..path.len], path);
    const alen: linux.socklen_t = @intCast(ADDR_HDR + path.len + 1);
    const wrc = linux.sendto(cfd, "policy show\n", 12, 0, @ptrCast(&sa), alen);
    try std.testing.expect(linux.errno(wrc) == .SUCCESS);

    ctl.handle(); // serves the reply

    var out: [512]u8 = undefined;
    const rrc = linux.recvfrom(cfd, &out, out.len, 0, null, null);
    try std.testing.expect(linux.errno(rrc) == .SUCCESS);
    const reply = out[0..rrc];
    try std.testing.expect(std.mem.indexOf(u8, reply, "policy add --src 0.0.0.0/0 --dst 192.168.9.0/24 --action forward --target 5") != null);
}

test "control: status replies 'unavailable' until bound, then a full report" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-status-{d}.sock", .{linux.getpid()});

    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var ctl: Control = undefined;
    try ctl.bindInPlace(path, "/tmp/btunnel-status.policy", &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);

    // Addressable client socket (abstract autobind return address).
    const cs = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(cs) == .SUCCESS);
    const cfd: linux.fd_t = @intCast(cs);
    defer _ = linux.close(cfd);
    var ba = linux.sockaddr.un{ .path = undefined };
    ba.family = linux.AF.UNIX;
    try std.testing.expect(linux.errno(linux.bind(cfd, @ptrCast(&ba), ADDR_HDR)) == .SUCCESS);

    var sa = linux.sockaddr.un{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..path.len], path);
    const alen: linux.socklen_t = @intCast(ADDR_HDR + path.len + 1);

    // Before bindStatus: status is gracefully unavailable (no null deref).
    _ = linux.sendto(cfd, "status\n", 7, 0, @ptrCast(&sa), alen);
    ctl.handle();
    var out: [1024]u8 = undefined;
    var rrc = linux.recvfrom(cfd, &out, out.len, 0, null, null);
    try std.testing.expect(linux.errno(rrc) == .SUCCESS);
    try std.testing.expect(std.mem.indexOf(u8, out[0..rrc], "status unavailable") != null);

    // After bindStatus: a full report is served.
    var reg = peer.PeerRegistry.init(1);
    var c = stats.Counters{};
    ctl.bindStatus(.{ .version = "1.2.3", .mode = "raw_direct", .listen_port = 51820, .tun_name = "btun0", .local_id = 1 }, &reg, &c);

    _ = linux.sendto(cfd, "status\n", 7, 0, @ptrCast(&sa), alen);
    ctl.handle();
    rrc = linux.recvfrom(cfd, &out, out.len, 0, null, null);
    try std.testing.expect(linux.errno(rrc) == .SUCCESS);
    try std.testing.expect(std.mem.indexOf(u8, out[0..rrc], "btunnel v1.2.3 [running]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..rrc], "traffic:") != null);
}

test "control: save persists a replayable snapshot and acks" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-save-{d}.sock", .{linux.getpid()});
    var snap_buf: [64]u8 = undefined;
    const snap = try std.fmt.bufPrint(&snap_buf, "/tmp/btunnel-save-{d}.policy", .{linux.getpid()});

    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var ctl: Control = undefined;
    try ctl.bindInPlace(path, snap, &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);
    defer unlinkPath(snap);

    try sendCommand(path, "policy add --src 10.1.0.0/16 --dst 10.2.0.0/16 --action drop\n");
    ctl.handle();

    const cs = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(cs) == .SUCCESS);
    const cfd: linux.fd_t = @intCast(cs);
    defer _ = linux.close(cfd);
    var ba = linux.sockaddr.un{ .path = undefined };
    ba.family = linux.AF.UNIX;
    try std.testing.expect(linux.errno(linux.bind(cfd, @ptrCast(&ba), ADDR_HDR)) == .SUCCESS);

    var sa = linux.sockaddr.un{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..path.len], path);
    const alen: linux.socklen_t = @intCast(ADDR_HDR + path.len + 1);
    try std.testing.expect(linux.errno(linux.sendto(cfd, "save\n", 5, 0, @ptrCast(&sa), alen)) == .SUCCESS);

    ctl.handle();

    var ack: [256]u8 = undefined;
    const rrc = linux.recvfrom(cfd, &ack, ack.len, 0, null, null);
    try std.testing.expect(linux.errno(rrc) == .SUCCESS);
    try std.testing.expect(std.mem.indexOf(u8, ack[0..rrc], "saved 1 rule") != null);

    // Snapshot file holds the replayable command.
    var snapz: [108]u8 = undefined;
    @memcpy(snapz[0..snap.len], snap);
    snapz[snap.len] = 0;
    const ofd = linux.open(@ptrCast(&snapz), .{ .ACCMODE = .RDONLY }, 0);
    try std.testing.expect(linux.errno(ofd) == .SUCCESS);
    const rfd: linux.fd_t = @intCast(ofd);
    defer _ = linux.close(rfd);
    var fbuf: [256]u8 = undefined;
    const frc = linux.read(rfd, &fbuf, fbuf.len);
    try std.testing.expect(linux.errno(frc) == .SUCCESS);
    try std.testing.expect(std.mem.indexOf(u8, fbuf[0..frc], "policy add --src 10.1.0.0/16 --dst 10.2.0.0/16 --action drop") != null);
}

test "client: send/request to an absent daemon report DaemonUnavailable" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-absent-{d}.sock", .{linux.getpid()});
    unlinkPath(path); // ensure nothing is bound there

    try std.testing.expectError(error.DaemonUnavailable, send(path, "policy add --src 0.0.0.0/0 --dst 10.0.0.0/8 --action drop\n"));

    var out: [64]u8 = undefined;
    try std.testing.expectError(error.DaemonUnavailable, request(path, "policy show\n", &out, 200));
}

test "client: request times out as NoResponse when the daemon never replies" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-silent-{d}.sock", .{linux.getpid()});

    // A bound socket that accepts the datagram but never replies.
    const ss = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(ss) == .SUCCESS);
    const sfd: linux.fd_t = @intCast(ss);
    defer _ = linux.close(sfd);
    defer unlinkPath(path);
    var sa = linux.sockaddr.un{ .path = undefined };
    @memset(&sa.path, 0);
    @memcpy(sa.path[0..path.len], path);
    const alen: linux.socklen_t = @intCast(ADDR_HDR + path.len + 1);
    try std.testing.expect(linux.errno(linux.bind(sfd, @ptrCast(&sa), alen)) == .SUCCESS);

    var out: [64]u8 = undefined;
    try std.testing.expectError(error.NoResponse, request(path, "policy show\n", &out, 150));
}

test "client: round-trips a real request() against a served control socket" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/btunnel-rt-{d}.sock", .{linux.getpid()});

    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var ctl: Control = undefined;
    try ctl.bindInPlace(path, "/tmp/btunnel-rt.policy", &active, &.{});
    defer ctl.deinit();
    defer unlinkPath(path);

    try send(path, "policy add --src 0.0.0.0/0 --dst 172.16.0.0/12 --action forward --target 7\n");
    ctl.handle();

    const Server = struct {
        fn loop(c: *Control, stop: *std.atomic.Value(bool)) void {
            const ts = linux.timespec{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
            while (!stop.load(.acquire)) {
                c.handle();
                _ = linux.nanosleep(&ts, null);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var th = try std.Thread.spawn(.{}, Server.loop, .{ &ctl, &stop });
    defer {
        stop.store(true, .release);
        th.join();
    }

    var out: [512]u8 = undefined;
    const reply = try request(path, "policy show\n", &out, 2000);
    try std.testing.expect(std.mem.indexOf(u8, reply, "--dst 172.16.0.0/12 --action forward --target 7") != null);
}

