//! 任务 8：ptctl 控制工具入口。
//!
//! 将终端命令行参数打包为文本流，通过 UDS 掷给主进程。
//! 脚手架：参数拼接 + 本地分词校验已落地；UDS 投递待任务 8 收尾。

const std = @import("std");
const bt = @import("btunnel");

pub fn main(init: std.process.Init.Minimal) !void {
    var buf: [512]u8 = undefined;
    var len: usize = 0;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // 跳过 argv[0]
    var first = true;
    while (it.next()) |arg| {
        if (!first and len < buf.len) {
            buf[len] = ' ';
            len += 1;
        }
        first = false;
        const n = @min(arg.len, buf.len - len);
        @memcpy(buf[len..][0..n], arg[0..n]);
        len += n;
    }

    const line = buf[0..len];
    const cmd = bt.uds.parseCommand(line) catch |err| {
        std.debug.print("ptctl: 无法解析指令 ({s})\n", .{@errorName(err)});
        std.debug.print("用法: ptctl policy add --src X --dst Y --action forward --target Z\n", .{});
        std.debug.print("      ptctl policy show | ptctl save\n", .{});
        std.process.exit(2);
    };

    std.debug.print("ptctl: 指令已校验 -> {s}\n", .{@tagName(cmd)});
    // TODO(任务 8)：connect AF_UNIX 到 SOCKET_PATH，write(line)。
    std.debug.print("scaffold: UDS 投递未实现 (见任务 8)\n", .{});
}

test "ptctl module wiring" {
    _ = bt.uds;
}
