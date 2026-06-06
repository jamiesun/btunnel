//! Single-threaded `__sync_*` builtins for pre-ARMv6 targets (e.g. armv5te /
//! arm926ej_s).
//!
//! Why this exists: ARMv5 has no load-exclusive/store-exclusive (LDREX/STREX)
//! and no kernel-helper-free way to do an atomic read-modify-write, so when the
//! standard library's `std.Io.Threaded` plumbing (Mutex / Condition / Queue) is
//! compiled in, the linker is left with undefined references to the legacy GCC
//! `__sync_*_1` / `__sync_*_4` intrinsics.
//!
//! Why a *plain* (non-atomic) implementation is correct here: Subnetra runs a
//! strictly single-threaded, lock-free reactor (AGENT.md iron law #3 — "No
//! threads. No locks."), and `subnetra` is a one-shot single-threaded client.
//! There is only ever one thread of execution in the process, so no other
//! thread can observe a torn read-modify-write. A sequential RMW by the sole
//! thread is therefore indistinguishable from a hardware-atomic one. (If this
//! binary ever genuinely spawned a second thread, these shims would be unsafe —
//! but doing so would already violate iron law #3.)
//!
//! This file is dependency-free Zig (no libc, no third-party code) and is only
//! pulled into the build for arm targets that lack the v6 feature; see the
//! comptime gate in `main.zig` / `subnetra.zig`.

const std = @import("std");

// GCC `__sync` semantics:
//   __sync_fetch_and_OP(ptr, val)  -> returns the *old* value, stores OP(old,val)
//   __sync_lock_test_and_set(ptr, val) -> returns old, stores val
//   __sync_val_compare_and_swap(ptr, oldval, newval) -> returns the value that
//       was in *ptr; stores newval only if it equalled oldval.

fn fetchAdd(comptime T: type, ptr: *T, val: T) T {
    const old = ptr.*;
    ptr.* = old +% val;
    return old;
}
fn fetchSub(comptime T: type, ptr: *T, val: T) T {
    const old = ptr.*;
    ptr.* = old -% val;
    return old;
}
fn fetchAnd(comptime T: type, ptr: *T, val: T) T {
    const old = ptr.*;
    ptr.* = old & val;
    return old;
}
fn fetchOr(comptime T: type, ptr: *T, val: T) T {
    const old = ptr.*;
    ptr.* = old | val;
    return old;
}
fn fetchXor(comptime T: type, ptr: *T, val: T) T {
    const old = ptr.*;
    ptr.* = old ^ val;
    return old;
}
fn lockTestAndSet(comptime T: type, ptr: *T, val: T) T {
    const old = ptr.*;
    ptr.* = val;
    return old;
}
fn valCompareAndSwap(comptime T: type, ptr: *T, oldval: T, newval: T) T {
    const cur = ptr.*;
    if (cur == oldval) ptr.* = newval;
    return cur;
}

// 4-byte (u32) variants.
export fn __sync_fetch_and_add_4(ptr: *u32, val: u32) callconv(.c) u32 {
    return fetchAdd(u32, ptr, val);
}
export fn __sync_fetch_and_sub_4(ptr: *u32, val: u32) callconv(.c) u32 {
    return fetchSub(u32, ptr, val);
}
export fn __sync_fetch_and_and_4(ptr: *u32, val: u32) callconv(.c) u32 {
    return fetchAnd(u32, ptr, val);
}
export fn __sync_fetch_and_or_4(ptr: *u32, val: u32) callconv(.c) u32 {
    return fetchOr(u32, ptr, val);
}
export fn __sync_fetch_and_xor_4(ptr: *u32, val: u32) callconv(.c) u32 {
    return fetchXor(u32, ptr, val);
}
export fn __sync_lock_test_and_set_4(ptr: *u32, val: u32) callconv(.c) u32 {
    return lockTestAndSet(u32, ptr, val);
}
export fn __sync_val_compare_and_swap_4(ptr: *u32, oldval: u32, newval: u32) callconv(.c) u32 {
    return valCompareAndSwap(u32, ptr, oldval, newval);
}

// 1-byte (u8) variants.
export fn __sync_fetch_and_add_1(ptr: *u8, val: u8) callconv(.c) u8 {
    return fetchAdd(u8, ptr, val);
}
export fn __sync_fetch_and_sub_1(ptr: *u8, val: u8) callconv(.c) u8 {
    return fetchSub(u8, ptr, val);
}
export fn __sync_fetch_and_and_1(ptr: *u8, val: u8) callconv(.c) u8 {
    return fetchAnd(u8, ptr, val);
}
export fn __sync_fetch_and_or_1(ptr: *u8, val: u8) callconv(.c) u8 {
    return fetchOr(u8, ptr, val);
}
export fn __sync_fetch_and_xor_1(ptr: *u8, val: u8) callconv(.c) u8 {
    return fetchXor(u8, ptr, val);
}
export fn __sync_lock_test_and_set_1(ptr: *u8, val: u8) callconv(.c) u8 {
    return lockTestAndSet(u8, ptr, val);
}
export fn __sync_val_compare_and_swap_1(ptr: *u8, oldval: u8, newval: u8) callconv(.c) u8 {
    return valCompareAndSwap(u8, ptr, oldval, newval);
}

/// Pull all `export fn`s into the link by referencing this from a comptime
/// block in the executable roots; `force` is a no-op marker.
pub fn force() void {}
