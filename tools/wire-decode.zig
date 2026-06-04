//! wire-decode — offline, read-only datagram inspector (issue #60).
//!
//! Takes a captured btunnel datagram (hex), the link PSK (64-hex), and the
//! sender/receiver mesh ids, then reuses the LIVE protocol + crypto code to
//! parse the header, derive the session key, and authenticate/decrypt the body
//! — so the decoder can never drift from the wire format. It prints the header
//! fields, an explicit "auth OK"/"auth FAIL" line, and (on success) the inner
//! IPv4 5-tuple.
//!
//! This is a LOCAL operator diagnostic, not an on-wire behaviour: the daemon
//! drops silently on auth failure for stealth (AGENT.md iron law #4), but here
//! printing the result is fine because nothing is emitted to the network. It
//! requires the PSK, so it grants no capability an operator who already holds
//! the link secret lacks — never paste a production PSK into a shared log. It is
//! NOT part of the shipped daemon (built via `zig build tool:wire-decode`).

const std = @import("std");
const bt = @import("btunnel");
const build_options = @import("build_options");

const reactor = bt.reactor;
const crypto = bt.crypto;

const HEADER_LEN = reactor.HEADER_LEN; // 20
const MAX_WIRE = reactor.MAX_WIRE;
const MAX_PLAINTEXT = reactor.MAX_PLAINTEXT;

const USAGE =
    \\Usage: wire-decode --data <hex> --psk <64hex> --to <id> [--from <id>]
    \\
    \\Parse and authenticate a single captured btunnel datagram offline.
    \\
    \\  --data <hex>   the raw datagram bytes as hex (e.g. from tcpdump)
    \\  --psk  <hex>   the link's 64-char hex pre-shared key
    \\  --to   <id>    the receiver's mesh id (this node's local_id)
    \\  --from <id>    the sender's mesh id (defaults to the header key_id)
    \\  -h, --help     show this help
    \\  -V, --version  show version
    \\
;

const Header = struct {
    version: u8,
    flags: u8,
    key_id: u16,
    epoch: u64,
    seq: u64,
};

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

fn parseHeader(datagram: []const u8) !Header {
    if (datagram.len < HEADER_LEN) return error.TooShort;
    return .{
        .version = datagram[0],
        .flags = datagram[1],
        .key_id = std.mem.readInt(u16, datagram[2..][0..2], .little),
        .epoch = std.mem.readInt(u64, datagram[4..][0..8], .little),
        .seq = std.mem.readInt(u64, datagram[12..][0..8], .little),
    };
}

/// Derive the receive session key for `(from -> to)` exactly as the daemon does
/// (`deriveLinkKey` then `deriveSessionKey`) and authenticate/decrypt the body
/// into `out`. Returns the recovered plaintext length, or `error.AuthFailed`.
fn openInner(datagram: []const u8, psk: crypto.Key, from_id: u32, to_id: u32, out: []u8) !usize {
    const hdr = try parseHeader(datagram);
    const link_key = crypto.deriveLinkKey(psk, from_id, to_id);
    const skey = crypto.deriveSessionKey(link_key, hdr.epoch);
    const ct = datagram[HEADER_LEN..];
    return crypto.open(skey, hdr.seq, ct, out) catch error.AuthFailed;
}

fn fmtIpv4(buf: []u8, be: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ be[0], be[1], be[2], be[3] }) catch buf[0..0];
}

fn printInner(io: std.Io, pkt: []const u8) void {
    if (pkt.len < 20 or (pkt[0] >> 4) != 4) {
        writeOut(io, "  inner: not an IPv4 packet\n");
        return;
    }
    const ihl: usize = @as(usize, pkt[0] & 0x0f) * 4;
    const proto = pkt[9];
    var sbuf: [16]u8 = undefined;
    var dbuf: [16]u8 = undefined;
    const src = fmtIpv4(&sbuf, pkt[12..16]);
    const dst = fmtIpv4(&dbuf, pkt[16..20]);

    var line: [160]u8 = undefined;
    if ((proto == 6 or proto == 17) and pkt.len >= ihl + 4) {
        const sport = std.mem.readInt(u16, pkt[ihl..][0..2], .big);
        const dport = std.mem.readInt(u16, pkt[ihl + 2 ..][0..2], .big);
        const msg = std.fmt.bufPrint(&line, "  inner: IPv4 {s}:{d} -> {s}:{d} proto={d} len={d}\n", .{ src, sport, dst, dport, proto, pkt.len }) catch return;
        writeOut(io, msg);
    } else {
        const msg = std.fmt.bufPrint(&line, "  inner: IPv4 {s} -> {s} proto={d} len={d}\n", .{ src, dst, proto, pkt.len }) catch return;
        writeOut(io, msg);
    }
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
        const v = std.fmt.bufPrint(&vbuf, "wire-decode (btunnel v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    const data_hex = flagValue(args, "--data") orelse {
        writeErr(io, "wire-decode: --data <hex> is required\n");
        return error.InvalidArgument;
    };
    const psk_hex = flagValue(args, "--psk") orelse {
        writeErr(io, "wire-decode: --psk <64hex> is required\n");
        return error.InvalidArgument;
    };
    const to_raw = flagValue(args, "--to") orelse {
        writeErr(io, "wire-decode: --to <id> is required\n");
        return error.InvalidArgument;
    };

    var dbuf: [MAX_WIRE]u8 = undefined;
    const datagram = std.fmt.hexToBytes(&dbuf, data_hex) catch {
        writeErr(io, "wire-decode: --data is not valid hex (or too long)\n");
        return error.InvalidArgument;
    };

    if (psk_hex.len != 64) {
        writeErr(io, "wire-decode: --psk must be 64 hex chars\n");
        return error.InvalidArgument;
    }
    var psk: crypto.Key = undefined;
    _ = std.fmt.hexToBytes(&psk, psk_hex) catch {
        writeErr(io, "wire-decode: --psk is not valid hex\n");
        return error.InvalidArgument;
    };

    const to_id = std.fmt.parseInt(u32, to_raw, 10) catch {
        writeErr(io, "wire-decode: --to must be an integer\n");
        return error.InvalidArgument;
    };

    const hdr = parseHeader(datagram) catch {
        writeErr(io, "wire-decode: datagram too short to hold a header\n");
        return error.TooShort;
    };
    const from_id: u32 = if (flagValue(args, "--from")) |raw|
        std.fmt.parseInt(u32, raw, 10) catch {
            writeErr(io, "wire-decode: --from must be an integer\n");
            return error.InvalidArgument;
        }
    else
        hdr.key_id;

    var hbuf: [256]u8 = undefined;
    const hmsg = std.fmt.bufPrint(&hbuf, "header: version={d} flags={d} key_id={d} epoch={d} seq={d}\n", .{
        hdr.version, hdr.flags, hdr.key_id, hdr.epoch, hdr.seq,
    }) catch return;
    writeOut(io, hmsg);

    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = openInner(datagram, psk, from_id, to_id, &out) catch {
        writeOut(io, "auth FAIL (wrong PSK/ids, tampered, or truncated)\n");
        return error.AuthFailed;
    };
    writeOut(io, "auth OK\n");
    printInner(io, out[0..plen]);
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

const TEST_PSK: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;
const TEST_FROM: u32 = 2;
const TEST_TO: u32 = 1;
const TEST_EPOCH: u64 = bt.protocol_vectors.MIN_EPOCH;
const TEST_SEQ: u64 = 7;
// A minimal well-formed IPv4 header: src 10.0.0.2 -> dst 10.0.0.3.
const TEST_INNER = [_]u8{
    0x45, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x40, 0x01, 0x00, 0x00,
    10,   0,    0,    2,    10,   0,    0,    3,
};

fn buildDatagram(out: []u8) usize {
    const link = crypto.deriveLinkKey(TEST_PSK, TEST_FROM, TEST_TO);
    const skey = crypto.deriveSessionKey(link, TEST_EPOCH);
    out[0] = reactor.WIRE_VERSION;
    out[1] = 0;
    std.mem.writeInt(u16, out[2..][0..2], @intCast(TEST_FROM), .little);
    std.mem.writeInt(u64, out[4..][0..8], TEST_EPOCH, .little);
    std.mem.writeInt(u64, out[12..][0..8], TEST_SEQ, .little);
    const sealed = crypto.seal(skey, TEST_SEQ, &TEST_INNER, out[HEADER_LEN..]);
    return HEADER_LEN + sealed;
}

test "parseHeader recovers the wire fields" {
    var wire: [MAX_WIRE]u8 = undefined;
    const n = buildDatagram(&wire);
    const hdr = try parseHeader(wire[0..n]);
    try std.testing.expectEqual(reactor.WIRE_VERSION, hdr.version);
    try std.testing.expectEqual(@as(u8, 0), hdr.flags);
    try std.testing.expectEqual(@as(u16, @intCast(TEST_FROM)), hdr.key_id);
    try std.testing.expectEqual(TEST_EPOCH, hdr.epoch);
    try std.testing.expectEqual(TEST_SEQ, hdr.seq);
}

test "openInner authenticates and recovers the inner packet" {
    var wire: [MAX_WIRE]u8 = undefined;
    const n = buildDatagram(&wire);
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = try openInner(wire[0..n], TEST_PSK, TEST_FROM, TEST_TO, &out);
    try std.testing.expectEqualSlices(u8, &TEST_INNER, out[0..plen]);
}

test "openInner fails on a tampered ciphertext" {
    var wire: [MAX_WIRE]u8 = undefined;
    const n = buildDatagram(&wire);
    wire[HEADER_LEN] ^= 0x01; // flip a ciphertext byte
    var out: [MAX_PLAINTEXT]u8 = undefined;
    try std.testing.expectError(error.AuthFailed, openInner(wire[0..n], TEST_PSK, TEST_FROM, TEST_TO, &out));
}

test "openInner fails under the wrong receiver id" {
    var wire: [MAX_WIRE]u8 = undefined;
    const n = buildDatagram(&wire);
    var out: [MAX_PLAINTEXT]u8 = undefined;
    try std.testing.expectError(error.AuthFailed, openInner(wire[0..n], TEST_PSK, TEST_FROM, TEST_TO + 1, &out));
}
