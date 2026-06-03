const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default to ReleaseSmall per the design doc (≤ 512KB static binary target).
    // Unlike `standardOptimizeOption`, this makes a bare `zig build` (no flags)
    // resolve to ReleaseSmall instead of Debug, while still honoring explicit
    // `-Doptimize=...` and `--release=...` overrides (e.g. `-Doptimize=Debug`
    // for local development).
    const optimize: std.builtin.OptimizeMode = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse switch (b.release_mode) {
        .off, .any, .small => .ReleaseSmall,
        .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
    };

    // Shared core library module: re-exports config / policy / crypto / tun /
    // reactor / uds so both the daemon and the control tool can import it.
    const core = b.addModule("btunnel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // btunnel: the single-threaded epoll reactor daemon.
    const btunnel = b.addExecutable(.{
        .name = "btunnel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "btunnel", .module = core },
            },
        }),
    });
    b.installArtifact(btunnel);

    // ptctl: the lightweight UDS control client.
    const ptctl = b.addExecutable(.{
        .name = "ptctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ptctl.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "btunnel", .module = core },
            },
        }),
    });
    b.installArtifact(ptctl);

    // `zig build run` runs the daemon.
    const run_step = b.step("run", "Run the btunnel daemon");
    const run_cmd = b.addRunArtifact(btunnel);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs every `test` block reachable from the core module
    // plus the two executable root modules.
    const test_step = b.step("test", "Run unit tests");

    const core_tests = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const btunnel_tests = b.addTest(.{ .root_module = btunnel.root_module });
    test_step.dependOn(&b.addRunArtifact(btunnel_tests).step);

    const ptctl_tests = b.addTest(.{ .root_module = ptctl.root_module });
    test_step.dependOn(&b.addRunArtifact(ptctl_tests).step);
}
