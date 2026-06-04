//! `zig build vectors` entry point: emit the canonical KAT set as JSON to
//! stdout. Redirect it to regenerate the committed golden file:
//!
//!     zig build vectors > tests/protocol-vectors.json
//!
//! The golden is pinned against the live protocol code by the conformance test
//! in `src/protocol_conformance.zig`, so regenerating it is the *only* approved
//! way to change the wire vectors — and doing so forces a deliberate review of
//! whatever protocol change made them move.

const std = @import("std");
const vectors = @import("protocol_vectors.zig");

pub fn main(init: std.process.Init) !void {
    var buf: [64 * 1024]u8 = undefined;
    const json = try vectors.writeJson(&buf);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(init.io, json);
}
