//! Darwin (macOS) OS backend (issue #75): interface-conformant stubs.
//!
//! These expose the same `TunDevice` / `Poller` surface as `os/linux.zig` so the
//! reactor and `main` compile against the comptime-selected backend with no
//! runtime OS branch, but every entry point returns `error.Unsupported`. The
//! real implementations land in their own issues: `utun` TUN device (#76) and
//! the `poll(2)` readiness loop (#77).

const std = @import("std");
const posix = std.posix;
const sys = @import("../sys.zig");
const Trigger = @import("mod.zig").Trigger;

// utun interface names ("utunN") fit the BSD IFNAMSIZ of 16.
pub const IFNAMSIZ: usize = 16;

pub const TunError = error{
    Unsupported,
    OpenFailed,
    IoctlFailed,
} || posix.OpenError;

pub const TunDevice = struct {
    fd: posix.fd_t,
    name: [IFNAMSIZ]u8,

    /// Stub until the macOS `utun` backend (#76): PF_SYSTEM/SYSPROTO_CONTROL
    /// socket, `UTUN_CONTROL_NAME` ctl_info, 4-byte AF address prefix.
    pub fn open(if_name: []const u8) TunError!TunDevice {
        _ = if_name;
        return TunError.Unsupported;
    }

    pub fn ifname(self: *const TunDevice) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }

    pub fn close(self: *TunDevice) void {
        _ = self;
    }
};

/// Stub until the macOS `poll(2)` readiness loop (#77). macOS `poll` is
/// level-triggered, so `Trigger` collapses to a no-op there.
pub const Poller = struct {
    pub fn init() !Poller {
        return error.Unsupported;
    }

    pub fn deinit(self: *Poller) void {
        _ = self;
    }

    pub fn add(self: *Poller, fd: sys.fd_t, trigger: Trigger) !void {
        _ = self;
        _ = fd;
        _ = trigger;
        return error.Unsupported;
    }

    pub fn wait(self: *Poller, out: []sys.fd_t) !usize {
        _ = self;
        _ = out;
        return error.Unsupported;
    }
};
