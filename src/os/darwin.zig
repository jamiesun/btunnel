//! Darwin (macOS) OS backend: a real `utun` L3 TUN device (#76) plus the 4-byte
//! address-family framing utun requires, and a `poll(2)` readiness primitive
//! (#77), behind the same interface as `os/linux.zig`.
//!
//! A utun is created not via a `/dev` node but by `connect`-ing a
//! `PF_SYSTEM` / `SYSPROTO_CONTROL` socket to the kernel control
//! `com.apple.net.utun_control`. Each frame on the fd is prefixed with a 4-byte
//! protocol family (big-endian `AF_INET` for v1's IPv4 data plane); `tunRead`
//! strips it and `tunWrite` prepends it via `writev`, so the reactor core and
//! its resident rx/tx buffers only ever see a bare IP packet.

const std = @import("std");
const posix = std.posix;
const system = std.posix.system;
const sys = @import("../sys.zig");
const Trigger = @import("mod.zig").Trigger;

// utun control plane (xnu: bsd/sys/kern_control.h, bsd/sys/sys_domain.h,
// bsd/net/if_utun.h).
const PF_SYSTEM: u32 = 32;
const AF_SYSTEM: u8 = 32;
const SYSPROTO_CONTROL: u32 = 2;
const AF_SYS_CONTROL: u16 = 2;
const UTUN_OPT_IFNAME: u32 = 2;
const UTUN_CONTROL_NAME = "com.apple.net.utun_control";
const MAX_KCTL_NAME: usize = 96;
// _IOWR('N', 3, struct ctl_info); struct ctl_info is 100 bytes.
const CTLIOCGINFO: u32 = 0xc0644e03;

// utun frames carry a 4-byte protocol family ahead of the IP packet. v1 is
// IPv4-only, so the family is AF_INET (2) encoded as a big-endian u32.
const AF_INET_PREFIX = [4]u8{ 0, 0, 0, 2 };

const ctl_info = extern struct {
    ctl_id: u32 = 0,
    ctl_name: [MAX_KCTL_NAME]u8 = [_]u8{0} ** MAX_KCTL_NAME,
};

const sockaddr_ctl = extern struct {
    sc_len: u8,
    sc_family: u8,
    ss_sysaddr: u16,
    sc_id: u32,
    sc_unit: u32,
    sc_reserved: [5]u32 = [_]u32{0} ** 5,
};

comptime {
    std.debug.assert(@sizeOf(ctl_info) == 100);
    std.debug.assert(@sizeOf(sockaddr_ctl) == 32);
}

// utun interface names ("utunN") fit the BSD IFNAMSIZ of 16.
pub const IFNAMSIZ: usize = 16;

pub const TunError = error{
    Unsupported,
    SocketFailed,
    IoctlFailed,
    ConnectFailed,
    GetNameFailed,
    FcntlFailed,
} || posix.OpenError;

pub const TunDevice = struct {
    fd: posix.fd_t,
    name: [IFNAMSIZ]u8,

    /// Create and configure a non-blocking L3 `utun` interface. The kernel
    /// assigns the next free `utunN` (sc_unit = 0) and the resolved name is read
    /// back via `UTUN_OPT_IFNAME`. `if_name` is accepted for symmetry with the
    /// Linux backend but ignored — macOS does not let the caller name a utun.
    /// Requires root; returns `error.AccessDenied` otherwise so callers can tell
    /// a privilege gap from a real failure.
    pub fn open(if_name: []const u8) TunError!TunDevice {
        _ = if_name;

        const fd = sys.socket(PF_SYSTEM, sys.SOCK.DGRAM, SYSPROTO_CONTROL, false, true) catch
            return TunError.SocketFailed;
        errdefer _ = sys.close(fd);

        // Resolve the utun kernel-control id by name.
        var info = ctl_info{};
        @memcpy(info.ctl_name[0..UTUN_CONTROL_NAME.len], UTUN_CONTROL_NAME);
        if (sys.errno(system.ioctl(fd, @as(c_int, @bitCast(CTLIOCGINFO)), &info)) != .SUCCESS)
            return TunError.IoctlFailed;

        // Attach to the control; sc_unit 0 means "next free utun".
        const addr = sockaddr_ctl{
            .sc_len = @sizeOf(sockaddr_ctl),
            .sc_family = AF_SYSTEM,
            .ss_sysaddr = AF_SYS_CONTROL,
            .sc_id = info.ctl_id,
            .sc_unit = 0,
        };
        const crc = system.connect(fd, @ptrCast(&addr), @sizeOf(sockaddr_ctl));
        switch (sys.errno(crc)) {
            .SUCCESS => {},
            .PERM, .ACCES => return TunError.AccessDenied,
            else => return TunError.ConnectFailed,
        }

        // Read back the kernel-assigned interface name ("utunN").
        var name = std.mem.zeroes([IFNAMSIZ]u8);
        var nlen: sys.socklen_t = @intCast(name.len);
        if (sys.errno(system.getsockopt(fd, @as(i32, @intCast(SYSPROTO_CONTROL)), UTUN_OPT_IFNAME, &name, &nlen)) != .SUCCESS)
            return TunError.GetNameFailed;

        sys.setNonblock(fd) catch return TunError.FcntlFailed;

        return .{ .fd = fd, .name = name };
    }

    /// NUL-terminated slice of the resolved interface name.
    pub fn ifname(self: *const TunDevice) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }

    pub fn close(self: *TunDevice) void {
        _ = sys.close(self.fd);
    }
};

/// Read one IP packet from the utun fd, stripping the 4-byte AF header so the
/// reactor sees a bare L3 packet. Returns null on EAGAIN / EOF / a runt frame /
/// transient error ("stop draining this tick"). Retries on EINTR.
pub fn tunRead(fd: posix.fd_t, buf: []u8) ?[]u8 {
    while (true) {
        const rc = sys.read(fd, buf.ptr, buf.len);
        const e = sys.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return null;
        const n: usize = @intCast(rc);
        if (n <= AF_INET_PREFIX.len) return null; // header-only / runt: nothing to forward
        return buf[AF_INET_PREFIX.len..n];
    }
}

/// Write one bare IP packet to the utun fd, prepending the 4-byte AF header via
/// `writev` so the reactor's tx buffer stays a bare packet (no prepend copy).
/// Returns true once the kernel accepts the frame. Retries on EINTR.
pub fn tunWrite(fd: posix.fd_t, pkt: []const u8) bool {
    var af = AF_INET_PREFIX;
    var iov = [2]posix.iovec_const{
        .{ .base = &af, .len = af.len },
        .{ .base = pkt.ptr, .len = pkt.len },
    };
    while (true) {
        const rc = system.writev(fd, &iov, iov.len);
        if (sys.errno(rc) == .INTR) continue;
        return sys.errno(rc) == .SUCCESS;
    }
}

/// Single-threaded, allocation-free `poll(2)` readiness source (#77). The
/// reactor watches a small, fixed fd set — `tun_fd`, the single `udp_fd`, and
/// the optional UDS control listener — so a `pollfd` array sized at startup
/// needs no per-iteration allocation. `poll` is level-triggered, so `Trigger`
/// (edge vs. level) is a no-op here; the pumps' drain-to-`EAGAIN` loop keeps the
/// level-triggered semantics correct and free of busy-spin.
pub const Poller = struct {
    // Headroom over the reactor's 3 fds (tun + udp + control). The data plane
    // never grows this set at runtime, so the bound is static.
    const MAX_FDS = 8;

    fds: [MAX_FDS]system.pollfd = undefined,
    n: usize = 0,

    pub fn init() !Poller {
        return .{};
    }

    pub fn deinit(self: *Poller) void {
        _ = self;
    }

    pub fn add(self: *Poller, fd: sys.fd_t, trigger: Trigger) !void {
        _ = trigger; // poll(2) is level-triggered; the drain pumps make this correct
        if (self.n >= self.fds.len) return error.TooManyFds;
        self.fds[self.n] = .{ .fd = fd, .events = system.POLL.IN, .revents = 0 };
        self.n += 1;
    }

    /// Block until at least one fd is ready (or `timeout_ms` elapses), write the
    /// ready fds into `out`, and return the count (bounded by `out.len`). A
    /// negative `timeout_ms` blocks forever; `0` polls without blocking; otherwise
    /// it caps the wait so the reactor can fire a due keepalive (issue #96). On a
    /// finite deadline EINTR returns 0 (a spurious wake; the caller recomputes the
    /// deadline and its clock-gated keepalive self-corrects); an infinite wait
    /// retries on EINTR as before. poll(2) already takes a millisecond timeout.
    pub fn wait(self: *Poller, out: []sys.fd_t, timeout_ms: i32) !usize {
        while (true) {
            const rc = system.poll(&self.fds, @intCast(self.n), timeout_ms);
            const e = sys.errno(rc);
            if (e == .INTR) {
                if (timeout_ms < 0) continue;
                return 0;
            }
            if (e != .SUCCESS) return error.PollFailed;
            var count: usize = 0;
            var i: usize = 0;
            while (i < self.n and count < out.len) : (i += 1) {
                if (self.fds[i].revents != 0) {
                    out[count] = self.fds[i].fd;
                    count += 1;
                }
            }
            return count;
        }
    }
};
