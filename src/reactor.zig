//! Task 6 (issue #5): Core reactor (data-plane reactor).
//!
//! Single-threaded epoll edge-triggered loop: non-blocking forwarding between
//! TUN_FD and UDP_FD across a multi-peer hub-and-spoke mesh. Routing is driven
//! by the policy tree's `target` (Model A): a matched entry names either the
//! local TUN (`target == LOCAL_TARGET`) or a peer id to forward/relay to. Egress
//! is dispatched uniformly via `egress(mode, pkt)`; adding a mode only adds a
//! branch, never touches the main loop. v1 ships raw_direct only; kcp_arq /
//! fec_xor are v2 roadmap and return NotImplemented for now.
//!
//! Iron laws honoured here:
//! - Zero data-plane allocation: every packet buffer is resident in `Reactor`
//!   (rx, tx, and a third `relay` buffer for hub forwarding).
//! - Single-threaded, lock-free, epoll edge-triggered (EPOLLET); fds are forced
//!   non-blocking and each readable fd is drained until EAGAIN.
//! - Crypto auth failure / replay / malformed input are dropped silently.
//!
//! Security model (issue #5):
//! - Each peer has its own directional keys (`crypto.deriveLinkKey`), so per-peer
//!   nonce counters can never collide under the shared PSK.
//! - Inbound datagrams are filtered by source endpoint; the decoded inner IPv4
//!   source must fall inside the source peer's `allowed_src` prefix, defeating
//!   inner-source spoofing by an authenticated spoke.
//! - The hub never reflects a packet back to its source peer (no-reflect guard).
//!   Topology is single-hub hub-and-spoke; spokes do not relay.
//!
//! Control plane (issue #6): an optional `*uds.Control` listener is registered
//! level-triggered so `ptctl` can hot-swap the policy tree at runtime; the data
//! plane only ever reads the tree atomically and never blocks on control I/O.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const policy = @import("policy.zig");
const crypto = @import("crypto.zig");
const peer = @import("peer.zig");
const uds = @import("uds.zig");

/// Private wire header (packed struct, physically aligned): 1B version + 1B
/// flags + 2B reserved negotiation field + 8B boot epoch (issue #14, identifies
/// the sender's current session so the receiver can derive the matching session
/// key statelessly and scope anti-replay per session) + 8B monotonic sequence
/// number (doubles as the nonce and anti-replay basis). 20 bytes total. The
/// header is serialized field-by-field (see `encodeEgress`/`decodeIngress`)
/// rather than by memory layout, so the wire format is endian-stable.
pub const WireHeader = packed struct {
    version: u8 = 1,
    flags: u8 = 0,
    /// Reserved for the v2 handshake negotiation.
    reserved: u16 = 0,
    /// Sender boot epoch (wall-clock ns at startup); never zero.
    epoch: u64,
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
    std.debug.assert(HEADER_LEN == 20);
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

/// Serialize the wire header for the session's next sequence number, seal
/// `ip_pkt` after it, and return the total wire length. Allocation-free: writes
/// straight into `out`. The header carries the session `epoch` so the receiver
/// can derive the matching session key (issue #14); the body is sealed with the
/// epoch-bound session key, and `seq` is drawn from the per-session monotonic
/// counter (never reused with the same key).
pub fn encodeEgress(tx: *crypto.TxSession, ip_pkt: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= HEADER_LEN + ip_pkt.len + crypto.TAG_LEN);
    const seq = tx.counter.next();
    out[0] = WIRE_VERSION;
    out[1] = 0; // flags
    std.mem.writeInt(u16, out[2..][0..2], 0, .little); // reserved
    std.mem.writeInt(u64, out[4..][0..8], tx.epoch, .little);
    std.mem.writeInt(u64, out[12..][0..8], seq, .little);
    const sealed = crypto.seal(tx.skey, seq, ip_pkt, out[HEADER_LEN..]);
    return HEADER_LEN + sealed;
}

/// Parse, authenticate, then anti-replay check an inbound datagram against the
/// receive session. Writes the recovered IP packet into `out` and returns its
/// length, or `null` if the datagram must be dropped (malformed header,
/// reserved bits set, stale/zero epoch, auth failure, or replay).
///
/// Session-epoch handling (issue #14) is forward-only: the highest
/// authenticated epoch wins. A packet from an older epoch than the one in force
/// is dropped before any crypto (cheap, and it rejects cross-session replay of a
/// retired lifetime). A packet from a newer epoch, once authenticated, adopts
/// that epoch and RESETS the replay window — this is what lets a one-sided
/// sender restart re-establish a fresh accepted session instead of being stuck
/// behind a window that ran ahead. Authentication always runs BEFORE any state
/// is mutated, so a forged higher epoch (or sequence number) can never poison
/// the session.
pub fn decodeIngress(rx: *crypto.RxSession, datagram: []const u8, out: []u8) ?usize {
    if (datagram.len < HEADER_LEN) return null;
    if (datagram[0] != WIRE_VERSION) return null;
    if (datagram[1] != 0) return null; // flags reserved in v1
    if (std.mem.readInt(u16, datagram[2..][0..2], .little) != 0) return null; // reserved
    const pkt_epoch = std.mem.readInt(u64, datagram[4..][0..8], .little);
    if (pkt_epoch == 0) return null; // zero is the "no session" sentinel, never valid on the wire
    const seq = std.mem.readInt(u64, datagram[12..][0..8], .little);

    // Forward-only: a strictly older epoch than the one in force is a retired
    // session (or a cross-epoch replay). Drop before spending any crypto.
    if (rx.epoch != 0 and pkt_epoch < rx.epoch) return null;

    // Steady state reuses the cached session key; a newer (or first) epoch
    // derives a candidate key that is only committed after authentication.
    const key = if (pkt_epoch == rx.epoch) rx.skey else crypto.deriveSessionKey(rx.link_key, pkt_epoch);

    const ct = datagram[HEADER_LEN..];
    const plen = crypto.open(key, seq, ct, out) catch return null; // silent drop on auth/truncation

    // Authenticated: a newer epoch now supersedes the old session — adopt it and
    // start a fresh replay window so the restarted sender's low sequence numbers
    // are accepted again.
    if (pkt_epoch > rx.epoch) {
        rx.epoch = pkt_epoch;
        rx.skey = key;
        rx.window = .{};
    }
    if (!rx.window.accept(seq)) return null; // replay or too old -> drop
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

/// Extract the IPv4 source address (host byte order). Assumes the packet has
/// already passed `ipv4Dst` validation (same header length guarantees).
fn ipv4Src(pkt: []const u8) ?u32 {
    if (pkt.len < 20) return null;
    return std.mem.readInt(u32, pkt[12..][0..4], .big);
}

fn nonblockBit() usize {
    return @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
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
    /// Optional AF_UNIX control listener (issue #6). When present its datagram
    /// socket is registered level-triggered in `run()` and drained via
    /// `Control.handle()`; the control plane owns the policy-tree storage and the
    /// data plane only reads `active` atomically.
    control: ?*uds.Control = null,
    active: *policy.ActiveTree,
    mode: EgressMode = .raw_direct,
    /// Multi-peer endpoint + crypto registry (per-peer keys, counters, windows).
    registry: *peer.PeerRegistry,
    rx: [BUF_LEN]u8 = undefined,
    tx: [BUF_LEN]u8 = undefined,
    /// Third resident buffer for hub relay: an inbound datagram decoded into
    /// `tx` is re-sealed into `relay` before forwarding to another peer, so the
    /// two operations never alias.
    relay: [BUF_LEN]u8 = undefined,

    pub fn init(
        tun_fd: linux.fd_t,
        udp_fd: linux.fd_t,
        control: ?*uds.Control,
        active: *policy.ActiveTree,
        registry: *peer.PeerRegistry,
    ) Reactor {
        return .{
            .tun_fd = tun_fd,
            .udp_fd = udp_fd,
            .control = control,
            .active = active,
            .registry = registry,
        };
    }

    fn epollAdd(epfd: i32, fd: linux.fd_t, events: u32) !void {
        var ev = linux.epoll_event{
            .events = events,
            .data = .{ .fd = fd },
        };
        const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fd, &ev);
        if (linux.errno(rc) != .SUCCESS) return error.EpollCtlFailed;
    }

    /// Single-threaded epoll_wait loop (Linux only). Forces TUN/UDP non-blocking,
    /// registers them edge-triggered, registers the optional control socket
    /// level-triggered, and dispatches readable events to the drain pumps. Runs
    /// until an unrecoverable epoll error.
    pub fn run(self: *Reactor) !void {
        if (builtin.os.tag != .linux) return error.Unsupported;

        try setNonblock(self.tun_fd);
        try setNonblock(self.udp_fd);

        const epfd_rc = linux.epoll_create1(0);
        if (linux.errno(epfd_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epfd: i32 = @intCast(epfd_rc);
        defer _ = linux.close(epfd);

        try epollAdd(epfd, self.tun_fd, linux.EPOLL.IN | linux.EPOLL.ET);
        try epollAdd(epfd, self.udp_fd, linux.EPOLL.IN | linux.EPOLL.ET);
        // Control socket is level-triggered: handle() processes a bounded number
        // of commands per tick, and epoll re-notifies while datagrams remain.
        if (self.control) |c| try epollAdd(epfd, c.fd, linux.EPOLL.IN);

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
                    self.pumpUdpIngress();
                } else if (self.control != null and fd == self.control.?.fd) {
                    self.control.?.handle();
                }
            }
        }
    }

    /// Drain the TUN fd (locally-originated traffic): read each IP packet, look
    /// up its destination in the policy tree to find the target peer, seal it
    /// with that peer's key, and forward. Packets with no route, a DROP rule, a
    /// LOCAL target (would loop to self), or an unknown target are dropped.
    /// Loops until EAGAIN.
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
            const entry = self.active.load().match(dst) orelse continue; // no route -> drop
            if (entry.action == .drop) continue;
            if (entry.target == peer.LOCAL_TARGET) continue; // local-origin to local -> drop
            const dst_peer = self.registry.findById(entry.target) orelse continue; // unknown target
            if (pkt.len > MAX_PLAINTEXT) continue; // oversized -> drop
            egress(self.mode, pkt) catch continue; // v2 modes not yet shipped -> drop

            const wire_len = encodeEgress(&dst_peer.tx, pkt, &self.tx);
            self.sendTo(dst_peer.endpoint, self.tx[0..wire_len]);
        }
    }

    /// Drain the UDP fd: filter by source endpoint, authenticate + anti-replay
    /// with the source peer's key, enforce inner-source binding, then route by
    /// the policy `target` — deliver to the local TUN, or relay to another peer
    /// (hub behaviour). Loops until EAGAIN.
    pub fn pumpUdpIngress(self: *Reactor) void {
        while (true) {
            var src: linux.sockaddr.in = undefined;
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.recvfrom(self.udp_fd, &self.rx, self.rx.len, 0, @ptrCast(&src), &slen);
            const e = linux.errno(rc);
            if (e == .AGAIN) return;
            if (e == .INTR) continue;
            if (e != .SUCCESS) return;
            const dgram = self.rx[0..rc];

            // Source-endpoint filter: only a configured peer is admitted.
            const src_peer = self.registry.findByAddr(src.addr, src.port) orelse continue;

            const plen = decodeIngress(&src_peer.rx, dgram, &self.tx) orelse continue;
            const pkt = self.tx[0..plen];

            // Inner-source binding: the decoded source IP must belong to the
            // source peer's allowed prefix (anti-spoofing).
            const isrc = ipv4Src(pkt) orelse continue;
            if (!src_peer.allowed_src.contains(isrc)) continue;

            const dst = ipv4Dst(pkt) orelse continue;
            const entry = self.active.load().match(dst) orelse continue; // no route -> drop
            if (entry.action == .drop) continue;

            if (entry.target == peer.LOCAL_TARGET) {
                self.writeTun(pkt);
                continue;
            }

            // Relay to another peer (hub forwarding).
            const dst_peer = self.registry.findById(entry.target) orelse continue; // unknown target
            if (dst_peer.id == src_peer.id) continue; // no-reflect guard
            if (pkt.len > MAX_PLAINTEXT) continue;
            const wire_len = encodeEgress(&dst_peer.tx, pkt, &self.relay);
            self.sendTo(dst_peer.endpoint, self.relay[0..wire_len]);
        }
    }

    fn sendTo(self: *Reactor, endpoint: linux.sockaddr.in, buf: []const u8) void {
        var ep = endpoint;
        while (true) {
            const rc = linux.sendto(
                self.udp_fd,
                buf.ptr,
                buf.len,
                0,
                @ptrCast(&ep),
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

test "WireHeader is 20 bytes" {
    try std.testing.expectEqual(@as(usize, 20), HEADER_LEN);
}

test "egress: v1 raw_direct works, v2 modes return NotImplemented" {
    try egress(.raw_direct, &.{});
    try std.testing.expectError(EgressError.NotImplemented, egress(.kcp_arq, &.{}));
    try std.testing.expectError(EgressError.NotImplemented, egress(.fec_xor, &.{}));
    try std.testing.expectEqual(@as(u16, 1452), mtuFor(.raw_direct));
}

test "codec: encodeEgress -> decodeIngress roundtrips the IP packet" {
    const key: crypto.Key = [_]u8{0x11} ** crypto.KEY_LEN;
    var tx = crypto.TxSession.init(key, 0x1700_0000_0000_0001);
    var rx = crypto.RxSession.init(key);

    const ip_pkt = [_]u8{ 0x45, 0, 0, 28 } ++ [_]u8{0} ** 12 ++ [_]u8{ 10, 0, 0, 2 } ++ [_]u8{0} ** 8;
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(&tx, &ip_pkt, &wire);
    try std.testing.expectEqual(HEADER_LEN + ip_pkt.len + crypto.TAG_LEN, wlen);
    try std.testing.expectEqual(WIRE_VERSION, wire[0]);

    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(&rx, wire[0..wlen], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &ip_pkt, out[0..plen]);
    // The receiver adopted the sender's epoch.
    try std.testing.expectEqual(@as(u64, 0x1700_0000_0000_0001), rx.epoch);
}

test "codec: decodeIngress drops tampered, replayed, and malformed datagrams" {
    const key: crypto.Key = [_]u8{0x22} ** crypto.KEY_LEN;
    var tx = crypto.TxSession.init(key, 0x1700_0000_0000_0001);

    const ip_pkt = [_]u8{ 0x45, 0, 0, 20 } ++ [_]u8{0} ** 16;
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(&tx, &ip_pkt, &wire);
    var out: [MAX_PLAINTEXT]u8 = undefined;

    // Tampered ciphertext -> auth fails -> drop, and the replay window must not
    // have advanced (a fresh valid copy still decodes afterwards).
    var rx = crypto.RxSession.init(key);
    var tampered = wire;
    tampered[wlen - 1] ^= 0xFF;
    try std.testing.expect(decodeIngress(&rx, tampered[0..wlen], &out) == null);
    try std.testing.expect(decodeIngress(&rx, wire[0..wlen], &out) != null);

    // Replay of the same seq is dropped the second time.
    try std.testing.expect(decodeIngress(&rx, wire[0..wlen], &out) == null);

    // Wrong version byte -> drop.
    var badver = wire;
    badver[0] = 2;
    try std.testing.expect(decodeIngress(&rx, badver[0..wlen], &out) == null);

    // Set reserved flags byte -> drop.
    var badflags = wire;
    badflags[1] = 1;
    try std.testing.expect(decodeIngress(&rx, badflags[0..wlen], &out) == null);

    // Zero epoch (the "no session" sentinel) -> drop.
    var badepoch = wire;
    std.mem.writeInt(u64, badepoch[4..][0..8], 0, .little);
    try std.testing.expect(decodeIngress(&rx, badepoch[0..wlen], &out) == null);

    // Too short for a header -> drop.
    try std.testing.expect(decodeIngress(&rx, wire[0 .. HEADER_LEN - 1], &out) == null);
}

test "codec: session epoch is forward-only (stale dropped, newer resets window)" {
    const key: crypto.Key = [_]u8{0x33} ** crypto.KEY_LEN;
    const ip_pkt = [_]u8{ 0x45, 0, 0, 20 } ++ [_]u8{0} ** 16;
    var out: [MAX_PLAINTEXT]u8 = undefined;
    var rx = crypto.RxSession.init(key);

    // Session 1 (epoch E1) sends a few packets; the receiver advances its window.
    var tx1 = crypto.TxSession.init(key, 1_700_000_000_000_000_000);
    var w1a: [MAX_WIRE]u8 = undefined;
    var w1b: [MAX_WIRE]u8 = undefined;
    const l1a = encodeEgress(&tx1, &ip_pkt, &w1a); // seq 1
    const l1b = encodeEgress(&tx1, &ip_pkt, &w1b); // seq 2
    try std.testing.expect(decodeIngress(&rx, w1a[0..l1a], &out) != null);
    try std.testing.expect(decodeIngress(&rx, w1b[0..l1b], &out) != null);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_000), rx.epoch);

    // The sender restarts: session 2 (a later epoch) restarts seq at 1. Without
    // the epoch reset this seq-1 packet would be rejected as a replay; with it,
    // the newer epoch is adopted and the window resets, so it is accepted.
    var tx2 = crypto.TxSession.init(key, 1_700_000_000_000_000_500);
    var w2: [MAX_WIRE]u8 = undefined;
    const l2 = encodeEgress(&tx2, &ip_pkt, &w2); // seq 1 again, new epoch
    try std.testing.expect(decodeIngress(&rx, w2[0..l2], &out) != null);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_500), rx.epoch);

    // A leftover packet from the retired session 1 (older epoch) is now dropped,
    // defeating cross-epoch replay of the previous lifetime.
    var w1c: [MAX_WIRE]u8 = undefined;
    const l1c = encodeEgress(&tx1, &ip_pkt, &w1c); // session 1, seq 3
    try std.testing.expect(decodeIngress(&rx, w1c[0..l1c], &out) == null);

    // Replay within the live session 2 is still rejected.
    try std.testing.expect(decodeIngress(&rx, w2[0..l2], &out) == null);
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

fn ipPkt(src: [4]u8, dst: [4]u8) [28]u8 {
    var p = [_]u8{0} ** 28;
    p[0] = 0x45; // IPv4, IHL=5
    p[3] = 28; // total length
    p[8] = 64; // TTL
    @memcpy(p[12..16], &src);
    @memcpy(p[16..20], &dst);
    return p;
}

const ANY_SRC = policy.Cidr{ .network = 0, .prefix = 0 };
const TEST_EPOCH: u64 = 1_700_000_000_000_000_000;

test "pump: TUN->UDP seals to the policy-selected peer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x33} ** crypto.KEY_LEN;

    // tun side: a pipe whose read end the reactor drains.
    var pipe_fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe_fds, linux.O{ .NONBLOCK = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback(); // reactor's udp_fd (local id 1)
    defer _ = linux.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // peer A (id 2)
    defer _ = linux.close(udp_a);

    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, try addrOf(udp_a), ANY_SRC, TEST_EPOCH);

    // Route 10.0.0.2 -> peer 2.
    const entries = [_]policy.PolicyEntry{.{
        .src = try policy.parseCidr("0.0.0.0/0"),
        .dst = try policy.parseCidr("10.0.0.2/32"),
        .action = .forward,
        .target = 2,
    }};
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    var r = Reactor.init(pipe_fds[0], udp_hub, null, &active, &reg);

    const ip_pkt = ipPkt(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 });
    _ = linux.write(pipe_fds[1], &ip_pkt, ip_pkt.len);

    r.pumpTunToUdp();

    var buf: [MAX_WIRE]u8 = undefined;
    const rc = linux.recvfrom(udp_a, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);

    // Peer A decodes with its rx key for traffic from the hub: derive(psk, 1, 2).
    const a_rx_key = crypto.deriveLinkKey(psk, 1, 2);
    var a_rx = crypto.RxSession.init(a_rx_key);
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(&a_rx, buf[0..rc], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &ip_pkt, out[0..plen]);

    // A packet whose destination has no route is dropped (no default peer).
    const no_route = ipPkt(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 9 });
    _ = linux.write(pipe_fds[1], &no_route, no_route.len);
    r.pumpTunToUdp();
    const rc2 = linux.recvfrom(udp_a, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(rc2) == .AGAIN);
}

test "pump: relay A -> hub -> B routes by policy target, no-reflect holds" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x44} ** crypto.KEY_LEN;

    const udp_hub = try makeUdpLoopback(); // reactor (local id 1)
    defer _ = linux.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // spoke A (id 2)
    defer _ = linux.close(udp_a);
    const udp_b = try makeUdpLoopback(); // spoke B (id 3)
    defer _ = linux.close(udp_b);

    const hub_addr = try addrOf(udp_hub);

    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, try addrOf(udp_a), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);
    _ = try reg.add(psk, 3, try addrOf(udp_b), try policy.parseCidr("10.0.0.3/32"), TEST_EPOCH);

    // 10.0.0.3 relays to peer 3; 10.0.0.2 would reflect back to the source.
    const entries = [_]policy.PolicyEntry{
        .{ .src = try policy.parseCidr("0.0.0.0/0"), .dst = try policy.parseCidr("10.0.0.3/32"), .action = .forward, .target = 3 },
        .{ .src = try policy.parseCidr("0.0.0.0/0"), .dst = try policy.parseCidr("10.0.0.2/32"), .action = .forward, .target = 2 },
    };
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    // tun fd unused on the relay path; a throwaway pipe write end keeps it valid.
    var pipe_fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe_fds, linux.O{ .NONBLOCK = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);

    // A seals with its tx key to the hub: derive(psk, 2, 1).
    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);
    const to_b = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 3 });
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(&a_tx, &to_b, &wire);
    _ = linux.sendto(udp_a, &wire, wlen, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(linux.sockaddr.in));

    r.pumpUdpIngress();

    // B receives the relayed packet, decodes with derive(psk, 1, 3).
    var buf: [MAX_WIRE]u8 = undefined;
    const rcb = linux.recvfrom(udp_b, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(rcb) == .SUCCESS);
    const b_rx_key = crypto.deriveLinkKey(psk, 1, 3);
    var b_rx = crypto.RxSession.init(b_rx_key);
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(&b_rx, buf[0..rcb], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &to_b, out[0..plen]);

    // No-reflect: A sends a packet destined to itself (target 2). The hub must
    // not bounce it back to A.
    const to_self = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 2 });
    const wlen2 = encodeEgress(&a_tx, &to_self, &wire);
    _ = linux.sendto(udp_a, &wire, wlen2, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(linux.sockaddr.in));
    r.pumpUdpIngress();
    const rca = linux.recvfrom(udp_a, &buf, buf.len, 0, null, null);
    try std.testing.expect(linux.errno(rca) == .AGAIN);
}

test "pump: ingress delivers LOCAL target, drops strangers and inner-source spoofs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    var pipe_fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe_fds, linux.O{ .NONBLOCK = true })) != .SUCCESS) return error.SkipZigTest;
    defer _ = linux.close(pipe_fds[0]);
    defer _ = linux.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback(); // reactor (local id 1)
    defer _ = linux.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // spoke A (id 2), bound to 10.0.0.2/32
    defer _ = linux.close(udp_a);
    const udp_c = try makeUdpLoopback(); // an unregistered stranger
    defer _ = linux.close(udp_c);

    const hub_addr = try addrOf(udp_hub);

    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, try addrOf(udp_a), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);

    // 10.0.0.1 is the hub's own TUN address (LOCAL delivery).
    const entries = [_]policy.PolicyEntry{.{
        .src = try policy.parseCidr("0.0.0.0/0"),
        .dst = try policy.parseCidr("10.0.0.1/32"),
        .action = .forward,
        .target = peer.LOCAL_TARGET,
    }};
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);

    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    // A single per-peer session for everything peer A legitimately sends (mirrors
    // reality: one counter per peer, so sequence numbers never repeat against the
    // hub's per-peer replay window).
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);

    // Stranger (not in the registry) -> dropped by the source filter, even with
    // a correctly-sealed packet (the source filter fires before decode). Its own
    // session never reaches the hub's receive state.
    const legit = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 });
    var stray_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);
    var wire: [MAX_WIRE]u8 = undefined;
    const wl0 = encodeEgress(&stray_tx, &legit, &wire);
    _ = linux.sendto(udp_c, &wire, wl0, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(linux.sockaddr.in));
    r.pumpUdpIngress();
    var buf: [MAX_PLAINTEXT]u8 = undefined;
    try std.testing.expect(linux.errno(linux.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);

    // Inner-source spoof: A is bound to 10.0.0.2/32 but claims source 10.0.0.99.
    const spoof = ipPkt(.{ 10, 0, 0, 99 }, .{ 10, 0, 0, 1 });
    const wl1 = encodeEgress(&a_tx, &spoof, &wire);
    _ = linux.sendto(udp_a, &wire, wl1, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(linux.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(linux.errno(linux.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);

    // Legitimate packet from A to the LOCAL target -> written to the TUN.
    const wl2 = encodeEgress(&a_tx, &legit, &wire);
    _ = linux.sendto(udp_a, &wire, wl2, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(linux.sockaddr.in));
    r.pumpUdpIngress();
    const rc = linux.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    try std.testing.expectEqualSlices(u8, &legit, buf[0..rc]);
}
