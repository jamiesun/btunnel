//! Linux OS backend (issue #75): the real `/dev/net/tun` TUN device and the
//! epoll edge-triggered readiness primitive. Moved here byte-for-byte from
//! `tun.zig` and `reactor.zig` behind the backend interface in `os/mod.zig`;
//! Linux behaviour is unchanged.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;
const sys = @import("../sys.zig");
const Trigger = @import("mod.zig").Trigger;

// --- TUN device (/dev/net/tun) ------------------------------------------------

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

/// Read one IP packet from the TUN fd into `buf`, returning the packet slice or
/// `null` on EAGAIN / EOF / transient error (i.e. "stop draining this tick").
/// Retries on EINTR. Linux `tun` with `IFF_NO_PI` already delivers a bare L3
/// packet, so this is a thin pass-through; the macOS backend strips utun's
/// 4-byte address-family header here so the reactor core stays platform-blind.
pub fn tunRead(fd: posix.fd_t, buf: []u8) ?[]u8 {
    while (true) {
        const rc = sys.read(fd, buf.ptr, buf.len);
        const e = sys.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return null;
        if (rc == 0) return null;
        return buf[0..@intCast(rc)];
    }
}

/// Write one bare IP packet `pkt` to the TUN fd. Returns true once the kernel
/// accepts it. Retries on EINTR. Linux writes the packet verbatim; macOS
/// prepends the 4-byte AF header inside its own backend.
pub fn tunWrite(fd: posix.fd_t, pkt: []const u8) bool {
    while (true) {
        const rc = sys.write(fd, pkt.ptr, pkt.len);
        if (sys.errno(rc) == .INTR) continue;
        return sys.errno(rc) == .SUCCESS;
    }
}

// --- Readiness primitive (epoll) ----------------------------------------------
/// Single-threaded epoll readiness source. `.edge` registrations are EPOLLET
/// (the reactor drains each ready fd to EAGAIN); `.level` registrations are
/// level-triggered (the control handler processes a bounded number of commands
/// per tick and epoll re-notifies while datagrams remain).
pub const Poller = struct {
    epfd: i32,

    pub fn init() !Poller {
        const rc = linux.epoll_create1(0);
        if (sys.errno(rc) != .SUCCESS) return error.EpollCreateFailed;
        return .{ .epfd = @intCast(rc) };
    }

    pub fn deinit(self: *Poller) void {
        _ = sys.close(self.epfd);
    }

    pub fn add(self: *Poller, fd: sys.fd_t, trigger: Trigger) !void {
        const flags: u32 = switch (trigger) {
            .edge => linux.EPOLL.IN | linux.EPOLL.ET,
            .level => linux.EPOLL.IN,
        };
        var ev = linux.epoll_event{
            .events = flags,
            .data = .{ .fd = fd },
        };
        const rc = linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
        if (sys.errno(rc) != .SUCCESS) return error.EpollCtlFailed;
    }

    /// Block until at least one fd is ready, write the ready fds into `out`, and
    /// return the count (bounded by `out.len`). Retries internally on EINTR.
    pub fn wait(self: *Poller, out: []sys.fd_t) !usize {
        var events: [16]linux.epoll_event = undefined;
        const cap = @min(out.len, events.len);
        while (true) {
            const nrc = linux.epoll_wait(self.epfd, &events, @intCast(cap), -1);
            const e = sys.errno(nrc);
            if (e == .INTR) continue;
            if (e != .SUCCESS) return error.EpollWaitFailed;
            const n: usize = @intCast(nrc);
            var i: usize = 0;
            while (i < n) : (i += 1) out[i] = events[i].data.fd;
            return n;
        }
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
