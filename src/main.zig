//! btunnel daemon entry point.
//!
//! Load config (config.json or the comptime default) -> sanity check -> build
//! the peer registry -> open the TUN device, bind the UDP and AF_UNIX control
//! sockets -> run the single-threaded epoll reactor.
//!
//! `--check` validates the configuration (config + peer registry) and exits
//! without touching any device or socket; the full run blocks in the reactor.
//!
//! Environment overrides (used by the integration harness so multiple daemons
//! can coexist in one mount namespace):
//!   BTUNNEL_SOCK  control socket path (default uds.SOCKET_PATH)
//!   BTUNNEL_TUN   TUN interface name  (default "btun0")

const std = @import("std");
const linux = std.os.linux;
const bt = @import("btunnel");

// Pre-ARMv6 targets (e.g. armv5te) lack hardware atomics, so the standard
// library's threaded primitives leave undefined `__sync_*` references. BTunnel
// is single-threaded (iron law #3), so a plain in-house shim resolves them
// safely. Only linked in for arm CPUs without the v6 feature.
const builtin = @import("builtin");
comptime {
    if (builtin.cpu.arch == .arm and
        !std.Target.arm.featureSetHas(builtin.cpu.features, .has_v6))
    {
        _ = @import("atomic_shim.zig");
    }
}

const CONFIG_PATH = "config.json";
const CONFIG_MAX = 64 * 1024;
const DEFAULT_TUN = "btun0";

/// Read and parse config.json with raw syscalls (consistent with the rest of
/// the data path). A missing file falls back to the compile-time default;
/// malformed JSON or an unreadable file is propagated so startup aborts.
fn loadConfig(allocator: std.mem.Allocator) !bt.config.Config {
    const orc = linux.open(CONFIG_PATH, .{ .ACCMODE = .RDONLY }, 0);
    switch (linux.errno(orc)) {
        .SUCCESS => {},
        .NOENT => return bt.config.Config.default(),
        else => return error.ConfigOpenFailed,
    }
    const fd: i32 = @intCast(orc);
    defer _ = linux.close(fd);

    var buf: [CONFIG_MAX]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const rc = linux.read(fd, buf[total..].ptr, buf.len - total);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ConfigReadFailed,
        }
        if (rc == 0) break;
        total += rc;
    }
    return bt.config.Config.fromJson(allocator, buf[0..total]);
}

/// Open and bind a non-blocking IPv4 UDP socket on 0.0.0.0:`port`.
fn openUdp(port: u16) !linux.fd_t {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.UdpSocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // 0.0.0.0
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        return error.UdpBindFailed;
    }
    return fd;
}

fn hasFlag(args: std.process.Args, flag: []const u8) bool {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const cfg = loadConfig(std.heap.page_allocator) catch |err| {
        std.debug.print("config load failed: {s}\n", .{@errorName(err)});
        return err;
    };
    cfg.validate(&.{}) catch |err| {
        std.debug.print("config sanity check failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // Sample this daemon's boot epoch once (issue #14): binds every transmit
    // session to this lifetime so the nonce space is fresh after a restart. A
    // failed/implausible clock is fatal (fail-closed).
    const boot_epoch = bt.peer.bootEpoch() catch |err| {
        std.debug.print("boot epoch unavailable (clock not set?): {s}\n", .{@errorName(err)});
        return err;
    };

    // Build the peer registry so any malformed mesh configuration aborts startup
    // (issue #5). Pointers into the registry are stable for its lifetime.
    var registry = bt.peer.PeerRegistry.fromConfig(cfg, boot_epoch) catch |err| {
        std.debug.print("peer registry build failed: {s}\n", .{@errorName(err)});
        return err;
    };

    if (hasFlag(init.args, "--check")) {
        std.debug.print(
            "btunnel v0.1.0 (mtu={d}, udp_port={d}, mode={s}, local_id={d}, peers={d}) [config ok]\n",
            .{ cfg.local_tun_mtu, cfg.listen_port, @tagName(bt.reactor.EgressMode.raw_direct), cfg.local_id, registry.len },
        );
        return;
    }

    const sock_path: []const u8 = if (std.process.Environ.getPosix(init.environ, "BTUNNEL_SOCK")) |s|
        s
    else
        bt.uds.SOCKET_PATH;
    const tun_name: []const u8 = if (std.process.Environ.getPosix(init.environ, "BTUNNEL_TUN")) |s|
        s
    else
        DEFAULT_TUN;

    // Snapshot path for `ptctl save`: derive `<sock>.policy` so coexisting
    // daemons (shared mount ns) never collide on the snapshot file.
    var save_buf: [108]u8 = undefined;
    const suffix = ".policy";
    if (sock_path.len + suffix.len > save_buf.len) {
        std.debug.print("control socket path too long: {s}\n", .{sock_path});
        return error.PathTooLong;
    }
    @memcpy(save_buf[0..sock_path.len], sock_path);
    @memcpy(save_buf[sock_path.len..][0..suffix.len], suffix);
    const save_path = save_buf[0 .. sock_path.len + suffix.len];

    // Open the TUN device. The netdev exists only while this fd is held.
    var tun = bt.tun.TunDevice.open(tun_name) catch |err| {
        std.debug.print("tun open failed ({s}); need CAP_NET_ADMIN and /dev/net/tun\n", .{@errorName(err)});
        return err;
    };
    defer tun.close();

    const udp_fd = openUdp(cfg.listen_port) catch |err| {
        std.debug.print("udp bind failed ({s}) on port {d}\n", .{ @errorName(err), cfg.listen_port });
        return err;
    };
    defer _ = linux.close(udp_fd);

    // The policy tree starts empty; operators install rules at runtime via
    // ptctl. The Control owns the double-buffered tree and publishes it here.
    var empty = bt.policy.PolicyTree{ .entries = &.{} };
    var active = bt.policy.ActiveTree.init(&empty);
    var control: bt.uds.Control = undefined;
    control.bindInPlace(sock_path, save_path, &active, &.{}) catch |err| {
        std.debug.print("control socket bind failed ({s}) at {s}\n", .{ @errorName(err), sock_path });
        return err;
    };
    defer control.deinit();

    std.debug.print(
        "btunnel v0.1.0 (mtu={d}, udp_port={d}, mode={s}, local_id={d}, peers={d}) tun={s} sock={s} [ready]\n",
        .{ cfg.local_tun_mtu, cfg.listen_port, @tagName(bt.reactor.EgressMode.raw_direct), cfg.local_id, registry.len, tun.ifname(), sock_path },
    );

    var reactor = bt.reactor.Reactor.init(tun.fd, udp_fd, &control, &active, &registry);
    reactor.run() catch |err| {
        std.debug.print("reactor exited: {s}\n", .{@errorName(err)});
        return err;
    };
}

test "daemon module wiring" {
    _ = bt.reactor;
    _ = bt.config;
}

