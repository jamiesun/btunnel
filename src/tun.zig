//! 任务 4：TUN 网卡系统驱动（Data-Plane Device）
//!
//! 通过原生 std.posix 系统调用打开 /dev/net/tun，ioctl 实例化虚拟网卡，
//! 设置 O_NONBLOCK。脚手架：保留无依赖初始化骨架，Linux 专属逻辑以
//! `builtin.os` 守卫，非 Linux 平台编译通过但运行返回 Unsupported。

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

    /// 以非阻塞方式打开并配置一块 L3 TUN 网卡（IFF_TUN | IFF_NO_PI）。
    /// TODO(任务 4)：补全 TUNSETIFF ioctl 与 ifreq 结构填充。
    pub fn open(if_name: []const u8) TunError!TunDevice {
        if (builtin.os.tag != .linux) return TunError.Unsupported;

        const fd = try posix.open(CLONE_PATH, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0);
        errdefer posix.close(fd);

        var name: [IFNAMSIZ]u8 = [_]u8{0} ** IFNAMSIZ;
        const n = @min(if_name.len, IFNAMSIZ - 1);
        @memcpy(name[0..n], if_name[0..n]);

        // 占位：实际的 TUNSETIFF ioctl 在任务 4 落地。
        return TunError.Unsupported;
    }

    pub fn close(self: *TunDevice) void {
        posix.close(self.fd);
    }
};

test "TUN 常量与结构" {
    try std.testing.expectEqual(@as(u16, 0x0001), IFF_TUN);
    try std.testing.expectEqual(@as(usize, 16), IFNAMSIZ);
    try std.testing.expectEqual(IFNAMSIZ, @sizeOf([IFNAMSIZ]u8));
}
