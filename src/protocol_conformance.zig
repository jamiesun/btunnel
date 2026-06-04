//! Wire-protocol drift sentinel.
//!
//! Pins the committed golden `tests/protocol-vectors.json` against the live
//! protocol code. The golden is regenerated *from* the code (`zig build
//! vectors`), so this test does not just recompute-and-agree-with-itself: it
//! re-renders the JSON from the current `crypto.zig`/`reactor.zig` and asserts
//! it is byte-for-byte identical to the committed file.
//!
//! Therefore any change to a wire constant, KDF label, byte order, header
//! layout, or AEAD parameter moves the rendered bytes and FAILS here — forcing
//! a deliberate `zig build vectors > tests/protocol-vectors.json` regeneration
//! and a bump of the documented `wire_version` when the change is not backward
//! compatible. This is the contract every other implementation (other OS, other
//! language) must hold to interoperate.

const std = @import("std");
const vectors = @import("protocol_vectors.zig");

const GOLDEN = @embedFile("protocol_golden");

test "golden protocol vectors match the live wire implementation" {
    var buf: [64 * 1024]u8 = undefined;
    const rendered = try vectors.writeJson(&buf);
    std.testing.expectEqualStrings(GOLDEN, rendered) catch |err| {
        std.debug.print(
            "\nPROTOCOL DRIFT: tests/protocol-vectors.json no longer matches the code.\n" ++
                "If this change is intentional, regenerate the golden with:\n" ++
                "    zig build vectors > tests/protocol-vectors.json\n" ++
                "and, if the wire format changed incompatibly, bump wire_version in\n" ++
                "docs/PROTOCOL.md and reactor.WIRE_VERSION.\n\n",
            .{},
        );
        return err;
    };
}
