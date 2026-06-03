//! btunnel daemon entry point.
//!
//! Load config (config.json or the comptime default) -> sanity check ->
//! (pending Tasks 5/7) open TUN, bind UDP/UDS, start the single-threaded epoll
//! reactor.

const std = @import("std");
const linux = std.os.linux;
const bt = @import("btunnel");

const CONFIG_PATH = "config.json";
const CONFIG_MAX = 64 * 1024;

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

pub fn main() !void {
    const cfg = loadConfig(std.heap.page_allocator) catch |err| {
        std.debug.print("config load failed: {s}\n", .{@errorName(err)});
        return err;
    };
    cfg.validate(&.{}) catch |err| {
        std.debug.print("config sanity check failed: {s}\n", .{@errorName(err)});
        return err;
    };

    // Build the peer registry so any malformed mesh configuration aborts startup
    // (issue #5). The registry is unused until the reactor is wired (issue #7).
    const registry = bt.peer.PeerRegistry.fromConfig(cfg) catch |err| {
        std.debug.print("peer registry build failed: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print(
        "btunnel v0.1.0 (mtu={d}, udp_port={d}, mode={s}, local_id={d}, peers={d})\n",
        .{ cfg.local_tun_mtu, cfg.listen_port, @tagName(bt.reactor.EgressMode.raw_direct), cfg.local_id, registry.len },
    );
    std.debug.print("scaffold: reactor not yet wired (see task 7)\n", .{});
}

test "daemon module wiring" {
    _ = bt.reactor;
    _ = bt.config;
}
