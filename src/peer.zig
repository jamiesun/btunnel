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
const linux = std.os.linux;
const crypto = @import("crypto.zig");
const config = @import("config.zig");

pub const MAX_PEERS = config.MAX_PEERS;

/// Policy `target` value that means "deliver to the local TUN" rather than
/// forwarding to a peer. Zero is reserved and may never be a peer id.
pub const LOCAL_TARGET: u32 = 0;

pub const Peer = struct {
    id: u32,
    endpoint: linux.sockaddr.in,
    allowed_src: config.Cidr,
    tx_key: crypto.Key,
    rx_key: crypto.Key,
    tx: crypto.NonceCounter = .{},
    rx: crypto.ReplayWindow = .{},
};

pub const RegistryError = error{
    TooManyPeers,
    DuplicateId,
    DuplicateEndpoint,
    ReservedPeerId,
    SelfReference,
    MissingLocalId,
    EntropyUnavailable,
};

/// Random high word for a transmit nonce counter, sourced from getrandom so
/// nonces do not repeat across a restart with the same key.
///
/// Entropy failure is FATAL: silently falling back to a constant would make the
/// reseed deterministic and risk reusing a `(link key, nonce)` pair across
/// restarts, which is catastrophic for ChaCha20-Poly1305. On a non-Linux host
/// (unit tests only; never a real deployment) a constant 0 is returned.
///
/// Known v1 limitation: a 32-bit random high word does not fully solve restart
/// safety — after a one-sided restart the receiver's replay window may still be
/// ahead of the fresh counter, and the high word can collide by birthday. A
/// proper session epoch / boot-nonce handshake is deferred to the v2
/// negotiation (the wire header's reserved field is reserved for it).
fn randomHigh() RegistryError!u32 {
    if (builtin.os.tag != .linux) return 0;
    var b: [4]u8 = undefined;
    const rc = linux.getrandom(&b, b.len, 0);
    if (linux.errno(rc) != .SUCCESS or rc != b.len) return error.EntropyUnavailable;
    return std.mem.readInt(u32, &b, .little);
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

    /// Register a peer, deriving its directional keys from `psk` and reseeding
    /// its transmit nonce counter. Rejects the reserved id 0, the node's own id,
    /// duplicate ids/endpoints, and overflow.
    pub fn add(
        self: *PeerRegistry,
        psk: crypto.Key,
        id: u32,
        endpoint: linux.sockaddr.in,
        allowed_src: config.Cidr,
    ) RegistryError!*Peer {
        if (id == LOCAL_TARGET) return error.ReservedPeerId;
        if (id == self.local_id) return error.SelfReference;
        if (self.len >= MAX_PEERS) return error.TooManyPeers;
        if (self.findById(id) != null) return error.DuplicateId;
        if (self.findByAddr(endpoint.addr, endpoint.port) != null) return error.DuplicateEndpoint;

        const high = try randomHigh();
        const p = &self.peers[self.len];
        p.* = .{
            .id = id,
            .endpoint = endpoint,
            .allowed_src = allowed_src,
            // Sender uses (local -> peer); the peer derives the matching rx key
            // with the same ordered pair, and vice versa.
            .tx_key = crypto.deriveLinkKey(psk, self.local_id, id),
            .rx_key = crypto.deriveLinkKey(psk, id, self.local_id),
        };
        p.tx.reseedHigh(high);
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
    pub fn fromConfig(cfg: config.Config) RegistryError!PeerRegistry {
        if (cfg.peer_count > 0 and cfg.local_id == LOCAL_TARGET) return error.MissingLocalId;
        var reg = PeerRegistry.init(cfg.local_id);
        var i: usize = 0;
        while (i < cfg.peer_count) : (i += 1) {
            const spec = cfg.peers[i];
            _ = try reg.add(cfg.psk, spec.id, spec.endpoint, spec.allowed_src);
        }
        return reg;
    }
};

fn testEndpoint(comptime text: []const u8) linux.sockaddr.in {
    return config.parseEndpoint(text) catch unreachable;
}

test "registry: add, lookup, and directional keys agree across the link" {
    const psk: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;

    var hub = PeerRegistry.init(1); // local node is the hub (id 1)
    const a = try hub.add(psk, 2, testEndpoint("10.0.0.2:51820"), .{ .network = 0, .prefix = 0 });
    const b = try hub.add(psk, 3, testEndpoint("10.0.0.3:51820"), .{ .network = 0, .prefix = 0 });

    try std.testing.expectEqual(@as(usize, 2), hub.len);
    try std.testing.expectEqual(a, hub.findById(2).?);
    try std.testing.expectEqual(b, hub.findById(3).?);
    try std.testing.expect(hub.findById(9) == null);
    try std.testing.expectEqual(a, hub.findByAddr(a.endpoint.addr, a.endpoint.port).?);

    // The hub's tx key to peer 2 must equal peer 2's rx key for traffic from the
    // hub: spoke 2 (local id 2) derives rx = deriveLinkKey(psk, 1, 2).
    var spoke = PeerRegistry.init(2);
    const hub_seen_by_spoke = try spoke.add(psk, 1, testEndpoint("10.0.0.1:51820"), .{ .network = 0, .prefix = 0 });
    try std.testing.expectEqualSlices(u8, &a.tx_key, &hub_seen_by_spoke.rx_key);
    try std.testing.expectEqualSlices(u8, &a.rx_key, &hub_seen_by_spoke.tx_key);
}

test "registry: rejects reserved id, self-reference, duplicates, and overflow" {
    const psk: crypto.Key = [_]u8{0x5a} ** crypto.KEY_LEN;
    const any = config.Cidr{ .network = 0, .prefix = 0 };

    var reg = PeerRegistry.init(1);
    try std.testing.expectError(RegistryError.ReservedPeerId, reg.add(psk, 0, testEndpoint("10.0.0.9:1"), any));
    try std.testing.expectError(RegistryError.SelfReference, reg.add(psk, 1, testEndpoint("10.0.0.9:1"), any));

    _ = try reg.add(psk, 2, testEndpoint("10.0.0.2:51820"), any);
    try std.testing.expectError(RegistryError.DuplicateId, reg.add(psk, 2, testEndpoint("10.0.0.5:51820"), any));
    try std.testing.expectError(RegistryError.DuplicateEndpoint, reg.add(psk, 5, testEndpoint("10.0.0.2:51820"), any));

    // Fill to capacity, then overflow.
    var reg2 = PeerRegistry.init(100);
    var port: u16 = 1;
    var id: u32 = 1;
    while (id <= MAX_PEERS) : (id += 1) {
        var ep = testEndpoint("10.1.0.1:1");
        ep.port = std.mem.nativeToBig(u16, port);
        port += 1;
        _ = try reg2.add(psk, id, ep, any);
    }
    var ep_last = testEndpoint("10.1.0.1:1");
    ep_last.port = std.mem.nativeToBig(u16, port);
    try std.testing.expectError(RegistryError.TooManyPeers, reg2.add(psk, 999, ep_last, any));
}

test "registry: fromConfig requires a local_id when peers are present" {
    var cfg = config.Config.default();
    cfg.psk = [_]u8{0x5a} ** 32;
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = testEndpoint("10.0.0.2:51820"), .allowed_src = .{ .network = 0, .prefix = 0 } };

    cfg.local_id = 0;
    try std.testing.expectError(RegistryError.MissingLocalId, PeerRegistry.fromConfig(cfg));

    cfg.local_id = 1;
    const reg = try PeerRegistry.fromConfig(cfg);
    try std.testing.expectEqual(@as(usize, 1), reg.len);
}
