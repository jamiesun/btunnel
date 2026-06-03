//! 任务 6：核心反应堆（Data-Plane Reactor）
//!
//! 单线程 epoll 边缘触发闭环：TUN_FD / UDP_FD / UDS_FD 非阻塞盲转。
//! 出口统一经 `egress(mode, pkt)` 分发，新增模式只填分支，不动主循环。
//! v1 仅交付 raw_direct；kcp_arq / fec_xor 为 v2 Roadmap，暂返回 NotImplemented。

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");

/// 私有报头（packed struct 物理对齐）：1B 版本 + 1B 标志 + 2B 预留协商字段
/// + 8B 单调递增序列号（兼作 nonce 与防重放依据）。共 12 字节。
pub const WireHeader = packed struct {
    version: u8 = 1,
    flags: u8 = 0,
    /// v2 握手协商预留。
    reserved: u16 = 0,
    seq: u64,
};

pub const HEADER_LEN = @divExact(@bitSizeOf(WireHeader), 8);

/// 出口流控模式。新增模式只在此处与 `egress` 增加分支。
pub const EgressMode = enum {
    raw_direct, // v1：跳过重传，MTU 1452
    kcp_arq, // v2：自研 arena 版 ARQ，MTU 1428
    fec_xor, // v2：自研前向纠错
};

pub fn mtuFor(mode: EgressMode) u16 {
    return switch (mode) {
        .raw_direct => 1452,
        .kcp_arq => 1428,
        .fec_xor => 1428,
    };
}

pub const EgressError = error{NotImplemented};

/// 出口分发。v1 仅 raw_direct 落地，其余为 v2 预留分支。
pub fn egress(mode: EgressMode, pkt: []const u8) EgressError!void {
    switch (mode) {
        .raw_direct => {
            // TODO(任务 6)：经物理 UDP 套接字 sendto 发出。
            _ = pkt;
        },
        .kcp_arq, .fec_xor => return EgressError.NotImplemented,
    }
}

pub const Reactor = struct {
    tun_fd: std.posix.fd_t,
    udp_fd: std.posix.fd_t,
    uds_fd: std.posix.fd_t,
    active: *policy.ActiveTree,
    mode: EgressMode = .raw_direct,

    /// 单线程 epoll_wait 闭环。脚手架：Linux 专属，骨架待任务 6 落地。
    pub fn run(self: *Reactor) !void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        _ = self;
        return error.Unsupported;
    }
};

test "WireHeader 为 12 字节" {
    try std.testing.expectEqual(@as(usize, 12), HEADER_LEN);
}

test "egress: v1 raw_direct 落地，v2 模式返回 NotImplemented" {
    try egress(.raw_direct, &.{});
    try std.testing.expectError(EgressError.NotImplemented, egress(.kcp_arq, &.{}));
    try std.testing.expectError(EgressError.NotImplemented, egress(.fec_xor, &.{}));
    try std.testing.expectEqual(@as(u16, 1452), mtuFor(.raw_direct));
}
