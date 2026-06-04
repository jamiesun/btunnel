//! crypto-bench — offline AEAD/KDF microbenchmark (issue #66).
//!
//! Measures the per-packet crypto cost that bounds a single node's packet rate:
//! ChaCha20-Poly1305 `seal`/`open` plus the Blake2b-256 key-derivation steps,
//! using the LIVE `crypto` primitives. It does NO network I/O; the numbers are an
//! upper bound (crypto cost only) for capacity planning on constrained targets.
//! NOT part of the shipped daemon (built via `zig build tool:crypto-bench`).

const std = @import("std");
const builtin = @import("builtin");
const bt = @import("btunnel");
const build_options = @import("build_options");

const crypto = bt.crypto;
const MAX_PLAINTEXT = bt.reactor.MAX_PLAINTEXT;
const TAG_LEN = crypto.TAG_LEN;

const USAGE =
    \\Usage: crypto-bench [--size BYTES] [--iters N]
    \\
    \\Microbenchmark btunnel's AEAD seal/open and key-derivation primitives.
    \\Reports an upper bound (crypto cost only) for capacity planning.
    \\
    \\  --size BYTES   plaintext size per op (default 1400, max 1452)
    \\  --iters N      iterations per measurement (default 200000)
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

fn nowNs(io: std.Io) i128 {
    const t = std.Io.Timestamp.now(io, .awake);
    return @intCast(t.nanoseconds);
}

/// seal(plaintext) then open() and assert the round-trip recovers the input.
/// Run once before timing so a broken build can never report bogus throughput.
fn roundTripOk(key: crypto.Key, pt: []const u8, ctbuf: []u8, outbuf: []u8) bool {
    const n = crypto.seal(key, 1, pt, ctbuf);
    const m = crypto.open(key, 1, ctbuf[0..n], outbuf) catch return false;
    return std.mem.eql(u8, pt, outbuf[0..m]);
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
        const v = std.fmt.bufPrint(&vbuf, "crypto-bench (btunnel v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    var size: usize = 1400;
    if (flagValue(args, "--size")) |raw| {
        size = std.fmt.parseInt(usize, raw, 10) catch {
            writeErr(io, "crypto-bench: invalid --size value\n");
            return error.InvalidArgument;
        };
    }
    if (size < 1) size = 1;
    if (size > MAX_PLAINTEXT) size = MAX_PLAINTEXT;

    var iters: usize = 200_000;
    if (flagValue(args, "--iters")) |raw| {
        iters = std.fmt.parseInt(usize, raw, 10) catch {
            writeErr(io, "crypto-bench: invalid --iters value\n");
            return error.InvalidArgument;
        };
        if (iters == 0) {
            writeErr(io, "crypto-bench: --iters must be >= 1\n");
            return error.InvalidArgument;
        }
    }

    const key: crypto.Key = [_]u8{0x42} ** crypto.KEY_LEN;
    var pt: [MAX_PLAINTEXT]u8 = undefined;
    for (pt[0..size], 0..) |*b, i| b.* = @intCast(i & 0xff);
    var ct: [MAX_PLAINTEXT + TAG_LEN]u8 = undefined;
    var out: [MAX_PLAINTEXT]u8 = undefined;

    if (!roundTripOk(key, pt[0..size], &ct, &out)) {
        writeErr(io, "crypto-bench: seal/open round-trip self-check FAILED — aborting\n");
        return error.SelfCheckFailed;
    }

    var hdr: [256]u8 = undefined;
    writeOut(io, std.fmt.bufPrint(&hdr, "crypto-bench: arch={s} optimize={s} size={d}B iters={d}\n", .{
        @tagName(builtin.cpu.arch), @tagName(builtin.mode), size, iters,
    }) catch "");

    // seal
    {
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const n = crypto.seal(key, @intCast(i + 1), pt[0..size], &ct);
            std.mem.doNotOptimizeAway(ct[n - 1]);
        }
        report(io, "seal ", iters, size, nowNs(io) - t0);
    }

    // open (seal once up front, then time repeated opens of the same datagram)
    {
        const n = crypto.seal(key, 7, pt[0..size], &ct);
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const m = crypto.open(key, 7, ct[0..n], &out) catch unreachable;
            std.mem.doNotOptimizeAway(out[m - 1]);
        }
        report(io, "open ", iters, size, nowNs(io) - t0);
    }

    // deriveLinkKey
    {
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const lk = crypto.deriveLinkKey(key, @intCast(i), 1);
            std.mem.doNotOptimizeAway(lk[0]);
        }
        reportKdf(io, "deriveLinkKey   ", iters, nowNs(io) - t0);
    }

    // deriveSessionKey
    {
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const sk = crypto.deriveSessionKey(key, @intCast(i));
            std.mem.doNotOptimizeAway(sk[0]);
        }
        reportKdf(io, "deriveSessionKey", iters, nowNs(io) - t0);
    }
}

fn report(io: std.Io, label: []const u8, iters: usize, size: usize, ns: i128) void {
    const ns_f: f64 = @floatFromInt(@max(ns, 1));
    const iters_f: f64 = @floatFromInt(iters);
    const ops_per_sec = iters_f * 1e9 / ns_f;
    const mb_per_sec = iters_f * @as(f64, @floatFromInt(size)) / (ns_f / 1e9) / 1e6;
    var buf: [160]u8 = undefined;
    writeOut(io, std.fmt.bufPrint(&buf, "  {s}: {d:.0} ops/sec, {d:.1} MB/sec, {d:.1} ns/op\n", .{
        label, ops_per_sec, mb_per_sec, ns_f / iters_f,
    }) catch "");
}

fn reportKdf(io: std.Io, label: []const u8, iters: usize, ns: i128) void {
    const ns_f: f64 = @floatFromInt(@max(ns, 1));
    const iters_f: f64 = @floatFromInt(iters);
    var buf: [160]u8 = undefined;
    writeOut(io, std.fmt.bufPrint(&buf, "  {s}: {d:.0} ops/sec, {d:.1} ns/op\n", .{
        label, iters_f * 1e9 / ns_f, ns_f / iters_f,
    }) catch "");
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

test "seal/open round-trip self-check helper holds" {
    const key: crypto.Key = [_]u8{0x42} ** crypto.KEY_LEN;
    var pt: [64]u8 = undefined;
    for (&pt, 0..) |*b, i| b.* = @intCast(i);
    var ct: [64 + TAG_LEN]u8 = undefined;
    var out: [64]u8 = undefined;
    try std.testing.expect(roundTripOk(key, &pt, &ct, &out));

    // A tampered ciphertext must fail the round-trip.
    const n = crypto.seal(key, 1, &pt, &ct);
    ct[0] ^= 0xff;
    try std.testing.expect((crypto.open(key, 1, ct[0..n], &out) catch null) == null);
}
