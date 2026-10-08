const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "zg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zg").dependOn(&run.step);

    // The library, for other packages: `b.dependency("zg", .{}).module("zg")`.
    const zg_mod = b.addModule("zg", .{
        .root_source_file = b.path("src/zg.zig"),
        .target = target,
        .optimize = optimize,
    });

    // In-process benchmark of the core: `zig build bench -- FILE PATTERN [options]`.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zg", .module = zg_mod }},
        }),
    });
    b.installArtifact(bench);
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run the in-process benchmark").dependOn(&bench_run.step);

    // Concurrent searches on one engine: `zig build stress -- BIG_FILE SMALL_FILE`.
    const stress = b.addExecutable(.{
        .name = "stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/stress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zg", .module = zg_mod }},
        }),
    });
    b.installArtifact(stress);
    const stress_run = b.addRunArtifact(stress);
    if (b.args) |args| stress_run.addArgs(args);
    b.step("stress", "Run concurrent searches on one engine").dependOn(&stress_run.step);

    // Corpus generator and the zg-vs-ripgrep comparison driver (`zig build gen -- DIR`,
    // `zig build compare -- --dir DIR`).
    for ([_][]const u8{ "gen", "compare" }) |name| {
        const tool = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("bench/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(tool);
        const tool_run = b.addRunArtifact(tool);
        if (b.args) |args| tool_run.addArgs(args);
        b.step(name, b.fmt("Run bench/{s}.zig", .{name})).dependOn(&tool_run.step);
    }

    // Tests keep runtime safety checks (overflow, bounds, ...) on, unlike the release binary.
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimization mode for tests (default: ReleaseSafe)") orelse .ReleaseSafe;
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
        }),
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
