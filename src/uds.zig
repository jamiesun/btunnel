//! Task 7: Control-plane Unix domain socket.
//!
//! The daemon listens on /var/run/btunnel.sock, receives plaintext token
//! commands from ptctl, tokenizes them, rebuilds the policy tree in an arena,
//! then calls policy's atomic swap interface (lock-free injection). Scaffold:
//! the tokenizer is implemented and testable; the listener is a skeleton pending
//! Task 7.

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");

pub const SOCKET_PATH = "/var/run/btunnel.sock";

pub const ParseError = error{
    UnknownCommand,
    MissingArgument,
    InvalidValue,
};

/// Control command.
pub const Command = union(enum) {
    policy_add: policy.PolicyEntry,
    policy_show,
    save,
};

fn nextValue(it: *std.mem.TokenIterator(u8, .scalar)) ParseError![]const u8 {
    return it.next() orelse ParseError.MissingArgument;
}

/// Tokenize a line of plaintext command into a Command.
/// e.g. `policy add --src 192.168.1.0/24 --dst 192.168.2.0/24 --action forward --target 3`
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

/// Daemon listener skeleton.
pub const Listener = struct {
    fd: std.posix.fd_t,

    /// TODO(Task 7): bind/listen on AF_UNIX, accept, read commands, hot-swap the
    /// policy tree.
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

test "parseCommand: show / save / errors" {
    try std.testing.expect(try parseCommand("policy show") == .policy_show);
    try std.testing.expect(try parseCommand("save") == .save);
    try std.testing.expectError(ParseError.UnknownCommand, parseCommand("bogus"));
    try std.testing.expectError(ParseError.MissingArgument, parseCommand("policy add --src 10.0.0.0/24"));
}
