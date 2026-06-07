//! udp-blast — saturating UDP load generator for the data-plane benchmark (issue #97).
//!
//! Sends fixed-size UDP datagrams to a destination as fast as the kernel accepts
//! them, for a bounded duration, then reports the OFFERED load (packets, bytes,
//! pps, Gbps). It is the traffic source for `test/integration/bench.sh`: run inside
//! a spoke's network namespace, it injects overlay traffic into `snr0` so the
//! daemon's real tun-read -> seal -> udp-send path (and, for the relay variant, the
//! hub's udp-recv -> udp-send path) is exercised end to end. The reproducible
//! pps/throughput ceiling is then read from each daemon's OWN counters
//! (`subnetra status`), not from this tool's self-report — this number is only the
//! offered load, the upper bound the daemon is pushed against.
//!
//! Why an in-tree blaster (not iperf3): issue #97 explicitly allows "a tiny in-tree
//! UDP blaster", and a dependency-free, deterministic, `ReleaseFast` generator makes
//! the CI baseline reproducible without installing a host tool. `iperf3` remains the
//! richer host-tool option documented for live-overlay field measurement (issue #102,
//! deployment.md §10).
//!
//! It is NOT part of the shipped daemon (built via `zig build tool:udp-blast`, never
//! installed by default) and opens exactly one connected UDP socket — no allocation,
//! no config, no control plane.

const std = @import("std");
const builtin = @import("builtin");
const bt = @import("subnetra");
const build_options = @import("build_options");

const config = bt.config;
const sys = bt.sys;

/// UDP payload size that makes the inner IPv4 packet exactly the snr0 MTU (1400):
/// 1400 - 20 (IPv4) - 8 (UDP) = 1372.
const DEFAULT_PAYLOAD = 1372;
/// Per-datagram L3+L4 overhead added to the UDP payload to get the inner packet size.
const IP_UDP_OVERHEAD = 28;
/// Largest payload we will craft (one resident buffer, no allocation).
const MAX_PAYLOAD = 65507;
/// Check the wall clock once per this many sends so `clock` cost never dominates.
const TIME_CHECK_STRIDE = 1024;

const USAGE =
    \\Usage: udp-blast --dst IP:PORT [--size BYTES] [--secs N] [--count N]
    \\
    \\Saturating UDP load generator for the data-plane benchmark (issue #97). Sends
    \\fixed-size datagrams as fast as the kernel accepts them and reports the OFFERED
    \\load. Run it inside a spoke netns so traffic enters the overlay via snr0; read
    \\the achieved pps/throughput from each daemon's own `subnetra status` counters.
    \\
    \\  --dst IP:PORT  destination (required), e.g. 10.0.0.3:9
    \\  --size BYTES   UDP payload per datagram (default 1372 -> 1400B inner = snr0 MTU)
    \\  --secs N       blast duration in seconds (default 5)
    \\  --count N      stop after N datagrams (default 0 = unbounded, time-only)
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

/// Offered-load arithmetic, isolated for unit testing (no I/O).
const Report = struct {
    sent: u64,
    bytes: u64,
    elapsed_ns: i128,

    fn pps(self: Report) f64 {
        const s = self.seconds();
        return if (s > 0) @as(f64, @floatFromInt(self.sent)) / s else 0;
    }

    fn gbps(self: Report) f64 {
        const s = self.seconds();
        return if (s > 0) @as(f64, @floatFromInt(self.bytes)) * 8.0 / s / 1e9 else 0;
    }

    fn seconds(self: Report) f64 {
        const ns: f64 = @floatFromInt(@max(self.elapsed_ns, 1));
        return ns / 1e9;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;

    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        writeOut(io, USAGE);
        return;
    }
    if (hasFlag(args, "--version") or hasFlag(args, "-V")) {
        var vbuf: [80]u8 = undefined;
        const v = std.fmt.bufPrint(&vbuf, "udp-blast (subnetra v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    const dst_str = flagValue(args, "--dst") orelse {
        writeErr(io, "udp-blast: --dst IP:PORT is required (e.g. --dst 10.0.0.3:9)\n");
        return error.InvalidArgument;
    };
    const dest = config.parseEndpoint(dst_str) catch {
        writeErr(io, "udp-blast: invalid --dst (want IP:PORT with a nonzero port, e.g. 10.0.0.3:9)\n");
        return error.InvalidArgument;
    };

    var size: usize = DEFAULT_PAYLOAD;
    if (flagValue(args, "--size")) |raw| {
        size = std.fmt.parseInt(usize, raw, 10) catch {
            writeErr(io, "udp-blast: invalid --size value\n");
            return error.InvalidArgument;
        };
        if (size < 1) size = 1;
        if (size > MAX_PAYLOAD) size = MAX_PAYLOAD;
    }

    var secs: u64 = 5;
    if (flagValue(args, "--secs")) |raw| {
        secs = std.fmt.parseInt(u64, raw, 10) catch {
            writeErr(io, "udp-blast: invalid --secs value\n");
            return error.InvalidArgument;
        };
        if (secs == 0) secs = 1;
    }

    var count: u64 = 0; // 0 == unbounded (time-bounded only)
    if (flagValue(args, "--count")) |raw| {
        count = std.fmt.parseInt(u64, raw, 10) catch {
            writeErr(io, "udp-blast: invalid --count value\n");
            return error.InvalidArgument;
        };
    }

    // One resident, fixed payload buffer (no data-path allocation, mirroring the
    // daemon's discipline even though this is a test tool).
    var payload: [MAX_PAYLOAD]u8 = undefined;
    for (payload[0..size], 0..) |*b, i| b.* = @intCast(i & 0xff);

    const fd = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, false, true) catch {
        writeErr(io, "udp-blast: socket() failed\n");
        return error.SocketFailed;
    };
    defer _ = sys.close(fd);

    const addrlen: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    const deadline_ns = secs * std.time.ns_per_s;
    const sleep_on_backpressure = sys.timespec{ .sec = 0, .nsec = 50_000 }; // 50us

    var sent: u64 = 0;
    var send_errs: u64 = 0;
    const t0 = nowNs(io);
    var elapsed: i128 = 0;
    while (true) {
        const rc = sys.sendto(fd, &payload, size, 0, @ptrCast(&dest), addrlen);
        if (sys.errno(rc) == .SUCCESS) {
            sent += 1;
        } else {
            // Under saturation a UDP send to a full device queue returns ENOBUFS
            // (or EAGAIN); pause briefly so we don't hot-spin and starve the
            // daemon we are trying to measure, then keep offering load.
            send_errs += 1;
            _ = sys.nanosleep(&sleep_on_backpressure, null);
        }

        if (count != 0 and sent >= count) {
            elapsed = nowNs(io) - t0;
            break;
        }
        // Amortize the clock read across a batch of sends.
        if ((sent + send_errs) % TIME_CHECK_STRIDE == 0) {
            elapsed = nowNs(io) - t0;
            if (elapsed >= deadline_ns) break;
        }
    }
    if (elapsed <= 0) elapsed = nowNs(io) - t0;

    const rep = Report{ .sent = sent, .bytes = sent * size, .elapsed_ns = elapsed };
    var out: [320]u8 = undefined;
    writeOut(io, std.fmt.bufPrint(&out,
        "udp-blast: dst={s} payload={d}B inner={d}B secs={d:.2} sent={d} errs={d}\n" ++
        "  offered: {d:.0} pps, {d:.3} Gbps ({d} bytes)\n", .{
        dst_str, size, size + IP_UDP_OVERHEAD, rep.seconds(), sent, send_errs,
        rep.pps(), rep.gbps(), rep.bytes,
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

test "udp-blast destination parses to network byte order via the live config parser" {
    // The blaster reuses the daemon's own endpoint parser, so its target lands in
    // network byte order exactly like a configured peer endpoint.
    const ep = try config.parseEndpoint("10.0.0.3:9");
    const octets: [4]u8 = @bitCast(ep.addr);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 3 }, octets);
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 9), ep.port);
}

test "udp-blast offered-load arithmetic: pps and Gbps over a known window" {
    // 100000 datagrams of 1372B in exactly 1s -> 100000 pps and ~1.0976 Gbps.
    const rep = Report{ .sent = 100_000, .bytes = 100_000 * 1372, .elapsed_ns = std.time.ns_per_s };
    try std.testing.expectApproxEqAbs(@as(f64, 100_000), rep.pps(), 1.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0976), rep.gbps(), 0.0005);
    // A zero-length window must not divide by zero.
    const z = Report{ .sent = 0, .bytes = 0, .elapsed_ns = 0 };
    try std.testing.expectEqual(@as(f64, 0), z.pps());
    try std.testing.expectEqual(@as(f64, 0), z.gbps());
}

test "udp-blast inner-size accounting matches the snr0 MTU default" {
    try std.testing.expectEqual(@as(usize, 1400), DEFAULT_PAYLOAD + IP_UDP_OVERHEAD);
}
