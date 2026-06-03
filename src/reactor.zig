//! Task 6: Core reactor (data-plane reactor).
//!
//! Single-threaded epoll edge-triggered loop: non-blocking blind forwarding of
//! TUN_FD / UDP_FD / UDS_FD. Egress is dispatched uniformly via
//! `egress(mode, pkt)`; adding a mode only adds a branch, never touches the main
//! loop. v1 ships raw_direct only; kcp_arq / fec_xor are v2 roadmap and return
//! NotImplemented for now.

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");

/// Private wire header (packed struct, physically aligned): 1B version + 1B
/// flags + 2B reserved negotiation field + 8B monotonic sequence number (doubles
/// as the nonce and anti-replay basis). 12 bytes total.
pub const WireHeader = packed struct {
    version: u8 = 1,
    flags: u8 = 0,
    /// Reserved for the v2 handshake negotiation.
    reserved: u16 = 0,
    seq: u64,
};

pub const HEADER_LEN = @divExact(@bitSizeOf(WireHeader), 8);

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

pub const EgressError = error{NotImplemented};

/// Egress dispatch. v1 ships raw_direct only; the rest are v2-reserved branches.
pub fn egress(mode: EgressMode, pkt: []const u8) EgressError!void {
    switch (mode) {
        .raw_direct => {
            // TODO(Task 6): send out via the physical UDP socket (sendto).
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

    /// Single-threaded epoll_wait loop. Scaffold: Linux-only, skeleton pending
    /// Task 6.
    pub fn run(self: *Reactor) !void {
        if (builtin.os.tag != .linux) return error.Unsupported;
        _ = self;
        return error.Unsupported;
    }
};

test "WireHeader is 12 bytes" {
    try std.testing.expectEqual(@as(usize, 12), HEADER_LEN);
}

test "egress: v1 raw_direct works, v2 modes return NotImplemented" {
    try egress(.raw_direct, &.{});
    try std.testing.expectError(EgressError.NotImplemented, egress(.kcp_arq, &.{}));
    try std.testing.expectError(EgressError.NotImplemented, egress(.fec_xor, &.{}));
    try std.testing.expectEqual(@as(u16, 1452), mtuFor(.raw_direct));
}
