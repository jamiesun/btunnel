//! Task 3: Multi-subnet policy matching engine.
//!
//! - CIDR parsing ("192.168.1.0/24" -> network + mask)
//! - Bitwise longest-prefix matching
//! - Lock-free RCU: the policy tree is read atomically via `*const PolicyTree`
//!   and hot-swapped via an atomic pointer exchange.

const std = @import("std");
const config = @import("config.zig");

pub const Cidr = config.Cidr;

pub const Action = enum { forward, drop };

pub const PolicyEntry = struct {
    src: Cidr,
    dst: Cidr,
    action: Action,
    /// Forwarding peer id (ignored when DROP).
    target: u32 = 0,
};

/// CIDR parsing lives in `config.zig` (single source of truth); re-exported
/// here for callers that already speak `policy`.
pub const ParseError = config.CidrError;
pub const parseCidr = config.parseCidr;

fn cidrContains(c: Cidr, ip: u32) bool {
    const m = c.mask();
    return (ip & m) == (c.network & m);
}

/// Immutable policy tree. Built as a whole by the control plane in a dedicated
/// arena; read-only on the data plane.
pub const PolicyTree = struct {
    entries: []const PolicyEntry,

    /// Longest-prefix match: returns the matched entry, or null if none.
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

/// RCU holder: the data plane reads the current tree pointer atomically via
/// `load()`; the control plane replaces it wholesale via `swap()` with a single
/// atomic write. Lock-free; the old pointer remains safe to read by holders
/// after a swap.
pub const ActiveTree = struct {
    ptr: *const PolicyTree,

    pub fn init(initial: *const PolicyTree) ActiveTree {
        return .{ .ptr = initial };
    }

    pub fn load(self: *const ActiveTree) *const PolicyTree {
        return @atomicLoad(*const PolicyTree, &self.ptr, .acquire);
    }

    /// Atomic pointer swap; returns the replaced old tree (caller reclaims it on
    /// an idle loop iteration).
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

test "CIDR Overlap & Matching: longest prefix wins" {
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

test "RCU Hot-Swap: old pointer stays readable after swap" {
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
    const held = active.load(); // data plane holds the old pointer

    const swapped_out = active.swap(&new_tree);
    try std.testing.expectEqual(&old_tree, swapped_out);

    // Old pointer still reads the original rule.
    try std.testing.expectEqual(Action.drop, held.match(0x0A00_0001).?.action);
    // A fresh read hits the new rule.
    try std.testing.expectEqual(Action.forward, active.load().match(0x0A00_0001).?.action);
}
