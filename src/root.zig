//! BTunnel core library.
//!
//! Re-exports every internal module so that the daemon (`main.zig`) and the
//! control tool (`ptctl.zig`) share a single compiled module. Keeping the
//! `@import`s here also makes every module's `test` block reachable from
//! `zig build test`.

pub const config = @import("config.zig");
pub const policy = @import("policy.zig");
pub const crypto = @import("crypto.zig");
pub const tun = @import("tun.zig");
pub const peer = @import("peer.zig");
pub const reactor = @import("reactor.zig");
pub const uds = @import("uds.zig");
pub const netplan = @import("netplan.zig");
pub const stats = @import("stats.zig");
pub const protocol_vectors = @import("protocol_vectors.zig");
pub const protocol_conformance = @import("protocol_conformance.zig");

test {
    // Pull in every submodule's test blocks.
    @import("std").testing.refAllDecls(@This());
}
