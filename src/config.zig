//! Task 2: Configuration snapshot & sanity check.
//!
//! Parse `config.json` once at startup via `std.json`; if the file is missing
//! the caller falls back to the comptime hard-coded default. Malformed JSON or
//! an out-of-range field aborts startup (the daemon never silently runs a
//! half-valid config). This module is pure (no file I/O) so it stays portable
//! and unit-testable on any host; the actual file read lives in `main.zig`.

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

/// CIDR string parse errors (canonical home; re-exported by `policy.zig`).
pub const CidrError = error{
    MissingSlash,
    InvalidOctet,
    InvalidPrefix,
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

    /// Compile-time hardcoded fallback config (used when config.json is
    /// missing). Note: the fallback PSK is all-zero, which `validate()`
    /// deliberately rejects — the default config is intentionally NON-RUNNABLE
    /// until a real PSK is provisioned via config.json (iron law #5).
    pub fn default() Config {
        return .{};
    }

    /// Whether the PSK is unset (all-zero). v1 mandates a real PSK.
    pub fn pskIsZero(self: Config) bool {
        return std.mem.allEqual(u8, &self.psk, 0);
    }

    /// Foolproof boundary checks: mandatory non-zero PSK + MTU range +
    /// virtual/host subnet overlap. A missing/all-zero PSK is rejected so the
    /// daemon can never start unauthenticated.
    pub fn validate(self: Config, host_subnets: []const Cidr) SanityError!void {
        if (self.pskIsZero()) return SanityError.InvalidPsk;
        if (self.local_tun_mtu < MTU_MIN or self.local_tun_mtu > MTU_MAX) {
            return SanityError.MtuOutOfRange;
        }
        for (host_subnets) |hs| {
            if (self.virtual_subnet.overlaps(hs)) return SanityError.SubnetOverlap;
        }
    }

    /// On-wire JSON schema. Defaults mirror `Config` so a partial document is
    /// valid; `psk` is a 64-char hex string and `virtual_subnet` a CIDR string.
    /// Unknown fields are ignored so forward-compatible keys (e.g. the future
    /// multi-peer `peers` array, issue #5) do not break v1 parsing.
    const Wire = struct {
        negotiation_version: u8 = 1,
        psk: []const u8 = "",
        local_tun_mtu: u16 = 1452,
        listen_port: u16 = 51820,
        virtual_subnet: []const u8 = "10.0.0.0/24",
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

        var cfg = Config{
            .negotiation_version = w.negotiation_version,
            .local_tun_mtu = w.local_tun_mtu,
            .listen_port = w.listen_port,
            .virtual_subnet = parseCidr(w.virtual_subnet) catch return error.InvalidCidr,
        };

        if (w.psk.len != 0) {
            if (w.psk.len != 64) return error.InvalidPsk;
            _ = std.fmt.hexToBytes(cfg.psk[0..], w.psk) catch return error.InvalidPsk;
        }

        return cfg;
    }
};

test "validate: MTU out of range is rejected" {
    var cfg = Config.default();
    cfg.psk = [_]u8{0x5a} ** 32; // provision a PSK so the MTU fuse is what fires
    cfg.local_tun_mtu = 9000;
    try std.testing.expectError(SanityError.MtuOutOfRange, cfg.validate(&.{}));

    cfg.local_tun_mtu = 1452;
    try cfg.validate(&.{});
}

test "validate: virtual/host subnet overlap is rejected" {
    var cfg = Config.default(); // 10.0.0.0/24
    cfg.psk = [_]u8{0x5a} ** 32;
    const overlap = Cidr{ .network = 0x0A00_0000, .prefix = 16 }; // 10.0.0.0/16
    try std.testing.expectError(SanityError.SubnetOverlap, cfg.validate(&.{overlap}));

    const disjoint = Cidr{ .network = 0xC0A8_0100, .prefix = 24 }; // 192.168.1.0/24
    try cfg.validate(&.{disjoint});
}

test "validate: a missing/all-zero PSK is rejected (mandatory PSK, iron law #5)" {
    // The compile-time default ships an all-zero PSK and must be non-runnable.
    const def = Config.default();
    try std.testing.expect(def.pskIsZero());
    try std.testing.expectError(SanityError.InvalidPsk, def.validate(&.{}));

    // A provisioned PSK clears the gate.
    var cfg = Config.default();
    cfg.psk = [_]u8{0x01} ** 32;
    try std.testing.expect(!cfg.pskIsZero());
    try cfg.validate(&.{});
}

test "JSON Parser & Sanity Check" {
    const a = std.testing.allocator;

    // A full document maps every field and decodes the hex PSK.
    const psk_hex = "0123456789abcdef" ** 4; // 64 hex chars
    const ok =
        "{ \"negotiation_version\": 1, \"psk\": \"" ++ psk_hex ++
        "\", \"local_tun_mtu\": 1400, \"listen_port\": 4000, \"virtual_subnet\": \"10.9.0.0/24\" }";
    const cfg = try Config.fromJson(a, ok);
    try cfg.validate(&.{});
    try std.testing.expectEqual(@as(u16, 1400), cfg.local_tun_mtu);
    try std.testing.expectEqual(@as(u16, 4000), cfg.listen_port);
    try std.testing.expectEqual(@as(u32, 0x0A09_0000), cfg.virtual_subnet.network);
    try std.testing.expectEqual(@as(u6, 24), cfg.virtual_subnet.prefix);
    try std.testing.expectEqual(@as(u8, 0x01), cfg.psk[0]);
    try std.testing.expectEqual(@as(u8, 0xef), cfg.psk[7]);

    // A partial document falls back to per-field defaults (and a zero PSK).
    const partial = "{ \"local_tun_mtu\": 1300 }";
    const cfg2 = try Config.fromJson(a, partial);
    try std.testing.expectEqual(@as(u16, 1300), cfg2.local_tun_mtu);
    try std.testing.expectEqual(@as(u16, 51820), cfg2.listen_port);
    try std.testing.expectEqual([_]u8{0} ** 32, cfg2.psk);

    // An out-of-range MTU parses but is rejected by the sanity check (fuse).
    // (PSK provided so the MTU check is what fires, not the PSK gate.)
    const bad_mtu = "{ \"psk\": \"" ++ psk_hex ++ "\", \"local_tun_mtu\": 9000 }";
    const cfg3 = try Config.fromJson(a, bad_mtu);
    try std.testing.expectError(SanityError.MtuOutOfRange, cfg3.validate(&.{}));

    // Malformed JSON aborts parsing (no silent default fallback).
    try std.testing.expect(std.meta.isError(Config.fromJson(a, "{ not valid json")));

    // A non-64-char PSK is rejected.
    try std.testing.expectError(error.InvalidPsk, Config.fromJson(a, "{ \"psk\": \"abcd\" }"));

    // A malformed virtual subnet is rejected.
    try std.testing.expectError(error.InvalidCidr, Config.fromJson(a, "{ \"virtual_subnet\": \"10.0.0.0\" }"));
}

test "parseCidr" {
    const c = try parseCidr("192.168.1.0/24");
    try std.testing.expectEqual(@as(u32, 0xC0A8_0100), c.network);
    try std.testing.expectEqual(@as(u6, 24), c.prefix);
    try std.testing.expectError(CidrError.MissingSlash, parseCidr("10.0.0.0"));
    try std.testing.expectError(CidrError.InvalidPrefix, parseCidr("10.0.0.0/33"));
}
