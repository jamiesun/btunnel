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

/// Forwarding target meaning "deliver to the local TUN" (mirrors
/// `peer.LOCAL_TARGET`; kept as a local constant so `policy` stays decoupled
/// from `peer`). A `PolicyEntry.target` of 0 is local delivery; any other value
/// is a peer id to forward/relay to.
pub const LOCAL_TARGET: u32 = 0;

pub const DeriveError = error{OutOfSpace};

/// Derive the bootstrap policy for a simplified (`role`) config (issue #21).
/// Pure and unit-testable: writes the generated `PolicyEntry`s into `out` and
/// returns the populated slice. Assumes `cfg` already passed `validate()`
/// (which guarantees a hub peer owns a specific non-overlapping prefix, a spoke
/// has exactly one hub peer and a local target, etc.). `role=manual` yields an
/// empty policy — identical to the original "operator installs rules via subnetra"
/// behavior.
///
/// Policy match is destination-only (longest-prefix), so every entry uses a
/// permissive `src` of 0.0.0.0/0; the hub's per-peer `allowed_src` is what
/// enforces inner-source binding on the data plane.
pub fn deriveInitialPolicy(cfg: config.Config, out: []PolicyEntry) DeriveError![]PolicyEntry {
    const any = Cidr{ .network = 0, .prefix = 0 };
    var n: usize = 0;
    const push = struct {
        fn f(buf: []PolicyEntry, idx: *usize, e: PolicyEntry) DeriveError!void {
            if (idx.* >= buf.len) return DeriveError.OutOfSpace;
            buf[idx.*] = e;
            idx.* += 1;
        }
    }.f;

    switch (cfg.role) {
        .manual => {},
        .hub => {
            // Relay each peer's owned prefix to that peer.
            var i: usize = 0;
            while (i < cfg.peer_count) : (i += 1) {
                try push(out, &n, .{
                    .src = any,
                    .dst = cfg.peers[i].allowed_src,
                    .action = .forward,
                    .target = cfg.peers[i].id,
                });
            }
        },
        .spoke => {
            const hub_id = cfg.peers[0].id;
            // Local delivery rules (emitted FIRST so they win a longest-prefix
            // tie against the hub route).
            if (cfg.local_route_count > 0) {
                var i: usize = 0;
                while (i < cfg.local_route_count) : (i += 1) {
                    try push(out, &n, .{
                        .src = any,
                        .dst = cfg.local_routes[i],
                        .action = .forward,
                        .target = LOCAL_TARGET,
                    });
                }
            } else {
                // validate() guarantees local_tun_ip is set when no local_routes.
                const ip = cfg.local_tun_ip.?;
                try push(out, &n, .{
                    .src = any,
                    .dst = .{ .network = ip.network, .prefix = 32 },
                    .action = .forward,
                    .target = LOCAL_TARGET,
                });
            }
            // Hub route(s): explicit remote_routes, else the overlay subnet.
            if (cfg.remote_route_count > 0) {
                var i: usize = 0;
                while (i < cfg.remote_route_count) : (i += 1) {
                    try push(out, &n, .{
                        .src = any,
                        .dst = cfg.remote_routes[i],
                        .action = .forward,
                        .target = hub_id,
                    });
                }
            } else {
                try push(out, &n, .{
                    .src = any,
                    .dst = cfg.virtual_subnet,
                    .action = .forward,
                    .target = hub_id,
                });
            }
        },
    }
    return out[0..n];
}

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

test "deriveInitialPolicy: manual role yields an empty policy (issue #21)" {
    var cfg = config.Config.default();
    cfg.role = .manual;
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };
    var buf: [8]PolicyEntry = undefined;
    const out = try deriveInitialPolicy(cfg, &buf);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "deriveInitialPolicy: hub relays each peer's owned prefix (issue #21)" {
    var cfg = config.Config.default();
    cfg.role = .hub;
    cfg.peer_count = 2;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .allowed_src = try parseCidr("10.0.0.2/32"), .psk = [_]u8{0x5a} ** 32 };
    cfg.peers[1] = .{ .id = 3, .endpoint = undefined, .allowed_src = try parseCidr("10.0.0.3/32"), .psk = [_]u8{0x6b} ** 32 };
    var buf: [8]PolicyEntry = undefined;
    const out = try deriveInitialPolicy(cfg, &buf);
    try std.testing.expectEqual(@as(usize, 2), out.len);

    const tree = PolicyTree{ .entries = out };
    // 10.0.0.2 routes to peer 2, 10.0.0.3 to peer 3.
    const h2 = tree.match(0x0A00_0002).?;
    try std.testing.expectEqual(Action.forward, h2.action);
    try std.testing.expectEqual(@as(u32, 2), h2.target);
    try std.testing.expectEqual(@as(u32, 3), tree.match(0x0A00_0003).?.target);
}

test "deriveInitialPolicy: spoke local /32 wins over the hub default route (issue #21)" {
    var cfg = config.Config.default(); // virtual_subnet 10.0.0.0/24
    cfg.role = .spoke;
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 1, .endpoint = undefined, .allowed_src = try parseCidr("10.0.0.0/24"), .psk = [_]u8{0x5a} ** 32 };
    cfg.local_route_count = 1;
    cfg.local_routes[0] = try parseCidr("10.0.0.2/32");

    var buf: [8]PolicyEntry = undefined;
    const out = try deriveInitialPolicy(cfg, &buf);
    try std.testing.expectEqual(@as(usize, 2), out.len); // local + virtual_subnet default

    const tree = PolicyTree{ .entries = out };
    // The spoke's own address is delivered LOCAL...
    const local = tree.match(0x0A00_0002).?;
    try std.testing.expectEqual(LOCAL_TARGET, local.target);
    // ...while another overlay address falls through to the hub (id 1).
    try std.testing.expectEqual(@as(u32, 1), tree.match(0x0A00_0003).?.target);
}

test "deriveInitialPolicy: spoke without local_routes uses local_tun_ip as a /32 (issue #21)" {
    var cfg = config.Config.default();
    cfg.role = .spoke;
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 1, .endpoint = undefined, .allowed_src = try parseCidr("10.0.0.0/24"), .psk = [_]u8{0x5a} ** 32 };
    // A /24 host address must collapse to a /32 local route, NOT the whole /24.
    cfg.local_tun_ip = try parseCidr("10.0.0.2/24");

    var buf: [8]PolicyEntry = undefined;
    const out = try deriveInitialPolicy(cfg, &buf);
    const tree = PolicyTree{ .entries = out };
    // Only the exact /32 is local; a sibling overlay address routes to the hub.
    try std.testing.expectEqual(LOCAL_TARGET, tree.match(0x0A00_0002).?.target);
    try std.testing.expectEqual(@as(u32, 1), tree.match(0x0A00_0003).?.target);
}

test "deriveInitialPolicy: spoke remote_routes route specific subnets via the hub (issue #21)" {
    var cfg = config.Config.default();
    cfg.role = .spoke;
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 1, .endpoint = undefined, .allowed_src = try parseCidr("0.0.0.0/0"), .psk = [_]u8{0x5a} ** 32 };
    cfg.local_route_count = 1;
    cfg.local_routes[0] = try parseCidr("192.168.10.0/24");
    cfg.remote_route_count = 1;
    cfg.remote_routes[0] = try parseCidr("192.168.31.0/24");

    var buf: [8]PolicyEntry = undefined;
    const out = try deriveInitialPolicy(cfg, &buf);
    const tree = PolicyTree{ .entries = out };
    // Local LAN delivered locally; remote LAN forwarded to the hub.
    try std.testing.expectEqual(LOCAL_TARGET, tree.match(0xC0A8_0A05).?.target); // 192.168.10.5
    try std.testing.expectEqual(@as(u32, 1), tree.match(0xC0A8_1F05).?.target); // 192.168.31.5
    // A destination in neither route does not match (no default route emitted).
    try std.testing.expectEqual(@as(?PolicyEntry, null), tree.match(0x0808_0808));
}

test "deriveInitialPolicy: OutOfSpace when the buffer is too small" {
    var cfg = config.Config.default();
    cfg.role = .hub;
    cfg.peer_count = 2;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .allowed_src = try parseCidr("10.0.0.2/32"), .psk = [_]u8{0x5a} ** 32 };
    cfg.peers[1] = .{ .id = 3, .endpoint = undefined, .allowed_src = try parseCidr("10.0.0.3/32"), .psk = [_]u8{0x6b} ** 32 };
    var buf: [1]PolicyEntry = undefined;
    try std.testing.expectError(DeriveError.OutOfSpace, deriveInitialPolicy(cfg, &buf));
}
