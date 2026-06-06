//! config-gen — scaffold a consistent hub + spoke config set (issue #63).
//!
//! Emits a ready-to-edit hub-and-spoke `config.json` set with freshly generated,
//! per-link-unique PSKs already placed IDENTICALLY on both ends (issue #13
//! symmetry), correct roles, mesh ids, and `/32` source bindings. The only edit
//! left for the operator is filling in the real endpoint IPs (emitted as obvious
//! `REPLACE_*` placeholders). PSKs are drawn from the OS CSPRNG and the tool
//! fails closed if no secure entropy source is available.
//!
//! Offline and side-effect-free except for `--out DIR` (which writes the files).
//! NOT part of the shipped daemon (built via `zig build tool:config-gen`).

const std = @import("std");
const bt = @import("subnetra");
const build_options = @import("build_options");

const MAX_SPOKES = 32;
const DOC_BUF = 8192;
const HexKey = [64]u8;

const USAGE =
    \\Usage: config-gen [--spokes N] [--subnet CIDR] [--port P] [--mtu M] [--out DIR]
    \\
    \\Generate a hub + N-spoke config set with fresh, per-link-unique PSKs placed
    \\on both ends. Endpoints are REPLACE_* placeholders for you to fill in.
    \\
    \\  --spokes N     number of spokes (default 2, max 32)
    \\  --subnet CIDR  virtual /24 subnet (default 10.0.0.0/24)
    \\  --port P       listen/endpoint port (default 51820)
    \\  --mtu M        tunnel MTU (default 1400)
    \\  --out DIR      write hub.json + spoke-K.json into DIR (default: stdout)
    \\  -h, --help     show this help
    \\  -V, --version  show version
    \\
;

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

/// Minimal fixed-buffer string builder (no allocator, no partial-write surprises).
const Buf = struct {
    data: []u8,
    len: usize = 0,
    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(self.data[self.len..], fmt, args) catch return;
        self.len += s.len;
    }
    fn slice(self: *const Buf) []const u8 {
        return self.data[0..self.len];
    }
};

/// Endpoint rendering: `placeholder` emits an obvious REPLACE token the operator
/// must edit; `example` emits a valid distinct IP so generated docs can be parsed
/// and validated directly (used by the tests).
const EndpointStyle = enum { placeholder, example };

fn writeEndpoint(b: *Buf, style: EndpointStyle, label: []const u8, octet: u32, port: u16) void {
    switch (style) {
        .placeholder => b.print("REPLACE_{s}_IP:{d}", .{ label, port }),
        .example => b.print("203.0.113.{d}:{d}", .{ octet, port }),
    }
}

const Params = struct {
    spokes: usize,
    addr_prefix: []const u8, // first three octets, e.g. "10.0.0"
    subnet: []const u8,
    port: u16,
    mtu: u16,
};

/// Build the hub document. Spoke k has mesh id k+1 and source 10.x.y.(k+1)/32.
fn buildHub(out: []u8, p: Params, keys: []const HexKey, style: EndpointStyle) []const u8 {
    var b = Buf{ .data = out };
    b.print(
        "{{\n  \"role\": \"hub\",\n  \"local_id\": 1,\n  \"local_tun_mtu\": {d},\n  \"listen_port\": {d},\n  \"virtual_subnet\": \"{s}\",\n  \"peers\": [\n",
        .{ p.mtu, p.port, p.subnet },
    );
    var k: usize = 0;
    while (k < p.spokes) : (k += 1) {
        const id: u32 = @intCast(k + 2);
        b.print("    {{ \"id\": {d}, \"endpoint\": \"", .{id});
        writeEndpoint(&b, style, "SPOKE", id, p.port);
        b.print("\", \"allowed_src\": \"{s}.{d}/32\", \"psk\": \"{s}\" }}{s}\n", .{
            p.addr_prefix, id, keys[k], if (k + 1 < p.spokes) "," else "",
        });
    }
    b.print("  ]\n}}\n", .{});
    return b.slice();
}

/// Build spoke k's document (k is 0-based; mesh id = k+2). Its single peer is the
/// hub (id 1); the shared PSK is keys[k], byte-identical to the hub's entry.
fn buildSpoke(out: []u8, k: usize, p: Params, keys: []const HexKey, style: EndpointStyle) []const u8 {
    const id: u32 = @intCast(k + 2);
    var b = Buf{ .data = out };
    b.print(
        "{{\n  \"role\": \"spoke\",\n  \"local_id\": {d},\n  \"local_tun_mtu\": {d},\n  \"listen_port\": {d},\n  \"virtual_subnet\": \"{s}\",\n  \"local_tun_ip\": \"{s}.{d}/24\",\n  \"peers\": [\n",
        .{ id, p.mtu, p.port, p.subnet, p.addr_prefix, id },
    );
    b.print("    {{ \"id\": 1, \"endpoint\": \"", .{});
    writeEndpoint(&b, style, "HUB", 1, p.port);
    b.print("\", \"allowed_src\": \"0.0.0.0/0\", \"psk\": \"{s}\" }}\n", .{keys[k]});
    b.print("  ]\n}}\n", .{});
    return b.slice();
}

/// Extract the first three octets of a dotted CIDR (e.g. "10.0.0.0/24" -> "10.0.0").
fn addrPrefix24(subnet: []const u8) ?[]const u8 {
    var dots: usize = 0;
    for (subnet, 0..) |c, i| {
        if (c == '.') {
            dots += 1;
            if (dots == 3) return subnet[0..i];
        }
    }
    return null;
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
        const v = std.fmt.bufPrint(&vbuf, "config-gen (subnetra v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    var spokes: usize = 2;
    if (flagValue(args, "--spokes")) |raw| {
        spokes = std.fmt.parseInt(usize, raw, 10) catch {
            writeErr(io, "config-gen: invalid --spokes value\n");
            return error.InvalidArgument;
        };
    }
    if (spokes < 1 or spokes > MAX_SPOKES) {
        writeErr(io, "config-gen: --spokes must be between 1 and 32\n");
        return error.InvalidArgument;
    }

    const subnet = flagValue(args, "--subnet") orelse "10.0.0.0/24";
    const addr_prefix = addrPrefix24(subnet) orelse {
        writeErr(io, "config-gen: --subnet must be a dotted IPv4 CIDR (e.g. 10.0.0.0/24)\n");
        return error.InvalidArgument;
    };
    const port: u16 = if (flagValue(args, "--port")) |raw|
        std.fmt.parseInt(u16, raw, 10) catch {
            writeErr(io, "config-gen: invalid --port value\n");
            return error.InvalidArgument;
        }
    else
        51820;
    const mtu: u16 = if (flagValue(args, "--mtu")) |raw|
        std.fmt.parseInt(u16, raw, 10) catch {
            writeErr(io, "config-gen: invalid --mtu value\n");
            return error.InvalidArgument;
        }
    else
        1400;

    // One fresh, per-link-unique PSK per spoke (fail closed on entropy error).
    var keys: [MAX_SPOKES]HexKey = undefined;
    var i: usize = 0;
    while (i < spokes) : (i += 1) {
        var raw: [32]u8 = undefined;
        io.randomSecure(&raw) catch {
            writeErr(io, "config-gen: secure entropy source unavailable\n");
            return error.EntropyUnavailable;
        };
        keys[i] = std.fmt.bytesToHex(raw, .lower);
    }

    const p = Params{ .spokes = spokes, .addr_prefix = addr_prefix, .subnet = subnet, .port = port, .mtu = mtu };

    var doc: [DOC_BUF]u8 = undefined;
    if (flagValue(args, "--out")) |dir| {
        try emitToDir(io, dir, p, keys[0..spokes]);
        var msg: [256]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "config-gen: wrote hub.json + {d} spoke file(s) to {s}/ (fill in the REPLACE_* endpoints)\n", .{ spokes, dir }) catch return;
        writeOut(io, m);
    } else {
        writeOut(io, "// ==== hub.json ====\n");
        writeOut(io, buildHub(&doc, p, keys[0..spokes], .placeholder));
        var k: usize = 0;
        while (k < spokes) : (k += 1) {
            var hdr: [64]u8 = undefined;
            writeOut(io, std.fmt.bufPrint(&hdr, "\n// ==== spoke-{d}.json ====\n", .{k + 1}) catch "\n");
            writeOut(io, buildSpoke(&doc, k, p, keys[0..spokes], .placeholder));
        }
    }
}

fn emitToDir(io: std.Io, dir: []const u8, p: Params, keys: []const HexKey) !void {
    var doc: [DOC_BUF]u8 = undefined;
    var path: [512]u8 = undefined;

    const hub_path = try std.fmt.bufPrint(&path, "{s}/hub.json", .{dir});
    try writeFile(io, hub_path, buildHub(&doc, p, keys, .placeholder));

    var k: usize = 0;
    while (k < p.spokes) : (k += 1) {
        const sp = try std.fmt.bufPrint(&path, "{s}/spoke-{d}.json", .{ dir, k + 1 });
        try writeFile(io, sp, buildSpoke(&doc, k, p, keys, .placeholder));
    }
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn hasFlag(args: std.process.Args, flag: []const u8) bool {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn flagValue(args: std.process.Args, flag: []const u8) ?[]const u8 {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return it.next();
    }
    return null;
}

// --- tests -----------------------------------------------------------------

fn testKeys(n: usize, buf: []HexKey) void {
    var k: usize = 0;
    while (k < n) : (k += 1) {
        // Distinct, valid 64-hex keys; byte k repeated so each link differs.
        const raw = [_]u8{@intCast(0x10 + k)} ** 32;
        buf[k] = std.fmt.bytesToHex(raw, .lower);
    }
}

test "generated hub + spoke docs parse and validate once endpoints are real" {
    const allocator = std.testing.allocator;
    var keys: [MAX_SPOKES]HexKey = undefined;
    const n: usize = 3;
    testKeys(n, &keys);
    const p = Params{ .spokes = n, .addr_prefix = "10.0.0", .subnet = "10.0.0.0/24", .port = 51820, .mtu = 1400 };

    var doc: [DOC_BUF]u8 = undefined;

    // Hub: example endpoints make it directly parseable + validatable.
    {
        const hub = buildHub(&doc, p, keys[0..n], .example);
        const cfg = try bt.config.Config.fromJson(allocator, hub);
        try cfg.validate(&.{});
        try std.testing.expectEqual(@as(usize, n), cfg.peer_count);
        _ = try bt.peer.PeerRegistry.fromConfig(cfg, bt.protocol_vectors.MIN_EPOCH);
    }

    // Each spoke validates and carries the SAME PSK as the hub's entry for it.
    var k: usize = 0;
    while (k < n) : (k += 1) {
        var sdoc: [DOC_BUF]u8 = undefined;
        const spoke = buildSpoke(&sdoc, k, p, keys[0..n], .example);
        const cfg = try bt.config.Config.fromJson(allocator, spoke);
        try cfg.validate(&.{});
        try std.testing.expectEqual(@as(usize, 1), cfg.peer_count);

        // Symmetry: spoke's hub-link PSK == hub's spoke-link PSK == keys[k].
        var expect: bt.config.Psk = undefined;
        _ = try std.fmt.hexToBytes(&expect, &keys[k]);
        try std.testing.expectEqualSlices(u8, &expect, &cfg.peers[0].psk);
    }
}

test "link PSKs are unique across spokes" {
    var keys: [MAX_SPOKES]HexKey = undefined;
    testKeys(3, &keys);
    try std.testing.expect(!std.mem.eql(u8, &keys[0], &keys[1]));
    try std.testing.expect(!std.mem.eql(u8, &keys[1], &keys[2]));
}
