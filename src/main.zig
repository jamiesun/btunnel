//! subnetrad daemon entry point.
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
//!   SUBNETRA_SOCK  control socket path (default uds.SOCKET_PATH)
//!   SUBNETRA_TUN   TUN interface name  (default "snr0")

const std = @import("std");
const linux = std.os.linux;
const bt = @import("subnetra");
const sys = bt.sys;
const build_options = @import("build_options");

// Pre-ARMv6 targets (e.g. armv5te) lack hardware atomics, so the standard
// library's threaded primitives leave undefined `__sync_*` references. Subnetra
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
const DEFAULT_TUN = "snr0";

const USAGE =
    \\subnetrad — stateless L3 UDP tunnel daemon
    \\
    \\Usage: subnetrad [OPTIONS]
    \\
    \\Options:
    \\  --config PATH         Path to the JSON config (default: ./config.json).
    \\  --check               Validate the config + peer registry and exit.
    \\  --print-network-plan  Print the host ip(8) commands for this config and exit.
    \\  --path-mtu N          Path MTU used by --print-network-plan (default 1420).
    \\  -h, --help            Show this help and exit.
    \\  -V, --version         Show the version and exit.
    \\
    \\Environment:
    \\  SUBNETRA_CONFIG  Config path (overridden by --config).
    \\  SUBNETRA_SOCK    Control socket path (default /var/run/subnetra.sock).
    \\  SUBNETRA_TUN     TUN interface name (default snr0).
    \\
    \\The daemon never mutates host networking; use --print-network-plan to emit
    \\the commands to run, and `subnetra status` to inspect a running daemon.
    \\
;

/// Flags that consume the following argv token as their value.
const VALUE_FLAGS = [_][]const u8{ "--config", "--path-mtu" };
/// Standalone boolean flags.
const BOOL_FLAGS = [_][]const u8{ "--check", "--print-network-plan", "--help", "-h", "--version", "-V" };

/// Fail fast on an unrecognized argument so a typo like `--chek` aborts instead
/// of silently starting the daemon with the mistyped flag ignored. No positional
/// arguments are accepted.
fn validateArgs(args: std.process.Args) !void {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    outer: while (it.next()) |a| {
        for (VALUE_FLAGS) |f| {
            if (std.mem.eql(u8, a, f)) {
                _ = it.next(); // consume the value token
                continue :outer;
            }
        }
        for (BOOL_FLAGS) |f| {
            if (std.mem.eql(u8, a, f)) continue :outer;
        }
        std.debug.print("unknown argument: {s}\n\n{s}", .{ a, USAGE });
        return error.UnknownArgument;
    }
}

/// Resolve the config path from --config, then SUBNETRA_CONFIG, then the default.
/// Returns a NUL-terminated slice usable directly with the open(2) syscall and
/// whether it was given explicitly (so a missing explicit path fails loudly
/// instead of silently falling back to the compile-time default).
fn resolveConfigPath(args: std.process.Args, environ: anytype, buf: []u8) !struct { path: [:0]const u8, explicit: bool } {
    var explicit = true;
    const p: []const u8 = if (flagValue(args, "--config")) |v|
        v
    else if (std.process.Environ.getPosix(environ, "SUBNETRA_CONFIG")) |s|
        s
    else blk: {
        explicit = false;
        break :blk CONFIG_PATH;
    };
    if (p.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return .{ .path = buf[0..p.len :0], .explicit = explicit };
}

/// Read and parse the config at `path` with portable `std.posix` syscalls
/// (`std.os.linux.*` emits raw Linux syscall numbers that mis-dispatch on XNU —
/// issue #73). A missing DEFAULT file falls back to the compile-time default; a
/// missing EXPLICIT path (--config/SUBNETRA_CONFIG) is an error so a typo'd path
/// never silently runs on built-in defaults. Malformed JSON or an unreadable file
/// is propagated so startup aborts.
fn loadConfig(allocator: std.mem.Allocator, path: [:0]const u8, explicit: bool) !bt.config.Config {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch |err| switch (err) {
        error.FileNotFound => return if (explicit) error.ConfigNotFound else bt.config.Config.default(),
        else => return error.ConfigOpenFailed,
    };
    defer _ = std.posix.system.close(fd);

    var buf: [CONFIG_MAX]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(fd, buf[total..]) catch return error.ConfigReadFailed;
        if (n == 0) break;
        total += n;
    }
    return bt.config.Config.fromJson(allocator, buf[0..total]);
}

/// Open and bind a non-blocking IPv4 UDP socket on 0.0.0.0:`port`.
fn openUdp(port: u16) !sys.fd_t {
    const fd = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, true, true) catch return error.UdpSocketFailed;
    errdefer _ = sys.close(fd);

    var addr = sys.sockaddr.in{
        .family = sys.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // 0.0.0.0
    };
    if (sys.errno(sys.bind(fd, @ptrCast(&addr), @sizeOf(sys.sockaddr.in))) != .SUCCESS) {
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

/// Return the value following `flag` in argv (e.g. `--path-mtu 1400`), or null
/// if the flag is absent or has no following token.
fn flagValue(args: std.process.Args, flag: []const u8) ?[]const u8 {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return it.next();
    }
    return null;
}

fn envTunName(environ: anytype) []const u8 {
    return if (std.process.Environ.getPosix(environ, "SUBNETRA_TUN")) |s| s else DEFAULT_TUN;
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Help/version short-circuit BEFORE loading config so they work on a box with
    // no config.json present (operator convenience).
    if (hasFlag(init.args, "--help") or hasFlag(init.args, "-h")) {
        std.debug.print("{s}", .{USAGE});
        return;
    }
    if (hasFlag(init.args, "--version") or hasFlag(init.args, "-V")) {
        std.debug.print("subnetra v{s}\n", .{build_options.version});
        return;
    }
    validateArgs(init.args) catch |err| return err;

    var cfg_path_buf: [4096]u8 = undefined;
    const resolved = resolveConfigPath(init.args, init.environ, &cfg_path_buf) catch |err| {
        std.debug.print("config path invalid: {s}\n", .{@errorName(err)});
        return err;
    };
    const cfg = loadConfig(std.heap.page_allocator, resolved.path, resolved.explicit) catch |err| {
        std.debug.print("config load failed ({s}): {s}\n", .{ resolved.path, @errorName(err) });
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
            "subnetra v{s} (mtu={d}, udp_port={d}, mode={s}, local_id={d}, peers={d}) [config ok]\n",
            .{ build_options.version, cfg.local_tun_mtu, cfg.listen_port, @tagName(bt.reactor.EgressMode.raw_direct), cfg.local_id, registry.len },
        );
        return;
    }

    // `--print-network-plan` (issue #23): emit the host networking commands for
    // this config and exit. Print-only — the daemon never mutates host state.
    if (hasFlag(init.args, "--print-network-plan")) {
        const path_mtu: u16 = if (flagValue(init.args, "--path-mtu")) |v|
            std.fmt.parseInt(u16, v, 10) catch {
                std.debug.print("invalid --path-mtu value: {s}\n", .{v});
                return error.InvalidArgument;
            }
        else
            bt.netplan.DEFAULT_PATH_MTU;
        var plan_buf: [8192]u8 = undefined;
        const plan = bt.netplan.render(&plan_buf, cfg, envTunName(init.environ), path_mtu) catch |err| {
            std.debug.print("network plan render failed: {s}\n", .{@errorName(err)});
            return err;
        };
        std.debug.print("{s}", .{plan});
        return;
    }

    const sock_path: []const u8 = if (std.process.Environ.getPosix(init.environ, "SUBNETRA_SOCK")) |s|
        s
    else
        bt.uds.SOCKET_PATH;
    const tun_name: []const u8 = envTunName(init.environ);

    // Snapshot path for `subnetra save`: derive `<sock>.policy` so coexisting
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
    var tun = bt.os.TunDevice.open(tun_name) catch |err| {
        std.debug.print("tun open failed ({s}); need CAP_NET_ADMIN and /dev/net/tun\n", .{@errorName(err)});
        return err;
    };
    defer tun.close();

    const udp_fd = openUdp(cfg.listen_port) catch |err| {
        std.debug.print("udp bind failed ({s}) on port {d}\n", .{ @errorName(err), cfg.listen_port });
        return err;
    };
    defer _ = sys.close(udp_fd);

    // Data-plane counters (issue #24): shared by reference between the reactor
    // (writer) and the control plane (reader for `subnetra status`). Single-threaded
    // reactor, so plain increments are race-free.
    var counters = bt.stats.Counters{};

    // The policy tree's bootstrap depends on `role` (issue #21): `manual` starts
    // empty (operators install rules via subnetra), `hub`/`spoke` auto-derive the
    // initial forwarding/delivery rules from the config. Derived AFTER the peer
    // registry so every target id is known-valid. The buffer must outlive the
    // bindInPlace call (which copies it into the Control's double buffer).
    var initial_buf: [bt.config.MAX_PEERS + bt.config.MAX_ROUTES * 2]bt.policy.PolicyEntry = undefined;
    const initial_policy = bt.policy.deriveInitialPolicy(cfg, &initial_buf) catch |err| {
        std.debug.print("initial policy derivation failed: {s}\n", .{@errorName(err)});
        return err;
    };
    var empty = bt.policy.PolicyTree{ .entries = &.{} };
    var active = bt.policy.ActiveTree.init(&empty);
    var control: bt.uds.Control = undefined;
    control.bindInPlace(sock_path, save_path, &active, initial_policy) catch |err| {
        std.debug.print("control socket bind failed ({s}) at {s}\n", .{ @errorName(err), sock_path });
        return err;
    };
    defer control.deinit();
    control.bindStatus(.{
        .version = build_options.version,
        .mode = @tagName(bt.reactor.EgressMode.raw_direct),
        .listen_port = cfg.listen_port,
        .tun_name = tun.ifname(),
        .local_id = cfg.local_id,
    }, &registry, &counters);

    std.debug.print(
        "subnetra v{s} (mtu={d}, udp_port={d}, mode={s}, local_id={d}, peers={d}) tun={s} sock={s} [ready]\n",
        .{ build_options.version, cfg.local_tun_mtu, cfg.listen_port, @tagName(bt.reactor.EgressMode.raw_direct), cfg.local_id, registry.len, tun.ifname(), sock_path },
    );

    var reactor = bt.reactor.Reactor.init(tun.fd, udp_fd, &control, &active, &registry);
    reactor.counters = &counters;

    // Privileged setup is complete: the TUN device and all sockets are open and
    // will not be reopened. The reactor only does read/write/recv/send/epoll on
    // these held fds plus pure-userspace policy swaps, so it needs no further
    // privilege. Drop all capabilities now to shrink the blast radius if the
    // data path is ever compromised (issue #38). Fail closed when we started
    // privileged but could not drop.
    dropCapabilities() catch |err| {
        std.debug.print("capability drop failed: {s}\n", .{@errorName(err)});
        return err;
    };

    reactor.run() catch |err| {
        std.debug.print("reactor exited: {s}\n", .{@errorName(err)});
        return err;
    };
}

/// `_LINUX_CAPABILITY_VERSION_3`: the 64-bit capability ABI (two u32 words).
const CAP_VERSION_3: u32 = 0x20080522;

/// Authoritative highest valid capability number, read from the kernel. Falls
/// back to a generous bound if `/proc` is unreadable; dropping a nonexistent
/// capability from the bounding set is a harmless `EINVAL`.
fn capLastCap() usize {
    const fallback: usize = 63;
    const rc = linux.open("/proc/sys/kernel/cap_last_cap", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return fallback;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [32]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return fallback;
    const s = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    return std.fmt.parseInt(usize, s, 10) catch fallback;
}

/// Drop every capability after the privileged setup phase. Three layers:
///   1. `PR_SET_NO_NEW_PRIVS` — bars regaining privilege through execve.
///   2. Empty the bounding set up to `cap_last_cap` (needs CAP_SETPCAP, so done
///      *before* the effective set is cleared) so caps can never be reacquired.
///   3. `capset` clears the effective/permitted/inheritable sets for the thread.
/// Fail closed: if we currently HOLD capabilities (started privileged) and the
/// `capset` clear fails, return an error so startup aborts rather than silently
/// running privileged. When already unprivileged (e.g. an unprivileged user
/// namespace) there is nothing to drop and a `capset` refusal is tolerated.
fn dropCapabilities() !void {
    // Linux capability/prctl model only. macOS uses a different privilege model
    // (the spoke runs with the privileges needed for utun; see the macOS
    // acceptance runbook), so there is nothing to drop here — fail open.
    if (builtin.os.tag != .linux) return;

    _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);

    const last = capLastCap();
    var cap: usize = 0;
    while (cap <= last) : (cap += 1) {
        _ = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), cap, 0, 0, 0);
    }

    var hdr = linux.cap_user_header_t{ .version = CAP_VERSION_3, .pid = 0 };
    var cur = [_]linux.cap_user_data_t{.{ .effective = 0, .permitted = 0, .inheritable = 0 }} ** 2;
    const had_caps = blk: {
        if (linux.errno(linux.capget(&hdr, &cur[0])) != .SUCCESS) break :blk false;
        break :blk (cur[0].permitted | cur[0].effective | cur[1].permitted | cur[1].effective) != 0;
    };

    var data = [_]linux.cap_user_data_t{.{ .effective = 0, .permitted = 0, .inheritable = 0 }} ** 2;
    if (linux.errno(linux.capset(&hdr, &data[0])) != .SUCCESS) {
        if (had_caps) return error.CapDropFailed;
        // Already unprivileged: nothing meaningful to drop.
    }
}

test "daemon module wiring" {
    _ = bt.reactor;
    _ = bt.config;
}

