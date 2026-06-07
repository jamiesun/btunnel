//! Comptime OS backend selector (issue #75).
//!
//! The two genuinely platform-specific data-plane seams — the TUN device and
//! the readiness primitive — are resolved here at `comptime` by `builtin.os.tag`
//! so the reactor's per-packet hot path carries **zero** runtime `if (darwin)`
//! branches (RFC §3, §5). Each backend exposes the same surface:
//!
//!   - `TunDevice`: `open(name) !TunDevice`, `ifname() []const u8`, `close()`,
//!     with resident `fd` / `name` fields the data plane reads directly.
//!   - `tunRead(fd, buf) ?[]u8` / `tunWrite(fd, pkt) bool`: per-packet TUN I/O.
//!     Linux is a verbatim read/write; Darwin strips / prepends the 4-byte utun
//!     address-family header so the reactor only ever sees a bare IP packet.
//!   - `Poller`: `init() !Poller`, `add(fd, Trigger) !void`,
//!     `wait(out: []fd_t, timeout_ms: i32) !usize` (block up to `timeout_ms`,
//!     negative = forever, until ≥1 ready, write the ready fds; retry on EINTR
//!     only when blocking forever), `deinit()`. Pumps drain each ready fd to
//!     `EAGAIN`. The finite timeout drives the spoke keepalive (issue #96).
//!
//! Linux carries the real epoll + `/dev/net/tun` implementation; Darwin carries
//! a `poll(2)` readiness loop + `utun` TUN device. Both present the identical
//! surface so the data path selects an implementation purely at comptime.

const builtin = @import("builtin");

/// Readiness registration mode. Linux maps `.edge`→`EPOLLET` (fd is drained to
/// `EAGAIN`) and `.level`→level-triggered (handler processes a bounded number of
/// events per tick and relies on re-notification). macOS `poll(2)` is always
/// level-triggered; the distinction is a no-op there.
pub const Trigger = enum { edge, level };

pub const backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("darwin.zig"),
    else => @compileError("subnetra: no OS backend for '" ++ @tagName(builtin.os.tag) ++ "' (only linux and macos are supported)"),
};

pub const TunDevice = backend.TunDevice;
pub const Poller = backend.Poller;

/// Per-packet TUN I/O, resolved to the native backend at comptime. `tunRead`
/// returns the bare IP packet (or null to stop draining this tick); `tunWrite`
/// returns whether the kernel accepted the frame.
pub const tunRead = backend.tunRead;
pub const tunWrite = backend.tunWrite;

/// Comptime conformance check: both backends must present the surface the
/// reactor compiles against, so the data path selects an implementation at
/// comptime with no runtime OS conditional. Validated against *both* files
/// (not just the native one) so a stub drift on either platform fails the build.
fn assertBackend(comptime B: type) void {
    for ([_][]const u8{ "TunDevice", "Poller", "tunRead", "tunWrite" }) |decl| {
        if (!@hasDecl(B, decl)) @compileError("os backend missing '" ++ decl ++ "'");
    }
    for ([_][]const u8{ "open", "ifname", "close" }) |m| {
        if (!@hasDecl(B.TunDevice, m)) @compileError("os backend TunDevice missing '" ++ m ++ "'");
    }
    for ([_][]const u8{ "init", "add", "wait", "deinit" }) |m| {
        if (!@hasDecl(B.Poller, m)) @compileError("os backend Poller missing '" ++ m ++ "'");
    }
}

test "os backends satisfy the reactor interface (comptime)" {
    comptime assertBackend(@import("linux.zig"));
    comptime assertBackend(@import("darwin.zig"));
}

test "native Poller reports a readable fd" {
    const std = @import("std");
    const sys = @import("../sys.zig");
    const system = std.posix.system;

    // A pipe is a synchronous, platform-uniform readiness source (unlike macOS
    // loopback UDP, which defers delivery). Exercises whichever backend is
    // native: poll(2) on macOS, epoll on Linux. Allocation-free by construction
    // — no allocator is threaded through the readiness path.
    var fds: [2]i32 = undefined;
    if (system.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = sys.close(fds[0]);
    defer _ = sys.close(fds[1]);

    var poller = try Poller.init();
    defer poller.deinit();
    try poller.add(fds[0], .level);

    _ = sys.write(fds[1], "x", 1);

    var ready: [4]sys.fd_t = undefined;
    const n = try poller.wait(&ready, -1);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(fds[0], ready[0]);
}
