//! Issue #23: host network plan printer (`--print-network-plan`).
//!
//! Scope (v1): PRINT ONLY. This module computes and renders the exact host
//! networking commands an operator must run for a configured Hub/Spoke node —
//! TUN interface MTU, local TUN address, and routes to the remote subnets
//! reachable through the tunnel — plus an optional TCP MSS clamp hint. The
//! daemon never mutates host networking state itself (auto-apply is an explicit
//! Non-Goal: it would require shelling out to `ip` or a pure-Zig netlink
//! implementation, breaking the zero-dependency single-binary guarantee).
//!
//! The output is deterministic so it can be diffed and so the integration
//! harness and the documented deployment stay in sync. The MTU is derived from
//! the real wire constants (never a hardcoded magic number) so it tracks the
//! protocol if the header or tag size ever changes.

const std = @import("std");
const config = @import("config.zig");
const reactor = @import("reactor.zig");
const crypto = @import("crypto.zig");

/// Outer encapsulation a tunnelled packet pays on the underlay: an IPv4 header
/// (20) + a UDP header (8). IPv4-only in v1 (IPv6 underlay is out of scope).
pub const OUTER_OVERHEAD: u16 = 28;

/// Total per-packet overhead added on top of the inner IP packet: subnetra wire
/// header + AEAD tag + outer IPv4/UDP. Computed from the live constants so the
/// recommended MTU can never silently drift from the actual protocol.
pub const TUNNEL_OVERHEAD: u16 = reactor.HEADER_LEN + crypto.TAG_LEN + OUTER_OVERHEAD;

/// Largest safe inner (tunnel) MTU for a given underlay path MTU. Returns 0 if
/// the path is too small to carry any payload (degenerate config).
pub fn maxTunMtu(path_mtu: u16) u16 {
    if (path_mtu <= TUNNEL_OVERHEAD) return 0;
    return path_mtu - TUNNEL_OVERHEAD;
}

/// Default underlay path MTU assumed when the operator does not override it.
pub const DEFAULT_PATH_MTU: u16 = 1500;

fn writeCidr(w: anytype, c: config.Cidr) !void {
    const a: u32 = c.network;
    try w.print("{d}.{d}.{d}.{d}/{d}", .{
        (a >> 24) & 0xff,
        (a >> 16) & 0xff,
        (a >> 8) & 0xff,
        a & 0xff,
        c.prefix,
    });
}

/// Minimal fixed-buffer appender (Zig 0.16 dropped `std.io.fixedBufferStream`).
/// `print` formats into the tail of the buffer; overflow surfaces as an error so
/// the plan is never silently truncated.
const Appender = struct {
    buf: []u8,
    len: usize = 0,

    fn print(self: *Appender, comptime fmt: []const u8, args: anytype) !void {
        const slice = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += slice.len;
    }

    fn writeAll(self: *Appender, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn written(self: *const Appender) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Canonicalize a CIDR to its network address (mask off host bits) so a route
/// derived from a peer's `allowed_src` is the subnet, not a host inside it.
fn networkOf(c: config.Cidr) config.Cidr {
    return .{ .network = c.network & c.mask(), .prefix = c.prefix };
}

/// Render the network plan for `cfg` into `out`, returning the written slice.
/// Deterministic and side-effect free (pure formatting); the caller writes the
/// result to stdout. `path_mtu` is the assumed underlay path MTU.
pub fn render(out: []u8, cfg: config.Config, tun_name: []const u8, path_mtu: u16) ![]const u8 {
    var fbs = Appender{ .buf = out };
    const w = &fbs;

    const max_mtu = maxTunMtu(path_mtu);

    try w.print("# subnetra network plan for interface '{s}'\n", .{tun_name});
    try w.print("# underlay path MTU assumed: {d} (override with --path-mtu N)\n", .{path_mtu});
    try w.print(
        "# tunnel overhead: {d} bytes (wire header {d} + AEAD tag {d} + outer IPv4/UDP {d})\n",
        .{ TUNNEL_OVERHEAD, reactor.HEADER_LEN, crypto.TAG_LEN, OUTER_OVERHEAD },
    );
    try w.print("# recommended max tunnel MTU for this path: {d}\n", .{max_mtu});
    if (cfg.local_tun_mtu > max_mtu) {
        try w.print(
            "# WARNING: configured local_tun_mtu {d} exceeds the recommended max {d};\n" ++
                "#          packets larger than {d} bytes may fragment or be silently dropped.\n",
            .{ cfg.local_tun_mtu, max_mtu, max_mtu },
        );
    }
    try w.writeAll("\n");

    // 1) Interface MTU + bring the link up. The TUN MTU must equal the daemon's
    //    configured tunnel MTU so the kernel never hands oversized inner packets
    //    to the data plane (which would drop them as oversized).
    try w.print("ip link set {s} mtu {d} up\n", .{ tun_name, cfg.local_tun_mtu });

    // 2) Local TUN address.
    if (cfg.local_tun_ip) |ip| {
        try w.print("ip addr add ", .{});
        try writeCidr(w, ip);
        try w.print(" dev {s}\n", .{tun_name});
    } else {
        try w.print(
            "# set the local TUN address (config 'local_tun_ip' is unset):\n" ++
                "#   ip addr add <A.B.C.D/prefix> dev {s}\n",
            .{tun_name},
        );
    }

    // 3) Routes for the remote subnets reachable through the tunnel, derived
    //    from each peer's allowed_src. A permissive 0.0.0.0/0 is skipped (adding
    //    a default route via the tunnel would blackhole all host traffic).
    try w.writeAll("# routes to remote subnets reachable via the tunnel:\n");
    var any_route = false;
    var i: usize = 0;
    while (i < cfg.peer_count) : (i += 1) {
        const net = networkOf(cfg.peers[i].allowed_src);
        if (net.prefix == 0) {
            try w.print("# (peer id {d}: allowed_src is 0.0.0.0/0 — no route emitted; set a specific prefix)\n", .{cfg.peers[i].id});
            continue;
        }
        try w.print("ip route add ", .{});
        try writeCidr(w, net);
        try w.print(" dev {s}\n", .{tun_name});
        any_route = true;
    }
    if (!any_route) {
        try w.writeAll("# (no specific remote subnets configured)\n");
    }

    // 4) Optional MSS clamp guidance. PMTU blackholes are a common symptom of a
    //    too-large MTU; clamping TCP MSS to the path keeps TCP usable even when
    //    ICMP fragmentation-needed is filtered.
    try w.writeAll(
        "\n# optional: clamp TCP MSS to the tunnel path (avoids PMTU blackholes):\n" ++
            "#   nft add rule inet filter forward tcp flags syn tcp option maxseg size set rt mtu\n" ++
            "#   (iptables equivalent: iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN \\\n" ++
            "#      -j TCPMSS --clamp-mss-to-pmtu)\n",
    );

    return fbs.written();
}

test "maxTunMtu derives from the live wire constants" {
    // 1500 path: 1500 - (20 + 16 + 28) = 1436.
    try std.testing.expectEqual(@as(u16, 1436), maxTunMtu(1500));
    try std.testing.expectEqual(@as(u16, 64), TUNNEL_OVERHEAD);
    // Degenerate: path no larger than the overhead yields 0.
    try std.testing.expectEqual(@as(u16, 0), maxTunMtu(TUNNEL_OVERHEAD));
    try std.testing.expectEqual(@as(u16, 0), maxTunMtu(10));
}

test "render: deterministic plan with address, route, and MTU" {
    var cfg = config.Config.default();
    cfg.local_tun_mtu = 1400;
    cfg.local_tun_ip = .{ .network = 0x0A00_0002, .prefix = 24 }; // 10.0.0.2/24
    cfg.peer_count = 1;
    cfg.peers[0] = .{
        .id = 3,
        .endpoint = undefined,
        .allowed_src = try config.parseCidr("192.168.31.0/24"),
        .psk = [_]u8{0x5a} ** 32,
    };

    var buf: [4096]u8 = undefined;
    const plan = try render(&buf, cfg, "snr0", 1500);

    try std.testing.expect(std.mem.indexOf(u8, plan, "ip link set snr0 mtu 1400 up") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "ip addr add 10.0.0.2/24 dev snr0") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "ip route add 192.168.31.0/24 dev snr0") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "recommended max tunnel MTU for this path: 1436") != null);
    // 1400 <= 1436, so no warning.
    try std.testing.expect(std.mem.indexOf(u8, plan, "WARNING") == null);
}

test "render: warns when configured MTU exceeds the path maximum" {
    var cfg = config.Config.default();
    cfg.local_tun_mtu = 1452; // > 1436 on a 1500 path
    cfg.peer_count = 1;
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };

    var buf: [4096]u8 = undefined;
    const plan = try render(&buf, cfg, "snr0", 1500);
    try std.testing.expect(std.mem.indexOf(u8, plan, "WARNING") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "exceeds the recommended max 1436") != null);
}

test "render: unset local_tun_ip emits a placeholder, /0 allowed_src emits no route" {
    var cfg = config.Config.default();
    cfg.local_tun_mtu = 1400;
    cfg.local_tun_ip = null;
    cfg.peer_count = 1;
    // Default allowed_src is 0.0.0.0/0.
    cfg.peers[0] = .{ .id = 2, .endpoint = undefined, .psk = [_]u8{0x5a} ** 32 };

    var buf: [4096]u8 = undefined;
    const plan = try render(&buf, cfg, "snr0", 1500);
    try std.testing.expect(std.mem.indexOf(u8, plan, "'local_tun_ip' is unset") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan, "no route emitted") != null);
    // No concrete `ip route add` line should appear for a /0 peer.
    try std.testing.expect(std.mem.indexOf(u8, plan, "ip route add") == null);
}
