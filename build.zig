const std = @import("std");

// Single source of truth for the release version: `build.zig.zon`'s `.version`.
// It is injected into the daemon banner via the `build_options` module below,
// so the string is never duplicated in source. Bump it there before tagging
// (see AGENT.md §6).
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Expose the package version to the daemon as `@import("build_options")`.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
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
    const core = b.addModule("subnetra", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    // The wire-protocol golden lives under tests/ (human-visible, diffable) but
    // is outside the module's package path, so expose it as an embeddable import
    // for the conformance sentinel (`src/protocol_conformance.zig`).
    core.addAnonymousImport("protocol_golden", .{
        .root_source_file = b.path("tests/protocol-vectors.json"),
    });

    // subnetrad: the single-threaded epoll reactor daemon.
    const subnetrad = b.addExecutable(.{
        .name = "subnetrad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "subnetra", .module = core },
            },
        }),
    });
    b.installArtifact(subnetrad);
    subnetrad.root_module.addOptions("build_options", build_options);

    // subnetra: the lightweight UDS control client.
    const subnetra = b.addExecutable(.{
        .name = "subnetra",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/subnetra.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "subnetra", .module = core },
            },
        }),
    });
    b.installArtifact(subnetra);
    subnetra.root_module.addOptions("build_options", build_options);

    // gen-vectors: emits the canonical wire-protocol KAT set as JSON. Used to
    // (re)generate the committed golden `tests/protocol-vectors.json`, which the
    // conformance test pins against the live protocol code.
    const gen_vectors = b.addExecutable(.{
        .name = "gen-vectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_vectors.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vectors_step = b.step("vectors", "Print the wire-protocol conformance vectors (JSON) to stdout");
    const vectors_run = b.addRunArtifact(gen_vectors);
    vectors_step.dependOn(&vectors_run.step);

    // ------------------------------------------------------------------
    // tools/: out-of-tree auxiliary utilities (issue #57). Each tool is a
    // standalone executable exposed via its own `tool:<name>` step and is
    // **never** part of the default `zig build` install, so a bare `zig build`
    // keeps shipping only `subnetrad` + `subnetra` and the static-size budget is
    // untouched. Building a tool explicitly drops its binary under
    // `zig-out/tools/`. Tools MAY import the `subnetra` core module to reuse
    // config / crypto / protocol; the data plane (src/) must NEVER import
    // anything under tools/ — the dependency is strictly one-way.
    const tools_test_step = b.step("tools-test", "Run unit tests for the tools/ utilities");
    const ToolSpec = struct { name: []const u8, src: []const u8, needs_core: bool };
    const tool_specs = [_]ToolSpec{
        .{ .name = "keygen", .src = "tools/keygen.zig", .needs_core = false },
        .{ .name = "config-lint", .src = "tools/config-lint.zig", .needs_core = true },
        .{ .name = "wire-decode", .src = "tools/wire-decode.zig", .needs_core = true },
        .{ .name = "key-derive", .src = "tools/key-derive.zig", .needs_core = true },
        .{ .name = "config-gen", .src = "tools/config-gen.zig", .needs_core = true },
        .{ .name = "crypto-bench", .src = "tools/crypto-bench.zig", .needs_core = true },
    };
    for (tool_specs) |spec| {
        const core_import = [_]std.Build.Module.Import{.{ .name = "subnetra", .module = core }};
        const tool_mod = b.createModule(.{
            .root_source_file = b.path(spec.src),
            .target = target,
            .optimize = optimize,
            .imports = if (spec.needs_core) &core_import else &.{},
        });
        tool_mod.addOptions("build_options", build_options);

        const tool_exe = b.addExecutable(.{ .name = spec.name, .root_module = tool_mod });
        // Install only under the explicit step, into zig-out/tools/ — not the
        // default install step, so `zig build` never ships these.
        const tool_install = b.addInstallArtifact(tool_exe, .{
            .dest_dir = .{ .override = .{ .custom = "tools" } },
        });
        const tool_step = b.step(
            b.fmt("tool:{s}", .{spec.name}),
            b.fmt("Build the {s} tool into zig-out/tools/ (not installed by default)", .{spec.name}),
        );
        tool_step.dependOn(&tool_install.step);

        // Tool unit tests live behind `zig build tools-test`, kept out of the
        // main `test` step so dev-only diagnostics never enter the shipped
        // daemon's verification path.
        const tool_tests = b.addTest(.{ .root_module = tool_mod });
        tools_test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }

    // `zig build run` runs the daemon.
    const run_step = b.step("run", "Run the subnetrad daemon");
    const run_cmd = b.addRunArtifact(subnetrad);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs every `test` block reachable from the core module
    // plus the two executable root modules.
    const test_step = b.step("test", "Run unit tests");

    const core_tests = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const subnetrad_tests = b.addTest(.{ .root_module = subnetrad.root_module });
    test_step.dependOn(&b.addRunArtifact(subnetrad_tests).step);

    const subnetra_tests = b.addTest(.{ .root_module = subnetra.root_module });
    test_step.dependOn(&b.addRunArtifact(subnetra_tests).step);
}
