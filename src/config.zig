//! 任务 2：配置自检（Configuration Snapshot）
//!
//! JSON 解析 + 编译期备用配置 + 防呆边界自检。
//! 本文件为脚手架：`validate` 已落地真实边界校验，`fromJson` 提供最小实现，
//! 握手协商字段已预留。

const std = @import("std");

pub const MTU_MIN: u16 = 68;
pub const MTU_MAX: u16 = 1500;

/// 32 字节预共享密钥（PSK）。
pub const Psk = [32]u8;

pub const SanityError = error{
    MtuOutOfRange,
    SubnetOverlap,
    InvalidPsk,
};

/// 表示一个 CIDR 网段（网络号 + 前缀长度）。
pub const Cidr = struct {
    /// 主机字节序的网络地址。
    network: u32,
    prefix: u6,

    pub fn mask(self: Cidr) u32 {
        if (self.prefix == 0) return 0;
        return @as(u32, 0xffff_ffff) << @intCast(32 - @as(u6, self.prefix));
    }

    /// 两个网段是否存在地址空间重叠。
    pub fn overlaps(a: Cidr, b: Cidr) bool {
        const m = a.mask() & b.mask();
        return (a.network & m) == (b.network & m);
    }
};

pub const Config = struct {
    /// v1 报头/配置协商版本（v1 固定为 1，为 v2 握手预留）。
    negotiation_version: u8 = 1,
    /// 预共享密钥。
    psk: Psk = [_]u8{0} ** 32,
    /// 隧道 MTU。
    local_tun_mtu: u16 = 1452,
    /// 本机 UDP 监听端口。
    listen_port: u16 = 51820,
    /// 虚拟子网（默认 10.0.0.0/24）。
    virtual_subnet: Cidr = .{ .network = 0x0A00_0000, .prefix = 24 },

    /// 编译期硬编码的缺省底盘配置（config.json 缺失时使用）。
    pub fn default() Config {
        return .{};
    }

    /// 防呆边界自检：MTU 区间 + 虚拟子网与宿主机物理子网重叠检测。
    pub fn validate(self: Config, host_subnets: []const Cidr) SanityError!void {
        if (self.local_tun_mtu < MTU_MIN or self.local_tun_mtu > MTU_MAX) {
            return SanityError.MtuOutOfRange;
        }
        for (host_subnets) |hs| {
            if (self.virtual_subnet.overlaps(hs)) return SanityError.SubnetOverlap;
        }
    }

    /// 一次性吞入 config.json。脚手架阶段：解析失败或缺失则回退到缺省底盘。
    /// TODO(任务 2)：实现 psk hex/base64 解码与完整字段映射。
    pub fn fromJson(allocator: std.mem.Allocator, slice: []const u8) Config {
        _ = allocator;
        _ = slice;
        return Config.default();
    }
};

test "validate: MTU 越界被拦截" {
    var cfg = Config.default();
    cfg.local_tun_mtu = 9000;
    try std.testing.expectError(SanityError.MtuOutOfRange, cfg.validate(&.{}));

    cfg.local_tun_mtu = 1452;
    try cfg.validate(&.{});
}

test "validate: 虚拟子网与物理子网重叠被拦截" {
    const cfg = Config.default(); // 10.0.0.0/24
    const overlap = Cidr{ .network = 0x0A00_0000, .prefix = 16 }; // 10.0.0.0/16
    try std.testing.expectError(SanityError.SubnetOverlap, cfg.validate(&.{overlap}));

    const disjoint = Cidr{ .network = 0xC0A8_0100, .prefix = 24 }; // 192.168.1.0/24
    try cfg.validate(&.{disjoint});
}
