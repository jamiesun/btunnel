//! Portable raw-syscall layer.
//!
//! `std.os.linux.*` emits raw Linux syscall *numbers*; on XNU (macOS) those
//! dispatch to unrelated calls, so the daemon "runs" but corrupts immediately
//! (issue #73). This module routes the portable syscalls through
//! `std.posix.system` — the libc-compatible layer that is `std.c` on macOS and
//! `std.os.linux` on Linux — so the config / UDP data plane / UDS control plane
//! speak the correct ABI on both platforms. Types and constants come from
//! `std.posix.*`, which selects the right per-OS layout (`sockaddr.in` carries
//! the BSD `len` byte on macOS, etc.).
//!
//! Zero third-party dependencies (iron law #1): this is our own thin wrapper
//! over the standard library. The genuinely Linux-only primitives — `epoll`,
//! `/dev/net/tun` + `TUNSETIFF`, and the capability/`prctl` model — are **not**
//! here; they live behind the OS backend (`src/os/`) or are guarded inline.
//!
//! Call-site convention is unchanged from the old `linux.*` style: invoke the
//! syscall, then classify the result with `sys.errno(rc)` (which takes
//! `anytype` and decodes the native per-OS representation), then `@intCast(rc)`
//! the success value. `errno` must be read immediately after the call.

const std = @import("std");
const builtin = @import("builtin");

/// The libc-compatible syscall layer: `std.c` on macOS, `std.os.linux` on Linux.
pub const system = std.posix.system;

/// Per-OS errno decoder (handles the `-errno` return on Linux and the
/// `-1` + thread-local `errno` convention on macOS).
pub const errno = std.posix.errno;
pub const E = std.posix.E;

// ---- types (per-OS layout, selected by std.posix) ----
pub const fd_t = std.posix.fd_t;
pub const socket_t = std.posix.socket_t;
pub const socklen_t = std.posix.socklen_t;
pub const sockaddr = std.posix.sockaddr;
pub const timespec = std.posix.timespec;

// ---- constants ----
pub const AF = std.posix.AF;
pub const SOCK = std.posix.SOCK;
pub const O = std.posix.O;
pub const F = std.posix.F;
pub const MSG = std.posix.MSG;
pub const CLOCK = std.posix.CLOCK;
pub const FD_CLOEXEC = std.posix.FD_CLOEXEC;
pub const AT = std.posix.AT;
pub const POLL = std.posix.POLL;
pub const mode_t = std.posix.mode_t;
pub const pollfd = std.posix.pollfd;
pub const Stat = std.posix.Stat;

// ---- portable syscalls without a high-level std.posix wrapper ----
// Re-exported from the libc-compatible layer; same calling convention the tree
// already used with `linux.*`.
pub const close = system.close;
pub const bind = system.bind;
pub const fcntl = system.fcntl;
pub const getsockname = system.getsockname;
pub const unlink = system.unlink;
pub const getpid = system.getpid;
pub const clock_gettime = system.clock_gettime;
pub const fsync = system.fsync;
pub const fchmod = system.fchmod;
pub const chmod = system.chmod;
pub const rename = system.rename;
pub const poll = system.poll;
pub const nanosleep = system.nanosleep;

/// Read the permission bits (`st_mode & 0o7777`) of the filesystem node at
/// NUL-terminated `path`. Deliberately path-based, not fd-based: on macOS an
/// `fstat` of a bound AF_UNIX socket fd reports the in-kernel socket object's
/// mode (always `0666`) rather than the on-disk node, and the raw Linux syscall
/// layer exposes only `statx`, not `fstat`. Used to assert the control socket is
/// owner-only.
pub fn statMode(path: [*:0]const u8) error{StatFailed}!u16 {
    if (builtin.os.tag == .linux) {
        var sx: system.Statx = undefined;
        const rc = system.statx(AT.FDCWD, path, 0, .{ .MODE = true }, &sx);
        if (errno(rc) != .SUCCESS) return error.StatFailed;
        return @intCast(sx.mode & 0o7777);
    } else {
        var st: Stat = undefined;
        const rc = system.fstatat(AT.FDCWD, path, &st, 0);
        if (errno(rc) != .SUCCESS) return error.StatFailed;
        return @intCast(st.mode & 0o7777);
    }
}

pub const OpenError = std.posix.OpenError;
/// Portable `open(2)` returning a raw fd or the standard error set. Used for the
/// durable snapshot temp-file write and snapshot read-back.
pub fn openZ(path: [*:0]const u8, flags: O, perm: mode_t) OpenError!fd_t {
    return std.posix.openatZ(AT.FDCWD, path, flags, perm);
}

/// Set the process file-creation mask, returning the previous value. Linux has
/// no high-level wrapper (raw `umask` syscall); macOS uses the libc function.
pub fn umask(mode: mode_t) mode_t {
    if (builtin.os.tag == .linux) {
        return @intCast(std.os.linux.syscall1(.umask, @as(usize, mode)));
    }
    return system.umask(mode);
}

/// Best-effort directory creation for the control-socket runtime dir (e.g.
/// `/run/subnetra`). A single level only — the parent (`/run`) is expected to
/// exist. Linux goes through the raw `mkdirat` syscall (portable across arches
/// that lack a bare `mkdir`, e.g. arm64); macOS uses libc. The result is meant
/// to be ignored: an already-present dir (EEXIST, e.g. created by systemd's
/// `RuntimeDirectory`) is the normal case.
pub fn mkdir(path: [*:0]const u8, mode: mode_t) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.mkdirat(AT.FDCWD, path, @intCast(mode));
    } else {
        _ = system.mkdir(path, mode);
    }
}

// The buffer-taking calls differ in pointer type between layers (`std.c` uses
// `*anyopaque`; `std.os.linux` uses `[*]u8`). Thin inline wrappers keep the
// existing `(fd, ptr, len, ...)` call shape and `@ptrCast` for the libc layer,
// with zero overhead (inlined, no allocation — safe on the data-plane line).

const ReadRet = @TypeOf(system.read(@as(fd_t, undefined), @as([*]u8, undefined), @as(usize, undefined)));
pub inline fn read(fd: fd_t, buf: [*]u8, count: usize) ReadRet {
    return system.read(fd, @ptrCast(buf), count);
}

const WriteRet = @TypeOf(system.write(@as(fd_t, undefined), @as([*]const u8, undefined), @as(usize, undefined)));
pub inline fn write(fd: fd_t, buf: [*]const u8, count: usize) WriteRet {
    return system.write(fd, @ptrCast(buf), count);
}

const SendtoRet = @TypeOf(system.sendto(@as(fd_t, undefined), @as([*]const u8, undefined), @as(usize, undefined), @as(u32, undefined), @as(?*const sockaddr, undefined), @as(socklen_t, undefined)));
pub inline fn sendto(fd: fd_t, buf: [*]const u8, len: usize, flags: u32, dest: ?*const sockaddr, addrlen: socklen_t) SendtoRet {
    return system.sendto(fd, @ptrCast(buf), len, @intCast(flags), dest, addrlen);
}

const RecvfromRet = @TypeOf(system.recvfrom(@as(fd_t, undefined), @as([*]u8, undefined), @as(usize, undefined), @as(u32, undefined), @as(?*sockaddr, undefined), @as(?*socklen_t, undefined)));
pub inline fn recvfrom(fd: fd_t, buf: [*]u8, len: usize, flags: u32, src: ?*sockaddr, addrlen: ?*socklen_t) RecvfromRet {
    return system.recvfrom(fd, @ptrCast(buf), len, @intCast(flags), src, addrlen);
}

const SetsockoptRet = @TypeOf(system.setsockopt(@as(fd_t, undefined), @as(i32, undefined), @as(u32, undefined), @as([*]const u8, undefined), @as(socklen_t, undefined)));
pub inline fn setsockopt(fd: fd_t, level: i32, optname: u32, optval: [*]const u8, optlen: socklen_t) SetsockoptRet {
    return system.setsockopt(fd, level, optname, @ptrCast(optval), optlen);
}

/// `O_NONBLOCK` as the raw flag word fcntl(F_SETFL) expects.
pub fn nonblockBit() usize {
    return @as(u32, @bitCast(O{ .NONBLOCK = true }));
}

/// Third argument type of `fcntl(2)`: Linux's `std.os.linux.fcntl` is fixed-arity
/// (`arg: usize`), while macOS exposes the C-variadic `fcntl` which resolves the
/// integer flag argument as `c_int`.
const FcntlArg = if (builtin.os.tag == .linux) usize else c_int;

/// Put `fd` into non-blocking mode via fcntl (portable; Linux's `SOCK_NONBLOCK`
/// type bit is rejected by the macOS `socket(2)`).
pub fn setNonblock(fd: fd_t) error{FcntlFailed}!void {
    const cur = fcntl(fd, F.GETFL, @as(FcntlArg, 0));
    if (errno(cur) != .SUCCESS) return error.FcntlFailed;
    const flags: FcntlArg = @intCast(@as(usize, @intCast(cur)) | nonblockBit());
    const rc = fcntl(fd, F.SETFL, flags);
    if (errno(rc) != .SUCCESS) return error.FcntlFailed;
}

/// Set the close-on-exec flag on `fd` via fcntl (macOS `socket(2)` rejects the
/// Linux `SOCK_CLOEXEC` type bit, so it is applied here).
pub fn setCloexec(fd: fd_t) error{FcntlFailed}!void {
    const cur = fcntl(fd, F.GETFD, @as(FcntlArg, 0));
    if (errno(cur) != .SUCCESS) return error.FcntlFailed;
    const flags: FcntlArg = @intCast(@as(usize, @intCast(cur)) | @as(usize, FD_CLOEXEC));
    const rc = fcntl(fd, F.SETFD, flags);
    if (errno(rc) != .SUCCESS) return error.FcntlFailed;
}

pub const SocketError = error{ SocketFailed, FcntlFailed };

/// Create a socket and apply non-blocking / close-on-exec **portably**.
///
/// Linux folds these into the `socket(2)` type argument
/// (`SOCK_NONBLOCK`/`SOCK_CLOEXEC`); macOS's BSD `socket(2)` rejects those bits
/// (`EPROTONOSUPPORT`), so they are applied with follow-up `fcntl` calls. The
/// kernel-atomic Linux path is preserved; macOS takes the two-step path.
pub fn socket(domain: u32, sock_type: u32, protocol: u32, nonblock: bool, cloexec: bool) SocketError!fd_t {
    var t = sock_type;
    if (builtin.os.tag == .linux) {
        if (nonblock) t |= SOCK.NONBLOCK;
        if (cloexec) t |= SOCK.CLOEXEC;
    }
    const rc = system.socket(domain, t, protocol);
    if (errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: fd_t = @intCast(rc);
    if (builtin.os.tag != .linux) {
        if (nonblock) setNonblock(fd) catch {
            _ = close(fd);
            return error.FcntlFailed;
        };
        if (cloexec) setCloexec(fd) catch {
            _ = close(fd);
            return error.FcntlFailed;
        };
    }
    return fd;
}

/// Create a non-blocking, close-on-exec pipe portably (Linux `pipe2`; macOS
/// `pipe` + `fcntl`). Used by the host test harness.
pub fn pipeNonblock() error{ PipeFailed, FcntlFailed }![2]fd_t {
    var fds: [2]fd_t = undefined;
    if (builtin.os.tag == .linux) {
        const rc = system.pipe2(&fds, O{ .NONBLOCK = true });
        if (errno(rc) != .SUCCESS) return error.PipeFailed;
        return fds;
    }
    const rc = system.pipe(&fds);
    if (errno(rc) != .SUCCESS) return error.PipeFailed;
    try setNonblock(fds[0]);
    try setNonblock(fds[1]);
    return fds;
}

test "sys: errno decodes a successful call" {
    const fd = try socket(AF.INET, SOCK.DGRAM, 0, true, true);
    defer _ = close(fd);
    try std.testing.expect(fd >= 0);
}

test "sys: setsockopt applies a socket option through the portable layer" {
    const fd = try socket(AF.INET, SOCK.DGRAM, 0, true, true);
    defer _ = close(fd);
    var on: i32 = 1;
    const rc = setsockopt(
        fd,
        @intCast(std.posix.SOL.SOCKET),
        @intCast(std.posix.SO.REUSEADDR),
        std.mem.asBytes(&on),
        @sizeOf(i32),
    );
    try std.testing.expectEqual(E.SUCCESS, errno(rc));
}
