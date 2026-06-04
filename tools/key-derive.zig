//! key-derive — print the reference link/session keys for a given input (issue #64).
//!
//! Reuses the LIVE key schedule (`crypto.deriveLinkKey` then
//! `crypto.deriveSessionKey`, keyed Blake2b-256) so its output is by definition
//! the reference an interoperating implementation must match (see
//! `docs/PROTOCOL.md` and the golden in `tests/protocol-vectors.json`). It does
//! no encryption and no wire framing — for that, see wire-decode (#60).
//!
//! Local diagnostic: it requires the PSK and prints DERIVED keys, so treat its
//! output as secret. NOT part of the shipped daemon.

const std = @import("std");
const bt = @import("btunnel");
const build_options = @import("build_options");

const crypto = bt.crypto;

const USAGE =
    \\Usage: key-derive --psk <64hex> --from <id> --to <id> [--epoch <ns>]
    \\
    \\Print the directional link key for (from -> to), and — if --epoch is given —
    \\the per-session key for that boot epoch. Uses btunnel's own key schedule.
    \\
    \\  --psk   <64hex>  the link pre-shared key
    \\  --from  <id>     sender mesh id
    \\  --to    <id>     receiver mesh id
    \\  --epoch <ns>     boot epoch (wall-clock ns); adds session_key output
    \\  -h, --help       show this help
    \\  -V, --version    show version
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
        const v = std.fmt.bufPrint(&vbuf, "key-derive (btunnel v{s})\n", .{build_options.version}) catch return;
        writeOut(io, v);
        return;
    }

    const psk_hex = flagValue(args, "--psk") orelse {
        writeErr(io, "key-derive: --psk <64hex> is required\n");
        return error.InvalidArgument;
    };
    const from_raw = flagValue(args, "--from") orelse {
        writeErr(io, "key-derive: --from <id> is required\n");
        return error.InvalidArgument;
    };
    const to_raw = flagValue(args, "--to") orelse {
        writeErr(io, "key-derive: --to <id> is required\n");
        return error.InvalidArgument;
    };

    if (psk_hex.len != 64) {
        writeErr(io, "key-derive: --psk must be 64 hex chars\n");
        return error.InvalidArgument;
    }
    var psk: crypto.Key = undefined;
    _ = std.fmt.hexToBytes(&psk, psk_hex) catch {
        writeErr(io, "key-derive: --psk is not valid hex\n");
        return error.InvalidArgument;
    };
    const from_id = std.fmt.parseInt(u32, from_raw, 10) catch {
        writeErr(io, "key-derive: --from must be an integer\n");
        return error.InvalidArgument;
    };
    const to_id = std.fmt.parseInt(u32, to_raw, 10) catch {
        writeErr(io, "key-derive: --to must be an integer\n");
        return error.InvalidArgument;
    };

    const link_key = crypto.deriveLinkKey(psk, from_id, to_id);
    var lbuf: [80]u8 = undefined;
    const lmsg = std.fmt.bufPrint(&lbuf, "link_key = {s}\n", .{std.fmt.bytesToHex(link_key, .lower)}) catch return;
    writeOut(io, lmsg);

    if (flagValue(args, "--epoch")) |epoch_raw| {
        const epoch = std.fmt.parseInt(u64, epoch_raw, 10) catch {
            writeErr(io, "key-derive: --epoch must be an integer\n");
            return error.InvalidArgument;
        };
        const session_key = crypto.deriveSessionKey(link_key, epoch);
        var sbuf: [80]u8 = undefined;
        const smsg = std.fmt.bufPrint(&sbuf, "session_key = {s}\n", .{std.fmt.bytesToHex(session_key, .lower)}) catch return;
        writeOut(io, smsg);
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

test "derives the golden v1-basic-link-1-to-2 link and session keys" {
    // Known answers from tests/protocol-vectors.json (vector v1-basic-link-1-to-2).
    var psk: crypto.Key = undefined;
    _ = try std.fmt.hexToBytes(&psk, "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a");
    const epoch: u64 = 1704067200000000000;

    const link_key = crypto.deriveLinkKey(psk, 1, 2);
    try std.testing.expectEqualStrings(
        "6b9b5d6f603359710fddd04e10ac772bd0e33aedab75b236d871ec936bea522a",
        &std.fmt.bytesToHex(link_key, .lower),
    );

    const session_key = crypto.deriveSessionKey(link_key, epoch);
    try std.testing.expectEqualStrings(
        "0f0404b8e2405e37a3504e51bcf70f912b81f92fba5d99581510cf52950c871e",
        &std.fmt.bytesToHex(session_key, .lower),
    );
}
