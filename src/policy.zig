//! 任务 3：多网段策略匹配引擎（Policy Engine）
//!
//! - CIDR 解析（"192.168.1.0/24" -> 网络号 + 掩码）
//! - 基于位运算的逆序最长前缀匹配
//! - 无锁 RCU：策略树以 `*const PolicyTree` 原子只读 + 原子指针交换热替换

const std = @import("std");
const config = @import("config.zig");

pub const Cidr = config.Cidr;

pub const Action = enum { forward, drop };

pub const PolicyEntry = struct {
    src: Cidr,
    dst: Cidr,
    action: Action,
    /// 转发目标对端 id（DROP 时忽略）。
    target: u32 = 0,
};

pub const ParseError = error{
    MissingSlash,
    InvalidOctet,
    InvalidPrefix,
};

/// 将 "A.B.C.D/P" 解析为 Cidr（主机字节序网络号）。
pub fn parseCidr(text: []const u8) ParseError!Cidr {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return ParseError.MissingSlash;
    const addr_str = text[0..slash];
    const prefix_str = text[slash + 1 ..];

    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4) return ParseError.InvalidOctet;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return ParseError.InvalidOctet;
    }
    if (i != 4) return ParseError.InvalidOctet;

    const prefix = std.fmt.parseInt(u8, prefix_str, 10) catch return ParseError.InvalidPrefix;
    if (prefix > 32) return ParseError.InvalidPrefix;

    const network = std.mem.readInt(u32, &octets, .big);
    return .{ .network = network, .prefix = @intCast(prefix) };
}

fn cidrContains(c: Cidr, ip: u32) bool {
    const m = c.mask();
    return (ip & m) == (c.network & m);
}

/// 不可变策略树。由控制面在独立 arena 中整体构建，数据面只读。
pub const PolicyTree = struct {
    entries: []const PolicyEntry,

    /// 逆序最长前缀匹配：返回命中的 entry，未命中返回 null。
    pub fn match(self: *const PolicyTree, dst_ip: u32) ?PolicyEntry {
        var best: ?PolicyEntry = null;
        var best_prefix: i16 = -1;
        for (self.entries) |e| {
            if (cidrContains(e.dst, dst_ip) and @as(i16, e.dst.prefix) > best_prefix) {
                best = e;
                best_prefix = e.dst.prefix;
            }
        }
        return best;
    }
};

/// RCU 持有者：数据面经 `load()` 原子读取当前树指针；控制面经 `swap()`
/// 用一次原子写整体替换。全程无锁，旧指针在替换后仍可被持有方安全读取。
pub const ActiveTree = struct {
    ptr: *const PolicyTree,

    pub fn init(initial: *const PolicyTree) ActiveTree {
        return .{ .ptr = initial };
    }

    pub fn load(self: *const ActiveTree) *const PolicyTree {
        return @atomicLoad(*const PolicyTree, &self.ptr, .acquire);
    }

    /// 原子指针交换，返回被替换下来的旧树（调用方在空闲轮回收）。
    pub fn swap(self: *ActiveTree, new_tree: *const PolicyTree) *const PolicyTree {
        const old = self.ptr;
        @atomicStore(*const PolicyTree, &self.ptr, new_tree, .release);
        return old;
    }
};

test "parseCidr" {
    const c = try parseCidr("192.168.1.0/24");
    try std.testing.expectEqual(@as(u32, 0xC0A8_0100), c.network);
    try std.testing.expectEqual(@as(u6, 24), c.prefix);
    try std.testing.expectError(ParseError.MissingSlash, parseCidr("10.0.0.0"));
    try std.testing.expectError(ParseError.InvalidPrefix, parseCidr("10.0.0.0/33"));
}

test "CIDR Overlap & Matching: 最长前缀优先" {
    const any = PolicyEntry{
        .src = try parseCidr("0.0.0.0/0"),
        .dst = try parseCidr("0.0.0.0/0"),
        .action = .drop,
    };
    const specific = PolicyEntry{
        .src = try parseCidr("0.0.0.0/0"),
        .dst = try parseCidr("192.168.2.0/24"),
        .action = .forward,
        .target = 3,
    };
    const tree = PolicyTree{ .entries = &.{ any, specific } };

    const hit_fwd = tree.match(0xC0A8_0264).?; // 192.168.2.100
    try std.testing.expectEqual(Action.forward, hit_fwd.action);

    const hit_drop = tree.match(0x0808_0808).?; // 8.8.8.8
    try std.testing.expectEqual(Action.drop, hit_drop.action);
}

test "RCU Hot-Swap: 旧指针替换后仍可安全读取" {
    const old_tree = PolicyTree{ .entries = &.{.{
        .src = try parseCidr("0.0.0.0/0"),
        .dst = try parseCidr("10.0.0.0/24"),
        .action = .drop,
    }} };
    const new_tree = PolicyTree{ .entries = &.{.{
        .src = try parseCidr("0.0.0.0/0"),
        .dst = try parseCidr("10.0.0.0/24"),
        .action = .forward,
        .target = 7,
    }} };

    var active = ActiveTree.init(&old_tree);
    const held = active.load(); // 数据面持有旧指针

    const swapped_out = active.swap(&new_tree);
    try std.testing.expectEqual(&old_tree, swapped_out);

    // 旧指针仍可安全读出原规则。
    try std.testing.expectEqual(Action.drop, held.match(0x0A00_0001).?.action);
    // 新读取命中新规则。
    try std.testing.expectEqual(Action.forward, active.load().match(0x0A00_0001).?.action);
}
