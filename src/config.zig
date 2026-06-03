//! Task 2: Configuration snapshot & sanity check.
//!
//! JSON parsing + compile-time fallback config + foolproof boundary checks.
//! Scaffold: `validate` implements real boundary checks; `fromJson` is a minimal
//! stub; the handshake negotiation field is reserved.

const std = @import("std");

pub const MTU_MIN: u16 = 68;
pub const MTU_MAX: u16 = 1500;

/// 32-byte pre-shared key (PSK).
pub const Psk = [32]u8;

pub const SanityError = error{
    MtuOutOfRange,
    SubnetOverlap,
    InvalidPsk,
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
};

pub const Config = struct {
    /// v1 header/config negotiation version (fixed to 1 in v1, reserved for the
    /// v2 handshake).
    negotiation_version: u8 = 1,
    /// Pre-shared key.
    psk: Psk = [_]u8{0} ** 32,
    /// Tunnel MTU.
    local_tun_mtu: u16 = 1452,
    /// Local UDP listen port.
    listen_port: u16 = 51820,
    /// Virtual subnet (default 10.0.0.0/24).
    virtual_subnet: Cidr = .{ .network = 0x0A00_0000, .prefix = 24 },

    /// Compile-time hardcoded fallback config (used when config.json is missing).
    pub fn default() Config {
        return .{};
    }

    /// Foolproof boundary checks: MTU range + virtual/host subnet overlap.
    pub fn validate(self: Config, host_subnets: []const Cidr) SanityError!void {
        if (self.local_tun_mtu < MTU_MIN or self.local_tun_mtu > MTU_MAX) {
            return SanityError.MtuOutOfRange;
        }
        for (host_subnets) |hs| {
            if (self.virtual_subnet.overlaps(hs)) return SanityError.SubnetOverlap;
        }
    }

    /// Ingest config.json in one shot. Scaffold stage: on parse failure or a
    /// missing file, fall back to the default config.
    /// TODO(Task 2): implement PSK hex/base64 decoding and full field mapping.
    pub fn fromJson(allocator: std.mem.Allocator, slice: []const u8) Config {
        _ = allocator;
        _ = slice;
        return Config.default();
    }
};

test "validate: MTU out of range is rejected" {
    var cfg = Config.default();
    cfg.local_tun_mtu = 9000;
    try std.testing.expectError(SanityError.MtuOutOfRange, cfg.validate(&.{}));

    cfg.local_tun_mtu = 1452;
    try cfg.validate(&.{});
}

test "validate: virtual/host subnet overlap is rejected" {
    const cfg = Config.default(); // 10.0.0.0/24
    const overlap = Cidr{ .network = 0x0A00_0000, .prefix = 16 }; // 10.0.0.0/16
    try std.testing.expectError(SanityError.SubnetOverlap, cfg.validate(&.{overlap}));

    const disjoint = Cidr{ .network = 0xC0A8_0100, .prefix = 24 }; // 192.168.1.0/24
    try cfg.validate(&.{disjoint});
}
