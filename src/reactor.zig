//! Task 6: Core reactor (data-plane reactor).
//!
//! Single-threaded epoll edge-triggered loop: non-blocking blind forwarding
//! between TUN_FD and UDP_FD. Egress is dispatched uniformly via
//! `egress(mode, pkt)`; adding a mode only adds a branch, never touches the main
//! loop. v1 ships raw_direct only; kcp_arq / fec_xor are v2 roadmap and return
//! NotImplemented for now.
//!
//! Iron laws honoured here:
//! - Zero data-plane allocation: every packet buffer is resident in `Reactor`.
//! - Single-threaded, lock-free, epoll edge-triggered (EPOLLET); fds are forced
//!   non-blocking and each readable fd is drained until EAGAIN.
//! - Crypto auth failure / replay / malformed input are dropped silently.
//!
//! Scope boundary: this is the single-peer point-to-point path. The multi-peer
//! endpoint table and relay target routing is issue #5; the AF_UNIX control
//! listener (accept/parse) is issue #7, so `uds_fd` is intentionally NOT
//! registered with epoll here.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const policy = @import("policy.zig");
const crypto = @import("crypto.zig");

/// Private wire header (packed struct, physically aligned): 1B version + 1B
/// flags + 2B reserved negotiation field + 8B monotonic sequence number (doubles
/// as the nonce and anti-replay basis). 12 bytes total. The header is serialized
/// field-by-field (see `encodeEgress`/`decodeIngress`) rather than by memory
/// layout, so the wire format is endian-stable.
pub const WireHeader = packed struct {
    version: u8 = 1,
    flags: u8 = 0,
    /// Reserved for the v2 handshake negotiation.
    reserved: u16 = 0,
    seq: u64,
};

pub const HEADER_LEN = @divExact(@bitSizeOf(WireHeader), 8);

/// On-wire protocol version for v1.
pub const WIRE_VERSION: u8 = 1;

/// Egress flow-control mode. New modes add a branch here and in `egress`.
pub const EgressMode = enum {
    raw_direct, // v1: skip retransmission, MTU 1452
    kcp_arq, // v2: in-house arena-based ARQ, MTU 1428
    fec_xor, // v2: in-house forward error correction
};

pub fn mtuFor(mode: EgressMode) u16 {
    return switch (mode) {
        .raw_direct => 1452,
        .kcp_arq => 1428,
        .fec_xor => 1428,
    };
}

/// Largest tunnelled IP packet (v1 raw_direct MTU).
pub const MAX_PLAINTEXT: usize = mtuFor(.raw_direct);
/// Largest datagram that ever crosses the UDP socket: header + ciphertext + tag.
pub const MAX_WIRE: usize = HEADER_LEN + MAX_PLAINTEXT + crypto.TAG_LEN;
/// Resident packet buffer size. Sized with headroom for jumbo-ish reads while
/// staying comfortably above MAX_WIRE.
pub const BUF_LEN: usize = 2048;

comptime {
    std.debug.assert(BUF_LEN >= MAX_WIRE);
    std.debug.assert(HEADER_LEN == 12);
}

pub const EgressError = error{NotImplemented};

/// Egress mode guard. v1 ships raw_direct only; the rest are v2-reserved
/// branches. The actual `sendto` happens in the reactor pump after this guard
/// admits the packet.
pub fn egress(mode: EgressMode, pkt: []const u8) EgressError!void {
    switch (mode) {
        .raw_direct => {
            _ = pkt;
        },
        .kcp_arq, .fec_xor => return EgressError.NotImplemented,
    }
}

/// Serialize the wire header for `seq`, seal `ip_pkt` after it, and return the
/// total wire length. Allocation-free: writes straight into `out`. `seq` is
/// drawn from the monotonic counter (never reused with the same key).
pub fn encodeEgress(key: crypto.Key, counter: *crypto.NonceCounter, ip_pkt: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= HEADER_LEN + ip_pkt.len + crypto.TAG_LEN);
    const seq = counter.next();
    out[0] = WIRE_VERSION;
    out[1] = 0; // flags
    std.mem.writeInt(u16, out[2..][0..2], 0, .little); // reserved
    std.mem.writeInt(u64, out[4..][0..8], seq, .little);
    const sealed = crypto.seal(key, seq, ip_pkt, out[HEADER_LEN..]);
    return HEADER_LEN + sealed;
}

/// Parse, authenticate, then anti-replay check an inbound datagram. Writes the
/// recovered IP packet into `out` and returns its length, or `null` if the
/// datagram must be dropped (malformed header, reserved bits set, auth failure,
/// or replay). Authentication runs BEFORE the replay window is advanced so a
/// forged sequence number can never poison the window.
pub fn decodeIngress(key: crypto.Key, window: *crypto.ReplayWindow, datagram: []const u8, out: []u8) ?usize {
    if (datagram.len < HEADER_LEN) return null;
    if (datagram[0] != WIRE_VERSION) return null;
    if (datagram[1] != 0) return null; // flags reserved in v1
    if (std.mem.readInt(u16, datagram[2..][0..2], .little) != 0) return null; // reserved
    const seq = std.mem.readInt(u64, datagram[4..][0..8], .little);
    const ct = datagram[HEADER_LEN..];
    const plen = crypto.open(key, seq, ct, out) catch return null; // silent drop on auth/truncation
    if (!window.accept(seq)) return null; // replay or too old -> drop
    return plen;
}

/// Extract the IPv4 destination address (host byte order) after validating the
/// header. Returns `null` for anything that is not a well-formed IPv4 packet.
fn ipv4Dst(pkt: []const u8) ?u32 {
    if (pkt.len < 20) return null;
    if ((pkt[0] >> 4) != 4) return null; // version
    const ihl = pkt[0] & 0x0f;
    if (ihl < 5) return null;
    if (pkt.len < @as(usize, ihl) * 4) return null;
    return std.mem.readInt(u32, pkt[16..][0..4], .big);
}

fn nonblockBit() usize {
    return @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
}

/// Random high word for the transmit nonce counter, sourced from getrandom so
/// that nonces do not repeat across a restart with the same key. Falls back to
/// 0 only if the syscall is unavailable (counter low bits still avoid same-run
/// reuse).
fn randomHigh() u32 {
    var b: [4]u8 = undefined;
    const rc = linux.getrandom(&b, b.len, 0);
    if (linux.errno(rc) != .SUCCESS or rc != b.len) return 0;
    return std.mem.readInt(u32, &b, .little);
}

fn setNonblock(fd: linux.fd_t) !void {
    const cur = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(cur) != .SUCCESS) return error.FcntlFailed;
    const rc = linux.fcntl(fd, linux.F.SETFL, cur | nonblockBit());
    if (linux.errno(rc) != .SUCCESS) return error.FcntlFailed;
}

pub const Reactor = struct {
    tun_fd: linux.fd_t,
    udp_fd: linux.fd_t,
    /// AF_UNIX control fd. Stored for completeness; registration + accept/parse
    /// is issue #7 and deliberately not wired into the epoll set here.
    uds_fd: linux.fd_t,
    active: *policy.ActiveTree,
    mode: EgressMode = .raw_direct,
    /// 32-byte pre-shared key for the AEAD seal/open.
    key: crypto.Key,
    /// The single remote endpoint (network byte order). Multi-peer is issue #5.
    peer: linux.sockaddr.in,
    tx_counter: crypto.NonceCounter = .{},
    rx_window: crypto.ReplayWindow = .{},
    rx: [BUF_LEN]u8 = undefined,
    tx: [BUF_LEN]u8 = undefined,

    /// Build a reactor and reseed the transmit nonce counter from a random high
    /// word so that, after a restart with the same PSK, sequence numbers (and
    /// therefore AEAD nonces) do not repeat.
    pub fn init(
        tun_fd: linux.fd_t,
        udp_fd: linux.fd_t,
        uds_fd: linux.fd_t,
        active: *policy.ActiveTree,
        key: crypto.Key,
        peer: linux.sockaddr.in,
    ) Reactor {
        var r = Reactor{
            .tun_fd = tun_fd,
            .udp_fd = udp_fd,
            .uds_fd = uds_fd,
            .active = active,
            .key = key,
            .peer = peer,
        };
        r.tx_counter.reseedHigh(randomHigh());
        return r;
    }

    fn epollAdd(epfd: i32, fd: linux.fd_t) !void {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = fd },
        };
        const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
        if (linux.errno(rc) != .SUCCESS) return error.EpollCtlFailed;
    }

    /// Single-threaded epoll_wait loop (Linux only). Forces TUN/UDP non-blocking,
    /// registers them edge-triggered, and dispatches readable events to the
    /// drain pumps. Runs until an unrecoverable epoll error.
    pub fn run(self: *Reactor) !void {
        if (builtin.os.tag != .linux) return error.Unsupported;

        try setNonblock(self.tun_fd);
        try setNonblock(self.udp_fd);

        const epfd_rc = linux.epoll_create1(0);
        if (linux.errno(epfd_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epfd: i32 = @intCast(epfd_rc);
        defer _ = linux.close(epfd);

        try epollAdd(epfd, self.tun_fd);
        try epollAdd(epfd, self.udp_fd);
        // uds_fd is intentionally NOT registered here (issue #7 owns accept/parse).

        var events: [16]linux.epoll_event = undefined;
        while (true) {
            const nrc = linux.epoll_wait(epfd, &events, events.len, -1);
            const e = linux.errno(nrc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return error.EpollWaitFailed;
            var i: usize = 0;
            while (i < nrc) : (i += 1) {
                const fd = events[i].data.fd;
                if (fd == self.tun_fd) {
                    self.pumpTunToUdp();
                } else if (fd == self.udp_fd) {
                    self.pumpUdpToTun();
                }
            }
        }
    }

    /// Drain the TUN fd: read each IP packet, apply the policy DROP decision,
    /// seal it, and blind-forward to the configured peer. Loops until EAGAIN.
    pub fn pumpTunToUdp(self: *Reactor) void {
        while (true) {
            const rc = linux.read(self.tun_fd, &self.rx, self.rx.len);
            const e = linux.errno(rc);
            if (e == .AGAIN) return;
            if (e == .INTR) continue;
            if (e != .SUCCESS) return; // transient read error: yield this round
            if (rc == 0) return;
            const pkt = self.rx[0..rc];

            const dst = ipv4Dst(pkt) orelse continue; // non-IPv4/malformed -> drop
            if (self.active.load().match(dst)) |entry| {
                if (entry.action == .drop) continue;
            }
            if (pkt.len > MAX_PLAINTEXT) continue; // oversized -> drop
            egress(self.mode, pkt) catch continue; // v2 modes not yet shipped -> drop

            const wire_len = encodeEgress(self.key, &self.tx_counter, pkt, &self.tx);
            self.sendToPeer(self.tx[0..wire_len]);
        }
    }

    /// Drain the UDP fd: filter by source endpoint, authenticate + anti-replay,
    /// and write the recovered IP packet to the TUN. Loops until EAGAIN.
    pub fn pumpUdpToTun(self: *Reactor) void {
        while (true) {
            var src: linux.sockaddr.in = undefined;
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.recvfrom(self.udp_fd, &self.rx, self.rx.len, 0, @ptrCast(&src), &slen);
            const e = linux.errno(rc);
            if (e == .AGAIN) return;
            if (e == .INTR) continue;
            if (e != .SUCCESS) return;
            const dgram = self.rx[0..rc];

            // Source-endpoint filter: only the configured peer is admitted.
            if (src.addr != self.peer.addr or src.port != self.peer.port) continue;

            const plen = decodeIngress(self.key, &self.rx_window, dgram, &self.tx) orelse continue;
            self.writeTun(self.tx[0..plen]);
        }
    }

    fn sendToPeer(self: *Reactor, buf: []const u8) void {
        while (true) {
            const rc = linux.sendto(
                self.udp_fd,
                buf.ptr,
                buf.len,
                0,
                @ptrCast(&self.peer),
                @sizeOf(linux.sockaddr.in),
            );
            if (linux.errno(rc) == .INTR) continue;
            return; // success or silent drop on error
        }
    }

    fn writeTun(self: *Reactor, buf: []const u8) void {
        while (true) {
            const rc = linux.write(self.tun_fd, buf.ptr, buf.len);
            if (linux.errno(rc) == .INTR) continue;
            return; // success or silent drop on error
        }
    }
};

test "WireHeader is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), HEADER_LEN);
}

test "egress: v1 raw_direct works, v2 modes return NotImplemented" {
    try egress(.raw_direct, &.{});
    try std.testing.expectError(EgressError.NotImplemented, egress(.kcp_arq, &.{}));
    try std.testing.expectError(EgressError.NotImplemented, egress(.fec_xor, &.{}));
    try std.testing.expectEqual(@as(u16, 1452), mtuFor(.raw_direct));
}

test "codec: encodeEgress -> decodeIngress roundtrips the IP packet" {
    const key: crypto.Key = [_]u8{0x11} ** crypto.KEY_LEN;
    var counter = crypto.NonceCounter{};
    var window = crypto.ReplayWindow{};

    const ip_pkt = [_]u8{ 0x45, 0, 0, 28 } ++ [_]u8{0} ** 12 ++ [_]u8{ 10, 0, 0, 2 } ++ [_]u8{0} ** 8;
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(key, &counter, &ip_pkt, &wire);
    try std.testing.expectEqual(HEADER_LEN + ip_pkt.len + crypto.TAG_LEN, wlen);
    try std.testing.expectEqual(WIRE_VERSION, wire[0]);

    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(key, &window, wire[0..wlen], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &ip_pkt, out[0..plen]);
}

test "codec: decodeIngress drops tampered, replayed, and malformed datagrams" {
    const key: crypto.Key = [_]u8{0x22} ** crypto.KEY_LEN;
    var counter = crypto.NonceCounter{};

    const ip_pkt = [_]u8{ 0x45, 0, 0, 20 } ++ [_]u8{0} ** 16;
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(key, &counter, &ip_pkt, &wire);
    var out: [MAX_PLAINTEXT]u8 = undefined;

    // Tampered ciphertext -> auth fails -> drop, and the replay window must not
    // have advanced (a fresh valid copy still decodes afterwards).
    var window = crypto.ReplayWindow{};
    var tampered = wire;
    tampered[wlen - 1] ^= 0xFF;
    try std.testing.expect(decodeIngress(key, &window, tampered[0..wlen], &out) == null);
    try std.testing.expect(decodeIngress(key, &window, wire[0..wlen], &out) != null);

    // Replay of the same seq is dropped the second time.
    try std.testing.expect(decodeIngress(key, &window, wire[0..wlen], &out) == null);

    // Wrong version byte -> drop.
    var badver = wire;
    badver[0] = 2;
    try std.testing.expect(decodeIngress(key, &window, badver[0..wlen], &out) == null);

    // Set reserved flags byte -> drop.
    var badflags = wire;
    badflags[1] = 1;
    try std.testing.expect(decodeIngress(key, &window, badflags[0..wlen], &out) == null);

    // Too short for a header -> drop.
    try std.testing.expect(decodeIngress(key, &window, wire[0 .. HEADER_LEN - 1], &out) == null);
}

// ---- Live-socket pump tests (Linux only; skip elsewhere / on permission gaps) ----

fn makeUdpLoopback() !linux.fd_t {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
    const fd: linux.fd_t = @intCast(rc);
    var addr = linux.sockaddr.in{ .family = linux.AF.INET, .port = 0, .addr = 0x0100007f }; // 127.0.0.1:0
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        _ = linux.close(fd);
        return error.SkipZigTest;
    }
    return fd;
}

fn addrOf(fd: linux.fd_t) !linux.sockaddr.in {
    var a: linux.sockaddr.in = undefined;
    var l: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&a), &l)) != .SUCCESS) return error.SkipZigTest;
    return a;
}

test "pump: TUN->UDP seals and forwards to the peer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const key: crypto.Key = [_]u8{0x33} ** crypto.KEY_LEN;
    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    // tun side: a pipe whose read end the reactor drains.
    var pipe_fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe_fds, linux.O{ .NONBLOCK = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const udp_a = try makeUdpLoopback(); // reactor's udp_fd
    defer _ = linux.close(udp_a);
    const udp_b = try makeUdpLoopback(); // the remote peer
    defer _ = linux.close(udp_b);
    const peer = try addrOf(udp_b);

    var r = Reactor.init(pipe_fds[0], udp_a, -1, &active, key, peer);

    const ip_pkt = [_]u8{ 0x45, 0, 0, 28 } ++ [_]u8{0} ** 12 ++ [_]u8{ 10, 0, 0, 9 } ++ [_]u8{0} ** 8;
    _ = linux.write(pipe_fds[1], &ip_pkt, ip_pkt.len);

    r.pumpTunToUdp();

    var buf: [MAX_WIRE]u8 = undefined;
    const rc = linux.recvfrom(udp_b, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);

    var window = crypto.ReplayWindow{};
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(key, &window, buf[0..rc], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &ip_pkt, out[0..plen]);
}

test "pump: UDP->TUN authenticates, filters source, and writes to TUN" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const key: crypto.Key = [_]u8{0x44} ** crypto.KEY_LEN;
    var empty = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&empty);

    var pipe_fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe_fds, linux.O{ .NONBLOCK = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const udp_a = try makeUdpLoopback(); // reactor's udp_fd
    defer _ = linux.close(udp_a);
    const udp_b = try makeUdpLoopback(); // the trusted peer
    defer _ = linux.close(udp_b);
    const udp_c = try makeUdpLoopback(); // an untrusted stranger
    defer _ = linux.close(udp_c);

    const peer = try addrOf(udp_b);
    const a_addr = try addrOf(udp_a);

    var r = Reactor.init(pipe_fds[1], udp_a, -1, &active, key, peer);

    const ip_pkt = [_]u8{ 0x45, 0, 0, 24 } ++ [_]u8{0} ** 12 ++ [_]u8{ 10, 0, 0, 5 } ++ [_]u8{0} ** 4;

    // Encode on the peer side with an independent counter.
    var counter = crypto.NonceCounter{};
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(key, &counter, &ip_pkt, &wire);

    // Stranger (udp_c) -> dropped by the source filter.
    _ = linux.sendto(udp_c, &wire, wlen, 0, @ptrCast(&a_addr), @sizeOf(linux.sockaddr.in));
    // Trusted peer (udp_b) -> accepted.
    _ = linux.sendto(udp_b, &wire, wlen, 0, @ptrCast(&a_addr), @sizeOf(linux.sockaddr.in));

    r.pumpUdpToTun();

    var buf: [MAX_PLAINTEXT]u8 = undefined;
    const rc = linux.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    try std.testing.expectEqualSlices(u8, &ip_pkt, buf[0..rc]);

    // Exactly one packet should have been delivered; the next read is empty.
    const rc2 = linux.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(linux.errno(rc2) == .AGAIN);

    // A tampered datagram from the trusted peer is silently dropped.
    var tampered = wire;
    tampered[wlen - 1] ^= 0xFF;
    _ = linux.sendto(udp_b, &tampered, wlen, 0, @ptrCast(&a_addr), @sizeOf(linux.sockaddr.in));
    r.pumpUdpToTun();
    const rc3 = linux.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(linux.errno(rc3) == .AGAIN);
}
