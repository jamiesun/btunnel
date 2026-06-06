//! wire-decode — offline, read-only datagram inspector (issue #60).
//!
//! Takes a captured subnetra datagram (hex), the link PSK (64-hex), and the
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
const bt = @import("subnetra");
const build_options = @import("build_options");

const reactor = bt.reactor;
const crypto = bt.crypto;

const HEADER_LEN = reactor.HEADER_LEN; // 20
const MAX_WIRE = reactor.MAX_WIRE;
const MAX_PLAINTEXT = reactor.MAX_PLAINTEXT;

const USAGE =
    \\Usage:
    \\  wire-decode --data <hex> --psk <64hex> --to <id> [--from <id>]
    \\  wire-decode --stream --key <from:to:64hex> [--key ...]   (reads hex datagrams, one per line, from stdin)
    \\
    \\Parse and authenticate captured subnetra datagram(s) offline.
    \\
    \\Single datagram:
    \\  --data <hex>   the raw datagram bytes as hex (e.g. from tcpdump)
    \\  --psk  <hex>   the link's 64-char hex pre-shared key
    \\  --to   <id>    the receiver's mesh id (this node's local_id)
    \\  --from <id>    the sender's mesh id (defaults to the header key_id)
    \\
    \\Bulk (stdin, one hex datagram per line):
    \\  --stream       decode every line of stdin, selecting the key by header key_id
    \\  --key <f:t:k>  a link key as sender_id:receiver_id:64hex_psk (repeatable, max 16)
    \\
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

const MAX_KEYS = 16;

/// A directional link key for bulk decoding: the sender id (matched against the
/// header `key_id`), the receiver id, and the link PSK.
const KeyEntry = struct { from: u32, to: u32, psk: crypto.Key };

/// Per-datagram outcome in bulk mode.
const Class = enum { decoded, auth_failed, no_key, skipped };

const Tally = struct {
    decoded: usize = 0,
    auth_failed: usize = 0,
    no_key: usize = 0,
    skipped: usize = 0,
};

/// Classify one datagram against the key map: skip non-subnetra/too-short input,
/// report when no key matches its `key_id`, otherwise try every key whose sender
/// id matches and return `decoded` (with `plen`) on the first that authenticates.
fn classify(datagram: []const u8, keys: []const KeyEntry, out: []u8, plen: *usize) Class {
    const hdr = parseHeader(datagram) catch return .skipped;
    if (hdr.version != reactor.WIRE_VERSION) return .skipped;

    var matched = false;
    for (keys) |k| {
        if (k.from != hdr.key_id) continue;
        matched = true;
        if (openInner(datagram, k.psk, k.from, k.to, out)) |n| {
            plen.* = n;
            return .decoded;
        } else |_| {}
    }
    if (!matched) return .no_key;
    return .auth_failed;
}

/// Parse repeated `--key <from>:<to>:<64hex>` arguments into `buf`.
fn parseKeys(args: std.process.Args, buf: []KeyEntry) !usize {
    var n: usize = 0;
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (!std.mem.eql(u8, a, "--key")) continue;
        const spec = it.next() orelse return error.InvalidArgument;
        if (n >= buf.len) return error.TooManyKeys;

        var parts = std.mem.splitScalar(u8, spec, ':');
        const from_s = parts.next() orelse return error.InvalidArgument;
        const to_s = parts.next() orelse return error.InvalidArgument;
        const psk_s = parts.next() orelse return error.InvalidArgument;
        if (parts.next() != null) return error.InvalidArgument;
        if (psk_s.len != 64) return error.InvalidArgument;

        var entry: KeyEntry = undefined;
        entry.from = std.fmt.parseInt(u32, from_s, 10) catch return error.InvalidArgument;
        entry.to = std.fmt.parseInt(u32, to_s, 10) catch return error.InvalidArgument;
        _ = std.fmt.hexToBytes(&entry.psk, psk_s) catch return error.InvalidArgument;
        buf[n] = entry;
        n += 1;
    }
    return n;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r\n");
}

/// Bulk mode: decode every newline-delimited hex datagram from stdin, selecting
/// the link key by header `key_id`, and print a per-record result plus a tally.
fn runStream(io: std.Io, args: std.process.Args) !void {
    var key_buf: [MAX_KEYS]KeyEntry = undefined;
    const nkeys = parseKeys(args, &key_buf) catch {
        writeErr(io, "wire-decode: invalid --key (expected from:to:64hex, max 16)\n");
        return error.InvalidArgument;
    };
    if (nkeys == 0) {
        writeErr(io, "wire-decode: --stream needs at least one --key from:to:64hex\n");
        return error.InvalidArgument;
    }
    const keys = key_buf[0..nkeys];

    // Read all of stdin into a fixed buffer (a capture pasted/piped as hex lines).
    var in_buf: [1 << 20]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var total: usize = 0;
    while (total < in_buf.len) {
        const n = stdin.readStreaming(io, &.{in_buf[total..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
    }

    var tally = Tally{};
    var dbuf: [MAX_WIRE]u8 = undefined;
    var out: [MAX_PLAINTEXT]u8 = undefined;
    var index: usize = 0;

    var lines = std.mem.splitScalar(u8, in_buf[0..total], '\n');
    while (lines.next()) |raw_line| {
        const line = trimLine(raw_line);
        if (line.len == 0) continue;
        index += 1;

        const datagram = std.fmt.hexToBytes(&dbuf, line) catch {
            tally.skipped += 1;
            var b: [64]u8 = undefined;
            writeOut(io, std.fmt.bufPrint(&b, "[{d}] skipped (not hex)\n", .{index}) catch "");
            continue;
        };

        var plen: usize = 0;
        const class = classify(datagram, keys, &out, &plen);
        var b: [256]u8 = undefined;
        switch (class) {
            .decoded => {
                tally.decoded += 1;
                const hdr = parseHeader(datagram) catch unreachable;
                writeOut(io, std.fmt.bufPrint(&b, "[{d}] auth OK   key_id={d} epoch={d} seq={d}\n", .{ index, hdr.key_id, hdr.epoch, hdr.seq }) catch "");
                printInner(io, out[0..plen]);
            },
            .auth_failed => {
                tally.auth_failed += 1;
                writeOut(io, std.fmt.bufPrint(&b, "[{d}] auth FAIL (key matched key_id but did not authenticate)\n", .{index}) catch "");
            },
            .no_key => {
                tally.no_key += 1;
                const hdr = parseHeader(datagram) catch unreachable;
                writeOut(io, std.fmt.bufPrint(&b, "[{d}] no key for key_id={d}\n", .{ index, hdr.key_id }) catch "");
            },
            .skipped => {
                tally.skipped += 1;
                writeOut(io, std.fmt.bufPrint(&b, "[{d}] skipped (not a v1 subnetra datagram)\n", .{index}) catch "");
            },
        }
    }

    var sbuf: [256]u8 = undefined;
    writeOut(io, std.fmt.bufPrint(&sbuf, "\nsummary: decoded={d} auth_failed={d} no_key={d} skipped={d}\n", .{
        tally.decoded, tally.auth_failed, tally.no_key, tally.skipped,
    }) catch "");
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
        const v = std.fmt.bufPrint(&vbuf, "wire-decode (subnetra v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    if (hasFlag(args, "--stream")) {
        return runStream(io, args);
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

test "classify selects the key by key_id and reports the bulk outcomes" {
    const keys = [_]KeyEntry{.{ .from = TEST_FROM, .to = TEST_TO, .psk = TEST_PSK }};
    var out: [MAX_PLAINTEXT]u8 = undefined;
    var plen: usize = 0;

    // A good datagram authenticates.
    var good: [MAX_WIRE]u8 = undefined;
    const gn = buildDatagram(&good);
    try std.testing.expectEqual(Class.decoded, classify(good[0..gn], &keys, &out, &plen));
    try std.testing.expectEqualSlices(u8, &TEST_INNER, out[0..plen]);

    // A tampered datagram matches the key_id but fails authentication.
    var bad: [MAX_WIRE]u8 = undefined;
    const bn = buildDatagram(&bad);
    bad[HEADER_LEN] ^= 0x01;
    try std.testing.expectEqual(Class.auth_failed, classify(bad[0..bn], &keys, &out, &plen));

    // No key whose sender id matches the header key_id.
    const other = [_]KeyEntry{.{ .from = TEST_FROM + 9, .to = TEST_TO, .psk = TEST_PSK }};
    try std.testing.expectEqual(Class.no_key, classify(good[0..gn], &other, &out, &plen));

    // A non-v1 datagram is skipped.
    var alien: [MAX_WIRE]u8 = undefined;
    const an = buildDatagram(&alien);
    alien[0] = reactor.WIRE_VERSION +% 1;
    try std.testing.expectEqual(Class.skipped, classify(alien[0..an], &keys, &out, &plen));

    // Too-short input is skipped.
    try std.testing.expectEqual(Class.skipped, classify(good[0 .. HEADER_LEN - 1], &keys, &out, &plen));
}
