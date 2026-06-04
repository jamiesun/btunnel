//! BTunnel wire-protocol conformance vectors (KAT — known-answer tests).
//!
//! This module is the executable companion to `docs/PROTOCOL.md`. It emits two
//! suites, both computed *straight from the live protocol code*
//! (`crypto.zig` + `reactor.zig`):
//!
//!   1. `vectors` — the SENDER/encode KAT. For each input tuple it pins the
//!      `link_key`, `session_key`, and the full on-wire `datagram` bytes.
//!   2. `receiver_cases` — the RECEIVER KAT. Each case replays a sequence of
//!      datagrams (some deliberately malformed/tampered/replayed/reordered)
//!      through `reactor.decodeIngress` against a live receive session and pins
//!      the accept/drop decision, the recovered plaintext, and the post-step
//!      session epoch. This is what closes the receiver-side drift blind spot:
//!      a change to any header-validation, epoch-ordering, authentication, or
//!      anti-replay rule moves these outputs.
//!
//! The committed golden file `tests/protocol-vectors.json` is exactly the JSON
//! this module emits (`zig build vectors`). The sentinel in
//! `src/protocol_conformance.zig` pins the golden against the live code, so any
//! silent change to a wire constant, KDF label, byte order, header layout, or
//! accept/drop rule fails `zig build test`.
//!
//! A second implementation (another OS, another language) is conformant iff it
//! reproduces every sender `output` and every receiver step outcome from the
//! matching inputs.

const std = @import("std");
const crypto = @import("crypto.zig");
const reactor = @import("reactor.zig");
const peer = @import("peer.zig");

/// Smallest boot epoch the protocol permits (2024-01-01T00:00:00Z in ns). Every
/// vector epoch is at or above this so the golden never describes a datagram a
/// conformant sender is forbidden to emit (see docs/PROTOCOL.md §2.3).
pub const MIN_EPOCH: u64 = 1_704_067_200 * std.time.ns_per_s;

// ---------------------------------------------------------------------------
// Sender KAT
// ---------------------------------------------------------------------------

/// One sender known-answer vector: deterministic inputs, no randomness.
pub const Vector = struct {
    name: []const u8,
    /// PSK as 64 lowercase hex chars (32 bytes).
    psk_hex: []const u8,
    /// Sender mesh node id (the tx anchor for key derivation).
    from_id: u32,
    /// Receiver mesh node id.
    to_id: u32,
    /// Sender boot epoch (wall-clock ns at startup); MUST be >= MIN_EPOCH.
    epoch: u64,
    /// Monotonic sequence number used for this datagram (doubles as the nonce).
    seq: u64,
    /// Inner plaintext (the tunnelled IP packet) as lowercase hex; may be empty.
    plaintext_hex: []const u8,
};

/// 1452-byte plaintext (the raw_direct inner MTU boundary), so a change to
/// `reactor.MAX_PLAINTEXT` / `mtuFor(.raw_direct)` would move a vector.
const MAX_PLAINTEXT_HEX = blk: {
    @setEvalBranchQuota(20000);
    var buf: [reactor.MAX_PLAINTEXT * 2]u8 = undefined;
    const hexd = "0123456789abcdef";
    var i: usize = 0;
    while (i < reactor.MAX_PLAINTEXT) : (i += 1) {
        const b: u8 = @intCast(i & 0xff);
        buf[i * 2] = hexd[b >> 4];
        buf[i * 2 + 1] = hexd[b & 0x0f];
    }
    const out = buf;
    break :blk &out;
};

/// The canonical sender KAT set. Never reorder or mutate existing entries (it
/// would break the golden); only append new ones.
pub const VECTORS = [_]Vector{
    .{
        .name = "v1-basic-link-1-to-2",
        .psk_hex = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a",
        .from_id = 1,
        .to_id = 2,
        .epoch = MIN_EPOCH,
        .seq = 1,
        // A minimal well-formed IPv4 header (20 bytes): src 10.0.0.2 dst 10.0.0.3.
        .plaintext_hex = "4500001400004000401100000a0000020a000003",
    },
    .{
        .name = "v2-distinct-ids-and-epoch",
        .psk_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        .from_id = 7,
        .to_id = 3,
        .epoch = 1893456000000000000, // 2030-01-01T00:00:00Z in ns
        .seq = 42,
        .plaintext_hex = "deadbeefcafebabe",
    },
    .{
        .name = "v3-high-seq-empty-payload",
        .psk_hex = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        .from_id = 2,
        .to_id = 1,
        .epoch = 1924992000000000000, // 2031-01-01T00:00:00Z in ns
        .seq = 4294967296, // 2^32, exercises the full 64-bit sequence/nonce
        .plaintext_hex = "",
    },
    .{
        .name = "v4-larger-payload",
        .psk_hex = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
        .from_id = 10,
        .to_id = 20,
        .epoch = 1704067200123456789, // MIN_EPOCH + 123456789 ns
        .seq = 2,
        .plaintext_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" ++
            "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
    },
    .{
        .name = "v5-mtu-boundary-1452B-payload",
        .psk_hex = "1111111111111111111111111111111111111111111111111111111111111111",
        .from_id = 4,
        .to_id = 5,
        .epoch = 1735689600000000000, // 2025-01-01T00:00:00Z in ns
        .seq = 7,
        .plaintext_hex = MAX_PLAINTEXT_HEX,
    },
};

// ---------------------------------------------------------------------------
// Hex helpers
// ---------------------------------------------------------------------------

const HEX = "0123456789abcdef";

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.BadHex,
    };
}

/// Decode `hex` into `out`, returning the written slice. Errors on odd length,
/// non-hex bytes, or insufficient space.
pub fn hexDecode(out: []u8, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.BadHex;
    const n = hex.len / 2;
    if (out.len < n) return error.NoSpaceLeft;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = (try hexNibble(hex[i * 2])) << 4 | (try hexNibble(hex[i * 2 + 1]));
    }
    return out[0..n];
}

fn hexEncode(out: []u8, bytes: []const u8) []u8 {
    std.debug.assert(out.len >= bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = HEX[b >> 4];
        out[i * 2 + 1] = HEX[b & 0x0f];
    }
    return out[0 .. bytes.len * 2];
}

// ---------------------------------------------------------------------------
// Sender computation
// ---------------------------------------------------------------------------

/// Build the on-wire datagram for `(link_key, epoch, seq, plaintext)` via the
/// real egress path, writing into `out` and returning its length. The transmit
/// counter is pinned to `seq` so the header is deterministic.
fn buildDatagram(link_key: crypto.Key, epoch: u64, seq: u64, plaintext: []const u8, out: []u8) usize {
    var tx = crypto.TxSession.init(link_key, epoch);
    tx.counter.value = seq;
    return reactor.encodeEgress(&tx, plaintext, out);
}

/// Computed sender outputs for a vector, all as lowercase hex.
pub const Output = struct {
    link_key: [crypto.KEY_LEN * 2]u8,
    session_key: [crypto.KEY_LEN * 2]u8,
    datagram: [reactor.MAX_WIRE * 2]u8,
    datagram_len: usize,
};

/// Map a sender vector to its canonical wire result, directly from live code.
pub fn compute(v: Vector) !Output {
    var psk: crypto.Key = undefined;
    const psk_bytes = try hexDecode(&psk, v.psk_hex);
    if (psk_bytes.len != crypto.KEY_LEN) return error.BadPskLength;

    var plain_buf: [reactor.MAX_PLAINTEXT]u8 = undefined;
    const plaintext = try hexDecode(&plain_buf, v.plaintext_hex);

    const link = crypto.deriveLinkKey(psk, v.from_id, v.to_id);
    const session = crypto.deriveSessionKey(link, v.epoch);

    var wire: [reactor.MAX_WIRE]u8 = undefined;
    const n = buildDatagram(link, v.epoch, v.seq, plaintext, &wire);

    var out: Output = .{
        .link_key = undefined,
        .session_key = undefined,
        .datagram = undefined,
        .datagram_len = n * 2,
    };
    _ = hexEncode(&out.link_key, &link);
    _ = hexEncode(&out.session_key, &session);
    _ = hexEncode(&out.datagram, wire[0..n]);
    return out;
}

// ---------------------------------------------------------------------------
// Receiver KAT
// ---------------------------------------------------------------------------

/// A mutation applied to an otherwise-valid datagram to exercise a receiver
/// drop rule. `none` keeps the datagram valid.
const Mutation = enum {
    none,
    bad_version, // byte 0 := 2
    bad_flags, // byte 1 := 1
    bad_reserved, // byte 2 := 1
    zero_epoch, // epoch field := 0
    truncate_header, // cut to HEADER_LEN-1 bytes
    flip_tag, // flip the last byte (AEAD auth failure)
    flip_body, // flip the first ciphertext byte (AEAD auth failure)
};

/// One step in a receiver case: a (possibly mutated) datagram derived from a
/// base (epoch, seq, plaintext) on the case's link, fed to `decodeIngress`.
const RxStep = struct {
    note: []const u8,
    epoch: u64,
    seq: u64,
    plaintext_hex: []const u8,
    mutation: Mutation = .none,
};

/// A receiver scenario: a fresh-or-preloaded receive session on one link, then
/// an ordered list of steps whose outcomes are pinned by the golden.
const RxCase = struct {
    name: []const u8,
    psk_hex: []const u8,
    from_id: u32,
    to_id: u32,
    /// Preload the receive session to this epoch before step 1 (0 = fresh).
    init_epoch: u64 = 0,
    steps: []const RxStep,
};

const IPV4_A = "4500001400004000401100000a0000020a000003"; // src 10.0.0.2

pub const RX_CASES = [_]RxCase{
    .{
        .name = "accept-then-replay",
        .psk_hex = "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a",
        .from_id = 1,
        .to_id = 2,
        .steps = &.{
            .{ .note = "valid datagram is accepted and adopts its epoch", .epoch = MIN_EPOCH, .seq = 5, .plaintext_hex = IPV4_A },
            .{ .note = "byte-identical replay of the same seq is dropped", .epoch = MIN_EPOCH, .seq = 5, .plaintext_hex = IPV4_A },
            .{ .note = "in-window reorder (lower unseen seq) is accepted", .epoch = MIN_EPOCH, .seq = 3, .plaintext_hex = IPV4_A },
            .{ .note = "replay of the reordered seq is dropped", .epoch = MIN_EPOCH, .seq = 3, .plaintext_hex = IPV4_A },
        },
    },
    .{
        .name = "header-and-auth-rejections",
        .psk_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        .from_id = 7,
        .to_id = 3,
        .steps = &.{
            .{ .note = "wrong version is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .bad_version },
            .{ .note = "non-zero flags is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .bad_flags },
            .{ .note = "non-zero reserved is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .bad_reserved },
            .{ .note = "zero epoch is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .zero_epoch },
            .{ .note = "datagram shorter than the header is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .truncate_header },
            .{ .note = "tampered tag fails authentication and is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .flip_tag },
            .{ .note = "tampered ciphertext fails authentication and is dropped", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A, .mutation = .flip_body },
            .{ .note = "after all drops a clean datagram is still accepted (state uncorrupted)", .epoch = MIN_EPOCH, .seq = 1, .plaintext_hex = IPV4_A },
        },
    },
    .{
        .name = "forward-only-epoch-ordering",
        .psk_hex = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
        .from_id = 10,
        .to_id = 20,
        .steps = &.{
            .{ .note = "first epoch E1 accepted", .epoch = MIN_EPOCH + 1000, .seq = 1, .plaintext_hex = IPV4_A },
            .{ .note = "strictly older epoch E0 < E1 dropped before crypto", .epoch = MIN_EPOCH + 500, .seq = 1, .plaintext_hex = IPV4_A },
            .{ .note = "newer epoch E2 > E1 accepted; window reset lets seq 1 through again", .epoch = MIN_EPOCH + 2000, .seq = 1, .plaintext_hex = IPV4_A },
        },
    },
    .{
        .name = "preloaded-session-rejects-stale-epoch",
        .psk_hex = "1111111111111111111111111111111111111111111111111111111111111111",
        .from_id = 4,
        .to_id = 5,
        .init_epoch = MIN_EPOCH + 10_000,
        .steps = &.{
            .{ .note = "datagram from an epoch older than the preloaded session is dropped", .epoch = MIN_EPOCH + 1, .seq = 1, .plaintext_hex = IPV4_A },
            .{ .note = "datagram at the preloaded epoch authenticates and is accepted", .epoch = MIN_EPOCH + 10_000, .seq = 1, .plaintext_hex = IPV4_A },
        },
    },
};

/// Build a (possibly mutated) datagram for a receiver step. Returns the slice.
fn buildRxDatagram(link_key: crypto.Key, step: RxStep, out: []u8) ![]u8 {
    var plain_buf: [reactor.MAX_PLAINTEXT]u8 = undefined;
    const plaintext = try hexDecode(&plain_buf, step.plaintext_hex);
    var n = buildDatagram(link_key, step.epoch, step.seq, plaintext, out);
    switch (step.mutation) {
        .none => {},
        .bad_version => out[0] = 2,
        .bad_flags => out[1] = 1,
        .bad_reserved => out[2] = 1,
        .zero_epoch => @memset(out[4..12], 0),
        .truncate_header => n = reactor.HEADER_LEN - 1,
        .flip_tag => out[n - 1] ^= 0xff,
        .flip_body => out[reactor.HEADER_LEN] ^= 0x01,
    }
    return out[0..n];
}

/// Run one receiver case against a live `RxSession`, returning per-step results.
/// `outcomes[i]` is the recovered-plaintext length, or null for a drop;
/// `epochs[i]` is the session epoch after the step.
const RxResult = struct {
    accepted: bool,
    plaintext: [reactor.MAX_PLAINTEXT]u8,
    plaintext_len: usize,
    epoch_after: u64,
};

fn runRxStep(rx: *crypto.RxSession, link_key: crypto.Key, step: RxStep) !RxResult {
    var dgram: [reactor.MAX_WIRE]u8 = undefined;
    const wire = try buildRxDatagram(link_key, step, &dgram);
    var out: [reactor.MAX_PLAINTEXT]u8 = undefined;
    const r = reactor.decodeIngress(rx, wire, &out);
    var res: RxResult = .{ .accepted = r != null, .plaintext = undefined, .plaintext_len = 0, .epoch_after = rx.epoch };
    if (r) |len| {
        @memcpy(res.plaintext[0..len], out[0..len]);
        res.plaintext_len = len;
    }
    return res;
}

// ---------------------------------------------------------------------------
// JSON rendering
// ---------------------------------------------------------------------------

/// Minimal fixed-buffer JSON appender (Zig 0.16 dropped fixedBufferStream).
const Appender = struct {
    buf: []u8,
    len: usize = 0,

    fn print(self: *Appender, comptime fmt: []const u8, args: anytype) !void {
        const slice = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += slice.len;
    }

    fn writeAll(self: *Appender, bytes: []const u8) !void {
        if (self.len + bytes.len > self.buf.len) return error.NoSpaceLeft;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn writeHex(self: *Appender, bytes: []const u8) !void {
        if (self.len + bytes.len * 2 > self.buf.len) return error.NoSpaceLeft;
        _ = hexEncode(self.buf[self.len..], bytes);
        self.len += bytes.len * 2;
    }
};

/// Render the full KAT set (sender vectors + receiver cases) as deterministic
/// JSON into `out`, returning the written slice. The byte layout is stable so
/// the committed golden file is an exact, diffable image of this output.
pub fn writeJson(out: []u8) ![]const u8 {
    var a = Appender{ .buf = out };
    const w = &a;

    try w.print(
        "{{\n" ++
            "  \"protocol\": \"btunnel\",\n" ++
            "  \"wire_version\": {d},\n" ++
            "  \"header_len\": {d},\n" ++
            "  \"tag_len\": {d},\n" ++
            "  \"max_plaintext\": {d},\n" ++
            "  \"aead\": \"ChaCha20-Poly1305\",\n" ++
            "  \"kdf\": \"Blake2b-256 (keyed)\",\n" ++
            "  \"vectors\": [\n",
        .{ reactor.WIRE_VERSION, reactor.HEADER_LEN, crypto.TAG_LEN, reactor.MAX_PLAINTEXT },
    );

    for (VECTORS, 0..) |v, i| {
        const o = try compute(v);
        try w.print(
            "    {{\n" ++
                "      \"name\": \"{s}\",\n" ++
                "      \"input\": {{\n" ++
                "        \"psk\": \"{s}\",\n" ++
                "        \"from_id\": {d},\n" ++
                "        \"to_id\": {d},\n" ++
                "        \"epoch\": {d},\n" ++
                "        \"seq\": {d},\n" ++
                "        \"plaintext\": \"{s}\"\n" ++
                "      }},\n" ++
                "      \"output\": {{\n" ++
                "        \"link_key\": \"{s}\",\n" ++
                "        \"session_key\": \"{s}\",\n" ++
                "        \"datagram\": \"{s}\"\n" ++
                "      }}\n" ++
                "    }}{s}\n",
            .{
                v.name,                        v.psk_hex,                            v.from_id,
                v.to_id,                       v.epoch,                              v.seq,
                v.plaintext_hex,               o.link_key[0..],                      o.session_key[0..],
                o.datagram[0..o.datagram_len], if (i + 1 < VECTORS.len) "," else "",
            },
        );
    }

    try w.writeAll("  ],\n  \"receiver_cases\": [\n");

    for (RX_CASES, 0..) |c, ci| {
        var psk: crypto.Key = undefined;
        _ = try hexDecode(&psk, c.psk_hex);
        // Receiver verifies traffic from `from_id` to itself (`to_id`) with the
        // sender's ordered pair (see crypto.deriveLinkKey / peer.add).
        const link = crypto.deriveLinkKey(psk, c.from_id, c.to_id);

        var rx = crypto.RxSession.init(link);
        if (c.init_epoch != 0) {
            rx.epoch = c.init_epoch;
            rx.skey = crypto.deriveSessionKey(link, c.init_epoch);
        }

        try w.print(
            "    {{\n" ++
                "      \"name\": \"{s}\",\n" ++
                "      \"link\": {{ \"psk\": \"{s}\", \"from_id\": {d}, \"to_id\": {d} }},\n" ++
                "      \"init_epoch\": {d},\n" ++
                "      \"steps\": [\n",
            .{ c.name, c.psk_hex, c.from_id, c.to_id, c.init_epoch },
        );

        for (c.steps, 0..) |step, si| {
            var dgram: [reactor.MAX_WIRE]u8 = undefined;
            const wire = try buildRxDatagram(link, step, &dgram);
            const res = try runRxStep(&rx, link, step);

            try w.print(
                "        {{\n" ++
                    "          \"note\": \"{s}\",\n" ++
                    "          \"datagram\": \"",
                .{step.note},
            );
            try w.writeHex(wire);
            try w.print(
                "\",\n" ++
                    "          \"expect\": \"{s}\",\n",
                .{if (res.accepted) "accept" else "drop"},
            );
            if (res.accepted) {
                try w.writeAll("          \"plaintext\": \"");
                try w.writeHex(res.plaintext[0..res.plaintext_len]);
                try w.print("\",\n          \"epoch_after\": {d}\n", .{res.epoch_after});
            } else {
                try w.print("          \"plaintext\": null,\n          \"epoch_after\": {d}\n", .{res.epoch_after});
            }
            try w.print("        }}{s}\n", .{if (si + 1 < c.steps.len) "," else ""});
        }

        try w.print("      ]\n    }}{s}\n", .{if (ci + 1 < RX_CASES.len) "," else ""});
    }

    try w.writeAll("  ]\n}\n");
    return a.buf[0..a.len];
}

// ---------------------------------------------------------------------------
// Tests: self-consistency and intended-behavior assertions. These complement
// the golden sentinel — the sentinel pins *stability*, these pin *correctness*.
// ---------------------------------------------------------------------------

test "hex round-trips" {
    var buf: [8]u8 = undefined;
    const bytes = try hexDecode(&buf, "0a0b0c");
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x0b, 0x0c }, bytes);
    var hex: [6]u8 = undefined;
    try std.testing.expectEqualStrings("0a0b0c", hexEncode(&hex, bytes));
}

test "every sender vector uses a spec-legal epoch" {
    for (VECTORS) |v| try std.testing.expect(v.epoch >= MIN_EPOCH);
}

test "sender datagram decodes back to the input plaintext" {
    for (VECTORS) |v| {
        const o = try compute(v);

        var psk: crypto.Key = undefined;
        _ = try hexDecode(&psk, v.psk_hex);
        const link = crypto.deriveLinkKey(psk, v.from_id, v.to_id);
        const session = crypto.deriveSessionKey(link, v.epoch);

        var dgram: [reactor.MAX_WIRE]u8 = undefined;
        const wire = try hexDecode(&dgram, o.datagram[0..o.datagram_len]);

        try std.testing.expectEqual(reactor.WIRE_VERSION, wire[0]);
        try std.testing.expectEqual(@as(u8, 0), wire[1]);
        try std.testing.expectEqual(v.epoch, std.mem.readInt(u64, wire[4..][0..8], .little));
        try std.testing.expectEqual(v.seq, std.mem.readInt(u64, wire[12..][0..8], .little));

        var plain_expect: [reactor.MAX_PLAINTEXT]u8 = undefined;
        const expect = try hexDecode(&plain_expect, v.plaintext_hex);

        var recovered: [reactor.MAX_PLAINTEXT]u8 = undefined;
        const plen = try crypto.open(session, v.seq, wire[reactor.HEADER_LEN..], &recovered);
        try std.testing.expectEqualSlices(u8, expect, recovered[0..plen]);
    }
}

fn rxLink(case: RxCase) !crypto.Key {
    var psk: crypto.Key = undefined;
    _ = try hexDecode(&psk, case.psk_hex);
    return crypto.deriveLinkKey(psk, case.from_id, case.to_id);
}

test "receiver: accept, replay, reorder semantics" {
    const c = RX_CASES[0];
    const link = try rxLink(c);
    var rx = crypto.RxSession.init(link);

    const r0 = try runRxStep(&rx, link, c.steps[0]);
    try std.testing.expect(r0.accepted); // first valid accepted
    try std.testing.expectEqual(c.steps[0].epoch, r0.epoch_after);

    const r1 = try runRxStep(&rx, link, c.steps[1]);
    try std.testing.expect(!r1.accepted); // byte-identical replay dropped

    const r2 = try runRxStep(&rx, link, c.steps[2]);
    try std.testing.expect(r2.accepted); // in-window reorder accepted

    const r3 = try runRxStep(&rx, link, c.steps[3]);
    try std.testing.expect(!r3.accepted); // its replay dropped
}

test "receiver: header/auth rejections never corrupt session state" {
    const c = RX_CASES[1];
    const link = try rxLink(c);
    var rx = crypto.RxSession.init(link);

    // Steps 0..6 are all malformed/tampered and MUST drop without adopting an
    // epoch (state stays pristine).
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const r = try runRxStep(&rx, link, c.steps[i]);
        try std.testing.expect(!r.accepted);
        try std.testing.expectEqual(@as(u64, 0), rx.epoch); // never mutated
    }
    // Step 7 is clean and must still be accepted.
    const last = try runRxStep(&rx, link, c.steps[7]);
    try std.testing.expect(last.accepted);
}

test "receiver: forward-only epoch ordering and window reset" {
    const c = RX_CASES[2];
    const link = try rxLink(c);
    var rx = crypto.RxSession.init(link);

    const r0 = try runRxStep(&rx, link, c.steps[0]);
    try std.testing.expect(r0.accepted);
    try std.testing.expectEqual(c.steps[0].epoch, rx.epoch);

    const r1 = try runRxStep(&rx, link, c.steps[1]); // older epoch
    try std.testing.expect(!r1.accepted);
    try std.testing.expectEqual(c.steps[0].epoch, rx.epoch); // unchanged

    const r2 = try runRxStep(&rx, link, c.steps[2]); // newer epoch, seq 1 again
    try std.testing.expect(r2.accepted);
    try std.testing.expectEqual(c.steps[2].epoch, rx.epoch); // adopted
}

test "receiver: preloaded session rejects a stale epoch" {
    const c = RX_CASES[3];
    const link = try rxLink(c);
    var rx = crypto.RxSession.init(link);
    rx.epoch = c.init_epoch;
    rx.skey = crypto.deriveSessionKey(link, c.init_epoch);

    const r0 = try runRxStep(&rx, link, c.steps[0]); // older than preload
    try std.testing.expect(!r0.accepted);

    const r1 = try runRxStep(&rx, link, c.steps[1]); // at preloaded epoch
    try std.testing.expect(r1.accepted);
}
