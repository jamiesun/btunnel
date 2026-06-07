//! Task 2: Configuration snapshot & sanity check.
//!
//! Parse `config.json` once at startup via `std.json`; if the file is missing
//! the caller falls back to the comptime hard-coded default. Malformed JSON or
//! an out-of-range field aborts startup (the daemon never silently runs a
//! half-valid config). This module is pure (no file I/O) so it stays portable
//! and unit-testable on any host; the actual file read lives in `main.zig`.

const std = @import("std");
const sys = @import("sys.zig");
const netplan = @import("netplan.zig");

pub const MTU_MIN: u16 = 68;
pub const MTU_MAX: u16 = 1500;

/// Default inner (TUN) MTU. Derived from the live wire constants so it stays the
/// largest inner packet that fits without fragmentation on the dominant 1500-byte
/// IPv4 underlay (issue #98) — never a second hard-coded literal that could drift.
/// Operators on jumbo / known-larger paths raise `local_tun_mtu` explicitly.
pub const DEFAULT_TUN_MTU: u16 = netplan.maxTunMtu(netplan.DEFAULT_PATH_MTU);

/// Maximum number of mesh peers a single node can be configured with. Fixed so
/// the registry stays zero-allocation (issue #5).
pub const MAX_PEERS: usize = 16;

/// Maximum number of local/remote route CIDRs a simplified (`role`) config can
/// declare. Fixed so the config stays zero-allocation; the derived policy never
/// exceeds MAX_PEERS + MAX_ROUTES*2 entries, well under MAX_POLICY_ENTRIES.
pub const MAX_ROUTES: usize = 8;

/// Maximum length of an optional human-readable peer name (issue #121). The name
/// is control-plane metadata ONLY — echoed in `subnetra status` so operators can
/// tell peers apart at a glance. It never goes on the wire and never influences a
/// packet's fate. Fixed-capacity so the registry stays zero-allocation.
pub const PEER_NAME_MAX: usize = 48;

/// 32-byte pre-shared key (PSK).
pub const Psk = [32]u8;

/// Deployment role for the simplified config (issue #21). `manual` (the default)
/// preserves the original low-level behavior: the policy tree starts empty and
/// the operator installs rules at runtime via `subnetra`. `hub`/`spoke` make the
/// daemon AUTO-DERIVE the initial policy from the peer/route declarations so no
/// hand-written forwarding rules are needed. The peer registry, key derivation,
/// and data plane are identical across roles — only the bootstrap policy differs.
pub const Role = enum { manual, hub, spoke };

/// Default built-in keepalive interval (seconds) for `role=spoke` when the config
/// omits `keepalive_secs` (issue #96). Chosen well under the common ~30s UDP NAT
/// mapping timeout so the pinhole never lapses, while staying light (one ~36-byte
/// datagram per interval). Hub/manual roles default to 0 (disabled).
pub const DEFAULT_SPOKE_KEEPALIVE_SECS: u32 = 20;

/// The keepalive default for a role when the config omits `keepalive_secs`:
/// non-zero only for a spoke, which is the side that sits behind NAT.
fn defaultKeepaliveSecs(role: Role) u32 {
    return switch (role) {
        .spoke => DEFAULT_SPOKE_KEEPALIVE_SECS,
        .manual, .hub => 0,
    };
}

pub const SanityError = error{
    MtuOutOfRange,
    SubnetOverlap,
    InvalidPsk,
    DuplicatePsk,
    /// role=hub: a peer's `allowed_src` is the permissive 0.0.0.0/0, so it could
    /// claim (and source-spoof) the whole address space. Each hub peer must own
    /// a specific prefix.
    HubPeerNeedsAllowedSrc,
    /// role=hub: two peers' `allowed_src` prefixes overlap, so a packet's
    /// destination (and a peer's spoof surface) is ambiguous between them.
    HubAllowedSrcOverlap,
    /// role=spoke: a spoke must point at exactly one hub peer.
    SpokeNeedsOneHub,
    /// role=spoke: the spoke declares no local delivery target (neither
    /// `local_routes` nor `local_tun_ip`), so inbound tunnel traffic has nowhere
    /// to land.
    SpokeMissingLocal,
    /// role=spoke: a `local_routes` entry is 0.0.0.0/0, which would tie the
    /// default hub route and trap ALL traffic locally — almost always a mistake.
    SpokeLocalRouteTooBroad,
    /// A mesh id (this node's `local_id` or a peer's `id`) exceeds 65535 and so
    /// cannot fit the 16-bit on-wire `key_id` selector (issue #34).
    PeerIdOutOfRange,
};

/// CIDR string parse errors (canonical home; re-exported by `policy.zig`).
pub const CidrError = error{
    MissingSlash,
    InvalidOctet,
    InvalidPrefix,
};

/// "IP:port" endpoint parse errors.
pub const EndpointError = error{
    MissingColon,
    InvalidOctet,
    InvalidPort,
};

/// A CIDR subnet (network address + prefix length).
pub const Cidr = struct {
    /// Network address in host byte order.
    network: u32,
    prefix: u6,

    pub fn mask(self: Cidr) u32 {
        if (self.prefix == 0) return 0;
        return @as(u32, 0xffff_ffff) << @intCast(32 - @as(u6, self.prefix));
    }

    /// Whether two subnets overlap in address space.
    pub fn overlaps(a: Cidr, b: Cidr) bool {
        const m = a.mask() & b.mask();
        return (a.network & m) == (b.network & m);
    }

    /// Whether a host-byte-order address falls inside this subnet. A /0 subnet
    /// (the permissive default) contains every address.
    pub fn contains(self: Cidr, ip: u32) bool {
        const m = self.mask();
        return (ip & m) == (self.network & m);
    }
};

/// A configured mesh peer: its mesh id, UDP endpoint (network byte order, ready
/// for `sendto`), and the inner source prefix bound to that endpoint. Inbound
/// packets whose inner IPv4 source falls outside `allowed_src` are dropped, so
/// an authenticated spoke cannot spoof another node's address (issue #5).
///
/// SECURITY NOTE: when `allowed_src` is omitted in config.json it defaults to
/// the permissive `0.0.0.0/0`, which accepts ANY inner source from that peer and
/// therefore disables the anti-spoofing guarantee for it. Operators should set a
/// tight prefix (typically the spoke's /32 or its assigned subnet) on every peer
/// of a hub. The default stays permissive only so single-link / trusted setups
/// keep working without extra configuration.
pub const PeerSpec = struct {
    id: u32,
    endpoint: sys.sockaddr.in,
    allowed_src: Cidr = .{ .network = 0, .prefix = 0 },
    /// Private per-link pre-shared key (issue #13). Each peer link has its OWN
    /// secret, so compromising one spoke's PSK cannot derive any other link's
    /// keys. Both ends of a link must configure the SAME value for that link;
    /// distinct links must use DISTINCT keys (enforced by `validate`).
    psk: Psk = [_]u8{0} ** 32,
    /// Optional human-readable label for this peer (issue #121). Control-plane
    /// METADATA ONLY: shown in `subnetra status` (human + JSON) so operators can
    /// tell peers apart without an external id->meaning lookup. It NEVER goes on
    /// the wire and is NEVER an identity/auth/routing input — key derivation, the
    /// wire `key_id`, peer matching, and policy all stay keyed on `id`. Empty
    /// (`name_len == 0`) renders id-only, exactly as before this field existed.
    name: [PEER_NAME_MAX]u8 = [_]u8{0} ** PEER_NAME_MAX,
    name_len: u8 = 0,

    /// The configured name as a slice (empty when none was set).
    pub fn nameSlice(self: *const PeerSpec) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Validate an optional peer name (issue #121) and copy it into `out`, returning
/// its byte length. The name must be printable ASCII (0x20..0x7E) so it is safe
/// to echo into a terminal `subnetra status` line — control/escape bytes are
/// rejected — and at most `PEER_NAME_MAX` bytes. An empty name is valid (len 0).
pub fn parsePeerName(text: []const u8, out: *[PEER_NAME_MAX]u8) error{ PeerNameTooLong, PeerNameNotPrintable }!u8 {
    if (text.len > PEER_NAME_MAX) return error.PeerNameTooLong;
    for (text) |ch| {
        if (ch < 0x20 or ch > 0x7E) return error.PeerNameNotPrintable;
    }
    @memcpy(out[0..text.len], text);
    return @intCast(text.len);
}

/// Parse "A.B.C.D/P" into a Cidr (network in host byte order).
pub fn parseCidr(text: []const u8) CidrError!Cidr {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return CidrError.MissingSlash;
    const addr_str = text[0..slash];
    const prefix_str = text[slash + 1 ..];

    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return CidrError.InvalidOctet;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return CidrError.InvalidOctet;
    }
    if (i != 4) return CidrError.InvalidOctet;

    const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return CidrError.InvalidPrefix;
    if (prefix > 32) return CidrError.InvalidPrefix;

    const network = std.mem.readInt(u32, &octets, .big);
    return .{ .network = network, .prefix = @intCast(prefix) };
}

/// Parse "A.B.C.D:port" into a `sockaddr.in` (address + port in network byte
/// order, ready to hand to `sendto`).
pub fn parseEndpoint(text: []const u8) EndpointError!sys.sockaddr.in {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return EndpointError.MissingColon;
    const ip_str = text[0..colon];
    const port_str = text[colon + 1 ..];

    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, ip_str, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return EndpointError.InvalidOctet;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return EndpointError.InvalidOctet;
    }
    if (i != 4) return EndpointError.InvalidOctet;

    const port = std.fmt.parseInt(u16, port_str, 10) catch return EndpointError.InvalidPort;
    if (port == 0) return EndpointError.InvalidPort;

    return .{
        .family = sys.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        // `octets` already hold the address in network byte order; reinterpret
        // their bytes as the u32 the kernel expects (memory layout preserved).
        .addr = @bitCast(octets),
    };
}

pub const Config = struct {
    /// v1 header/config negotiation version (fixed to 1 in v1). Reserved for
    /// future STATIC per-link transport-mode selection, never an on-wire
    /// handshake or in-band negotiation (AGENT.md iron law #8).
    negotiation_version: u8 = 1,
    /// Tunnel MTU.
    local_tun_mtu: u16 = DEFAULT_TUN_MTU,
    /// Local UDP listen port.
    listen_port: u16 = 51820,
    /// Virtual subnet (default 10.0.0.0/24).
    virtual_subnet: Cidr = .{ .network = 0x0A00_0000, .prefix = 24 },
    /// Optional local TUN interface address (host address + prefix), used only
    /// to emit `--print-network-plan` host setup commands. The daemon does NOT
    /// configure host addressing itself; this is operator guidance. `null` when
    /// unset (config field omitted), in which case the plan emits a placeholder.
    local_tun_ip: ?Cidr = null,
    /// This node's own mesh id, used to derive directional per-link keys. Must
    /// be non-zero and distinct from every peer id when `peers` is non-empty
    /// (issue #5). Zero means "single-node / no mesh configured".
    local_id: u32 = 0,
    /// Configured mesh peers (fixed-capacity, zero-allocation). Only the first
    /// `peer_count` entries are valid. Each peer carries its own private PSK
    /// (issue #13); there is no mesh-wide shared key.
    peers: [MAX_PEERS]PeerSpec = undefined,
    peer_count: usize = 0,

    /// Deployment role (issue #21). `manual` keeps the original behavior (empty
    /// initial policy); `hub`/`spoke` auto-derive the bootstrap policy.
    role: Role = .manual,
    /// role=spoke: subnets this node delivers LOCALLY (to its own TUN/host). When
    /// empty, `local_tun_ip` (as a /32) is used. Only the first
    /// `local_route_count` are valid.
    local_routes: [MAX_ROUTES]Cidr = undefined,
    local_route_count: usize = 0,
    /// role=spoke: subnets reachable THROUGH the hub. When empty, the spoke
    /// routes `virtual_subnet` to the hub (the overlay default). Only the first
    /// `remote_route_count` are valid.
    remote_routes: [MAX_ROUTES]Cidr = undefined,
    remote_route_count: usize = 0,

    /// Built-in spoke→hub NAT keepalive interval in seconds (issue #96). `0`
    /// disables it (the hub/manual default). A NATed `role=spoke` defaults to
    /// `DEFAULT_SPOKE_KEEPALIVE_SECS` so its UDP pinhole and the hub's learned
    /// endpoint stay fresh with no external pinger; set explicitly to override or
    /// to disable. Resolved in `fromJson` from the (optional) wire field.
    keepalive_secs: u32 = 0,

    /// Compile-time hardcoded fallback config (used when config.json is
    /// missing). Note: it has zero peers, which `validate()` deliberately
    /// rejects — the default config is intentionally NON-RUNNABLE until real
    /// peers with private PSKs are provisioned via config.json (iron law #5).
    pub fn default() Config {
        return .{};
    }

    /// Foolproof boundary checks: at least one authenticated peer link with a
    /// non-zero, per-link-unique PSK (issue #13) + MTU range + virtual/host
    /// subnet overlap. A config without a usable per-peer PSK is rejected so the
    /// daemon can never start unauthenticated.
    pub fn validate(self: Config, host_subnets: []const Cidr) SanityError!void {
        // A runnable node must have at least one peer link, each with a real
        // (non-zero) private key. Zero peers keeps the compile-time default
        // non-runnable (iron law #5).
        if (self.peer_count == 0) return SanityError.InvalidPsk;
        var i: usize = 0;
        while (i < self.peer_count) : (i += 1) {
            if (std.mem.allEqual(u8, &self.peers[i].psk, 0)) return SanityError.InvalidPsk;
            // Reusing one PSK across links would let a single compromised peer
            // derive every other link's keys, defeating the per-peer model.
            var j: usize = i + 1;
            while (j < self.peer_count) : (j += 1) {
                if (std.mem.eql(u8, &self.peers[i].psk, &self.peers[j].psk)) {
                    return SanityError.DuplicatePsk;
                }
            }
        }
        if (self.local_tun_mtu < MTU_MIN or self.local_tun_mtu > MTU_MAX) {
            return SanityError.MtuOutOfRange;
        }
        // Mesh ids ride the 16-bit on-wire key_id selector (issue #34), so this
        // node's id and every peer id must fit u16.
        if (self.local_id > 0xFFFF) return SanityError.PeerIdOutOfRange;
        i = 0;
        while (i < self.peer_count) : (i += 1) {
            if (self.peers[i].id > 0xFFFF) return SanityError.PeerIdOutOfRange;
        }
        for (host_subnets) |hs| {
            if (self.virtual_subnet.overlaps(hs)) return SanityError.SubnetOverlap;
        }

        // Role-specific structural checks (issue #21). `manual` adds none.
        switch (self.role) {
            .manual => {},
            .hub => {
                // Each hub peer must own a SPECIFIC, NON-OVERLAPPING source
                // prefix: it is reused as the relay destination AND the
                // anti-spoof source binding, so overlap makes both ambiguous.
                // Check every prefix first so a permissive 0.0.0.0/0 reports the
                // specific "needs allowed_src" error rather than a generic overlap.
                var hi: usize = 0;
                while (hi < self.peer_count) : (hi += 1) {
                    if (self.peers[hi].allowed_src.prefix == 0) {
                        return SanityError.HubPeerNeedsAllowedSrc;
                    }
                }
                hi = 0;
                while (hi < self.peer_count) : (hi += 1) {
                    var hj: usize = hi + 1;
                    while (hj < self.peer_count) : (hj += 1) {
                        if (self.peers[hi].allowed_src.overlaps(self.peers[hj].allowed_src)) {
                            return SanityError.HubAllowedSrcOverlap;
                        }
                    }
                }
            },
            .spoke => {
                if (self.peer_count != 1) return SanityError.SpokeNeedsOneHub;
                if (self.local_route_count == 0 and self.local_tun_ip == null) {
                    return SanityError.SpokeMissingLocal;
                }
                var si: usize = 0;
                while (si < self.local_route_count) : (si += 1) {
                    if (self.local_routes[si].prefix == 0) {
                        return SanityError.SpokeLocalRouteTooBroad;
                    }
                }
            },
        }
    }

    /// On-wire JSON schema. Defaults mirror `Config` so a partial document is
    /// valid; `virtual_subnet` is a CIDR string. The mesh-wide top-level `psk`
    /// was removed in issue #13 — it is kept here only as a tripwire so an old
    /// config that still carries it is loudly rejected (see `fromJson`). Unknown
    /// fields are otherwise ignored so forward-compatible keys do not break
    /// parsing.
    const Wire = struct {
        negotiation_version: u8 = 1,
        psk: []const u8 = "",
        local_tun_mtu: u16 = DEFAULT_TUN_MTU,
        listen_port: u16 = 51820,
        virtual_subnet: []const u8 = "10.0.0.0/24",
        local_tun_ip: []const u8 = "",
        local_id: u32 = 0,
        peers: []const WirePeer = &.{},
        role: []const u8 = "manual",
        local_routes: []const []const u8 = &.{},
        remote_routes: []const []const u8 = &.{},
        /// Optional (issue #96): omitted (`null`) means "use the role default"
        /// (`defaultKeepaliveSecs`); present means an explicit override, including
        /// `0` to disable keepalive on a spoke.
        keepalive_secs: ?u32 = null,
    };

    /// On-wire schema for a single mesh peer. `psk` is this link's private
    /// pre-shared key, a required 64-char hex string (issue #13). `name` is an
    /// optional human-readable label (issue #121): printable ASCII, <= 48 bytes,
    /// control-plane metadata only (never on the wire, never an identity input).
    const WirePeer = struct {
        id: u32 = 0,
        endpoint: []const u8 = "",
        allowed_src: []const u8 = "0.0.0.0/0",
        psk: []const u8 = "",
        name: []const u8 = "",
    };

    /// Parse a config.json document. Returns a fully-owned `Config` (no slices
    /// borrowed from the input or the parse arena). Propagates JSON syntax
    /// errors so the caller can abort startup. Does NOT run `validate`; the
    /// caller invokes it after loading.
    pub fn fromJson(allocator: std.mem.Allocator, slice: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(Wire, allocator, slice, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const w = parsed.value;

        // The mesh-wide top-level PSK was removed in issue #13. Reject it loudly
        // rather than silently ignoring it, so operators migrate to per-peer
        // `peers[].psk` instead of believing a shared key is still in force.
        if (w.psk.len != 0) return error.InvalidPsk;

        var cfg = Config{
            .negotiation_version = w.negotiation_version,
            .local_tun_mtu = w.local_tun_mtu,
            .listen_port = w.listen_port,
            .virtual_subnet = parseCidr(w.virtual_subnet) catch return error.InvalidCidr,
            .local_tun_ip = if (w.local_tun_ip.len == 0)
                null
            else
                parseCidr(w.local_tun_ip) catch return error.InvalidCidr,
            .local_id = w.local_id,
        };

        if (w.peers.len > MAX_PEERS) return error.TooManyPeers;
        for (w.peers, 0..) |wp, i| {
            // Every peer must carry a private 64-hex PSK; missing (empty) and
            // wrong-length both fail the length gate, malformed hex fails decode.
            if (wp.psk.len != 64) return error.InvalidPsk;
            var pk: Psk = undefined;
            _ = std.fmt.hexToBytes(pk[0..], wp.psk) catch return error.InvalidPsk;
            // Validate + copy the optional name into a fixed buffer; an over-long
            // or non-printable label aborts startup rather than reaching `status`.
            var name_buf: [PEER_NAME_MAX]u8 = [_]u8{0} ** PEER_NAME_MAX;
            const name_len = try parsePeerName(wp.name, &name_buf);
            // Copy every field out by value so nothing borrows the parse arena.
            cfg.peers[i] = .{
                .id = wp.id,
                .endpoint = parseEndpoint(wp.endpoint) catch return error.InvalidEndpoint,
                .allowed_src = parseCidr(wp.allowed_src) catch return error.InvalidCidr,
                .psk = pk,
                .name = name_buf,
                .name_len = name_len,
            };
        }
        cfg.peer_count = w.peers.len;

        // Simplified-config fields (issue #21). Parse-copy every route out by
        // value so nothing borrows the parse arena.
        cfg.role = if (std.mem.eql(u8, w.role, "manual"))
            .manual
        else if (std.mem.eql(u8, w.role, "hub"))
            .hub
        else if (std.mem.eql(u8, w.role, "spoke"))
            .spoke
        else
            return error.InvalidRole;

        // Keepalive interval (issue #96): an explicit value wins; otherwise fall
        // back to the role default (spoke → DEFAULT_SPOKE_KEEPALIVE_SECS, else 0),
        // so a plain `role=spoke` config gets NAT keepalive with no extra knob.
        cfg.keepalive_secs = w.keepalive_secs orelse defaultKeepaliveSecs(cfg.role);

        if (w.local_routes.len > MAX_ROUTES) return error.TooManyRoutes;
        for (w.local_routes, 0..) |r, i| {
            cfg.local_routes[i] = parseCidr(r) catch return error.InvalidCidr;
        }
        cfg.local_route_count = w.local_routes.len;

        if (w.remote_routes.len > MAX_ROUTES) return error.TooManyRoutes;
        for (w.remote_routes, 0..) |r, i| {
            cfg.remote_routes[i] = parseCidr(r) catch return error.InvalidCidr;
        }
        cfg.remote_route_count = w.remote_routes.len;

        return cfg;
    }
};

test "validate: MTU out of range is rejected" {
    var cfg = Config.default();
    // provision a peer with a non-zero PSK so the MTU fuse is what fires
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };
    cfg.local_tun_mtu = 9000;
    try std.testing.expectError(SanityError.MtuOutOfRange, cfg.validate(&.{}));

    cfg.local_tun_mtu = 1452;
    try cfg.validate(&.{});
}

test "default local_tun_mtu is the safe inner MTU for a 1500 underlay (issue #98)" {
    // Derived from the wire constants, never a second literal, so it cannot drift.
    try std.testing.expectEqual(@as(u16, 1436), DEFAULT_TUN_MTU);
    try std.testing.expectEqual(netplan.maxTunMtu(1500), DEFAULT_TUN_MTU);
    try std.testing.expectEqual(DEFAULT_TUN_MTU, Config.default().local_tun_mtu);
}

test "validate: a peer or local id beyond the u16 key_id range is rejected (issue #34)" {
    var cfg = Config.default();
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 0x1_0000, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };
    try std.testing.expectError(SanityError.PeerIdOutOfRange, cfg.validate(&.{}));

    // The maximum in-range id clears the gate.
    cfg.peers[0].id = 0xFFFF;
    try cfg.validate(&.{});

    // An out-of-range local_id (the egress key_id) is rejected too.
    cfg.local_id = 0x1_0000;
    try std.testing.expectError(SanityError.PeerIdOutOfRange, cfg.validate(&.{}));
}

test "validate: virtual/host subnet overlap is rejected" {
    var cfg = Config.default(); // 10.0.0.0/24
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };
    const overlap = Cidr{ .network = 0x0A00_0000, .prefix = 16 }; // 10.0.0.0/16
    try std.testing.expectError(SanityError.SubnetOverlap, cfg.validate(&.{overlap}));

    const disjoint = Cidr{ .network = 0xC0A8_0100, .prefix = 24 }; // 192.168.1.0/24
    try cfg.validate(&.{disjoint});
}

test "validate: a missing/all-zero per-peer PSK is rejected (mandatory PSK, iron law #5)" {
    // The compile-time default ships zero peers and must be non-runnable.
    const def = Config.default();
    try std.testing.expectEqual(@as(usize, 0), def.peer_count);
    try std.testing.expectError(SanityError.InvalidPsk, def.validate(&.{}));

    // A peer with an all-zero PSK is still rejected.
    var zero = Config.default();
    zero.peer_count = 1;
    zero.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0} ** 32 };
    try std.testing.expectError(SanityError.InvalidPsk, zero.validate(&.{}));

    // A provisioned per-peer PSK clears the gate.
    var cfg = Config.default();
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x01} ** 32 };
    try cfg.validate(&.{});
}

test "validate: reusing one PSK across peers is rejected (per-peer isolation, issue #13)" {
    var cfg = Config.default();
    cfg.peer_count = 2;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };
    cfg.peers[1] = .{ .id = 3, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };
    try std.testing.expectError(SanityError.DuplicatePsk, cfg.validate(&.{}));

    // Distinct per-link PSKs are accepted.
    cfg.peers[1].psk = [_]u8{0x6b} ** 32;
    try cfg.validate(&.{});
}

test "JSON Parser & Sanity Check" {
    const a = std.testing.allocator;
    const psk_hex = "0123456789abcdef" ** 4; // 64 hex chars

    // A document with a peer maps every field and decodes the hex PSK.
    const ok =
        "{ \"negotiation_version\": 1, \"local_tun_mtu\": 1400, \"listen_port\": 4000," ++
        " \"virtual_subnet\": \"10.9.0.0/24\", \"local_id\": 1, \"peers\": [" ++
        "{ \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"psk\": \"" ++ psk_hex ++ "\" } ] }";
    const cfg = try Config.fromJson(a, ok);
    try cfg.validate(&.{});
    try std.testing.expectEqual(@as(u16, 1400), cfg.local_tun_mtu);
    try std.testing.expectEqual(@as(u16, 4000), cfg.listen_port);
    try std.testing.expectEqual(@as(u32, 0x0A09_0000), cfg.virtual_subnet.network);
    try std.testing.expectEqual(@as(u6, 24), cfg.virtual_subnet.prefix);
    try std.testing.expectEqual(@as(u8, 0x01), cfg.peers[0].psk[0]);
    try std.testing.expectEqual(@as(u8, 0xef), cfg.peers[0].psk[7]);

    // A partial document falls back to per-field defaults (and zero peers).
    const partial = "{ \"local_tun_mtu\": 1300 }";
    const cfg2 = try Config.fromJson(a, partial);
    try std.testing.expectEqual(@as(u16, 1300), cfg2.local_tun_mtu);
    try std.testing.expectEqual(@as(u16, 51820), cfg2.listen_port);
    try std.testing.expectEqual(@as(usize, 0), cfg2.peer_count);

    // An out-of-range MTU parses but is rejected by the sanity check (fuse).
    const bad_mtu =
        "{ \"local_tun_mtu\": 9000, \"local_id\": 1, \"peers\": [" ++
        "{ \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"psk\": \"" ++ psk_hex ++ "\" } ] }";
    const cfg3 = try Config.fromJson(a, bad_mtu);
    try std.testing.expectError(SanityError.MtuOutOfRange, cfg3.validate(&.{}));

    // Malformed JSON aborts parsing (no silent default fallback).
    try std.testing.expect(std.meta.isError(Config.fromJson(a, "{ not valid json")));

    // A malformed virtual subnet is rejected.
    try std.testing.expectError(error.InvalidCidr, Config.fromJson(a, "{ \"virtual_subnet\": \"10.0.0.0\" }"));
}

test "fromJson: a top-level mesh-wide psk is loudly rejected (issue #13 tripwire)" {
    const a = std.testing.allocator;
    const psk_hex = "0123456789abcdef" ** 4;
    // The mesh-wide top-level PSK was removed in #13; an old config carrying it
    // must fail rather than be silently ignored.
    const old = "{ \"psk\": \"" ++ psk_hex ++ "\" }";
    try std.testing.expectError(error.InvalidPsk, Config.fromJson(a, old));
}

test "fromJson: a missing or malformed per-peer psk is rejected (issue #13)" {
    const a = std.testing.allocator;
    const psk_hex = "0123456789abcdef" ** 4;

    // Missing peer psk.
    const missing = "{ \"local_id\": 1, \"peers\": [ { \"id\": 2, \"endpoint\": \"10.0.0.2:51820\" } ] }";
    try std.testing.expectError(error.InvalidPsk, Config.fromJson(a, missing));

    // Wrong-length peer psk.
    const short =
        "{ \"local_id\": 1, \"peers\": [ { \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"psk\": \"abcd\" } ] }";
    try std.testing.expectError(error.InvalidPsk, Config.fromJson(a, short));

    // Malformed (non-hex) peer psk of the right length.
    const non_hex = "zz" ++ ("0123456789abcdef" ** 3) ++ "abcdefabcdefabcd"; // 64 chars, leading non-hex
    const bad_hex =
        "{ \"local_id\": 1, \"peers\": [ { \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"psk\": \"" ++
        non_hex ++ "\" } ] }";
    try std.testing.expectError(error.InvalidPsk, Config.fromJson(a, bad_hex));
    _ = psk_hex;
}

test "parseCidr" {
    const c = try parseCidr("192.168.1.0/24");
    try std.testing.expectEqual(@as(u32, 0xC0A8_0100), c.network);
    try std.testing.expectEqual(@as(u6, 24), c.prefix);
    try std.testing.expectError(CidrError.MissingSlash, parseCidr("10.0.0.0"));
    try std.testing.expectError(CidrError.InvalidPrefix, parseCidr("10.0.0.0/33"));
}

test "validate: role=hub requires specific, non-overlapping peer allowed_src (issue #21)" {
    var cfg = Config.default();
    cfg.role = .hub;
    cfg.peer_count = 2;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .allowed_src = .{ .network = 0x0A00_0002, .prefix = 32 }, .psk = [_]u8{0x5a} ** 32 };
    cfg.peers[1] = .{ .id = 3, .endpoint = undefined, .allowed_src = .{ .network = 0x0A00_0003, .prefix = 32 }, .psk = [_]u8{0x6b} ** 32 };
    try cfg.validate(&.{});

    // A permissive 0.0.0.0/0 allowed_src is rejected for a hub peer.
    cfg.peers[1].allowed_src = .{ .network = 0, .prefix = 0 };
    try std.testing.expectError(SanityError.HubPeerNeedsAllowedSrc, cfg.validate(&.{}));

    // Overlapping peer prefixes are rejected (10.0.0.0/24 contains 10.0.0.3/32).
    cfg.peers[1].allowed_src = .{ .network = 0x0A00_0003, .prefix = 32 };
    cfg.peers[0].allowed_src = .{ .network = 0x0A00_0000, .prefix = 24 };
    try std.testing.expectError(SanityError.HubAllowedSrcOverlap, cfg.validate(&.{}));
}

test "validate: role=spoke needs exactly one hub and a local target (issue #21)" {
    var cfg = Config.default();
    cfg.role = .spoke;
    cfg.peers[0] = .{ .id = 1, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };

    // Zero peers (no hub) is rejected.
    cfg.peer_count = 0;
    try std.testing.expectError(SanityError.InvalidPsk, cfg.validate(&.{})); // caught earlier by the PSK gate

    // Two peers (ambiguous hub) is rejected.
    cfg.peer_count = 2;
    cfg.peers[1] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x6b} ** 32 };
    try std.testing.expectError(SanityError.SpokeNeedsOneHub, cfg.validate(&.{}));

    // One hub but no local target (no local_routes, no local_tun_ip) is rejected.
    cfg.peer_count = 1;
    try std.testing.expectError(SanityError.SpokeMissingLocal, cfg.validate(&.{}));

    // local_tun_ip supplies the local target -> ok.
    cfg.local_tun_ip = .{ .network = 0x0A00_0002, .prefix = 24 };
    try cfg.validate(&.{});

    // A 0.0.0.0/0 local route is rejected as too broad.
    cfg.local_tun_ip = null;
    cfg.local_route_count = 1;
    cfg.local_routes[0] = .{ .network = 0, .prefix = 0 };
    try std.testing.expectError(SanityError.SpokeLocalRouteTooBroad, cfg.validate(&.{}));
}

test "fromJson: parses role and route arrays (issue #21)" {
    const a = std.testing.allocator;
    const psk_hex = "0123456789abcdef" ** 4;

    const spoke =
        "{ \"role\": \"spoke\", \"local_id\": 2, \"local_tun_ip\": \"10.0.0.2/24\"," ++
        " \"local_routes\": [\"10.0.0.2/32\"], \"remote_routes\": [\"192.168.31.0/24\"]," ++
        " \"peers\": [ { \"id\": 1, \"endpoint\": \"10.100.1.1:51820\", \"allowed_src\": \"10.0.0.0/24\", \"psk\": \"" ++
        psk_hex ++ "\" } ] }";
    const cfg = try Config.fromJson(a, spoke);
    try cfg.validate(&.{});
    try std.testing.expectEqual(Role.spoke, cfg.role);
    try std.testing.expectEqual(@as(usize, 1), cfg.local_route_count);
    try std.testing.expectEqual(@as(u32, 0x0A00_0002), cfg.local_routes[0].network);
    try std.testing.expectEqual(@as(usize, 1), cfg.remote_route_count);
    try std.testing.expectEqual(@as(u32, 0xC0A8_1F00), cfg.remote_routes[0].network);

    // An unknown role string is rejected.
    try std.testing.expectError(error.InvalidRole, Config.fromJson(a, "{ \"role\": \"mesh\" }"));

    // A malformed route CIDR is rejected.
    try std.testing.expectError(error.InvalidCidr, Config.fromJson(a, "{ \"local_routes\": [\"10.0.0.0\"] }"));
}

test "fromJson: keepalive_secs defaults per role and honors an explicit override (issue #96)" {
    const a = std.testing.allocator;

    // A spoke with no keepalive_secs gets the built-in NAT keepalive default.
    const spoke = try Config.fromJson(a, "{ \"role\": \"spoke\", \"local_id\": 2 }");
    try std.testing.expectEqual(DEFAULT_SPOKE_KEEPALIVE_SECS, spoke.keepalive_secs);

    // Hub and manual roles default to disabled (0).
    const hub = try Config.fromJson(a, "{ \"role\": \"hub\", \"local_id\": 1 }");
    try std.testing.expectEqual(@as(u32, 0), hub.keepalive_secs);
    const manual = try Config.fromJson(a, "{ \"local_id\": 1 }");
    try std.testing.expectEqual(@as(u32, 0), manual.keepalive_secs);

    // An explicit value always wins, including 0 to disable it on a spoke.
    const spoke_override = try Config.fromJson(a, "{ \"role\": \"spoke\", \"local_id\": 2, \"keepalive_secs\": 7 }");
    try std.testing.expectEqual(@as(u32, 7), spoke_override.keepalive_secs);
    const spoke_off = try Config.fromJson(a, "{ \"role\": \"spoke\", \"local_id\": 2, \"keepalive_secs\": 0 }");
    try std.testing.expectEqual(@as(u32, 0), spoke_off.keepalive_secs);
}

test "parseEndpoint: address and port land in network byte order" {
    const ep = try parseEndpoint("10.0.0.2:51820");
    try std.testing.expectEqual(sys.AF.INET, ep.family);
    // 10.0.0.2 in network byte order: bytes 0a 00 00 02.
    var addr_bytes: [4]u8 = @bitCast(ep.addr);
    try std.testing.expectEqualSlices(u8, &.{ 10, 0, 0, 2 }, &addr_bytes);
    // port 51820 = 0xCA6C; network order swaps to 0x6CCA.
    try std.testing.expectEqual(std.mem.nativeToBig(u16, 51820), ep.port);

    try std.testing.expectError(EndpointError.MissingColon, parseEndpoint("10.0.0.2"));
    try std.testing.expectError(EndpointError.InvalidPort, parseEndpoint("10.0.0.2:0"));
    try std.testing.expectError(EndpointError.InvalidOctet, parseEndpoint("10.0.0:51820"));
}

test "Cidr.contains: /0 is permissive, /32 is exact" {
    const any = Cidr{ .network = 0, .prefix = 0 };
    try std.testing.expect(any.contains(0x0A00_0002));
    try std.testing.expect(any.contains(0xFFFF_FFFF));

    const host = try parseCidr("10.0.0.2/32");
    try std.testing.expect(host.contains(0x0A00_0002));
    try std.testing.expect(!host.contains(0x0A00_0003));

    const net = try parseCidr("10.0.0.0/24");
    try std.testing.expect(net.contains(0x0A00_00FE));
    try std.testing.expect(!net.contains(0x0A00_0100));
}

test "fromJson: peers array is parsed into the registry spec" {
    const a = std.testing.allocator;
    const psk2 = "0123456789abcdef" ** 4;
    const psk3 = "fedcba9876543210" ** 4;
    const doc =
        "{ \"local_id\": 1, \"peers\": [" ++
        "{ \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"allowed_src\": \"10.0.0.2/32\", \"psk\": \"" ++ psk2 ++ "\" }," ++
        "{ \"id\": 3, \"endpoint\": \"10.0.0.3:51820\", \"psk\": \"" ++ psk3 ++ "\" }" ++
        "] }";
    const cfg = try Config.fromJson(a, doc);
    try cfg.validate(&.{});
    try std.testing.expectEqual(@as(u32, 1), cfg.local_id);
    try std.testing.expectEqual(@as(usize, 2), cfg.peer_count);
    try std.testing.expectEqual(@as(u32, 2), cfg.peers[0].id);
    try std.testing.expectEqual(@as(u6, 32), cfg.peers[0].allowed_src.prefix);
    // An omitted allowed_src defaults to the permissive 0.0.0.0/0.
    try std.testing.expectEqual(@as(u6, 0), cfg.peers[1].allowed_src.prefix);
    // Each peer carries its own distinct private PSK.
    try std.testing.expectEqual(@as(u8, 0x01), cfg.peers[0].psk[0]);
    try std.testing.expectEqual(@as(u8, 0xfe), cfg.peers[1].psk[0]);

    // A malformed endpoint aborts parsing.
    const bad = "{ \"peers\": [ { \"id\": 2, \"endpoint\": \"nope\", \"psk\": \"" ++ psk2 ++ "\" } ] }";
    try std.testing.expectError(error.InvalidEndpoint, Config.fromJson(a, bad));
}

test "fromJson: optional peer name is parsed, bounded, and printable-only (issue #121)" {
    const a = std.testing.allocator;
    const pskx = "0123456789abcdef" ** 4;

    // A present name is copied through; an omitted name leaves an empty label so
    // the peer renders id-only exactly as before this field existed.
    const doc =
        "{ \"local_id\": 1, \"peers\": [" ++
        "{ \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"name\": \"bj-office-gw\", \"psk\": \"" ++ pskx ++ "\" }," ++
        "{ \"id\": 3, \"endpoint\": \"10.0.0.3:51820\", \"psk\": \"" ++ pskx ++ "\" }" ++
        "] }";
    const cfg = try Config.fromJson(a, doc);
    try std.testing.expectEqualStrings("bj-office-gw", cfg.peers[0].nameSlice());
    try std.testing.expectEqual(@as(u8, 0), cfg.peers[1].name_len);
    try std.testing.expectEqualStrings("", cfg.peers[1].nameSlice());

    // An over-long name (> PEER_NAME_MAX bytes) is rejected at parse.
    const long_name = "x" ** (PEER_NAME_MAX + 1);
    const too_long =
        "{ \"peers\": [ { \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"name\": \"" ++
        long_name ++ "\", \"psk\": \"" ++ pskx ++ "\" } ] }";
    try std.testing.expectError(error.PeerNameTooLong, Config.fromJson(a, too_long));

    // A control character in the name is rejected (it would be echoed to a terminal).
    const ctrl =
        "{ \"peers\": [ { \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"name\": \"a\\u0007b\", \"psk\": \"" ++
        pskx ++ "\" } ] }";
    try std.testing.expectError(error.PeerNameNotPrintable, Config.fromJson(a, ctrl));

    // A name exactly at the cap is accepted (boundary).
    const max_name = "y" ** PEER_NAME_MAX;
    const at_cap =
        "{ \"peers\": [ { \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"name\": \"" ++
        max_name ++ "\", \"psk\": \"" ++ pskx ++ "\" } ] }";
    const cfg_cap = try Config.fromJson(a, at_cap);
    try std.testing.expectEqual(@as(u8, PEER_NAME_MAX), cfg_cap.peers[0].name_len);
}

test "per-peer PSKs derive different link keys (issue #13 AC)" {
    const a = std.testing.allocator;
    const crypto = @import("crypto.zig");
    const psk2 = "0123456789abcdef" ** 4;
    const psk3 = "fedcba9876543210" ** 4;
    const doc =
        "{ \"local_id\": 1, \"peers\": [" ++
        "{ \"id\": 2, \"endpoint\": \"10.0.0.2:51820\", \"psk\": \"" ++ psk2 ++ "\" }," ++
        "{ \"id\": 3, \"endpoint\": \"10.0.0.3:51820\", \"psk\": \"" ++ psk3 ++ "\" }" ++
        "] }";
    const cfg = try Config.fromJson(a, doc);

    // The hub (local_id 1) derives a TX key per link from each peer's private
    // PSK. Different PSKs ⇒ different link keys, so compromising peer 2's PSK
    // cannot forge or read peer 3's link.
    const k2 = crypto.deriveLinkKey(cfg.peers[0].psk, cfg.local_id, cfg.peers[0].id);
    const k3 = crypto.deriveLinkKey(cfg.peers[1].psk, cfg.local_id, cfg.peers[1].id);
    try std.testing.expect(!std.mem.eql(u8, &k2, &k3));
}
