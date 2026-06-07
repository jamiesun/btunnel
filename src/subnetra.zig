//! subnetra control tool entry point.
//!
//! Packs terminal command-line arguments into a text command line and ships it
//! to the daemon over the control UDS. `policy add` is fire-and-forget; `policy
//! show` and `save` wait for the daemon's reply and print it to stdout. A
//! missing daemon (or a request timeout) exits non-zero so scripts can detect it.

const std = @import("std");
const bt = @import("subnetra");
const linux = std.os.linux;
const build_options = @import("build_options");

// See main.zig: pre-ARMv6 atomics shim for the single-threaded build.
const builtin = @import("builtin");
comptime {
    if (builtin.cpu.arch == .arm and
        !std.Target.arm.featureSetHas(builtin.cpu.features, .has_v6))
    {
        _ = @import("atomic_shim.zig");
    }
}

const REQUEST_TIMEOUT_MS: i32 = 2000;

fn writeStdout(bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(1, bytes[off..].ptr, bytes.len - off);
        if (linux.errno(rc) != .SUCCESS) return;
        if (rc == 0) return;
        off += rc;
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var buf: [512]u8 = undefined;
    var len: usize = 0;

    // Version/help short-circuit before building a control command (these need no
    // running daemon).
    {
        var pre = std.process.Args.Iterator.init(init.args);
        _ = pre.skip();
        while (pre.next()) |arg| {
            if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                std.debug.print("subnetra v{s}\n", .{build_options.version});
                return;
            }
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                std.debug.print(
                    \\subnetra — Subnetra control client
                    \\
                    \\Usage:
                    \\  subnetra status [--json]            Show daemon status (health, peers, counters).
                    \\                                      --json emits a stable, versioned schema for monitoring.
                    \\  subnetra policy show                Print the active policy tree.
                    \\  subnetra policy add --src X --dst Y --action forward --target Z
                    \\  subnetra save                       Snapshot the active policy to disk.
                    \\  subnetra --version | --help
                    \\
                    \\Environment:
                    \\  SUBNETRA_SOCK  Control socket path (default /var/run/subnetra.sock).
                    \\
                , .{});
                return;
            }
        }
    }

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // skip argv[0]
    var first = true;
    while (it.next()) |arg| {
        const sep: usize = if (first) 0 else 1;
        // Reject overflow rather than silently truncating into a different command.
        if (len + sep + arg.len > buf.len) {
            std.debug.print("subnetra: command line too long (max {d} bytes)\n", .{buf.len});
            std.process.exit(2);
        }
        if (!first) {
            buf[len] = ' ';
            len += 1;
        }
        first = false;
        @memcpy(buf[len..][0..arg.len], arg);
        len += arg.len;
    }

    const line = buf[0..len];
    const cmd = bt.uds.parseCommand(line) catch |err| {
        std.debug.print("subnetra: failed to parse command ({s})\n", .{@errorName(err)});
        std.debug.print("usage: subnetra policy add --src X --dst Y --action forward --target Z\n", .{});
        std.debug.print("       subnetra policy show | subnetra status | subnetra save\n", .{});
        std.process.exit(2);
    };

    const path: []const u8 = if (std.process.Environ.getPosix(init.environ, "SUBNETRA_SOCK")) |s|
        s
    else
        bt.uds.SOCKET_PATH;
    switch (cmd) {
        .policy_add => {
            bt.uds.send(path, line) catch |err| failRequest(err, path);
        },
        .policy_show, .save, .status, .status_json => {
            var out: [bt.uds.MAX_REPLY]u8 = undefined;
            const reply = bt.uds.request(path, line, &out, REQUEST_TIMEOUT_MS) catch |err| failRequest(err, path);
            writeStdout(reply);
        },
    }
}

fn failRequest(err: bt.uds.ClientError, path: []const u8) noreturn {
    switch (err) {
        error.DaemonUnavailable => std.debug.print("subnetra: daemon not running (socket {s})\n", .{path}),
        error.NoResponse => std.debug.print("subnetra: no response from daemon (timed out)\n", .{}),
        else => std.debug.print("subnetra: control request failed ({s})\n", .{@errorName(err)}),
    }
    std.process.exit(1);
}

test "subnetra module wiring" {
    _ = bt.uds;
}
