//! mtu-probe — measure the REAL underlay path MTU between two nodes, then print
//! the safe subnetra tunnel MTU (issue #149).
//!
//! Why this exists: the daemon's `--print-network-plan` (issue #23) assumes a
//! 1500-byte underlay and derives `local_tun_mtu = 1436` from the live wire
//! constants. That assumption is wrong on PPPoE (1492), GRE/WireGuard-over-X,
//! mobile/CGNAT, and tunneled uplinks — and the classic fix, kernel Path MTU
//! Discovery, relies on routers returning ICMP "fragmentation needed". Those
//! ICMP messages are very commonly filtered (a "PMTU black hole"), which is
//! exactly the environment a censorship-resistant overlay runs in. So this tool
//! does NOT trust ICMP: it measures the path ACTIVELY, end to end, over plain
//! UDP, the same transport the data plane uses.
//!
//! How it works: a tiny request/response protocol between two copies of this
//! tool. On the far node you run the responder; on the near node the prober
//! binary-searches the largest UDP datagram that round-trips with the IPv4
//! Don't-Fragment bit set. A datagram larger than any hop's MTU is dropped (not
//! fragmented), so no ACK comes back — the absence of an ACK is the signal, and
//! it needs no ICMP. The largest payload that DOES round-trip + the 28-byte
//! IPv4/UDP header is the path MTU; subtracting subnetra's per-packet overhead
//! (`netplan.TUNNEL_OVERHEAD`, computed from the live header+tag sizes) gives the
//! `local_tun_mtu` you should configure.
//!
//!   # on the far node (e.g. the hub, reachable at its public endpoint):
//!   mtu-probe --listen 18020
//!   # on the near node:
//!   mtu-probe --probe 203.0.113.9:18020
//!
//! It is NOT part of the shipped daemon (built via `zig build tool:mtu-probe`,
//! never installed by default), opens its OWN plain UDP socket (never the tunnel
//! socket), allocates nothing on the probe path, and changes no host state.

const std = @import("std");
const builtin = @import("builtin");
const bt = @import("subnetra");
const build_options = @import("build_options");

const config = bt.config;
const sys = bt.sys;
const netplan = bt.netplan;

/// Outer IPv4(20)+UDP(8) header the underlay adds to our UDP payload. A probe of
/// payload P measures a path MTU of `P + OUTER`. Sourced from the live constant.
const OUTER = netplan.OUTER_OVERHEAD;
/// subnetra per-packet overhead (wire header + AEAD tag + outer IPv4/UDP),
/// derived from the live protocol so the recommendation can never drift.
const TUNNEL_OVERHEAD = netplan.TUNNEL_OVERHEAD;

/// Largest UDP payload we will ever craft — one resident buffer, no allocation.
const MAX_PAYLOAD = 65507;
/// Probe/ACK framing. Both carry a per-run nonce + per-probe seq so a delayed
/// ACK for one size is never miscounted for another. The ACK additionally
/// echoes the byte count the responder actually received (integrity guard).
const MAGIC = [4]u8{ 'S', 'M', 'T', 'U' };
const TYPE_PROBE: u8 = 1;
const TYPE_ACK: u8 = 2;
const HDR_LEN = 16; // magic(4)+type(1)+ver(1)+pad(2)+nonce(4)+seq(4)
const ACK_LEN = HDR_LEN + 4; // + received_len(4)
const PROTO_VER: u8 = 1;

/// Default underlay path-MTU search window (the on-wire IPv4 datagram size).
const DEFAULT_FLOOR: u16 = 576; // IPv4 minimum every host must handle
const DEFAULT_CEIL: u16 = 1500; // standard Ethernet; raise with --ceil for jumbo
const DEFAULT_LISTEN_PORT: u16 = 18020;
const DEFAULT_TIMEOUT_MS: u32 = 1000;
const DEFAULT_TRIES: u32 = 3;

const USAGE =
    \\Usage:
    \\  mtu-probe --listen [PORT]        run the responder (on the far node)
    \\  mtu-probe --probe IP:PORT        measure the path MTU to a responder
    \\
    \\Measures the REAL underlay path MTU between two nodes over plain UDP, with
    \\the IPv4 Don't-Fragment bit set, WITHOUT trusting ICMP (survives PMTU black
    \\holes). Then prints the safe subnetra `local_tun_mtu` for that path.
    \\
    \\Responder (--listen):
    \\  PORT             UDP port to bind on 0.0.0.0 (default 18020)
    \\  --secs N         exit after N seconds (default 0 = run until killed)
    \\
    \\Prober (--probe IP:PORT):
    \\  --floor N        smallest path MTU to test, bytes (default 576)
    \\  --ceil N         largest path MTU to test, bytes (default 1500)
    \\  --tries N        probes per size before declaring loss (default 3)
    \\  --timeout-ms N   per-probe ACK wait (default 1000)
    \\  --verbose        print each binary-search step
    \\
    \\Common:
    \\  -h, --help       show this help
    \\  -V, --version    show version
    \\
;

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
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

fn parseU32(args: std.process.Args, flag: []const u8, default: u32) u32 {
    if (flagValue(args, flag)) |raw| {
        return std.fmt.parseInt(u32, raw, 10) catch default;
    }
    return default;
}

// ---- pure, testable framing + bisection (no I/O) ----

/// Write the fixed 16-byte probe/ACK header into `buf`. Caller guarantees
/// `buf.len >= HDR_LEN`.
fn writeHeader(buf: []u8, kind: u8, nonce: u32, seq: u32) void {
    @memcpy(buf[0..4], &MAGIC);
    buf[4] = kind;
    buf[5] = PROTO_VER;
    buf[6] = 0;
    buf[7] = 0;
    std.mem.writeInt(u32, buf[8..12], nonce, .little);
    std.mem.writeInt(u32, buf[12..16], seq, .little);
}

/// Validate a datagram's header against the expected kind/nonce/seq. Returns
/// false for any foreign or stale datagram (fail-closed).
fn headerMatches(dgram: []const u8, kind: u8, nonce: u32, seq: u32) bool {
    if (dgram.len < HDR_LEN) return false;
    if (!std.mem.eql(u8, dgram[0..4], &MAGIC)) return false;
    if (dgram[4] != kind or dgram[5] != PROTO_VER) return false;
    if (std.mem.readInt(u32, dgram[8..12], .little) != nonce) return false;
    if (std.mem.readInt(u32, dgram[12..16], .little) != seq) return false;
    return true;
}

/// Binary search over the on-wire path MTU. `good` is the largest size confirmed
/// to round-trip; `next()` yields the midpoint to probe, `record()` folds the
/// result back in. Pure state machine so the search logic is unit-tested without
/// a network.
const Bisect = struct {
    lo: u16,
    hi: u16,
    good: u16 = 0,
    done: bool = false,

    fn init(floor: u16, ceil: u16) Bisect {
        return .{ .lo = floor, .hi = ceil };
    }

    fn next(self: *const Bisect) ?u16 {
        if (self.done or self.lo > self.hi) return null;
        return self.lo + (self.hi - self.lo) / 2;
    }

    fn record(self: *Bisect, mid: u16, ok: bool) void {
        if (ok) {
            self.good = mid;
            // `mid == hi` iff `lo == hi` (the last candidate): converged at the
            // top of the range, with nothing larger to test. Stop here rather
            // than computing `mid + 1`, which overflows u16 at the 65535 ceiling
            // (reachable on a path that passes the largest datagram, e.g. Linux
            // loopback with `--ceil 65535`).
            if (mid == self.hi) {
                self.done = true;
            } else {
                self.lo = mid + 1;
            }
        } else {
            if (mid == 0) {
                self.done = true;
            } else {
                self.hi = mid - 1;
            }
        }
    }
};

/// Clamp the path-derived tunnel MTU to the daemon's accepted range so the
/// printed recommendation is always a value `config.validate()` will accept.
/// `netplan.maxTunMtu` can return 0..67 (below `MTU_MIN`) for a tiny path, so
/// both ends are clamped; callers should additionally warn when the raw value
/// is below `MTU_MIN` (the path cannot carry a usable tunnel).
fn recommendedTunMtu(path_mtu: u16) u16 {
    const m = netplan.maxTunMtu(path_mtu);
    if (m > config.MTU_MAX) return config.MTU_MAX;
    if (m < config.MTU_MIN) return config.MTU_MIN;
    return m;
}

// ---- I/O roles ----

fn nowMillis(io: std.Io) i64 {
    const t = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(t.nanoseconds, std.time.ns_per_ms));
}

/// Set the IPv4 Don't-Fragment bit on `fd` so oversized probes are dropped in
/// flight (or rejected locally with EMSGSIZE) instead of being fragmented. On
/// Linux we use IP_PMTUDISC_PROBE: DF is set and the local PMTU cache is ignored,
/// so a stale cache can't cap the search — only the local interface MTU does.
/// macOS has no MTU_DISCOVER knob; IP_DONTFRAG sets the bit directly.
fn setDontFragment(fd: sys.fd_t) bool {
    const IPPROTO_IP: i32 = 0;
    if (builtin.os.tag == .linux) {
        const IP_MTU_DISCOVER: u32 = 10;
        const IP_PMTUDISC_PROBE: i32 = 3;
        var v: i32 = IP_PMTUDISC_PROBE;
        const rc = sys.setsockopt(fd, IPPROTO_IP, IP_MTU_DISCOVER, std.mem.asBytes(&v), @sizeOf(i32));
        return sys.errno(rc) == .SUCCESS;
    } else {
        const IP_DONTFRAG: u32 = 28;
        var v: i32 = 1;
        const rc = sys.setsockopt(fd, IPPROTO_IP, IP_DONTFRAG, std.mem.asBytes(&v), @sizeOf(i32));
        return sys.errno(rc) == .SUCCESS;
    }
}

/// Send one probe of on-wire size `path` and wait up to `timeout_ms` for the
/// matching ACK, retrying `tries` times to ride out ordinary loss. Returns true
/// iff the responder confirmed receipt of the full datagram. An EMSGSIZE on send
/// (probe exceeds the local interface MTU with DF set) is a definitive "too big".
fn probeOnce(
    io: std.Io,
    fd: sys.fd_t,
    dst: *const sys.sockaddr.in,
    buf: []u8,
    nonce: u32,
    seq: u32,
    path: u16,
    tries: u32,
    timeout_ms: u32,
) bool {
    const payload_len: usize = @as(usize, path) - OUTER;
    writeHeader(buf, TYPE_PROBE, nonce, seq);
    // Filler beyond the header is deterministic but irrelevant to the result.
    var i: usize = HDR_LEN;
    while (i < payload_len) : (i += 1) buf[i] = @intCast(i & 0xff);

    const addrlen: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    var ack: [64]u8 = undefined;

    var attempt: u32 = 0;
    while (attempt < tries) : (attempt += 1) {
        const src = sys.sendto(fd, buf.ptr, payload_len, 0, @ptrCast(dst), addrlen);
        switch (sys.errno(src)) {
            .SUCCESS => {},
            .MSGSIZE => return false, // DF + too big for the local interface
            else => continue, // transient (ENOBUFS/EAGAIN): retry
        }

        const deadline = nowMillis(io) +| @as(i64, @intCast(timeout_ms));
        var pfd = sys.pollfd{ .fd = fd, .events = sys.POLL.IN, .revents = 0 };
        while (true) {
            const remaining = deadline - nowMillis(io);
            if (remaining <= 0) break;
            const prc = sys.poll(@ptrCast(&pfd), 1, @intCast(@min(remaining, std.math.maxInt(i32))));
            switch (sys.errno(prc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => break,
            }
            if (prc == 0) break; // timed out
            if (pfd.revents & sys.POLL.IN == 0) break;
            const rrc = sys.recvfrom(fd, &ack, ack.len, 0, null, null);
            if (sys.errno(rrc) != .SUCCESS) break;
            const n: usize = @intCast(rrc);
            if (!headerMatches(ack[0..n], TYPE_ACK, nonce, seq)) continue; // foreign/stale
            if (n < ACK_LEN) continue;
            const recvd = std.mem.readInt(u32, ack[16..20], .little);
            if (recvd == payload_len) return true; // full datagram traversed
        }
    }
    return false;
}

fn runProber(io: std.Io, args: std.process.Args, dst_str: []const u8) !void {
    const dst = config.parseEndpoint(dst_str) catch {
        writeErr(io, "mtu-probe: invalid --probe target (want IP:PORT, e.g. 203.0.113.9:18020)\n");
        return error.InvalidArgument;
    };

    var floor: u16 = DEFAULT_FLOOR;
    var ceil: u16 = DEFAULT_CEIL;
    if (flagValue(args, "--floor")) |r| floor = std.fmt.parseInt(u16, r, 10) catch DEFAULT_FLOOR;
    if (flagValue(args, "--ceil")) |r| ceil = std.fmt.parseInt(u16, r, 10) catch DEFAULT_CEIL;
    const tries = parseU32(args, "--tries", DEFAULT_TRIES);
    const timeout_ms = parseU32(args, "--timeout-ms", DEFAULT_TIMEOUT_MS);
    const verbose = hasFlag(args, "--verbose");

    // A probe needs room for our header inside the UDP payload; the smallest
    // sensible path carries HDR_LEN payload bytes.
    const min_path: u16 = HDR_LEN + OUTER;
    if (floor < min_path) floor = min_path;
    if (ceil > MAX_PAYLOAD + OUTER) ceil = MAX_PAYLOAD + OUTER;
    if (floor > ceil) {
        writeErr(io, "mtu-probe: --floor must not exceed --ceil\n");
        return error.InvalidArgument;
    }

    const fd = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, false, true) catch {
        writeErr(io, "mtu-probe: socket() failed\n");
        return error.SocketFailed;
    };
    defer _ = sys.close(fd);
    if (!setDontFragment(fd)) {
        writeErr(io, "mtu-probe: could not set the IPv4 Don't-Fragment bit (results would be meaningless)\n");
        return error.SocketFailed;
    }

    const nonce: u32 = blk: {
        const ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
        const pid: u32 = @truncate(@as(u64, @bitCast(@as(i64, @intCast(sys.getpid())))));
        break :blk @as(u32, @truncate(@as(u128, @intCast(ns)))) ^ (pid << 13) ^ 0x5a17;
    };

    var buf: [MAX_PAYLOAD]u8 = undefined;
    var line: [256]u8 = undefined;

    writeOut(io, std.fmt.bufPrint(&line,
        "mtu-probe: probing {s}  range={d}..{d} (path MTU)  DF=on tries={d} timeout={d}ms\n", .{
        dst_str, floor, ceil, tries, timeout_ms,
    }) catch "");

    // Connectivity gate: the floor must round-trip, else the result is undefined
    // (responder down, all probes dropped, or the path is below the IPv4 minimum).
    var seq: u32 = 1;
    if (!probeOnce(io, fd, &dst, &buf, nonce, seq, floor, tries, timeout_ms)) {
        writeOut(io, std.fmt.bufPrint(&line,
            "mtu-probe: NO RESPONSE at the floor ({d}B). Responder not running/reachable, all\n" ++
            "  probes dropped, or the path MTU is below {d}. Lower --floor or check the link.\n", .{
            floor, floor,
        }) catch "");
        return error.NoResponse;
    }

    // floor already round-trips; search (floor, ceil] for the largest working
    // size. Guard `floor + 1` against u16 overflow when floor == ceil (== the
    // answer already) or floor is at the u16 max.
    var path_mtu: u16 = floor;
    if (floor < ceil) {
        var search = Bisect.init(floor + 1, ceil);
        search.good = floor;
        while (search.next()) |mid| {
            seq += 1;
            const ok = probeOnce(io, fd, &dst, &buf, nonce, seq, mid, tries, timeout_ms);
            if (verbose) {
                writeOut(io, std.fmt.bufPrint(&line, "  probe {d}B ... {s}\n", .{ mid, if (ok) "ok" else "drop" }) catch "");
            }
            search.record(mid, ok);
        }
        path_mtu = search.good;
    }

    const rec = recommendedTunMtu(path_mtu);
    writeOut(io, std.fmt.bufPrint(&line,
        "mtu-probe: result\n" ++
        "  underlay path MTU : {d} bytes   (largest UDP payload that round-tripped: {d} + {d} IPv4/UDP)\n" ++
        "  subnetra overhead : {d} bytes\n" ++
        "  recommended       : local_tun_mtu = {d}\n", .{
        path_mtu, path_mtu - OUTER, OUTER, TUNNEL_OVERHEAD, rec,
    }) catch "");

    if (netplan.maxTunMtu(path_mtu) < config.MTU_MIN) {
        writeOut(io, std.fmt.bufPrint(&line,
            "  WARNING: this path ({d}B) is too small to carry a usable tunnel; local_tun_mtu was\n" ++
            "           floored to the minimum {d}. A path of at least {d}B is needed.\n", .{
            path_mtu, config.MTU_MIN, @as(u16, config.MTU_MIN) + TUNNEL_OVERHEAD,
        }) catch "");
    }

    if (path_mtu >= ceil) {
        writeOut(io, std.fmt.bufPrint(&line,
            "  note: every probe up to --ceil ({d}) succeeded; the true path MTU may be higher.\n" ++
            "        Re-run with a larger --ceil (e.g. --ceil 9000) on jumbo-frame paths.\n", .{ceil}) catch "");
    }
}

fn runResponder(io: std.Io, args: std.process.Args, port_str: ?[]const u8) !void {
    var port: u16 = DEFAULT_LISTEN_PORT;
    if (port_str) |p| {
        port = std.fmt.parseInt(u16, p, 10) catch {
            writeErr(io, "mtu-probe: invalid --listen PORT\n");
            return error.InvalidArgument;
        };
        if (port == 0) {
            writeErr(io, "mtu-probe: --listen PORT must be non-zero\n");
            return error.InvalidArgument;
        }
    }
    const secs = parseU32(args, "--secs", 0);

    const fd = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, false, true) catch {
        writeErr(io, "mtu-probe: socket() failed\n");
        return error.SocketFailed;
    };
    defer _ = sys.close(fd);

    var addr = sys.sockaddr.in{ .family = sys.AF.INET, .port = std.mem.nativeToBig(u16, port), .addr = 0 };
    if (sys.errno(sys.bind(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in))) != .SUCCESS) {
        writeErr(io, "mtu-probe: bind() failed (port in use or insufficient privilege)\n");
        return error.BindFailed;
    }

    var line: [160]u8 = undefined;
    writeOut(io, std.fmt.bufPrint(&line, "mtu-probe: responder listening on 0.0.0.0:{d} (Ctrl-C to stop)\n", .{port}) catch "");

    const deadline: ?i64 = if (secs == 0) null else nowMillis(io) +| @as(i64, @intCast(secs)) * 1000;
    var buf: [MAX_PAYLOAD]u8 = undefined;
    var ack: [ACK_LEN]u8 = undefined;

    while (true) {
        var timeout: i32 = -1; // block indefinitely when no deadline
        if (deadline) |d| {
            const remaining = d - nowMillis(io);
            if (remaining <= 0) break;
            timeout = @intCast(@min(remaining, std.math.maxInt(i32)));
        }
        var pfd = sys.pollfd{ .fd = fd, .events = sys.POLL.IN, .revents = 0 };
        const prc = sys.poll(@ptrCast(&pfd), 1, timeout);
        switch (sys.errno(prc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => break,
        }
        if (prc == 0) continue; // timeout tick
        if (pfd.revents & sys.POLL.IN == 0) continue;

        var src: sys.sockaddr = undefined;
        var srclen: sys.socklen_t = @sizeOf(sys.sockaddr);
        const rrc = sys.recvfrom(fd, &buf, buf.len, 0, &src, &srclen);
        if (sys.errno(rrc) != .SUCCESS) continue;
        const n: usize = @intCast(rrc);
        // Echo only well-formed probes; ignore stray traffic silently.
        if (n < HDR_LEN or !std.mem.eql(u8, buf[0..4], &MAGIC) or buf[4] != TYPE_PROBE or buf[5] != PROTO_VER) continue;

        const nonce = std.mem.readInt(u32, buf[8..12], .little);
        const seq = std.mem.readInt(u32, buf[12..16], .little);
        writeHeader(&ack, TYPE_ACK, nonce, seq);
        std.mem.writeInt(u32, ack[16..20], @intCast(n), .little);
        _ = sys.sendto(fd, &ack, ack.len, 0, &src, srclen);
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
        writeOut(io, std.fmt.bufPrint(&vbuf, "mtu-probe (subnetra v{s})\n", .{build_options.version}) catch return);
        return;
    }

    const probe_target = flagValue(args, "--probe");
    const is_listen = hasFlag(args, "--listen");

    if (probe_target != null and is_listen) {
        writeErr(io, "mtu-probe: choose one role — --listen OR --probe, not both\n");
        return error.InvalidArgument;
    }
    if (probe_target) |t| return runProber(io, args, t);
    if (is_listen) return runResponder(io, args, flagValue(args, "--listen"));

    writeErr(io, "mtu-probe: a role is required (--listen [PORT] or --probe IP:PORT). See --help.\n");
    return error.InvalidArgument;
}

// ---- tests (run via `zig build tools-test`) ----

test "mtu-probe: probe header round-trips and rejects foreign/stale datagrams" {
    var buf: [HDR_LEN]u8 = undefined;
    writeHeader(&buf, TYPE_PROBE, 0xDEADBEEF, 7);
    try std.testing.expect(headerMatches(&buf, TYPE_PROBE, 0xDEADBEEF, 7));
    // wrong kind, wrong nonce, wrong seq, and a too-short datagram all fail closed.
    try std.testing.expect(!headerMatches(&buf, TYPE_ACK, 0xDEADBEEF, 7));
    try std.testing.expect(!headerMatches(&buf, TYPE_PROBE, 0xDEADBEEE, 7));
    try std.testing.expect(!headerMatches(&buf, TYPE_PROBE, 0xDEADBEEF, 8));
    try std.testing.expect(!headerMatches(buf[0 .. HDR_LEN - 1], TYPE_PROBE, 0xDEADBEEF, 7));
    var foreign = buf;
    foreign[0] = 'X';
    try std.testing.expect(!headerMatches(&foreign, TYPE_PROBE, 0xDEADBEEF, 7));
}

test "mtu-probe: bisection converges on the true path MTU" {
    // Simulate a path that passes datagrams up to exactly 1492 (PPPoE).
    const true_mtu: u16 = 1492;
    var s = Bisect.init(577, 1500); // floor already confirmed, searching above it
    s.good = 576;
    var steps: usize = 0;
    while (s.next()) |mid| : (steps += 1) {
        s.record(mid, mid <= true_mtu);
        try std.testing.expect(steps < 16); // log2(924) search must terminate quickly
    }
    try std.testing.expectEqual(true_mtu, s.good);
}

test "mtu-probe: bisection at the ceiling reports the ceiling (true MTU may be higher)" {
    var s = Bisect.init(577, 1500);
    s.good = 576;
    while (s.next()) |mid| s.record(mid, true); // everything passes
    try std.testing.expectEqual(@as(u16, 1500), s.good);
}

test "mtu-probe: bisection at the u16 ceiling terminates without overflow" {
    // A path that passes the largest datagram (e.g. Linux loopback) with the u16
    // max as the ceiling must converge, not overflow `mid + 1` or loop forever.
    var s = Bisect.init(1400, 65535);
    var steps: usize = 0;
    while (s.next()) |mid| : (steps += 1) {
        s.record(mid, true);
        try std.testing.expect(steps < 32);
    }
    try std.testing.expectEqual(@as(u16, 65535), s.good);
}

test "mtu-probe: recommended tunnel MTU subtracts the live overhead and clamps to the daemon range" {
    // 1500 path -> 1436, exactly the daemon's default (issue #98); proves no drift.
    try std.testing.expectEqual(config.DEFAULT_TUN_MTU, recommendedTunMtu(1500));
    try std.testing.expectEqual(@as(u16, 1492 - 64), recommendedTunMtu(1492));
    // A path larger than 1500 still clamps the inner MTU to the accepted maximum.
    try std.testing.expectEqual(config.MTU_MAX, recommendedTunMtu(9000));
    // A path too small for a usable tunnel clamps UP to the accepted minimum, so
    // the printed value is always one `config.validate()` accepts.
    try std.testing.expectEqual(config.MTU_MIN, recommendedTunMtu(100)); // maxTunMtu(100)=36 < 68
    try std.testing.expectEqual(config.MTU_MIN, recommendedTunMtu(64)); // maxTunMtu(64)=0
}

test "mtu-probe: overhead constants track the live protocol" {
    try std.testing.expectEqual(@as(u16, 28), OUTER);
    try std.testing.expectEqual(@as(u16, 64), TUNNEL_OVERHEAD);
    try std.testing.expectEqual(TUNNEL_OVERHEAD, bt.reactor.HEADER_LEN + bt.crypto.TAG_LEN + OUTER);
}
