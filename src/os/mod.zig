//! Comptime OS backend selector (issue #75).
//!
//! The two genuinely platform-specific data-plane seams — the TUN device and
//! the readiness primitive — are resolved here at `comptime` by `builtin.os.tag`
//! so the reactor's per-packet hot path carries **zero** runtime `if (darwin)`
//! branches (RFC §3, §5). Each backend exposes the same surface:
//!
//!   - `TunDevice`: `open(name) !TunDevice`, `ifname() []const u8`, `close()`,
//!     with resident `fd` / `name` fields the data plane reads directly.
//!   - `Poller`: `init() !Poller`, `add(fd, Trigger) !void`,
//!     `wait(out: []fd_t) !usize` (block until ≥1 ready, write the ready fds,
//!     retry on EINTR), `deinit()`. Pumps drain each ready fd to `EAGAIN`.
//!
//! Linux carries the real epoll + `/dev/net/tun` implementation; Darwin ships
//! stubs returning `error.Unsupported` until the `utun` (#76) and `poll` (#77)
//! backends land.

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

/// Comptime conformance check: both backends must present the surface the
/// reactor compiles against, so the data path selects an implementation at
/// comptime with no runtime OS conditional. Validated against *both* files
/// (not just the native one) so a stub drift on either platform fails the build.
fn assertBackend(comptime B: type) void {
    for ([_][]const u8{ "TunDevice", "Poller" }) |decl| {
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
