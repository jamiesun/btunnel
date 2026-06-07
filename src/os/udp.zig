//! Batched UDP datagram I/O (issue #100).
//!
//! Every datagram on the data path used to pay a full `recvfrom` + `sendto`
//! syscall round; on a hub that cost is paid twice (ingress + relayed egress),
//! so the hub saturates a single core on syscall entry long before crypto or Zig
//! become the ceiling (measured by the issue #97 baseline: the relay path tops
//! out at ~100% of one core). `recvmmsg`/`sendmmsg` amortize that entry cost
//! across a batch of `BATCH` datagrams per syscall.
//!
//! `UdpBatch` is a **resident, fixed-at-startup** buffer set (iron law #2 — zero
//! data-plane allocation): `BATCH` input buffers drained per readiness event and
//! `BATCH` output buffers coalesced per egress flush, plus the small `mmsghdr` /
//! `iovec` scratch the kernel ABI needs. It lives as a single field of the
//! `Reactor`, so the whole data plane stays allocation-free.
//!
//! Platform split is **comptime** (iron law #3 lets the IO primitive be selected
//! at comptime, same as `os/` and `sys.zig`): Linux drives one `recvmmsg` /
//! `sendmmsg` per batch; macOS — which has neither — falls back to a loop of the
//! existing single `recvfrom` / `sendto` (one syscall per datagram, unchanged
//! behaviour) behind the identical surface, so the reactor's batch loop is the
//! same on both. Per-packet semantics are untouched (iron law #8): batching only
//! changes *packets-per-syscall*; each datagram is still independently decoded,
//! anti-replayed, and routed by the reactor exactly as before.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("../sys.zig");

const is_linux = builtin.os.tag == .linux;

/// Datagrams drained per `recvmmsg` and coalesced per `sendmmsg`. Sized for
/// strong syscall amortization at high PPS while keeping the resident buffer set
/// modest (`2 * BATCH * BUF_LEN`). Tunable with the issue #97 harness.
pub const BATCH: usize = 32;

/// Per-datagram buffer size. Mirrors `reactor.BUF_LEN`; asserted equal there so
/// the two never drift (kept local to avoid a circular import with the reactor).
pub const BUF_LEN: usize = 2048;

/// Linux `mmsghdr`/`iovec` scratch for one batch direction. On macOS the
/// fallback uses single `recvfrom`/`sendto`, so it needs no scratch — the type is
/// an empty struct and the arrays cost nothing.
const Scratch = if (is_linux) struct {
    msgs: [BATCH]std.os.linux.mmsghdr = undefined,
    iov: [BATCH]std.posix.iovec = undefined,
} else struct {};

/// Resident batched UDP I/O over a single non-blocking datagram socket.
pub const UdpBatch = struct {
    pub const N = BATCH;
    /// Per-datagram buffer size, re-exported so the reactor can assert it matches
    /// its own wire buffer size at comptime.
    pub const BUF = BUF_LEN;

    // Ingress: filled by `recv`.
    in_bufs: [N][BUF_LEN]u8 = undefined,
    in_addrs: [N]sys.sockaddr.in = undefined,
    in_lens: [N]u32 = undefined,
    recv_scratch: Scratch = .{},

    // Egress: staged by `nextOutBuf`/`commitOut`, transmitted by `flush`.
    out_bufs: [N][BUF_LEN]u8 = undefined,
    out_addrs: [N]sys.sockaddr.in = undefined,
    out_lens: [N]u32 = undefined,
    /// Caller-defined category per staged datagram (the reactor distinguishes a
    /// forwarded tun packet from a relayed one for honest counter attribution).
    out_tags: [N]u8 = undefined,
    out_n: usize = 0,
    send_scratch: Scratch = .{},

    /// Drain up to `N` datagrams from `fd` into the input buffers. Linux issues
    /// one `recvmmsg(MSG_DONTWAIT)`; macOS loops `recvfrom` (one syscall per
    /// datagram) until it would block. Returns the number received — `0` means
    /// the socket is drained (EAGAIN) or errored, so the caller stops this tick.
    /// Retries on EINTR. The fd is already non-blocking (set by the reactor).
    pub fn recv(self: *UdpBatch, fd: sys.fd_t) usize {
        if (is_linux) {
            const linux = std.os.linux;
            var i: usize = 0;
            while (i < N) : (i += 1) {
                self.recv_scratch.iov[i] = .{ .base = &self.in_bufs[i], .len = BUF_LEN };
                self.recv_scratch.msgs[i] = .{
                    .hdr = .{
                        .name = @ptrCast(&self.in_addrs[i]),
                        .namelen = @sizeOf(sys.sockaddr.in),
                        .iov = self.recv_scratch.iov[i..].ptr,
                        .iovlen = 1,
                        .control = null,
                        .controllen = 0,
                        .flags = 0,
                    },
                    .len = 0,
                };
            }
            while (true) {
                const rc = linux.recvmmsg(@intCast(fd), &self.recv_scratch.msgs, N, sys.MSG.DONTWAIT, null);
                const e = sys.errno(rc);
                if (e == .INTR) continue;
                if (e != .SUCCESS) return 0;
                const got: usize = @intCast(rc);
                var k: usize = 0;
                while (k < got) : (k += 1) self.in_lens[k] = self.recv_scratch.msgs[k].len;
                return got;
            }
        } else {
            var got: usize = 0;
            while (got < N) {
                var slen: sys.socklen_t = @sizeOf(sys.sockaddr.in);
                const rc = sys.recvfrom(fd, &self.in_bufs[got], BUF_LEN, 0, @ptrCast(&self.in_addrs[got]), &slen);
                const e = sys.errno(rc);
                if (e == .INTR) continue;
                if (e != .SUCCESS) break;
                self.in_lens[got] = @intCast(rc);
                got += 1;
            }
            return got;
        }
    }

    /// The `i`-th received datagram (valid for `i < recv()`'s return).
    pub fn datagram(self: *UdpBatch, i: usize) []u8 {
        return self.in_bufs[i][0..self.in_lens[i]];
    }

    /// Source endpoint of the `i`-th received datagram.
    pub fn source(self: *UdpBatch, i: usize) sys.sockaddr.in {
        return self.in_addrs[i];
    }

    /// True when the egress stage is full and must be flushed before staging more.
    pub fn isFull(self: *const UdpBatch) bool {
        return self.out_n == N;
    }

    /// Number of datagrams currently staged for egress.
    pub fn pending(self: *const UdpBatch) usize {
        return self.out_n;
    }

    /// Buffer (length `BUF_LEN`) to seal the next outbound datagram into. The
    /// caller seals straight into it (no copy), then calls `commitOut`. Must not
    /// be called when `isFull()`.
    pub fn nextOutBuf(self: *UdpBatch) []u8 {
        return &self.out_bufs[self.out_n];
    }

    /// Record the just-sealed outbound datagram (its wire length, destination,
    /// and caller category) and advance the stage.
    pub fn commitOut(self: *UdpBatch, wire_len: usize, dst: sys.sockaddr.in, tag: u8) void {
        self.out_addrs[self.out_n] = dst;
        self.out_lens[self.out_n] = @intCast(wire_len);
        self.out_tags[self.out_n] = tag;
        self.out_n += 1;
    }

    /// Category recorded for staged slot `i` (read after `flush` for attribution).
    pub fn tagAt(self: *const UdpBatch, i: usize) u8 {
        return self.out_tags[i];
    }

    /// Wire length of staged slot `i`.
    pub fn lenAt(self: *const UdpBatch, i: usize) u32 {
        return self.out_lens[i];
    }

    /// Transmit all staged datagrams and reset the stage. Linux coalesces them
    /// into `sendmmsg` (looping to push any leading-prefix remainder); macOS
    /// loops `sendto`. Returns the number of leading datagrams the kernel
    /// accepted — matching `sendmmsg` semantics, the first `sent` succeeded and
    /// the rest (if any) were not sent — so the caller attributes success/drop
    /// per slot. Always clears the stage, even on a short send.
    pub fn flush(self: *UdpBatch, fd: sys.fd_t) usize {
        const n = self.out_n;
        if (n == 0) return 0;
        var sent: usize = 0;
        if (is_linux) {
            const linux = std.os.linux;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                self.send_scratch.iov[i] = .{ .base = &self.out_bufs[i], .len = self.out_lens[i] };
                self.send_scratch.msgs[i] = .{
                    .hdr = .{
                        .name = @ptrCast(&self.out_addrs[i]),
                        .namelen = @sizeOf(sys.sockaddr.in),
                        .iov = self.send_scratch.iov[i..].ptr,
                        .iovlen = 1,
                        .control = null,
                        .controllen = 0,
                        .flags = 0,
                    },
                    .len = 0,
                };
            }
            while (sent < n) {
                const rc = linux.sendmmsg(@intCast(fd), self.send_scratch.msgs[sent..].ptr, @intCast(n - sent), sys.MSG.DONTWAIT);
                const e = sys.errno(rc);
                if (e == .INTR) continue;
                if (e != .SUCCESS) break; // EAGAIN/ENOBUFS/etc: remaining count as not-sent
                const s: usize = @intCast(rc);
                if (s == 0) break;
                sent += s;
            }
        } else {
            while (sent < n) {
                const rc = sys.sendto(fd, &self.out_bufs[sent], self.out_lens[sent], 0, @ptrCast(&self.out_addrs[sent]), @sizeOf(sys.sockaddr.in));
                const e = sys.errno(rc);
                if (e == .INTR) continue;
                if (e != .SUCCESS) break; // stop at first failure (sendmmsg leading-prefix semantics)
                sent += 1;
            }
        }
        self.out_n = 0;
        return sent;
    }
};

test "UdpBatch stages and reports egress slots before flush" {
    var b = UdpBatch{};
    try std.testing.expect(!b.isFull());
    try std.testing.expectEqual(@as(usize, 0), b.pending());

    const dst = sys.sockaddr.in{ .family = sys.AF.INET, .port = 0, .addr = 0x0100007f };
    const buf = b.nextOutBuf();
    try std.testing.expectEqual(@as(usize, BUF_LEN), buf.len);
    buf[0] = 0xAB;
    b.commitOut(7, dst, 1);

    try std.testing.expectEqual(@as(usize, 1), b.pending());
    try std.testing.expectEqual(@as(u8, 1), b.tagAt(0));
    try std.testing.expectEqual(@as(u32, 7), b.lenAt(0));
}

test "UdpBatch fills exactly N egress slots, then reports full" {
    var b = UdpBatch{};
    const dst = sys.sockaddr.in{ .family = sys.AF.INET, .port = 0, .addr = 0x0100007f };
    var i: usize = 0;
    while (i < UdpBatch.N) : (i += 1) {
        try std.testing.expect(!b.isFull());
        _ = b.nextOutBuf();
        b.commitOut(20, dst, 0);
    }
    try std.testing.expect(b.isFull());
    try std.testing.expectEqual(UdpBatch.N, b.pending());
}

test "UdpBatch loopback round-trips a batch (recv count, payloads, sources)" {
    // Cross-platform: exercises recvmmsg/sendmmsg on Linux and the
    // recvfrom/sendto fallback on macOS. Poll for readiness before draining so
    // macOS's deferred loopback delivery does not race the recv.
    const os = @import("mod.zig");

    const rx = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, true, false) catch return error.SkipZigTest;
    defer _ = sys.close(rx);
    var rx_addr = sys.sockaddr.in{ .family = sys.AF.INET, .port = 0, .addr = 0x0100007f };
    if (sys.errno(sys.bind(rx, @ptrCast(&rx_addr), @sizeOf(sys.sockaddr.in))) != .SUCCESS) return error.SkipZigTest;
    var alen: sys.socklen_t = @sizeOf(sys.sockaddr.in);
    if (sys.errno(sys.getsockname(rx, @ptrCast(&rx_addr), &alen)) != .SUCCESS) return error.SkipZigTest;

    const tx = sys.socket(sys.AF.INET, sys.SOCK.DGRAM, 0, true, false) catch return error.SkipZigTest;
    defer _ = sys.close(tx);

    const k = 5;
    var sent: usize = 0;
    while (sent < k) : (sent += 1) {
        const payload = [_]u8{ @intCast(sent), 0xEE, 0xFF };
        _ = sys.sendto(tx, &payload, payload.len, 0, @ptrCast(&rx_addr), @sizeOf(sys.sockaddr.in));
    }

    var poller = os.Poller.init() catch return error.SkipZigTest;
    defer poller.deinit();
    poller.add(rx, .level) catch return error.SkipZigTest;
    var ready: [4]sys.fd_t = undefined;
    _ = poller.wait(&ready, 1000) catch return error.SkipZigTest;

    var b = UdpBatch{};
    var total: usize = 0;
    var seen = [_]bool{false} ** k;
    // Drain to EAGAIN; a batch may arrive split across recv calls.
    var rounds: usize = 0;
    while (rounds < k + 2) : (rounds += 1) {
        const got = b.recv(rx);
        if (got == 0) break;
        var i: usize = 0;
        while (i < got) : (i += 1) {
            const d = b.datagram(i);
            try std.testing.expectEqual(@as(usize, 3), d.len);
            try std.testing.expect(d[0] < k);
            seen[d[0]] = true;
            try std.testing.expectEqual(@as(u32, rx_addr.addr), b.source(i).addr);
            total += 1;
        }
        if (total >= k) break;
    }
    try std.testing.expectEqual(@as(usize, k), total);
    for (seen) |s| try std.testing.expect(s);
}
