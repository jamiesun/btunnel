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
    /// Optional human-readable label (issue #121), copied from config. Resident,
    /// fixed-capacity, zero-allocation. Observability ONLY (`subnetra status`):
    /// the data plane and key derivation NEVER read it — peers stay keyed on
    /// `id`. Empty (`name_len == 0`) means the peer simply renders id-only.
    name: [config.PEER_NAME_MAX]u8 = [_]u8{0} ** config.PEER_NAME_MAX,
    name_len: u8 = 0,

    /// The peer's name as a slice (empty when none was configured).
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
/// a zero/low epoch would be catastrophic. On a non-Linux host (unit tests only;
/// never a real deployment) a fixed in-range constant is returned.
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
    if (builtin.os.tag != .linux) return MIN_BOOT_EPOCH_NS;
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
            // The name is pure metadata: copied onto the record AFTER key
            // derivation and registration, so it can never influence the keys,
            // the wire key_id, or peer matching (issue #121).
            @memcpy(p.name[0..spec.name_len], spec.nameSlice());
            p.name_len = spec.name_len;
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

    // Fill to capacity, then overflow.
    var reg2 = PeerRegistry.init(100);
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

test "registry: peer name is metadata only — resident, never a key/match input (issue #121)" {
    const epoch: u64 = 1_700_000_000_000_000_000;
    const ep = testEndpoint("10.0.0.2:51820");
    const psk: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;
    const any = config.Cidr{ .network = 0, .prefix = 0 };

    // Two configs identical EXCEPT for the peer's name.
    var named = config.Config.default();
    named.local_id = 1;
    named.peer_count = 1;
    named.peers[0] = .{ .id = 2, .endpoint = ep, .allowed_src = any, .psk = psk };
    const nm = "bj-office-gw";
    @memcpy(named.peers[0].name[0..nm.len], nm);
    named.peers[0].name_len = nm.len;

    var anon = config.Config.default();
    anon.local_id = 1;
    anon.peer_count = 1;
    anon.peers[0] = .{ .id = 2, .endpoint = ep, .allowed_src = any, .psk = psk };

    var reg_named = try PeerRegistry.fromConfig(named, epoch);
    var reg_anon = try PeerRegistry.fromConfig(anon, epoch);

    // The name is resident on the record and equals the configured label.
    const p_named = reg_named.findById(2).?;
    try std.testing.expectEqualStrings("bj-office-gw", p_named.nameSlice());
    // The nameless peer is found by the SAME id lookup — matching keys on id, not name.
    const p_anon = reg_anon.findById(2).?;
    try std.testing.expectEqual(@as(u8, 0), p_anon.name_len);

    // CRITICAL (iron law #5): the directional link keys are byte-identical with and
    // without a name, proving the name never feeds key derivation. If the name ever
    // leaked into key material these would differ and this test would fail.
    try std.testing.expectEqualSlices(u8, &p_anon.tx.link_key, &p_named.tx.link_key);
    try std.testing.expectEqualSlices(u8, &p_anon.rx.link_key, &p_named.rx.link_key);
}

test "registry: bootEpoch is non-zero and time-ordered" {
    const e = try bootEpoch();
    try std.testing.expect(e >= MIN_BOOT_EPOCH_NS);
    try std.testing.expect(e != 0);
}
