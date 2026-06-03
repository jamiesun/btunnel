//! Task 4: TUN device system driver (data-plane device).
//!
//! Opens /dev/net/tun via native std.posix syscalls, instantiates the virtual
//! NIC with ioctl, and sets O_NONBLOCK. Scaffold: keeps a dependency-free init
//! skeleton; Linux-specific logic is guarded by `builtin.os`. On non-Linux
//! platforms it compiles but returns Unsupported at runtime.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const CLONE_PATH = "/dev/net/tun";

// linux/if_tun.h
pub const IFF_TUN: u16 = 0x0001;
pub const IFF_NO_PI: u16 = 0x1000;
pub const IFNAMSIZ: usize = 16;

pub const TunError = error{
    Unsupported,
    OpenFailed,
    IoctlFailed,
} || posix.OpenError;

pub const TunDevice = struct {
    fd: posix.fd_t,
    name: [IFNAMSIZ]u8,

    /// Open and configure an L3 TUN NIC in non-blocking mode (IFF_TUN | IFF_NO_PI).
    /// TODO(Task 4): complete the TUNSETIFF ioctl and ifreq struct population.
    pub fn open(if_name: []const u8) TunError!TunDevice {
        if (builtin.os.tag != .linux) return TunError.Unsupported;

        const fd = try posix.open(CLONE_PATH, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        errdefer posix.close(fd);

        var name: [IFNAMSIZ]u8 = [_]u8{0} ** IFNAMSIZ;
        const n = @min(if_name.len, IFNAMSIZ - 1);
        @memcpy(name[0..n], if_name[0..n]);

        // Placeholder: the real TUNSETIFF ioctl lands in Task 4.
        return TunError.Unsupported;
    }

    pub fn close(self: *TunDevice) void {
        posix.close(self.fd);
    }
};

test "TUN constants and struct" {
    try std.testing.expectEqual(@as(u16, 0x0001), IFF_TUN);
    try std.testing.expectEqual(@as(usize, 16), IFNAMSIZ);
    try std.testing.expectEqual(IFNAMSIZ, @sizeOf([IFNAMSIZ]u8));
}
