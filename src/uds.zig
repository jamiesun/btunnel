//! 任务 7：控制面 Unix 域套接字（Control-Plane UDS）
//!
//! 守护进程监听 /var/run/btunnel.sock，接收 ptctl 的明文 Token 指令，
//! 分词后在 arena 中重建策略树，再调用 policy 的原子 swap 接口（无锁注入）。
//! 脚手架：分词器已落地并可测试；监听器骨架待任务 7 落地。

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");

pub const SOCKET_PATH = "/var/run/btunnel.sock";

pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    InvalidValue,
};

/// 控制指令。
pub const Command = union(enum) {
    policy_add: policy.PolicyEntry,
    policy_show,
    save,
};

fn nextValue(it: *std.mem.TokenIterator(u8, .scalar)) ParseError![]const u8 {
    return it.next() orelse ParseError.MissingArgument;
}

/// 将一行明文指令分词为 Command。
/// 例：`policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3`
pub fn parseCommand(line: []const u8) ParseError!Command {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = it.next() orelse return ParseError.UnknownCommand;

    if (std.mem.eql(u8, verb, "save")) return .save;

    if (!std.mem.eql(u8, verb, "policy")) return ParseError.UnknownCommand;

    const sub = it.next() orelse return ParseError.MissingArgument;
    if (std.mem.eql(u8, sub, "show")) return .policy_show;
    if (!std.mem.eql(u8, sub, "add")) return ParseError.UnknownCommand;

    var entry = policy.PolicyEntry{
        .src = undefined,
        .dst = undefined,
        .action = .drop,
    };
    var have_src = false;
    var have_dst = false;

    while (it.next()) |flag| {
        if (std.mem.eql(u8, flag, "--src")) {
            entry.src = policy.parseCidr(try nextValue(&it)) catch return ParseError.InvalidValue;
            have_src = true;
        } else if (std.mem.eql(u8, flag, "--dst")) {
            entry.dst = policy.parseCidr(try nextValue(&it)) catch return ParseError.InvalidValue;
            have_dst = true;
        } else if (std.mem.eql(u8, flag, "--action")) {
            const v = try nextValue(&it);
            entry.action = if (std.mem.eql(u8, v, "forward"))
                .forward
            else if (std.mem.eql(u8, v, "drop"))
                .drop
            else
                return ParseError.InvalidValue;
        } else if (std.mem.eql(u8, flag, "--target")) {
            entry.target = std.fmt.parseInt(u32, try nextValue(&it), 10) catch return ParseError.InvalidValue;
        } else {
            return ParseError.UnknownCommand;
        }
    }

    if (!have_src or !have_dst) return ParseError.MissingArgument;
    return .{ .policy_add = entry };
}

/// 守护进程监听器骨架。
pub const Listener = struct {
    fd: std.posix.fd_t,

    /// TODO(任务 7)：bind/listen AF_UNIX，accept 后读取指令并热替换策略树。
    pub fn listen(path: []const u8) !Listener {
        if (builtin.os.tag != .linux) return error.Unsupported;
        _ = path;
        return error.Unsupported;
    }
};

test "parseCommand: policy add" {
    const cmd = try parseCommand("policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3");
    const e = cmd.policy_add;
    try std.testing.expectEqual(@as(u32, 0xC0A8_0200), e.dst.network);
    try std.testing.expectEqual(policy.Action.forward, e.action);
    try std.testing.expectEqual(@as(u32, 3), e.target);
}

test "parseCommand: show / save / 错误" {
    try std.testing.expect(try parseCommand("policy show") == .policy_show);
    try std.testing.expect(try parseCommand("save") == .save);
    try std.testing.expectError(ParseError.UnknownCommand, parseCommand("bogus"));
    try std.testing.expectError(ParseError.MissingArgument, parseCommand("policy add --src 10.0.0.0/24"));
}
