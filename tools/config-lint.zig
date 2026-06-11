//! config-lint — offline config.json validator (issue #59).
//!
//! Loads a config file through the daemon's OWN parser and sanity checks
//! (`config.fromJson` + `Config.validate` + `peer.PeerRegistry.fromConfig`) so
//! the linter can never drift from what the daemon enforces at startup.
//!
//! Unlike `subnetrad --check`, it has NO dependency on a sane system clock — it
//! feeds the registry a fixed synthetic epoch purely to exercise the structural
//! checks (duplicate ids/endpoints, reserved/self ids) — and it never opens a
//! socket. That makes it safe to run on a build/CI box whose wall clock is
//! skewed or whose kernel is not Linux. It is read-only, never echoes PSK
//! material, and is NOT part of the shipped daemon (built via
//! `zig build tool:config-lint`, never installed by default).

const std = @import("std");
const bt = @import("subnetra");
const build_options = @import("build_options");

const CONFIG_MAX = 64 * 1024;

/// Fixed, clock-independent epoch used only to satisfy `PeerRegistry.fromConfig`
/// (it binds the transmit session but is irrelevant to the structural checks the
/// linter cares about). Reusing the protocol's minimum valid epoch keeps the
/// value unambiguously "a real epoch" without reading the system clock.
const SYNTH_EPOCH: u64 = bt.protocol_vectors.MIN_EPOCH;

const USAGE =
    \\Usage: config-lint [PATH]
    \\
    \\Validate a subnetra config.json offline using the daemon's own parser and
    \\sanity checks. Exits 0 if the config is valid, non-zero otherwise.
    \\PATH defaults to "config.json".
    \\
    \\  -h, --help     show this help
    \\  -V, --version  show version
    \\
;

const Summary = struct {
    role: []const u8,
    local_id: u32,
    peer_count: usize,
    mtu: u16,
    listen_ports: [bt.config.MAX_LISTEN_PORTS]u16,
    listen_port_count: usize,
};

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn readFile(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var total: usize = 0;
    while (total < buf.len) {
        const n = file.readStreaming(io, &.{buf[total..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
    }
    return buf[0..total];
}

/// Run the exact validation pipeline the daemon runs at startup (minus the
/// clock-dependent boot epoch). Returns a summary on success, or propagates the
/// first parse/sanity/registry error so the caller can report it.
fn lint(allocator: std.mem.Allocator, slice: []const u8) !Summary {
    const cfg = try bt.config.Config.fromJson(allocator, slice);
    try cfg.validate(&.{});
    _ = try bt.peer.PeerRegistry.fromConfig(cfg, SYNTH_EPOCH);
    return .{
        .role = @tagName(cfg.role),
        .local_id = cfg.local_id,
        .peer_count = cfg.peer_count,
        .mtu = cfg.local_tun_mtu,
        .listen_ports = cfg.listen_ports,
        .listen_port_count = cfg.listen_port_count,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;

    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        writeOut(io, USAGE);
        return;
    }
    if (hasFlag(args, "--version") or hasFlag(args, "-V")) {
        var vbuf: [80]u8 = undefined;
        const v = std.fmt.bufPrint(&vbuf, "config-lint (subnetra v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    const path = firstPositional(args) orelse "config.json";

    var buf: [CONFIG_MAX]u8 = undefined;
    const slice = readFile(io, path, &buf) catch |err| {
        var ebuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "config-lint: cannot read {s}: {s}\n", .{ path, @errorName(err) }) catch return err;
        writeErr(io, msg);
        return err;
    };

    const summary = lint(init.gpa, slice) catch |err| {
        var ebuf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&ebuf, "config-lint: {s}: FAILED ({s})\n", .{ path, @errorName(err) }) catch return err;
        writeErr(io, msg);
        return err;
    };

    var obuf: [256]u8 = undefined;
    const out = std.fmt.bufPrint(&obuf, "config-lint: {s}: OK (role={s}, local_id={d}, peers={d}, mtu={d}, udp_ports={any})\n", .{
        path, summary.role, summary.local_id, summary.peer_count, summary.mtu, summary.listen_ports[0..summary.listen_port_count],
    }) catch return;
    writeOut(io, out);
}

fn hasFlag(args: std.process.Args, flag: []const u8) bool {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn firstPositional(args: std.process.Args) ?[]const u8 {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (a.len == 0 or a[0] != '-') return a;
    }
    return null;
}

const GOOD =
    \\{"local_id":1,"role":"manual","peers":[
    \\  {"id":2,"endpoint":"192.0.2.1:51820","allowed_src":"10.0.0.2/32",
    \\   "psk":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
;

test "lint accepts a well-formed config" {
    const s = try lint(std.testing.allocator, GOOD);
    try std.testing.expectEqual(@as(usize, 1), s.peer_count);
    try std.testing.expectEqualStrings("manual", s.role);
}

test "lint rejects a zero PSK (matches daemon validate)" {
    const bad =
        \\{"local_id":1,"role":"manual","peers":[
        \\  {"id":2,"endpoint":"192.0.2.1:51820","allowed_src":"10.0.0.2/32",
        \\   "psk":"0000000000000000000000000000000000000000000000000000000000000000"}]}
    ;
    try std.testing.expectError(error.InvalidPsk, lint(std.testing.allocator, bad));
}

test "lint rejects a duplicate PSK across links" {
    const dup =
        \\{"local_id":1,"role":"manual","peers":[
        \\  {"id":2,"endpoint":"192.0.2.1:51820","allowed_src":"10.0.0.2/32",
        \\   "psk":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        \\  {"id":3,"endpoint":"192.0.2.2:51820","allowed_src":"10.0.0.3/32",
        \\   "psk":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    try std.testing.expectError(error.DuplicatePsk, lint(std.testing.allocator, dup));
}

test "lint rejects a malformed CIDR" {
    const bad =
        \\{"local_id":1,"role":"manual","virtual_subnet":"not-a-cidr","peers":[
        \\  {"id":2,"endpoint":"192.0.2.1:51820","allowed_src":"10.0.0.2/32",
        \\   "psk":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
    ;
    try std.testing.expectError(error.InvalidCidr, lint(std.testing.allocator, bad));
}
