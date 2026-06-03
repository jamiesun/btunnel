//! 任务 5：密码学管道（Crypto Pipeline）
//!
//! - ChaCha20-Poly1305 全加密，运行时零分配（调用方传入固定缓冲区切片）
//! - Nonce 由每端 64-bit 单调递增计数器派生，绝不复用
//! - 接收端滑动窗口（64 位 bitmap）防重放

const std = @import("std");
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const KEY_LEN = Aead.key_length; // 32
pub const TAG_LEN = Aead.tag_length; // 16
pub const NONCE_LEN = Aead.nonce_length; // 12

pub const Key = [KEY_LEN]u8;

/// 由 64-bit 序列号派生 12 字节 nonce（低 8 字节存序列号，高位预留续接）。
pub fn nonceFromSeq(seq: u64) [NONCE_LEN]u8 {
    var n = [_]u8{0} ** NONCE_LEN;
    std.mem.writeInt(u64, n[0..8], seq, .little);
    return n;
}

/// 每端独立的单调递增计数器。发送即自增，绝不复用。
/// 重启后可用高位续接（`reseedHigh`）杜绝跨会话复用。
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

/// 加密：密文写入 `out[0..plaintext.len]`，Tag 追加在其后。
/// 要求 `out.len >= plaintext.len + TAG_LEN`。返回写入的总字节数。
pub fn seal(key: Key, seq: u64, plaintext: []const u8, out: []u8) usize {
    std.debug.assert(out.len >= plaintext.len + TAG_LEN);
    const ct = out[0..plaintext.len];
    var tag: [TAG_LEN]u8 = undefined;
    Aead.encrypt(ct, &tag, plaintext, &.{}, nonceFromSeq(seq), key);
    @memcpy(out[plaintext.len..][0..TAG_LEN], &tag);
    return plaintext.len + TAG_LEN;
}

/// 解密并认证：`ciphertext` 含尾部 16B Tag，明文写入 `out`。
/// 认证失败返回 error（调用方必须直接 Drop）。返回明文字节数。
pub fn open(key: Key, seq: u64, ciphertext: []const u8, out: []u8) !usize {
    if (ciphertext.len < TAG_LEN) return error.Truncated;
    const ct = ciphertext[0 .. ciphertext.len - TAG_LEN];
    var tag: [TAG_LEN]u8 = undefined;
    @memcpy(&tag, ciphertext[ciphertext.len - TAG_LEN ..][0..TAG_LEN]);
    std.debug.assert(out.len >= ct.len);
    try Aead.decrypt(out[0..ct.len], ct, tag, &.{}, nonceFromSeq(seq), key);
    return ct.len;
}

/// 64 包滑动窗口防重放。bit i 置位表示 (highest - i) 已收到。
pub const ReplayWindow = struct {
    highest: u64 = 0,
    bitmap: u64 = 0,

    /// 校验并更新：未见过且在窗口内返回 true；重放或过旧返回 false。
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
        if (diff >= 64) return false; // 超出窗口，过旧
        const mask = @as(u64, 1) << @intCast(diff);
        if (self.bitmap & mask != 0) return false; // 已见过，重放
        self.bitmap |= mask;
        return true;
    }
};

test "Crypto Invariance: 长度 +16 且明文一致" {
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

test "Nonce Monotonic: 严格递增不重复" {
    var c = NonceCounter{};
    var prev = c.next();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const cur = c.next();
        try std.testing.expect(cur > prev);
        prev = cur;
    }
}

test "Anti-Replay: 窗口外/重放被 Drop，乱序在窗口内被接受" {
    var w = ReplayWindow{};
    try std.testing.expect(w.accept(1));
    try std.testing.expect(w.accept(2));
    try std.testing.expect(w.accept(5));
    try std.testing.expect(w.accept(4)); // 乱序但窗口内
    try std.testing.expect(!w.accept(5)); // 重放
    try std.testing.expect(!w.accept(4)); // 重放
    try std.testing.expect(w.accept(100)); // 大跳跃，重置窗口
    try std.testing.expect(!w.accept(1)); // 窗口外，过旧
}
