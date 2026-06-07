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
//! level-triggered so `subnetra` can hot-swap the policy tree at runtime; the data
//! plane only ever reads the tree atomically and never blocks on control I/O.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const os = @import("os/mod.zig");
const policy = @import("policy.zig");
const crypto = @import("crypto.zig");
const peer = @import("peer.zig");
const uds = @import("uds.zig");
const stats = @import("stats.zig");

/// Private wire header (packed struct, physically aligned): 1B version + 1B
/// flags + 2B key_id (issue #34, the sender's own mesh id, used by the receiver
/// to SELECT the candidate peer/key before authentication so a NATed/roaming
/// spoke is identified by its key rather than its source endpoint) + 8B boot
/// epoch (issue #14, identifies the sender's current session so the receiver can
/// derive the matching session key statelessly and scope anti-replay per
/// session) + 8B monotonic sequence number (doubles as the nonce and anti-replay
/// basis). 20 bytes total. The header is serialized field-by-field (see
/// `encodeEgress`/`decodeIngress`) rather than by memory layout, so the wire
/// format is endian-stable.
pub const WireHeader = packed struct {
    version: u8 = 1,
    flags: u8 = 0,
    /// Sender mesh id (issue #34). An UNAUTHENTICATED selector: the receiver
    /// uses it only to pick which peer's key to try; a tampered value selects a
    /// wrong key and fails authentication (fail-closed). Little-endian on wire.
    key_id: u16 = 0,
    /// Sender boot epoch (wall-clock ns at startup); never zero.
    epoch: u64,
    seq: u64,
};

pub const HEADER_LEN = @divExact(@bitSizeOf(WireHeader), 8);

/// On-wire protocol version for v1.
pub const WIRE_VERSION: u8 = 1;

/// `WireHeader.flags` bit 0 (issue #96): this datagram is a one-way spoke→hub
/// keepalive, not a tunnelled packet. Its sealed body carries NO inner IP packet
/// (zero-length plaintext). The hub authenticates it like any datagram, uses it
/// only to keep the NAT pinhole open and refresh the learned endpoint, then drops
/// it before any inner-IPv4 parsing or routing. Every other flag bit stays
/// reserved (must be zero); a datagram setting one is dropped by `decodeIngress`.
pub const FLAG_KEEPALIVE: u8 = 0b0000_0001;

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
pub fn encodeEgress(tx: *crypto.TxSession, key_id: u16, ip_pkt: []const u8, out: []u8) usize {
    return encodeFramed(tx, key_id, 0, ip_pkt, out);
}

/// Seal a one-way keepalive (issue #96): the same header + seal path as a data
/// packet, but with the `KEEPALIVE` flag set and an EMPTY inner payload. Returns
/// the total wire length (`HEADER_LEN + crypto.TAG_LEN`). The sealed empty body
/// still authenticates and rides the monotonic nonce + replay window exactly like
/// a data packet, so it is not a handshake and needs no reply (iron law #8).
pub fn encodeKeepalive(tx: *crypto.TxSession, key_id: u16, out: []u8) usize {
    return encodeFramed(tx, key_id, FLAG_KEEPALIVE, &.{}, out);
}

/// Shared header serialization + seal for `encodeEgress` (flags 0) and
/// `encodeKeepalive` (flags `KEEPALIVE`, empty body). Allocation-free: writes
/// straight into `out`.
fn encodeFramed(tx: *crypto.TxSession, key_id: u16, flags: u8, ip_pkt: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= HEADER_LEN + ip_pkt.len + crypto.TAG_LEN);
    const seq = tx.counter.next();
    out[0] = WIRE_VERSION;
    out[1] = flags;
    std.mem.writeInt(u16, out[2..][0..2], key_id, .little); // key_id (sender mesh id)
    std.mem.writeInt(u64, out[4..][0..8], tx.epoch, .little);
    std.mem.writeInt(u64, out[12..][0..8], seq, .little);
    const sealed = crypto.seal(tx.skey, seq, ip_pkt, out[HEADER_LEN..]);
    return HEADER_LEN + sealed;
}

/// Read the `key_id` selector (the sender's mesh id) from a datagram's header
/// without authenticating it. Returns `null` only if the datagram is too short
/// to hold a header. The value is untrusted until `decodeIngress` authenticates
/// the datagram under the selected peer's key.
pub fn parseKeyId(datagram: []const u8) ?u16 {
    if (datagram.len < HEADER_LEN) return null;
    return std.mem.readInt(u16, datagram[2..][0..2], .little);
}

/// Parse, authenticate, then anti-replay check an inbound datagram against the
/// receive session. Writes the recovered IP packet into `out` and returns its
/// length, or `null` if the datagram must be dropped (malformed header,
/// stale/zero epoch, auth failure, or replay).
///
/// The header `key_id` (bytes [2..4]) is NOT validated here: it is the caller's
/// peer selector (see `parseKeyId`/`pumpUdpIngress`) and carries no meaning to
/// the receive session, which has already been chosen by it. A wrong `key_id`
/// selects a wrong key upstream and surfaces here as an authentication failure.
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
    if (datagram[1] & ~FLAG_KEEPALIVE != 0) return null; // only the KEEPALIVE flag (bit 0) is defined; other bits reserved
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
/// `pub` so out-of-tree benchmarks (tools/forward-bench.zig, issue #101) can
/// time the live parser; read-only, no data-plane behavior change.
pub fn ipv4Dst(pkt: []const u8) ?u32 {
    if (pkt.len < 20) return null;
    if ((pkt[0] >> 4) != 4) return null; // version
    const ihl = pkt[0] & 0x0f;
    if (ihl < 5) return null;
    if (pkt.len < @as(usize, ihl) * 4) return null;
    return std.mem.readInt(u32, pkt[16..][0..4], .big);
}

/// Extract the IPv4 source address (host byte order) after validating the
/// header. Applies the **same** version/IHL/length checks as `ipv4Dst` so that
/// the inner-source binding check and endpoint learning (issue #34) only ever
/// run on a well-formed IPv4 packet, regardless of evaluation order.
/// `pub` for the same out-of-tree benchmark use as `ipv4Dst` (issue #101).
pub fn ipv4Src(pkt: []const u8) ?u32 {
    if (pkt.len < 20) return null;
    if ((pkt[0] >> 4) != 4) return null; // version
    const ihl = pkt[0] & 0x0f;
    if (ihl < 5) return null;
    if (pkt.len < @as(usize, ihl) * 4) return null;
    return std.mem.readInt(u32, pkt[12..][0..4], .big);
}

pub const Reactor = struct {
    tun_fd: sys.fd_t,
    udp_fd: sys.fd_t,
    /// Optional AF_UNIX control listener (issue #6). When present its datagram
    /// socket is registered level-triggered in `run()` and drained via
    /// `Control.handle()`; the control plane owns the policy-tree storage and the
    /// data plane only reads `active` atomically.
    control: ?*uds.Control = null,
    active: *policy.ActiveTree,
    mode: EgressMode = .raw_direct,
    /// Multi-peer endpoint + crypto registry (per-peer keys, counters, windows).
    registry: *peer.PeerRegistry,
    /// Optional runtime counters (issue #24). Null in unit tests that don't care
    /// about observability; set by `main` so `subnetra status` can read them. Plain
    /// increments are safe under the single-threaded reactor (no atomics).
    counters: ?*stats.Counters = null,
    /// Spoke→hub keepalive (issue #96). `keepalive_ns == 0` disables it (the
    /// default, and the only setting for hub/manual roles); a NATed spoke sets a
    /// non-zero interval so it emits a tiny authenticated keepalive to its single
    /// hub peer, holding the NAT pinhole open and the hub's learned endpoint fresh
    /// with NO external sidecar. Wired by `main` for `role=spoke` only.
    keepalive_ns: u64 = 0,
    /// The hub peer id keepalives are sent to (the spoke's single hub). Only read
    /// when `keepalive_ns > 0`.
    keepalive_peer_id: u32 = 0,
    /// Monotonic-clock deadline (ns) of the next keepalive, armed in `run()`.
    keepalive_due_ns: u64 = 0,
    rx: [BUF_LEN]u8 = undefined,
    tx: [BUF_LEN]u8 = undefined,
    /// Third resident buffer for hub relay: an inbound datagram decoded into
    /// `tx` is re-sealed into `relay` before forwarding to another peer, so the
    /// two operations never alias.
    relay: [BUF_LEN]u8 = undefined,

    pub fn init(
        tun_fd: sys.fd_t,
        udp_fd: sys.fd_t,
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

    /// Single-threaded readiness loop. Forces TUN/UDP non-blocking, registers
    /// them edge-triggered and the optional control socket level-triggered on the
    /// comptime-selected `os.Poller`, and dispatches each ready fd to its drain
    /// pump. Runs until an unrecoverable poller error. The OS readiness mechanism
    /// (epoll on Linux, poll(2) on macOS) lives behind `os.Poller`; this loop has
    /// no runtime OS branch.
    pub fn run(self: *Reactor) !void {
        try sys.setNonblock(self.tun_fd);
        try sys.setNonblock(self.udp_fd);

        var poller = try os.Poller.init();
        defer poller.deinit();

        try poller.add(self.tun_fd, .edge);
        try poller.add(self.udp_fd, .edge);
        // Control socket is level-triggered: handle() processes a bounded number
        // of commands per tick, and the poller re-notifies while datagrams remain.
        if (self.control) |c| try poller.add(c.fd, .level);

        // Arm the first keepalive (issue #96). When disabled (keepalive_ns == 0)
        // the poll blocks forever as before — zero timer overhead on the hub.
        if (self.keepalive_ns != 0) self.keepalive_due_ns = monoNs() + self.keepalive_ns;

        var ready: [16]sys.fd_t = undefined;
        while (true) {
            // Emit a due keepalive, then derive the poll timeout from the next
            // deadline. Driven purely by the poll timeout in this single loop —
            // no threads, no timerfd, no second OS branch (issue #96).
            const now = monoNs();
            if (self.keepalive_ns != 0 and now >= self.keepalive_due_ns) {
                self.sendKeepalive();
                self.keepalive_due_ns = now + self.keepalive_ns;
            }
            const n = try poller.wait(&ready, self.keepaliveTimeoutMs(now));
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const fd = ready[i];
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

    /// Milliseconds the poll should block before the next keepalive is due, given
    /// the current monotonic `now_ns`; `-1` (block forever) when keepalive is
    /// disabled. Pure (takes the clock as an argument) so the schedule is
    /// unit-testable without sleeping. Rounds UP so the loop never busy-spins on a
    /// sub-millisecond remainder.
    fn keepaliveTimeoutMs(self: *const Reactor, now_ns: u64) i32 {
        if (self.keepalive_ns == 0) return -1;
        if (now_ns >= self.keepalive_due_ns) return 0;
        const ms = (self.keepalive_due_ns - now_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
        return if (ms > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(ms);
    }

    /// Seal and send one keepalive to the configured hub peer (issue #96).
    /// Best-effort: a vanished hub or a transient send error is counted-or-ignored,
    /// never fatal — the next interval simply tries again. Reuses the resident `tx`
    /// buffer (idle between pump dispatches in the single-threaded loop).
    fn sendKeepalive(self: *Reactor) void {
        const hub = self.registry.findById(self.keepalive_peer_id) orelse return;
        const wire_len = encodeKeepalive(&hub.tx, self.localKeyId(), &self.tx);
        if (self.sendTo(hub.endpoint, self.tx[0..wire_len])) self.cInc("keepalive_tx");
    }

    inline fn cInc(self: *Reactor, comptime field: []const u8) void {
        if (self.counters) |c| c.inc(field);
    }

    inline fn cAdd(self: *Reactor, comptime field: []const u8, n: u64) void {
        if (self.counters) |c| c.add(field, n);
    }

    /// Drain the TUN fd (locally-originated traffic): read each IP packet, look
    /// up its destination in the policy tree to find the target peer, seal it
    /// with that peer's key, and forward. Packets with no route, a DROP rule, a
    /// LOCAL target (would loop to self), or an unknown target are dropped.
    /// Loops until EAGAIN.
    pub fn pumpTunToUdp(self: *Reactor) void {
        while (true) {
            const pkt = os.tunRead(self.tun_fd, &self.rx) orelse return;
            self.cInc("tun_rx_packets");
            self.cAdd("tun_rx_bytes", @intCast(pkt.len));

            const dst = ipv4Dst(pkt) orelse {
                self.cInc("drop_tun_not_ipv4");
                continue; // non-IPv4/malformed -> drop
            };
            const entry = self.active.load().match(dst) orelse {
                self.cInc("drop_tun_no_route");
                continue; // no route -> drop
            };
            if (entry.action == .drop) {
                self.cInc("drop_tun_drop_rule");
                continue;
            }
            if (entry.target == peer.LOCAL_TARGET) {
                self.cInc("drop_tun_local_loop");
                continue; // local-origin to local -> drop
            }
            const dst_peer = self.registry.findById(entry.target) orelse {
                self.cInc("drop_tun_unknown_target");
                continue; // unknown target
            };
            if (pkt.len > MAX_PLAINTEXT) {
                self.cInc("drop_tun_oversized");
                continue; // oversized -> drop
            }
            egress(self.mode, pkt) catch {
                self.cInc("drop_tun_egress_err");
                continue; // v2 modes not yet shipped -> drop
            };

            const wire_len = encodeEgress(&dst_peer.tx, self.localKeyId(), pkt, &self.tx);
            if (self.sendTo(dst_peer.endpoint, self.tx[0..wire_len])) {
                self.cInc("udp_tx_packets");
                self.cAdd("udp_tx_bytes", wire_len);
            } else {
                self.cInc("drop_tun_send_err");
            }
        }
    }

    /// Drain the UDP fd: filter by source endpoint, authenticate + anti-replay
    /// with the source peer's key, enforce inner-source binding, then route by
    /// the policy `target` — deliver to the local TUN, or relay to another peer
    /// (hub behaviour). Loops until EAGAIN.
    pub fn pumpUdpIngress(self: *Reactor) void {
        while (true) {
            var src: sys.sockaddr.in = undefined;
            var slen: sys.socklen_t = @sizeOf(sys.sockaddr.in);
            const rc = sys.recvfrom(self.udp_fd, &self.rx, self.rx.len, 0, @ptrCast(&src), &slen);
            const e = sys.errno(rc);
            if (e == .AGAIN) return;
            if (e == .INTR) continue;
            if (e != .SUCCESS) return;
            const dgram = self.rx[0..@intCast(rc)];
            self.cInc("udp_rx_packets");
            self.cAdd("udp_rx_bytes", @intCast(rc));

            // Identity selector (issue #34): the candidate peer is chosen by the
            // header `key_id` (the sender's mesh id), NOT by source endpoint — a
            // NATed/roaming spoke may legitimately arrive from an unexpected
            // endpoint. This selection is only a HINT until the datagram
            // authenticates below; a wrong/forged key_id fails authentication.
            const key_id = parseKeyId(dgram) orelse {
                self.cInc("drop_udp_auth_or_invalid"); // too short to hold a header
                continue;
            };
            const src_peer = self.registry.findById(key_id) orelse {
                self.cInc("drop_udp_unknown_peer"); // key_id matches no configured peer
                continue;
            };

            const plen = decodeIngress(&src_peer.rx, dgram, &self.tx) orelse {
                self.cInc("drop_udp_auth_or_invalid");
                continue;
            };

            // Keepalive (issue #96): the datagram has authenticated AND passed the
            // anti-replay window inside `decodeIngress`, so it is genuinely
            // `src_peer` and not a replay. A keepalive carries NO inner packet, so
            // it refreshes the learned endpoint + `last_seen` (the whole point —
            // keeping a NATed spoke reachable) and is then dropped before any
            // inner-IPv4 parsing or routing. The flag byte is unauthenticated, but
            // an attacker can only set it on a datagram that already authenticates
            // and is not a replay, which grants no endpoint-move or delivery power
            // they did not already have (see issue #34's residual). An
            // UNauthenticated keepalive never reaches here — `decodeIngress`
            // dropped it above, so it changes nothing.
            if (dgram[1] & FLAG_KEEPALIVE != 0) {
                self.maybeLearnEndpoint(src_peer, src);
                self.cInc("keepalive_rx");
                continue;
            }
            const pkt = self.tx[0..plen];

            // Inner-source binding: the decoded source IP must belong to the
            // source peer's allowed prefix (anti-spoofing).
            const isrc = ipv4Src(pkt) orelse {
                self.cInc("drop_udp_not_ipv4");
                continue;
            };
            if (!src_peer.allowed_src.contains(isrc)) {
                self.cInc("drop_udp_spoof");
                continue;
            }

            // Endpoint roaming (issue #34): the datagram has now authenticated
            // AND passed the inner-source check, so it is genuinely `src_peer`.
            // Learn its current UDP endpoint so replies (and hub relays) follow a
            // roamed/NATed spoke without operator intervention. Strictly gated on
            // full decode success + the spoof check above, so a replayed, forged,
            // or inner-source-spoofed packet can never move the endpoint.
            self.maybeLearnEndpoint(src_peer, src);

            const dst = ipv4Dst(pkt) orelse {
                self.cInc("drop_udp_not_ipv4");
                continue;
            };
            const entry = self.active.load().match(dst) orelse {
                self.cInc("drop_udp_no_route");
                continue; // no route -> drop
            };
            if (entry.action == .drop) {
                self.cInc("drop_udp_drop_rule");
                continue;
            }

            if (entry.target == peer.LOCAL_TARGET) {
                if (self.writeTun(pkt)) {
                    self.cInc("tun_tx_packets");
                    self.cAdd("tun_tx_bytes", @intCast(plen));
                } else {
                    self.cInc("drop_udp_send_err");
                }
                continue;
            }

            // Relay to another peer (hub forwarding).
            const dst_peer = self.registry.findById(entry.target) orelse {
                self.cInc("drop_udp_unknown_target");
                continue; // unknown target
            };
            if (dst_peer.id == src_peer.id) {
                self.cInc("drop_udp_no_reflect");
                continue; // no-reflect guard
            }
            if (pkt.len > MAX_PLAINTEXT) {
                self.cInc("drop_udp_oversized");
                continue;
            }
            const wire_len = encodeEgress(&dst_peer.tx, self.localKeyId(), pkt, &self.relay);
            if (self.sendTo(dst_peer.endpoint, self.relay[0..wire_len])) {
                self.cInc("relay_packets");
                self.cAdd("relay_bytes", wire_len);
            } else {
                self.cInc("drop_udp_send_err");
            }
        }
    }

    /// Send `buf` to `endpoint`. Returns true if the datagram was handed to the
    /// kernel without error, false otherwise (so the caller can count send
    /// errors honestly rather than assuming success).
    fn sendTo(self: *Reactor, endpoint: sys.sockaddr.in, buf: []const u8) bool {
        var ep = endpoint;
        while (true) {
            const rc = sys.sendto(
                self.udp_fd,
                buf.ptr,
                buf.len,
                0,
                @ptrCast(&ep),
                @sizeOf(sys.sockaddr.in),
            );
            if (sys.errno(rc) == .INTR) continue;
            return sys.errno(rc) == .SUCCESS;
        }
    }

    /// Write `buf` (a bare IP packet) to the local TUN. Returns true on success,
    /// false on a write error (counted by the caller). The backend handles any
    /// platform framing (e.g. macOS utun's 4-byte address-family prefix).
    fn writeTun(self: *Reactor, buf: []const u8) bool {
        return os.tunWrite(self.tun_fd, buf);
    }

    /// This node's own mesh id as the egress `key_id` selector (issue #34). The
    /// id is validated to fit `u16` at config/registry load (`PeerRegistry.add`),
    /// so the narrowing cast never loses information.
    inline fn localKeyId(self: *Reactor) u16 {
        return @intCast(self.registry.local_id);
    }

    /// Update a peer's learned UDP endpoint from an authenticated datagram's
    /// source (issue #34). MUST be called only after the datagram has fully
    /// authenticated (decode + anti-replay), so an unauthenticated or replayed
    /// packet can never move the endpoint. For a routed data packet the caller
    /// also applies the inner-source binding check first; a keepalive (issue #96)
    /// carries no inner packet, so its authenticity rests entirely on auth+replay
    /// and it skips that check. The endpoint is runtime state only — it is never
    /// written back to config.
    fn maybeLearnEndpoint(self: *Reactor, p: *peer.Peer, src: sys.sockaddr.in) void {
        p.last_seen_wall_ns = wallNs();
        if (p.endpoint.addr != src.addr or p.endpoint.port != src.port) {
            p.endpoint.addr = src.addr;
            p.endpoint.port = src.port;
            self.cInc("udp_endpoint_learned");
        }
    }
};

/// Wall-clock nanoseconds for the observability-only `last_seen_wall_ns` field.
/// REALTIME (not MONOTONIC) so `subnetra status` shows a human-meaningful instant;
/// it is subject to NTP/clock jumps and MUST NOT drive any protocol logic. On a
/// non-Linux host (unit tests only) it returns 0.
fn wallNs() u64 {
    if (builtin.os.tag != .linux) return 0;
    var ts: sys.timespec = undefined;
    if (sys.errno(sys.clock_gettime(sys.CLOCK.REALTIME, &ts)) != .SUCCESS) return 0;
    if (ts.sec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Monotonic nanoseconds for keepalive scheduling (issue #96). Unlike `wallNs`
/// (REALTIME, Linux-only, observability) this MUST work on every platform the
/// reactor runs on, including macOS spokes, because it drives a real timer; it is
/// also immune to wall-clock steps. Returns 0 only on an impossible clock failure,
/// which at worst makes one keepalive fire early.
fn monoNs() u64 {
    var ts: sys.timespec = undefined;
    if (sys.errno(sys.clock_gettime(sys.CLOCK.MONOTONIC, &ts)) != .SUCCESS) return 0;
    if (ts.sec < 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

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
    const wlen = encodeEgress(&tx, 2, &ip_pkt, &wire);
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
    const wlen = encodeEgress(&tx, 2, &ip_pkt, &wire);
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

    // Set a still-reserved flag bit (bit 1) -> drop. Bit 0 is now KEEPALIVE and
    // is accepted; every other bit remains reserved and must be rejected.
    var badflags = wire;
    badflags[1] = 0b0000_0010;
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
    const l1a = encodeEgress(&tx1, 2, &ip_pkt, &w1a); // seq 1
    const l1b = encodeEgress(&tx1, 2, &ip_pkt, &w1b); // seq 2
    try std.testing.expect(decodeIngress(&rx, w1a[0..l1a], &out) != null);
    try std.testing.expect(decodeIngress(&rx, w1b[0..l1b], &out) != null);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_000), rx.epoch);

    // The sender restarts: session 2 (a later epoch) restarts seq at 1. Without
    // the epoch reset this seq-1 packet would be rejected as a replay; with it,
    // the newer epoch is adopted and the window resets, so it is accepted.
    var tx2 = crypto.TxSession.init(key, 1_700_000_000_000_000_500);
    var w2: [MAX_WIRE]u8 = undefined;
    const l2 = encodeEgress(&tx2, 2, &ip_pkt, &w2); // seq 1 again, new epoch
    try std.testing.expect(decodeIngress(&rx, w2[0..l2], &out) != null);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_500), rx.epoch);

    // A leftover packet from the retired session 1 (older epoch) is now dropped,
    // defeating cross-epoch replay of the previous lifetime.
    var w1c: [MAX_WIRE]u8 = undefined;
    const l1c = encodeEgress(&tx1, 2, &ip_pkt, &w1c); // session 1, seq 3
    try std.testing.expect(decodeIngress(&rx, w1c[0..l1c], &out) == null);

    // Replay within the live session 2 is still rejected.
    try std.testing.expect(decodeIngress(&rx, w2[0..l2], &out) == null);
}

test "keepalive: encodeKeepalive seals an empty KEEPALIVE-flagged datagram (issue #96)" {
    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;
    const link = crypto.deriveLinkKey(psk, 2, 1);
    var tx = crypto.TxSession.init(link, TEST_EPOCH);
    var rx = crypto.RxSession.init(link);

    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeKeepalive(&tx, 2, &wire);
    // A keepalive is exactly a header + a tag over an empty body — no inner packet.
    try std.testing.expectEqual(@as(usize, HEADER_LEN + crypto.TAG_LEN), wlen);
    try std.testing.expectEqual(WIRE_VERSION, wire[0]);
    try std.testing.expect(wire[1] & FLAG_KEEPALIVE != 0);

    // It authenticates and decodes to a zero-length plaintext (carries no packet).
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(&rx, wire[0..wlen], &out);
    try std.testing.expectEqual(@as(?usize, 0), plen);

    // Tampering the sealed body still fails authentication like any datagram.
    var tampered = wire;
    tampered[HEADER_LEN] ^= 0xFF;
    var rx2 = crypto.RxSession.init(link);
    try std.testing.expect(decodeIngress(&rx2, tampered[0..wlen], &out) == null);
}

test "keepalive: keepaliveTimeoutMs reflects the schedule (issue #96)" {
    var reg = peer.PeerRegistry.init(1);
    var tree = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&tree);
    var r = Reactor.init(-1, -1, null, &active, &reg);

    // Disabled -> block forever.
    r.keepalive_ns = 0;
    try std.testing.expectEqual(@as(i32, -1), r.keepaliveTimeoutMs(0));
    try std.testing.expectEqual(@as(i32, -1), r.keepaliveTimeoutMs(999));

    // Enabled, due in the future -> milliseconds remaining.
    r.keepalive_ns = 20 * std.time.ns_per_s;
    r.keepalive_due_ns = 1000 * std.time.ns_per_ms; // due at t=1000ms
    try std.testing.expectEqual(@as(i32, 1000), r.keepaliveTimeoutMs(0));
    try std.testing.expectEqual(@as(i32, 500), r.keepaliveTimeoutMs(500 * std.time.ns_per_ms));

    // Due now / overdue -> 0 (fire immediately, never negative).
    try std.testing.expectEqual(@as(i32, 0), r.keepaliveTimeoutMs(1000 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i32, 0), r.keepaliveTimeoutMs(5000 * std.time.ns_per_ms));

    // A sub-millisecond remainder rounds UP so the loop never busy-spins on it.
    r.keepalive_due_ns = 1; // 1 ns from t=0
    try std.testing.expectEqual(@as(i32, 1), r.keepaliveTimeoutMs(0));
}

// ---- Live-socket pump tests (Linux only; skip elsewhere / on permission gaps) ----

// Live-socket pump tests are Linux-gated: they assume synchronous loopback
// delivery (a Linux behaviour) so a datagram is readable immediately after
// sendto. macOS defers loopback delivery, so these would need explicit poll
// readiness; the production reactor never races (epoll/poll drive readiness).
// macOS data-plane behaviour is certified by the manual acceptance runbook
// (docs/macos-spoke-acceptance.md, issue #79) per the RFC.
fn makeUdpLoopback() !sys.fd_t {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, true, false) catch return error.SkipZigTest;
    var addr = sys.sockaddr.in{ .family = sys.AF.INET, .port = 0, .addr = 0x0100007f }; // 127.0.0.1:0
    if (sys.errno(sys.bind(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in))) != .SUCCESS) {
        _ = sys.close(fd);
        return error.SkipZigTest;
    }
    return fd;
}

fn addrOf(fd: sys.fd_t) !sys.sockaddr.in {
    var a: sys.sockaddr.in = undefined;
    var l: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    if (sys.errno(sys.getsockname(fd, @ptrCast(&a), &l)) != .SUCCESS) return error.SkipZigTest;
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

/// A synthetic UDP endpoint (127.0.0.1:`port`) used as a peer's *stale* configured
/// endpoint, so endpoint relearning (issue #34) is observable as a change away
/// from it. `port` is chosen below the ephemeral range so it never aliases a
/// loopback test socket.
fn fakeAddr(port: u16) sys.sockaddr.in {
    return .{ .family = sys.AF.INET, .port = std.mem.nativeToBig(u16, port), .addr = 0x0100007f };
}

fn sameEndpoint(a: sys.sockaddr.in, b: sys.sockaddr.in) bool {
    return a.addr == b.addr and a.port == b.port;
}

test "pump: TUN->UDP seals to the policy-selected peer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x33} ** crypto.KEY_LEN;

    // tun side: a pipe whose read end the reactor drains.
    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback(); // reactor's udp_fd (local id 1)
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // peer A (id 2)
    defer _ = sys.close(udp_a);

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
    var ctr = stats.Counters{};
    r.counters = &ctr;

    const ip_pkt = ipPkt(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 2 });
    _ = sys.write(pipe_fds[1], &ip_pkt, ip_pkt.len);

    r.pumpTunToUdp();

    // Issue #24: a forwarded packet bumps the rx-from-tun and tx-to-udp counters.
    try std.testing.expectEqual(@as(u64, 1), ctr.tun_rx_packets);
    try std.testing.expectEqual(@as(u64, 1), ctr.udp_tx_packets);
    try std.testing.expect(ctr.udp_tx_bytes > 0);

    var buf: [MAX_WIRE]u8 = undefined;
    const rc = sys.recvfrom(udp_a, &buf, buf.len, 0, null, null);
    try std.testing.expect(sys.errno(rc) == .SUCCESS);

    // Peer A decodes with its rx key for traffic from the hub: derive(psk, 1, 2).
    const a_rx_key = crypto.deriveLinkKey(psk, 1, 2);
    var a_rx = crypto.RxSession.init(a_rx_key);
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(&a_rx, buf[0..@intCast(rc)], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &ip_pkt, out[0..plen]);

    // A packet whose destination has no route is dropped (no default peer).
    const no_route = ipPkt(.{ 10, 0, 0, 1 }, .{ 10, 0, 0, 9 });
    _ = sys.write(pipe_fds[1], &no_route, no_route.len);
    r.pumpTunToUdp();
    const rc2 = sys.recvfrom(udp_a, &buf, buf.len, 0, null, null);
    try std.testing.expect(sys.errno(rc2) == .AGAIN);
    // The no-route packet was read but dropped: the drop counter records it.
    try std.testing.expectEqual(@as(u64, 2), ctr.tun_rx_packets);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_tun_no_route);
}

test "pump: relay A -> hub -> B routes by policy target, no-reflect holds" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x44} ** crypto.KEY_LEN;

    const udp_hub = try makeUdpLoopback(); // reactor (local id 1)
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // spoke A (id 2)
    defer _ = sys.close(udp_a);
    const udp_b = try makeUdpLoopback(); // spoke B (id 3)
    defer _ = sys.close(udp_b);

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
    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);

    // A seals with its tx key to the hub: derive(psk, 2, 1).
    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);
    const to_b = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 3 });
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(&a_tx, 2, &to_b, &wire);
    _ = sys.sendto(udp_a, &wire, wlen, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));

    r.pumpUdpIngress();

    // B receives the relayed packet, decodes with derive(psk, 1, 3).
    var buf: [MAX_WIRE]u8 = undefined;
    const rcb = sys.recvfrom(udp_b, &buf, buf.len, 0, null, null);
    try std.testing.expect(sys.errno(rcb) == .SUCCESS);
    const b_rx_key = crypto.deriveLinkKey(psk, 1, 3);
    var b_rx = crypto.RxSession.init(b_rx_key);
    var out: [MAX_PLAINTEXT]u8 = undefined;
    const plen = decodeIngress(&b_rx, buf[0..@intCast(rcb)], &out) orelse return error.UnexpectedDrop;
    try std.testing.expectEqualSlices(u8, &to_b, out[0..plen]);

    // No-reflect: A sends a packet destined to itself (target 2). The hub must
    // not bounce it back to A.
    const to_self = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 2 });
    const wlen2 = encodeEgress(&a_tx, 2, &to_self, &wire);
    _ = sys.sendto(udp_a, &wire, wlen2, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    const rca = sys.recvfrom(udp_a, &buf, buf.len, 0, null, null);
    try std.testing.expect(sys.errno(rca) == .AGAIN);
}

test "pump: ingress delivers LOCAL target, drops strangers and inner-source spoofs" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback(); // reactor (local id 1)
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // spoke A (id 2), bound to 10.0.0.2/32
    defer _ = sys.close(udp_a);
    const udp_c = try makeUdpLoopback(); // an unregistered stranger
    defer _ = sys.close(udp_c);

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
    var ctr = stats.Counters{};
    r.counters = &ctr;

    const a_addr = try addrOf(udp_a);
    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    // A single per-peer session for everything peer A legitimately sends (mirrors
    // reality: one counter per peer, so sequence numbers never repeat against the
    // hub's per-peer replay window).
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);

    const legit = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 });
    var wire: [MAX_WIRE]u8 = undefined;
    var buf: [MAX_PLAINTEXT]u8 = undefined;

    // Unknown `key_id` selector (issue #34): no peer has id 99, so the datagram is
    // dropped before any crypto runs. Sealed with A's real key but mislabelled.
    const wl_unk = encodeEgress(&a_tx, 99, &legit, &wire);
    _ = sys.sendto(udp_a, &wire, wl_unk, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_unknown_peer);

    // True stranger: a correct `key_id=2` but sealed with the WRONG key, arriving
    // from a brand-new endpoint (udp_c). It selects peer A, fails authentication,
    // and is dropped — and it MUST NOT move A's learned endpoint.
    const wrong_key: crypto.Key = [_]u8{0x77} ** crypto.KEY_LEN;
    var bad_tx = crypto.TxSession.init(wrong_key, TEST_EPOCH);
    const wl_bad = encodeEgress(&bad_tx, 2, &legit, &wire);
    _ = sys.sendto(udp_c, &wire, wl_bad, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_auth_or_invalid);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, a_addr));

    // Inner-source spoof: A is bound to 10.0.0.2/32 but claims source 10.0.0.99.
    // It authenticates (so the replay window records it) but fails the inner-source
    // check — and an authenticated-but-spoofed packet MUST NOT move the endpoint.
    const spoof = ipPkt(.{ 10, 0, 0, 99 }, .{ 10, 0, 0, 1 });
    const wl1 = encodeEgress(&a_tx, 2, &spoof, &wire);
    _ = sys.sendto(udp_c, &wire, wl1, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_spoof);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, a_addr));

    // Legitimate packet from A's configured endpoint -> written to the TUN. The
    // endpoint is unchanged, so no relearn is recorded.
    const wl2 = encodeEgress(&a_tx, 2, &legit, &wire);
    _ = sys.sendto(udp_a, &wire, wl2, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    const rc = sys.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(sys.errno(rc) == .SUCCESS);
    try std.testing.expectEqualSlices(u8, &legit, buf[0..@intCast(rc)]);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);
}

test "pump: an authenticated packet from a new endpoint relearns the peer (issue #34)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback();
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // A's ACTUAL (roamed) endpoint
    defer _ = sys.close(udp_a);

    const hub_addr = try addrOf(udp_hub);
    const a_addr = try addrOf(udp_a);

    // A is CONFIGURED at a stale endpoint; it actually transmits from udp_a.
    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, fakeAddr(9), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);
    try std.testing.expect(!sameEndpoint(reg.findById(2).?.endpoint, a_addr));

    const entries = [_]policy.PolicyEntry{.{
        .src = try policy.parseCidr("0.0.0.0/0"),
        .dst = try policy.parseCidr("10.0.0.1/32"),
        .action = .forward,
        .target = peer.LOCAL_TARGET,
    }};
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;

    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);
    const legit = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 });
    var wire: [MAX_WIRE]u8 = undefined;
    var buf: [MAX_PLAINTEXT]u8 = undefined;

    // First authenticated datagram from the new endpoint: delivered AND learned.
    const wl0 = encodeEgress(&a_tx, 2, &legit, &wire);
    _ = sys.sendto(udp_a, &wire, wl0, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    const rc0 = sys.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(sys.errno(rc0) == .SUCCESS);
    try std.testing.expectEqualSlices(u8, &legit, buf[0..@intCast(rc0)]);
    try std.testing.expectEqual(@as(u64, 1), ctr.udp_endpoint_learned);
    try std.testing.expectEqual(@as(u64, 0), ctr.drop_udp_unknown_peer);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, a_addr));

    // A second datagram from the SAME (now learned) endpoint does not relearn.
    const wl1 = encodeEgress(&a_tx, 2, &legit, &wire);
    _ = sys.sendto(udp_a, &wire, wl1, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    const rc1 = sys.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expect(sys.errno(rc1) == .SUCCESS);
    try std.testing.expectEqual(@as(u64, 1), ctr.udp_endpoint_learned);
}

test "pump: a replayed datagram from a new endpoint cannot move the endpoint (issue #34)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback();
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback();
    defer _ = sys.close(udp_a);
    const udp_c = try makeUdpLoopback(); // attacker replaying from elsewhere
    defer _ = sys.close(udp_c);

    const hub_addr = try addrOf(udp_hub);
    const a_addr = try addrOf(udp_a);

    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, a_addr, try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);

    const entries = [_]policy.PolicyEntry{.{
        .src = try policy.parseCidr("0.0.0.0/0"),
        .dst = try policy.parseCidr("10.0.0.1/32"),
        .action = .forward,
        .target = peer.LOCAL_TARGET,
    }};
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;

    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);
    const legit = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 1 });
    var wire: [MAX_WIRE]u8 = undefined;
    var buf: [MAX_PLAINTEXT]u8 = undefined;

    // A genuine datagram from A's real endpoint -> accepted, no endpoint change.
    const wl = encodeEgress(&a_tx, 2, &legit, &wire);
    _ = sys.sendto(udp_a, &wire, wl, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .SUCCESS);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);

    // The attacker replays the identical bytes from udp_c. The replay window
    // rejects it (decode null) BEFORE any endpoint learning, so A stays put.
    _ = sys.sendto(udp_c, &wire, wl, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_auth_or_invalid);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, a_addr));
}

test "pump: a short datagram is counted and never crashes parseKeyId (issue #34)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const udp_hub = try makeUdpLoopback();
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback();
    defer _ = sys.close(udp_a);
    const hub_addr = try addrOf(udp_hub);

    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, try addrOf(udp_a), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);

    const entries = [_]policy.PolicyEntry{.{
        .src = try policy.parseCidr("0.0.0.0/0"),
        .dst = try policy.parseCidr("10.0.0.1/32"),
        .action = .forward,
        .target = peer.LOCAL_TARGET,
    }};
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    var r = Reactor.init(0, udp_hub, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;

    // 3 bytes: too short to even hold the key_id selector at [2..4].
    const runt = [_]u8{ 1, 0, 0 };
    _ = sys.sendto(udp_a, &runt, runt.len, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_auth_or_invalid);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);
}
test "pump: relay learns the source's endpoint, leaves the destination's untouched (issue #34)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x44} ** crypto.KEY_LEN;

    const udp_hub = try makeUdpLoopback();
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback(); // A's ACTUAL (roamed) endpoint
    defer _ = sys.close(udp_a);
    const udp_b = try makeUdpLoopback(); // B, at its configured endpoint
    defer _ = sys.close(udp_b);

    const hub_addr = try addrOf(udp_hub);
    const a_addr = try addrOf(udp_a);
    const b_addr = try addrOf(udp_b);

    // A (id 2) is CONFIGURED at a stale endpoint; B (id 3) at its real one.
    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, fakeAddr(9), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);
    _ = try reg.add(psk, 3, b_addr, try policy.parseCidr("10.0.0.3/32"), TEST_EPOCH);

    const entries = [_]policy.PolicyEntry{
        .{ .src = try policy.parseCidr("0.0.0.0/0"), .dst = try policy.parseCidr("10.0.0.3/32"), .action = .forward, .target = 3 },
    };
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;

    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);
    const to_b = ipPkt(.{ 10, 0, 0, 2 }, .{ 10, 0, 0, 3 });
    var wire: [MAX_WIRE]u8 = undefined;
    const wlen = encodeEgress(&a_tx, 2, &to_b, &wire);
    _ = sys.sendto(udp_a, &wire, wlen, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();

    // B still receives the relayed packet at its (unchanged) endpoint.
    var buf: [MAX_WIRE]u8 = undefined;
    const rcb = sys.recvfrom(udp_b, &buf, buf.len, 0, null, null);
    try std.testing.expect(sys.errno(rcb) == .SUCCESS);

    // The hub learned A's real endpoint; B's endpoint was not disturbed.
    try std.testing.expectEqual(@as(u64, 1), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, a_addr));
    try std.testing.expect(sameEndpoint(reg.findById(3).?.endpoint, b_addr));
}
test "pump: an authenticated non-IPv4 inner packet is dropped before endpoint learning (#41)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback();
    defer _ = sys.close(udp_hub);
    const udp_a = try makeUdpLoopback();
    defer _ = sys.close(udp_a);
    const hub_addr = try addrOf(udp_hub);

    // A is configured at a stale endpoint; if learning ran it would move to udp_a.
    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, fakeAddr(9), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);

    const entries = [_]policy.PolicyEntry{.{
        .src = try policy.parseCidr("0.0.0.0/0"),
        .dst = try policy.parseCidr("10.0.0.1/32"),
        .action = .forward,
        .target = peer.LOCAL_TARGET,
    }};
    var tree = policy.PolicyTree{ .entries = &entries };
    var active = policy.ActiveTree.init(&tree);

    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;

    const a_tx_key = crypto.deriveLinkKey(psk, 2, 1);
    var a_tx = crypto.TxSession.init(a_tx_key, TEST_EPOCH);

    // Authenticated but malformed inner: version nibble is 0 (not 4). Bytes
    // [12..16] hold 10.0.0.2, which WOULD satisfy allowed_src if the source
    // parser skipped IPv4 validation — so this packet must be dropped at the
    // not_ipv4 gate, before any endpoint learning.
    var bad = [_]u8{0} ** 28;
    bad[12] = 10;
    bad[13] = 0;
    bad[14] = 0;
    bad[15] = 2;
    var wire: [MAX_WIRE]u8 = undefined;
    const wl = encodeEgress(&a_tx, 2, &bad, &wire);
    _ = sys.sendto(udp_a, &wire, wl, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();

    var buf: [MAX_PLAINTEXT]u8 = undefined;
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_not_ipv4);
    try std.testing.expectEqual(@as(u64, 0), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, fakeAddr(9)));
}

test "keepalive: a spoke emits a sealed KEEPALIVE datagram to its hub with no host traffic (issue #96)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const udp_hub = try makeUdpLoopback(); // the hub: receives the keepalive
    defer _ = sys.close(udp_hub);
    const udp_spoke = try makeUdpLoopback(); // the spoke's own UDP socket (egress)
    defer _ = sys.close(udp_spoke);

    const hub_addr = try addrOf(udp_hub);

    // A spoke (local_id=2) whose single hub peer is id=1 at hub_addr.
    var reg = peer.PeerRegistry.init(2);
    _ = try reg.add(psk, 1, hub_addr, ANY_SRC, TEST_EPOCH);

    var tree = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&tree);
    var r = Reactor.init(-1, udp_spoke, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;
    r.keepalive_ns = 20 * std.time.ns_per_s;
    r.keepalive_peer_id = 1;

    // Emit one keepalive directly (no TUN/host traffic involved).
    r.sendKeepalive();
    try std.testing.expectEqual(@as(u64, 1), ctr.keepalive_tx);

    // The hub receives exactly a header + tag, KEEPALIVE-flagged, and it
    // authenticates + decodes to a zero-length plaintext (no inner packet).
    var recv: [MAX_WIRE]u8 = undefined;
    const rc = sys.read(udp_hub, &recv, recv.len);
    try std.testing.expect(sys.errno(rc) == .SUCCESS);
    const got: usize = @intCast(rc);
    try std.testing.expectEqual(@as(usize, HEADER_LEN + crypto.TAG_LEN), got);
    try std.testing.expect(recv[1] & FLAG_KEEPALIVE != 0);

    var hub_rx = crypto.RxSession.init(crypto.deriveLinkKey(psk, 2, 1));
    var out: [MAX_PLAINTEXT]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), decodeIngress(&hub_rx, recv[0..got], &out));
}

test "keepalive: hub authenticated keepalive refreshes the endpoint and is not injected into the TUN (issue #96)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const psk: crypto.Key = [_]u8{0x55} ** crypto.KEY_LEN;

    const pipe_fds = sys.pipeNonblock() catch return error.SkipZigTest;
    defer _ = sys.close(pipe_fds[0]);
    defer _ = sys.close(pipe_fds[1]);

    const udp_hub = try makeUdpLoopback(); // hub's UDP socket (reactor udp_fd)
    defer _ = sys.close(udp_hub);
    const udp_spoke = try makeUdpLoopback(); // the spoke's ACTUAL (roamed) endpoint
    defer _ = sys.close(udp_spoke);

    const hub_addr = try addrOf(udp_hub);
    const spoke_addr = try addrOf(udp_spoke);

    // The hub (local_id=1) has the spoke (id=2) CONFIGURED at a stale endpoint;
    // the spoke really transmits from udp_spoke.
    var reg = peer.PeerRegistry.init(1);
    _ = try reg.add(psk, 2, fakeAddr(9), try policy.parseCidr("10.0.0.2/32"), TEST_EPOCH);
    try std.testing.expect(!sameEndpoint(reg.findById(2).?.endpoint, spoke_addr));

    var tree = policy.PolicyTree{ .entries = &.{} };
    var active = policy.ActiveTree.init(&tree);
    var r = Reactor.init(pipe_fds[1], udp_hub, null, &active, &reg);
    var ctr = stats.Counters{};
    r.counters = &ctr;

    var spoke_tx = crypto.TxSession.init(crypto.deriveLinkKey(psk, 2, 1), TEST_EPOCH);
    var wire: [MAX_WIRE]u8 = undefined;
    var buf: [MAX_PLAINTEXT]u8 = undefined;

    // The idle spoke sends one keepalive from its roamed endpoint.
    const wl = encodeKeepalive(&spoke_tx, 2, &wire);
    _ = sys.sendto(udp_spoke, &wire, wl, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();

    // It is counted as a keepalive, relearns the endpoint + refreshes last_seen,
    // and writes NOTHING to the TUN (it carries no inner packet).
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.keepalive_rx);
    try std.testing.expectEqual(@as(u64, 0), ctr.tun_tx_packets);
    try std.testing.expectEqual(@as(u64, 1), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, spoke_addr));
    try std.testing.expect(reg.findById(2).?.last_seen_wall_ns > 0);

    // A keepalive sealed with the WRONG key fails authentication: it is dropped
    // before the keepalive branch, so it moves nothing.
    const bad_psk: crypto.Key = [_]u8{0x66} ** crypto.KEY_LEN;
    var bad_tx = crypto.TxSession.init(crypto.deriveLinkKey(bad_psk, 2, 1), TEST_EPOCH);
    const wlb = encodeKeepalive(&bad_tx, 2, &wire);
    _ = sys.sendto(udp_spoke, &wire, wlb, 0, @ptrCast(@constCast(&hub_addr)), @sizeOf(sys.sockaddr.in));
    r.pumpUdpIngress();
    try std.testing.expect(sys.errno(sys.read(pipe_fds[0], &buf, buf.len)) == .AGAIN);
    try std.testing.expectEqual(@as(u64, 1), ctr.drop_udp_auth_or_invalid);
    try std.testing.expectEqual(@as(u64, 1), ctr.keepalive_rx);
    try std.testing.expectEqual(@as(u64, 1), ctr.udp_endpoint_learned);
    try std.testing.expect(sameEndpoint(reg.findById(2).?.endpoint, spoke_addr));
}

fn fuzzIngressDecode(_: void, smith: *std.testing.Smith) anyerror!void {
    // A fixed receive session: the fuzzer drives the datagram bytes, not the key.
    // The decode path must never crash, read out of bounds, or report a length
    // larger than the output buffer for ANY input — well-formed or hostile.
    const psk: crypto.Key = [_]u8{0xAB} ** crypto.KEY_LEN;
    var rx = crypto.RxSession.init(crypto.deriveLinkKey(psk, 1, 2));

    var dgram: [MAX_WIRE]u8 = undefined;
    const n = smith.slice(&dgram);
    const input = dgram[0..n];

    // parseKeyId is a pure header read: null iff too short, never otherwise.
    const kid = parseKeyId(input);
    try std.testing.expectEqual(input.len < HEADER_LEN, kid == null);

    var out: [MAX_PLAINTEXT]u8 = undefined;
    if (decodeIngress(&rx, input, &out)) |plen| {
        // A returned length must be a valid slice of the output buffer.
        try std.testing.expect(plen <= out.len);
    }
}

test "fuzz: UDP ingress decode path tolerates arbitrary datagrams (#40)" {
    try std.testing.fuzz({}, fuzzIngressDecode, .{});
}
