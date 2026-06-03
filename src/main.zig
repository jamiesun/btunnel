//! btunnel 守护进程入口。
//!
//! 脚手架：加载配置 → 自检 → （待任务 4/6/7）打开 TUN、绑定 UDP/UDS、
//! 启动单线程 epoll 反应堆。

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
