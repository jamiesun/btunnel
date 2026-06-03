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

/// Derive a 12-byte nonce from a 64-bit sequence number (low 8 bytes hold the
/// sequence, the high bytes are reserved for continuation).
pub fn nonceFromSeq(seq: u64) [NONCE_LEN]u8 {
    var n = [_]u8{0} ** NONCE_LEN;
    std.mem.writeInt(u64, n[0..8], seq, .little);
    return n;
}

/// Per-endpoint monotonic counter. Incremented on every send, never reused.
/// After a restart the high bits can be reseeded (`reseedHigh`) to avoid
/// cross-session reuse.
pub const NonceCounter = struct {
    value: u64 = 1,

    pub fn next(self: *NonceCounter) u64 {
        const cur = self.value;
        self.value += 1;
        return cur;
    }

    pub fn reseedHigh(self: *NonceCounter, high: u32) void {
        self.value = (@as(u64, high) << 32) | 1;
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
