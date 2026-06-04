//! keygen — offline pre-shared-key generator (issue #58).
//!
//! Draws 32 bytes from the OS CSPRNG (`io.randomSecure`, i.e. getrandom/arc4random
//! on the host) and prints them as a 64-char lowercase hex string — the exact
//! format `peers[].psk` in config.json expects (issue #13). One key per line;
//! `--count N` emits several keys for an N-peer mesh. The tool is offline and
//! side-effect-free: it only writes to stdout, never touches config or the
//! network, and is NOT part of the shipped daemon (built via
//! `zig build tool:keygen`, never installed by default).
//!
//! It fails closed: if no secure entropy source is available it aborts rather
//! than emitting key material drawn from a weaker source.

const std = @import("std");
const build_options = @import("build_options");

const KEY_LEN = 32;

const USAGE =
    \\Usage: keygen [--count N]
    \\
    \\Generate cryptographically-random 32-byte pre-shared keys, printed as
    \\64-char lowercase hex (one per line) for use as a config.json peers[].psk.
    \\
    \\  --count N      emit N keys (default 1)
    \\  -h, --help     show this help
    \\  -V, --version  show version
    \\
;

fn writeOut(io: std.Io, bytes: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, bytes) catch {};
}

fn writeErr(io: std.Io, bytes: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, bytes) catch {};
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = init.minimal.args;

    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        writeOut(io, USAGE);
        return;
    }
    if (hasFlag(args, "--version") or hasFlag(args, "-V")) {
        var vbuf: [80]u8 = undefined;
        const v = std.fmt.bufPrint(&vbuf, "keygen (btunnel v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    var count: usize = 1;
    if (flagValue(args, "--count")) |raw| {
        count = std.fmt.parseInt(usize, raw, 10) catch {
            writeErr(io, "keygen: invalid --count value\n");
            return error.InvalidArgument;
        };
        if (count == 0) {
            writeErr(io, "keygen: --count must be >= 1\n");
            return error.InvalidArgument;
        }
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key: [KEY_LEN]u8 = undefined;
        // Fail closed: never emit a key from a non-secure source.
        io.randomSecure(&key) catch {
            writeErr(io, "keygen: secure entropy source unavailable\n");
            return error.EntropyUnavailable;
        };
        const hex = std.fmt.bytesToHex(key, .lower); // [KEY_LEN*2]u8
        var line: [KEY_LEN * 2 + 1]u8 = undefined;
        @memcpy(line[0 .. KEY_LEN * 2], &hex);
        line[KEY_LEN * 2] = '\n';
        writeOut(io, &line);
    }
}

fn hasFlag(args: std.process.Args, flag: []const u8) bool {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn flagValue(args: std.process.Args, flag: []const u8) ?[]const u8 {
    var it = args.iterate();
    _ = it.skip(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, flag)) return it.next();
    }
    return null;
}

test "generated key formats to 64 lowercase hex chars and round-trips as a PSK" {
    // Exercise the format/parse path the daemon uses (std.fmt.hexToBytes + a
    // 64-char length gate, see config.fromJson) without touching the OS RNG.
    var key: [KEY_LEN]u8 = undefined;
    for (&key, 0..) |*b, idx| b.* = @intCast(idx);

    const hex = std.fmt.bytesToHex(key, .lower);
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    for (hex) |c| try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));

    var back: [KEY_LEN]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&back, &hex);
    try std.testing.expectEqual(@as(usize, KEY_LEN), decoded.len);
    try std.testing.expectEqualSlices(u8, &key, &back);
}
