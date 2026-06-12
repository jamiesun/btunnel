//! Task 6 (issue #5): Multi-peer registry for the hub-and-spoke data plane.
//!
//! A fixed-capacity, zero-allocation table mapping a mesh node id to its UDP
//! endpoint and its per-direction crypto state. Each peer holds:
//!   - a transmit key (`tx_key`) and receive key (`rx_key`) derived from the
//!     shared PSK and the ordered id pair, so every directional link has its own
//!     key. This is what makes per-peer nonce counters safe under a single PSK:
//!     a sequence number may repeat across links because the keys differ (see
//!     `crypto.deriveLinkKey`).
//!   - a monotonic transmit nonce counter and a receive anti-replay window.
//!   - `allowed_src`, the inner IPv4 source prefix bound to this endpoint, used
//!     to reject inner-source spoofing by an authenticated spoke.
//!
//! Topology scope (v1): single-hub hub-and-spoke. The hub relays between spokes;
//! spokes do not relay. The reactor additionally refuses to reflect a packet
//! back to its source peer as defence-in-depth against bounce loops.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const crypto = @import("crypto.zig");
const config = @import("config.zig");

pub const MAX_PEERS = config.MAX_PEERS;

/// Policy `target` value that means "deliver to the local TUN" rather than
/// forwarding to a peer. Zero is reserved and may never be a peer id.
pub const LOCAL_TARGET: u32 = 0;

pub const Peer = struct {
    id: u32,
    endpoint: sys.sockaddr.in,
    allowed_src: config.Cidr,
    /// Transmit session: epoch-bound key + monotonic counter (issue #14).
    tx: crypto.TxSession,
    /// Receive session: forward-only epoch + per-session anti-replay window.
    rx: crypto.RxSession,
    /// Wall-clock ns of the last authenticated datagram from this peer (issue
    /// #34). Observability only (`subnetra status`); never drives protocol logic.
    last_seen_wall_ns: u64 = 0,
    /// Optional human-readable label for this peer (observability only). Resident
    /// in a fixed-capacity buffer (no heap); `name_len == 0` means unset. METADATA
    /// ONLY: the data plane never reads it and it is never an identity/auth/routing
    /// input — key derivation, the wire `key_id`, and peer matching all stay keyed
    /// on the numeric `id` (iron law #5).
    name: [config.MAX_PEER_NAME_LEN]u8 = undefined,
    name_len: usize = 0,
    /// Index (into the reactor's `udp_fds`) of the local UDP socket this peer was
    /// last heard on. Egress to this peer goes back out THAT socket so the source
    /// port matches the NAT pinhole / cone the peer expects (multi-port listening).
    /// Defaults to 0 (the primary socket) until the first authenticated datagram.
    rx_fd_index: usize = 0,

    /// The peer's configured name as a slice (empty when unset).
    pub fn nameSlice(self: *const Peer) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const RegistryError = error{
    TooManyPeers,
    DuplicateId,
    DuplicateEndpoint,
    ReservedPeerId,
    SelfReference,
    MissingLocalId,
    /// A mesh id (this node's or a peer's) does not fit the 16-bit on-wire
    /// `key_id` selector (issue #34). Ids must be in 1..65535.
    PeerIdOutOfRange,
    ClockUnavailable,
};

/// Largest mesh id that fits the 16-bit wire `key_id` selector (issue #34).
pub const MAX_MESH_ID: u32 = 0xFFFF;

/// Earliest plausible boot epoch: 2024-01-01T00:00:00Z in nanoseconds. A clock
/// reporting an earlier wall time has not been set (no RTC / pre-NTP), which
/// would defeat the forward-only session-epoch ordering and risks a low,
/// collision-prone epoch. We fail closed rather than emit an unsafe epoch.
const MIN_BOOT_EPOCH_NS: u64 = 1_704_067_200 * std.time.ns_per_s;

/// This daemon's boot epoch (issue #14): wall-clock nanoseconds sampled once at
/// startup. Each process lifetime gets a distinct, time-ordered value, which:
///   - makes the per-session key (`crypto.deriveSessionKey`) fresh on every
///     restart so the transmit counter can safely restart at 1 without ever
///     reproducing a `(key, nonce)` pair from a previous lifetime, and
///   - lets receivers order sessions forward-only (a later boot supersedes an
///     earlier one) so a one-sided restart re-establishes a fresh session.
///
/// Clock failure or an implausibly early clock is FATAL (fail-closed): emitting
/// a zero/low epoch would be catastrophic. Linux and macOS — the shipped spoke
/// platforms — both sample the real wall clock through the portable
/// `clock_gettime` (issue #152: a `builtin.os.tag != .linux` short-circuit used
/// to hand macOS a CONSTANT epoch, silently re-opening the #14 restart
/// nonce-reuse break on Darwin). Only a genuinely unsupported OS — a
/// non-Linux/non-Darwin target that never runs as a daemon and is compiled for
/// unit tests alone — falls back to a fixed in-range constant.
///
/// Residual limitation (accepted by design, not deferred): if a node's wall clock
/// runs BACKWARD across a restart (e.g. no RTC and not yet NTP-synced), its new
/// epoch may be lower than a peer's last-seen epoch, and that peer will reject the
/// new session until wall time advances past the old epoch. Operators must keep
/// the clock monotonic across restarts (RTC/NTP) or restart both ends. There is
/// no in-protocol symmetric fix: Subnetra performs no handshake by design (AGENT.md
/// iron law #8), so this is mitigated operationally (see docs/deployment.md),
/// never by an epoch-exchange handshake.
pub fn bootEpoch() RegistryError!u64 {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return MIN_BOOT_EPOCH_NS;
    var ts: sys.timespec = undefined;
    if (sys.errno(sys.clock_gettime(sys.CLOCK.REALTIME, &ts)) != .SUCCESS) return error.ClockUnavailable;
    if (ts.sec < 0) return error.ClockUnavailable;
    const ns = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    if (ns < MIN_BOOT_EPOCH_NS) return error.ClockUnavailable;
    return ns;
}

/// Fixed-capacity peer table. Pointers returned by `add`/`findById`/`findByAddr`
/// are stable for the lifetime of the registry (the backing array never moves).
pub const PeerRegistry = struct {
    peers: [MAX_PEERS]Peer = undefined,
    len: usize = 0,
    /// This node's own mesh id (the "to"/"from" anchor for key derivation).
    local_id: u32,

    pub fn init(local_id: u32) PeerRegistry {
        return .{ .local_id = local_id };
    }

    /// Register a peer, deriving its directional link keys from `psk` and binding
    /// the transmit session to `boot_epoch` (issue #14). Rejects the reserved id
    /// 0, the node's own id, duplicate ids/endpoints, and overflow.
    pub fn add(
        self: *PeerRegistry,
        psk: crypto.Key,
        id: u32,
        endpoint: sys.sockaddr.in,
        allowed_src: config.Cidr,
        boot_epoch: u64,
    ) RegistryError!*Peer {
        if (id == LOCAL_TARGET) return error.ReservedPeerId;
        if (id == self.local_id) return error.SelfReference;
        // Both ids ride the 16-bit on-wire key_id selector (issue #34).
        if (id > MAX_MESH_ID or self.local_id > MAX_MESH_ID) return error.PeerIdOutOfRange;
        if (self.len >= MAX_PEERS) return error.TooManyPeers;
        if (self.findById(id) != null) return error.DuplicateId;
        if (self.findByAddr(endpoint.addr, endpoint.port) != null) return error.DuplicateEndpoint;

        // Sender uses (local -> peer); the peer derives the matching rx key with
        // the same ordered pair, and vice versa.
        const tx_link = crypto.deriveLinkKey(psk, self.local_id, id);
        const rx_link = crypto.deriveLinkKey(psk, id, self.local_id);
        const p = &self.peers[self.len];
        p.* = .{
            .id = id,
            .endpoint = endpoint,
            .allowed_src = allowed_src,
            .tx = crypto.TxSession.init(tx_link, boot_epoch),
            .rx = crypto.RxSession.init(rx_link),
        };
        self.len += 1;
        return p;
    }

    pub fn findById(self: *PeerRegistry, id: u32) ?*Peer {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.peers[i].id == id) return &self.peers[i];
        }
        return null;
    }

    /// Look a peer up by its UDP endpoint (network byte order), used as the
    /// inbound source-endpoint filter.
    pub fn findByAddr(self: *PeerRegistry, addr: u32, port: u16) ?*Peer {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.peers[i].endpoint.addr == addr and self.peers[i].endpoint.port == port) {
                return &self.peers[i];
            }
        }
        return null;
    }

    /// Build a registry from a parsed config. Requires a non-zero `local_id`
    /// whenever peers are present (key derivation must anchor on a real id).
    /// `boot_epoch` (from `bootEpoch()`) binds every transmit session to this
    /// daemon lifetime.
    pub fn fromConfig(cfg: config.Config, boot_epoch: u64) RegistryError!PeerRegistry {
        if (cfg.peer_count > 0 and cfg.local_id == LOCAL_TARGET) return error.MissingLocalId;
        var reg = PeerRegistry.init(cfg.local_id);
        var i: usize = 0;
        while (i < cfg.peer_count) : (i += 1) {
            const spec = cfg.peers[i];
            const p = try reg.add(spec.psk, spec.id, spec.endpoint, spec.allowed_src, boot_epoch);
            // Carry the optional human-readable label (observability only); it is
            // never read by the data plane or used for matching/key derivation.
            p.name_len = spec.name_len;
            @memcpy(p.name[0..spec.name_len], spec.name[0..spec.name_len]);
        }
        return reg;
    }
};

fn testEndpoint(comptime text: []const u8) sys.sockaddr.in {
    return config.parseEndpoint(text) catch unreachable;
}

test "registry: add, lookup, and directional keys agree across the link" {
    const psk: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;
    const epoch: u64 = 1_700_000_000_000_000_000;

    var hub = PeerRegistry.init(1); // local node is the hub (id 1)
    const a = try hub.add(psk, 2, testEndpoint("10.0.0.2:51820"), .{ .network = 0, .prefix = 0 }, epoch);
    const b = try hub.add(psk, 3, testEndpoint("10.0.0.3:51820"), .{ .network = 0, .prefix = 0 }, epoch);

    try std.testing.expectEqual(@as(usize, 2), hub.len);
    try std.testing.expectEqual(a, hub.findById(2).?);
    try std.testing.expectEqual(b, hub.findById(3).?);
    try std.testing.expect(hub.findById(9) == null);
    try std.testing.expectEqual(a, hub.findByAddr(a.endpoint.addr, a.endpoint.port).?);

    // The hub's tx link key to peer 2 must equal peer 2's rx link key for traffic
    // from the hub: spoke 2 (local id 2) derives rx = deriveLinkKey(psk, 1, 2).
    var spoke = PeerRegistry.init(2);
    const hub_seen_by_spoke = try spoke.add(psk, 1, testEndpoint("10.0.0.1:51820"), .{ .network = 0, .prefix = 0 }, epoch);
    try std.testing.expectEqualSlices(u8, &a.tx.link_key, &hub_seen_by_spoke.rx.link_key);
    try std.testing.expectEqualSlices(u8, &a.rx.link_key, &hub_seen_by_spoke.tx.link_key);
}

test "registry: rejects reserved id, self-reference, duplicates, and overflow" {
    const psk: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;
    const any = config.Cidr{ .network = 0, .prefix = 0 };
    const epoch: u64 = 1_700_000_000_000_000_000;

    var reg = PeerRegistry.init(1);
    try std.testing.expectError(RegistryError.ReservedPeerId, reg.add(psk, 0, testEndpoint("10.0.0.9:1"), any, epoch));
    try std.testing.expectError(RegistryError.SelfReference, reg.add(psk, 1, testEndpoint("10.0.0.9:1"), any, epoch));

    _ = try reg.add(psk, 2, testEndpoint("10.0.0.2:51820"), any, epoch);
    try std.testing.expectError(RegistryError.DuplicateId, reg.add(psk, 2, testEndpoint("10.0.0.5:51820"), any, epoch));
    try std.testing.expectError(RegistryError.DuplicateEndpoint, reg.add(psk, 5, testEndpoint("10.0.0.2:51820"), any, epoch));

    // Fill to capacity, then overflow. Use a local id outside the 1..MAX_PEERS
    // fill range (MAX_MESH_ID is always > MAX_PEERS) so the fill never trips the
    // self-reference guard, regardless of the configured peer cap.
    var reg2 = PeerRegistry.init(MAX_MESH_ID);
    var port: u16 = 1;
    var id: u32 = 1;
    while (id <= MAX_PEERS) : (id += 1) {
        var ep = testEndpoint("10.1.0.1:1");
        ep.port = std.mem.nativeToBig(u16, port);
        port += 1;
        _ = try reg2.add(psk, id, ep, any, epoch);
    }
    var ep_last = testEndpoint("10.1.0.1:1");
    ep_last.port = std.mem.nativeToBig(u16, port);
    try std.testing.expectError(RegistryError.TooManyPeers, reg2.add(psk, 999, ep_last, any, epoch));
}

test "registry: enforces the u16 key_id range for peer and local ids (issue #34)" {
    const psk: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;
    const any = config.Cidr{ .network = 0, .prefix = 0 };
    const epoch: u64 = 1_700_000_000_000_000_000;

    // The maximum in-range id (0xFFFF) is accepted: it still fits the wire key_id.
    var reg = PeerRegistry.init(1);
    _ = try reg.add(psk, MAX_MESH_ID, testEndpoint("10.0.0.9:1"), any, epoch);

    // One past the range (0x10000) overflows the u16 selector and is rejected.
    try std.testing.expectError(RegistryError.PeerIdOutOfRange, reg.add(psk, MAX_MESH_ID + 1, testEndpoint("10.0.0.8:1"), any, epoch));

    // An out-of-range LOCAL id is likewise rejected (it becomes the egress key_id).
    var reg_local = PeerRegistry.init(MAX_MESH_ID + 1);
    try std.testing.expectError(RegistryError.PeerIdOutOfRange, reg_local.add(psk, 2, testEndpoint("10.0.0.7:1"), any, epoch));
}

test "registry: fromConfig requires a local_id when peers are present" {
    var cfg = config.Config.default();
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = testEndpoint("10.0.0.2:51820"), .allowed_src = .{ .network = 0, .prefix = 0 }, .psk = [_]u8{0x5a} ** 32 };
    const epoch: u64 = 1_700_000_000_000_000_000;

    cfg.local_id = 0;
    try std.testing.expectError(RegistryError.MissingLocalId, PeerRegistry.fromConfig(cfg, epoch));

    cfg.local_id = 1;
    const reg = try PeerRegistry.fromConfig(cfg, epoch);
    try std.testing.expectEqual(@as(usize, 1), reg.len);
}

test "registry: bootEpoch is non-zero and time-ordered" {
    const e = try bootEpoch();
    try std.testing.expect(e >= MIN_BOOT_EPOCH_NS);
    try std.testing.expect(e != 0);
    // On the shipped spoke platforms the epoch MUST be sampled from the live wall
    // clock, never the fixed floor (issue #152): any real post-2024 clock is
    // strictly past MIN_BOOT_EPOCH_NS. macOS used to short-circuit to the
    // constant here (== MIN), silently re-opening the #14 restart nonce-reuse
    // break; a regression to that would fail this assertion.
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try std.testing.expect(e > MIN_BOOT_EPOCH_NS);
    }
}

test "registry: fromConfig carries the peer name as resident metadata only" {
    const psk2 = [_]u8{0x5a} ** 32;
    const psk3 = [_]u8{0x6b} ** 32;
    const epoch: u64 = 1_700_000_000_000_000_000;

    var cfg = config.Config.default();
    cfg.local_id = 1;
    cfg.peer_count = 2;
    // Peer 2 is named; peer 3 is anonymous.
    cfg.peers[0] = .{ .id = 2, .endpoint = testEndpoint("10.0.0.2:51820"), .allowed_src = .{ .network = 0, .prefix = 0 }, .psk = psk2 };
    cfg.peers[0].name_len = try config.parsePeerName(&cfg.peers[0].name, "alice-laptop");
    cfg.peers[1] = .{ .id = 3, .endpoint = testEndpoint("10.0.0.3:51820"), .allowed_src = .{ .network = 0, .prefix = 0 }, .psk = psk3 };

    var reg = try PeerRegistry.fromConfig(cfg, epoch);

    // The name is resident on the registry record (no heap), and omission stays
    // anonymous.
    const p2 = reg.findById(2).?;
    const p3 = reg.findById(3).?;
    try std.testing.expectEqualStrings("alice-laptop", p2.nameSlice());
    try std.testing.expectEqual(@as(usize, 0), p3.name_len);

    // METADATA ONLY: the name never participates in matching or key derivation.
    // Renaming a peer in place must not change which record an id/addr resolves to
    // nor the derived link keys (those are keyed on the numeric id + PSK).
    const tx_before = p2.tx.link_key;
    const rx_before = p2.rx.link_key;
    p2.name_len = try config.parsePeerName(&p2.name, "renamed-gw");
    try std.testing.expectEqual(p2, reg.findById(2).?);
    try std.testing.expectEqual(p2, reg.findByAddr(p2.endpoint.addr, p2.endpoint.port).?);
    try std.testing.expectEqualSlices(u8, &tx_before, &p2.tx.link_key);
    try std.testing.expectEqualSlices(u8, &rx_before, &p2.rx.link_key);
}
