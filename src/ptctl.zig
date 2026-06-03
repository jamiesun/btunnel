//! Task 8: ptctl control tool entry point.
//!
//! Packs terminal command-line arguments into a text stream and ships it to the
//! daemon over the UDS. Scaffold: argument concatenation + local tokenizer
//! validation are done; UDS delivery is pending Task 8.

const std = @import("std");
const bt = @import("btunnel");

pub fn main(init: std.process.Init.Minimal) !void {
    var buf: [512]u8 = undefined;
    var len: usize = 0;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // skip argv[0]
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
        std.debug.print("ptctl: failed to parse command ({s})\n", .{@errorName(err)});
        std.debug.print("usage: ptctl policy add --src X --dst Y --action forward --target Z\n", .{});
        std.debug.print("       ptctl policy show | ptctl save\n", .{});
        std.process.exit(2);
    };

    std.debug.print("ptctl: command validated -> {s}\n", .{@tagName(cmd)});
    // TODO(Task 8): connect AF_UNIX to SOCKET_PATH, write(line).
    std.debug.print("scaffold: UDS delivery not implemented (see Task 8)\n", .{});
}

test "ptctl module wiring" {
    _ = bt.uds;
}
