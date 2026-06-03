//! btunnel daemon entry point.
//!
//! Scaffold: load config -> sanity check -> (pending Tasks 4/6/7) open TUN, bind
//! UDP/UDS, start the single-threaded epoll reactor.

const std = @import("std");
const bt = @import("btunnel");

pub fn main() !void {
    const cfg = bt.config.Config.default();
    cfg.validate(&.{}) catch |err| {
        std.debug.print("config sanity check failed: {s}\n", .{@errorName(err)});
        return err;
    };

    std.debug.print(
        "btunnel v0.1.0 (mtu={d}, udp_port={d}, mode={s})\n",
        .{ cfg.local_tun_mtu, cfg.listen_port, @tagName(bt.reactor.EgressMode.raw_direct) },
    );
    std.debug.print("scaffold: reactor not yet wired (see tasks 4/6/7)\n", .{});
}

test "daemon module wiring" {
    _ = bt.reactor;
    _ = bt.config;
}
