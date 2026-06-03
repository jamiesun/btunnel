//! Task 4: TUN device system driver (data-plane device).
//!
//! Opens /dev/net/tun via native std.posix syscalls, instantiates the virtual
//! L3 NIC with the TUNSETIFF ioctl, and keeps it in non-blocking mode. Linux is
//! the only supported runtime; on other platforms it compiles but returns
//! Unsupported, so the rest of the tree stays cross-compilable.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

pub const CLONE_PATH = "/dev/net/tun";

// linux/if_tun.h
pub const IFF_TUN: u16 = 0x0001;
pub const IFF_NO_PI: u16 = 0x1000;
pub const IFNAMSIZ: usize = 16;

// _IOW('T', 202, int) — see linux/if_tun.h.
pub const TUNSETIFF: u32 = 0x400454ca;

/// struct ifreq (linux/if.h), 40 bytes on LP64. We only touch the name and the
/// flags field; the rest is the ifr_ifru union padding, zeroed.
const ifreq = extern struct {
    name: [IFNAMSIZ]u8,
    flags: i16,
    _pad: [22]u8,
};

comptime {
    std.debug.assert(@sizeOf(ifreq) == 40);
}

pub const TunError = error{
    Unsupported,
    OpenFailed,
    IoctlFailed,
} || posix.OpenError;

pub const TunDevice = struct {
    fd: posix.fd_t,
    name: [IFNAMSIZ]u8,

    /// Open and configure an L3 TUN NIC in non-blocking mode (IFF_TUN | IFF_NO_PI).
    /// On success the netdev exists for as long as `fd` stays open. Returns
    /// `error.AccessDenied` when the caller lacks CAP_NET_ADMIN, so callers and
    /// tests can distinguish a privilege gap from a real failure.
    pub fn open(if_name: []const u8) TunError!TunDevice {
        if (builtin.os.tag != .linux) return TunError.Unsupported;

        const orc = linux.open(CLONE_PATH, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        switch (linux.errno(orc)) {
            .SUCCESS => {},
            .ACCES, .PERM => return TunError.AccessDenied,
            .NOENT => return TunError.FileNotFound,
            else => return TunError.OpenFailed,
        }
        const fd: posix.fd_t = @intCast(orc);
        errdefer _ = linux.close(fd);

        var req = std.mem.zeroes(ifreq);
        const n = @min(if_name.len, IFNAMSIZ - 1);
        @memcpy(req.name[0..n], if_name[0..n]);
        req.flags = @bitCast(IFF_TUN | IFF_NO_PI);

        const rc = linux.ioctl(fd, TUNSETIFF, @intFromPtr(&req));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .PERM, .ACCES => return TunError.AccessDenied,
            else => return TunError.IoctlFailed,
        }

        // The kernel writes back the resolved interface name (it may differ when
        // an empty/duplicate name was requested).
        return .{ .fd = fd, .name = req.name };
    }

    /// NUL-terminated slice of the resolved interface name.
    pub fn ifname(self: *const TunDevice) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }

    pub fn close(self: *TunDevice) void {
        _ = linux.close(self.fd);
    }
};

test "TUN constants and struct" {
    try std.testing.expectEqual(@as(u16, 0x0001), IFF_TUN);
    try std.testing.expectEqual(@as(usize, 16), IFNAMSIZ);
    try std.testing.expectEqual(IFNAMSIZ, @sizeOf([IFNAMSIZ]u8));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ifreq));
}

test "TUN: open instantiates a real L3 netdev" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var dev = TunDevice.open("bttest0") catch |err| switch (err) {
        // No /dev/net/tun (e.g. plain CI) or no CAP_NET_ADMIN: not a code fault.
        error.FileNotFound, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
    defer dev.close();

    try std.testing.expect(dev.fd >= 0);
    try std.testing.expectEqualStrings("bttest0", dev.ifname());

    // While the fd is open the kernel exposes the netdev under sysfs.
    var buf: [64]u8 = undefined;
    const sys_path = try std.fmt.bufPrintZ(&buf, "/sys/class/net/{s}", .{dev.ifname()});
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.access(sys_path.ptr, 0)));
}
