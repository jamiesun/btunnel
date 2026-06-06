//! Task 5: Crypto pipeline.
//!
//! - ChaCha20-Poly1305 full encryption, zero allocation at runtime (the caller
//!   passes fixed-buffer slices)
//! - Nonce derived from a per-endpoint 64-bit monotonic counter, never reused
//! - Receiver-side sliding window (64-bit bitmap) anti-replay

const std = @import("std");
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const KEY_LEN = Aead.key_length; // 32
pub const TAG_LEN = Aead.tag_length; // 16
pub const NONCE_LEN = Aead.nonce_length; // 12

pub const Key = [KEY_LEN]u8;

const LINK_LABEL = "subnetra-v1-link";
const SESSION_LABEL = "subnetra-v1-session";

/// Derive a directional per-link key from the shared PSK and the ordered pair
/// of mesh node ids (`from_id` is the sender, `to_id` is the receiver).
///
/// This is the single most important defence for a shared-PSK mesh: without it,
/// two independent per-peer nonce counters can emit the same `(key, nonce)` pair
/// for different plaintexts, which catastrophically breaks ChaCha20-Poly1305.
/// Giving every directional link its own key makes each link's nonce space
/// disjoint, so a sequence number may safely repeat across links.
///
/// Both endpoints of a link agree on the key because they feed the identical
/// ordered pair: the sender uses `(local_id, peer_id)` for its tx key while the
/// receiver uses `(peer_id, local_id)` for the matching rx key.
pub fn deriveLinkKey(psk: Key, from_id: u32, to_id: u32) Key {
    const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
    var msg: [LINK_LABEL.len + 8]u8 = undefined;
    @memcpy(msg[0..LINK_LABEL.len], LINK_LABEL);
    std.mem.writeInt(u32, msg[LINK_LABEL.len..][0..4], from_id, .big);
    std.mem.writeInt(u32, msg[LINK_LABEL.len + 4 ..][0..4], to_id, .big);
    var out: Key = undefined;
    Blake2b256.hash(&msg, &out, .{ .key = &psk });
    return out;
}

/// Derive a 12-byte nonce from a 64-bit sequence number (low 8 bytes hold the
/// sequence, the high bytes are reserved for continuation).
pub fn nonceFromSeq(seq: u64) [NONCE_LEN]u8 {
    var n = [_]u8{0} ** NONCE_LEN;
    std.mem.writeInt(u64, n[0..8], seq, .little);
    return n;
}

/// Derive a per-session key from a directional link key and a boot epoch
/// (issue #14). Each daemon lifetime picks a fresh `epoch` (wall-clock
/// nanoseconds at startup), so the session key changes on every restart even
/// though the link key is stable. This lets the transmit sequence number safely
/// restart at 1 after a reboot: a fresh key means a repeated `(seq)` can never
/// reproduce a `(key, nonce)` pair that was used in a previous lifetime, which
/// would be catastrophic for ChaCha20-Poly1305.
///
/// The epoch is also carried on the wire so the receiver derives the matching
/// session key statelessly (no handshake), and uses it to scope its anti-replay
/// window per session (see `reactor.decodeIngress`).
pub fn deriveSessionKey(link_key: Key, epoch: u64) Key {
    const Blake2b256 = std.crypto.hash.blake2.Blake2b256;
    var msg: [SESSION_LABEL.len + 8]u8 = undefined;
    @memcpy(msg[0..SESSION_LABEL.len], SESSION_LABEL);
    std.mem.writeInt(u64, msg[SESSION_LABEL.len..][0..8], epoch, .big);
    var out: Key = undefined;
    Blake2b256.hash(&msg, &out, .{ .key = &link_key });
    return out;
}

/// Per-endpoint monotonic counter. Incremented on every send, never reused
/// within a session. Because the session key is epoch-bound (see
/// `deriveSessionKey`), the counter safely restarts at 1 on each daemon
/// lifetime.
pub const NonceCounter = struct {
    value: u64 = 1,

    pub fn next(self: *NonceCounter) u64 {
        const cur = self.value;
        self.value += 1;
        return cur;
    }
};

/// Transmit session state for one directional link (issue #14). Built once at
/// peer registration from the link key and this daemon's boot epoch. The egress
/// path stamps `epoch` into every header and seals with the epoch-bound `skey`.
pub const TxSession = struct {
    /// Stable directional link key (kept for inspection/tests).
    link_key: Key,
    /// Epoch-bound session key = deriveSessionKey(link_key, epoch).
    skey: Key,
    /// This daemon's boot epoch, carried on the wire.
    epoch: u64,
    /// Monotonic per-session sequence number.
    counter: NonceCounter = .{},

    pub fn init(link_key: Key, epoch: u64) TxSession {
        return .{
            .link_key = link_key,
            .skey = deriveSessionKey(link_key, epoch),
            .epoch = epoch,
        };
    }
};

/// Receive session state for one directional link (issue #14). Forward-only:
/// the highest authenticated epoch wins. `epoch == 0` is the "no session yet"
/// sentinel (a real boot epoch is wall-clock ns, never zero), in which case
/// `skey` is undefined and must not be read until an epoch has been adopted.
pub const RxSession = struct {
    /// Stable directional link key; session keys are derived from it on demand.
    link_key: Key,
    /// Currently-adopted peer epoch (0 = none seen yet).
    epoch: u64 = 0,
    /// Cached session key for `epoch` (valid only when `epoch != 0`).
    skey: Key = undefined,
    /// Anti-replay window, reset whenever a newer epoch is adopted.
    window: ReplayWindow = .{},

    pub fn init(link_key: Key) RxSession {
        return .{ .link_key = link_key };
    }
};

/// Encrypt: ciphertext is written to `out[0..plaintext.len]` with the tag
/// appended after it. Requires `out.len >= plaintext.len + TAG_LEN`. Returns the
/// total number of bytes written.
pub fn seal(key: Key, seq: u64, plaintext: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= plaintext.len + TAG_LEN);
    const ct = out[0..plaintext.len];
    var tag: [TAG_LEN]u8 = undefined;
    Aead.encrypt(ct, &tag, plaintext, &.{}, nonceFromSeq(seq), key);
    @memcpy(out[plaintext.len..][0..TAG_LEN], &tag);
    return plaintext.len + TAG_LEN;
}

/// Decrypt and authenticate: `ciphertext` includes the trailing 16-byte tag;
/// plaintext is written to `out`. Returns an error on authentication failure
/// (the caller must Drop). Returns the plaintext byte count.
pub fn open(key: Key, seq: u64, ciphertext: []const u8, out: []u8) !usize {
    if (ciphertext.len < TAG_LEN) return error.Truncated;
    const ct = ciphertext[0 .. ciphertext.len - TAG_LEN];
    var tag: [TAG_LEN]u8 = undefined;
    @memcpy(&tag, ciphertext[ciphertext.len - TAG_LEN ..][0..TAG_LEN]);
    std.debug.assert(out.len >= ct.len);
    try Aead.decrypt(out[0..ct.len], ct, tag, &.{}, nonceFromSeq(seq), key);
    return ct.len;
}

/// 64-packet sliding window anti-replay. Bit i set means (highest - i) was seen.
pub const ReplayWindow = struct {
    highest: u64 = 0,
    bitmap: u64 = 0,

    /// Validate and update: returns true if unseen and within the window;
    /// returns false for replays or sequences that are too old.
    pub fn accept(self: *ReplayWindow, seq: u64) bool {
        if (seq > self.highest) {
            const diff = seq - self.highest;
            if (diff >= 64) {
                self.bitmap = 1;
            } else {
                self.bitmap = (self.bitmap << @intCast(diff)) | 1;
            }
            self.highest = seq;
            return true;
        }
        const diff = self.highest - seq;
        if (diff >= 64) return false; // outside the window, too old
        const mask = @as(u64, 1) << @intCast(diff);
        if (self.bitmap & mask != 0) return false; // already seen, replay
        self.bitmap |= mask;
        return true;
    }
};

test "Crypto Invariance: length +16 and plaintext matches" {
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rand = prng.random();
    const key: Key = [_]u8{0x42} ** KEY_LEN;

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var plain: [64]u8 = undefined;
        const len = rand.intRangeAtMost(usize, 1, plain.len);
        rand.bytes(plain[0..len]);

        var sealed: [64 + TAG_LEN]u8 = undefined;
        const out_len = seal(key, @intCast(i + 1), plain[0..len], &sealed);
        try std.testing.expectEqual(len + TAG_LEN, out_len);

        var opened: [64]u8 = undefined;
        const plen = try open(key, @intCast(i + 1), sealed[0..out_len], &opened);
        try std.testing.expectEqualSlices(u8, plain[0..len], opened[0..plen]);
    }
}

test "Nonce Monotonic: strictly increasing, no repeats" {
    var c = NonceCounter{};
    var prev = c.next();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const cur = c.next();
        try std.testing.expect(cur > prev);
        prev = cur;
    }
}

test "Crypto: auth failure is rejected (tampered tag / wrong key / wrong seq)" {
    const key: Key = [_]u8{0x42} ** KEY_LEN;
    const plain = "the quick brown fox";

    var sealed: [plain.len + TAG_LEN]u8 = undefined;
    const out_len = seal(key, 7, plain, &sealed);

    var opened: [plain.len]u8 = undefined;

    // Sanity: the untouched ciphertext decrypts fine.
    _ = try open(key, 7, sealed[0..out_len], &opened);

    // Tampered tag (flip the last byte) -> AuthenticationFailed.
    var tampered = sealed;
    tampered[out_len - 1] ^= 0xFF;
    try std.testing.expectError(error.AuthenticationFailed, open(key, 7, tampered[0..out_len], &opened));

    // Tampered ciphertext body (flip the first byte).
    var tampered_body = sealed;
    tampered_body[0] ^= 0x01;
    try std.testing.expectError(error.AuthenticationFailed, open(key, 7, tampered_body[0..out_len], &opened));

    // Wrong key.
    const wrong_key: Key = [_]u8{0x43} ** KEY_LEN;
    try std.testing.expectError(error.AuthenticationFailed, open(wrong_key, 7, sealed[0..out_len], &opened));

    // Wrong seq (nonce mismatch) -> authentication fails, defeating replay/reorder forgery.
    try std.testing.expectError(error.AuthenticationFailed, open(key, 8, sealed[0..out_len], &opened));

    // Truncated input (shorter than the tag) is rejected before AEAD.
    try std.testing.expectError(error.Truncated, open(key, 7, sealed[0 .. TAG_LEN - 1], &opened));
}

test "Anti-Replay: out-of-window/replays dropped, in-window reorder accepted" {
    var w = ReplayWindow{};
    try std.testing.expect(w.accept(1));
    try std.testing.expect(w.accept(2));
    try std.testing.expect(w.accept(5));
    try std.testing.expect(w.accept(4)); // reordered but in window
    try std.testing.expect(!w.accept(5)); // replay
    try std.testing.expect(!w.accept(4)); // replay
    try std.testing.expect(w.accept(100)); // big jump, window resets
    try std.testing.expect(!w.accept(1)); // outside the window, too old
}

test "Anti-Replay: window boundary (diff==63 accepted, diff==64 rejected)" {
    // Advance highest to 64, then probe the exact 64-wide window edges.
    var w = ReplayWindow{};
    try std.testing.expect(w.accept(64)); // highest = 64, bit 0 = seq 64
    // seq 1 => diff = 63 (the oldest still-tracked slot) must be accepted once...
    try std.testing.expect(w.accept(1));
    // ...and rejected as a replay the second time.
    try std.testing.expect(!w.accept(1));
    // seq 0 => diff = 64, just outside the window, must be rejected as too old.
    try std.testing.expect(!w.accept(0));
}

test "Anti-Replay: forward shift preserves previously-seen bits" {
    // Seeing an old packet after the window slides forward must still be a replay.
    var w = ReplayWindow{};
    try std.testing.expect(w.accept(1)); // highest = 1
    try std.testing.expect(w.accept(64)); // slide forward by 63; seq 1 now at bit 63
    try std.testing.expect(!w.accept(1)); // still flagged seen -> replay
    // A fresh in-window seq between them is accepted exactly once.
    try std.testing.expect(w.accept(30));
    try std.testing.expect(!w.accept(30));
}

test "Link keys: directional pair agrees, namespace is disjoint" {
    const psk: Key = [_]u8{0x5a} ** KEY_LEN;

    // Sender (local=1) tx key for the link to peer 3 must equal the receiver's
    // (local=3) rx key for traffic arriving from peer 1.
    const hub_to_b_tx = deriveLinkKey(psk, 1, 3);
    const b_from_hub_rx = deriveLinkKey(psk, 1, 3);
    try std.testing.expectEqualSlices(u8, &hub_to_b_tx, &b_from_hub_rx);

    // The opposite direction is a different key (no accidental symmetry).
    const b_to_hub_tx = deriveLinkKey(psk, 3, 1);
    try std.testing.expect(!std.mem.eql(u8, &hub_to_b_tx, &b_to_hub_tx));

    // Two distinct destinations from the same sender get distinct keys, so an
    // identical sequence number on each link cannot collide into nonce reuse.
    const hub_to_a = deriveLinkKey(psk, 1, 2);
    const hub_to_b = deriveLinkKey(psk, 1, 3);
    try std.testing.expect(!std.mem.eql(u8, &hub_to_a, &hub_to_b));

    // The same nonce/seq under two different link keys yields different
    // ciphertext (and neither opens under the other key).
    const plain = "shared-psk nonce reuse must not break confidentiality";
    var ct_a: [plain.len + TAG_LEN]u8 = undefined;
    var ct_b: [plain.len + TAG_LEN]u8 = undefined;
    _ = seal(hub_to_a, 7, plain, &ct_a);
    _ = seal(hub_to_b, 7, plain, &ct_b);
    try std.testing.expect(!std.mem.eql(u8, &ct_a, &ct_b));
    var opened: [plain.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, open(hub_to_b, 7, &ct_a, &opened));
}

test "Session epoch: distinct epochs derive distinct session keys" {
    const link: Key = [_]u8{0x5a} ** KEY_LEN;
    const k1 = deriveSessionKey(link, 1_700_000_000_000_000_000);
    const k2 = deriveSessionKey(link, 1_700_000_000_000_000_001); // 1ns later
    try std.testing.expect(!std.mem.eql(u8, &k1, &k2));

    // Same (link, epoch) is reproducible so both ends agree statelessly.
    const k1b = deriveSessionKey(link, 1_700_000_000_000_000_000);
    try std.testing.expectEqualSlices(u8, &k1, &k1b);

    // A different link key under the same epoch yields a different session key.
    const other: Key = [_]u8{0x5b} ** KEY_LEN;
    const ko = deriveSessionKey(other, 1_700_000_000_000_000_000);
    try std.testing.expect(!std.mem.eql(u8, &k1, &ko));
}

test "Session epoch: restart with a fresh epoch avoids (key,nonce) reuse" {
    // The catastrophic case #14 fixes: a restart reuses the link key and the
    // transmit counter restarts at 1. With epoch-bound session keys, seq 1 in
    // two different lifetimes seals under different keys, so the ciphertext (and
    // the implied (key, nonce) pair) never repeats.
    const link: Key = [_]u8{0x42} ** KEY_LEN;
    const plain = "identical plaintext, identical seq, different lifetime";

    var s1 = TxSession.init(link, 1_700_000_000_000_000_000);
    var s2 = TxSession.init(link, 1_700_000_000_000_000_777); // a later boot

    const seq1 = s1.counter.next();
    const seq2 = s2.counter.next();
    try std.testing.expectEqual(seq1, seq2); // both restart at 1

    var ct1: [plain.len + TAG_LEN]u8 = undefined;
    var ct2: [plain.len + TAG_LEN]u8 = undefined;
    _ = seal(s1.skey, seq1, plain, &ct1);
    _ = seal(s2.skey, seq2, plain, &ct2);
    try std.testing.expect(!std.mem.eql(u8, &ct1, &ct2));

    // Neither lifetime's packet opens under the other lifetime's session key.
    var opened: [plain.len]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, open(s2.skey, seq1, &ct1, &opened));
}

