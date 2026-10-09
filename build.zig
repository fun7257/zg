const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

    // Debug information is left out of the binaries of a release (`-Dstrip`): 4.8 MB to about 0.4.
    const strip = b.option(bool, "strip", "Leave debug information out of zg (default: no)") orelse false;

    // The library, for other packages: `b.dependency("zg", .{}).module("zg")`.
    const zg_mod = b.addModule("zg", .{
        .root_source_file = b.path("src/zg.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
    });

    // The command line tool. Built for an x86-64 CPU without AVX2 (as for distribution), it
    // also carries copies of the core compiled for x86-64-v2 and -v3, and runs the one the
    // CPU it runs on supports (`cpuLevel` in src/main.zig). A copy is the same source in
    // another module: Zig compiles every module for its own target CPU, and a file belongs
    // to one module, hence the copies.
    const x86_below_v3 = target.result.cpu.arch == .x86_64 and !std.Target.x86.featureSetHas(target.result.cpu.features, .avx2);
    const cpu_dispatch = b.option(bool, "cpu-dispatch", "Also build the core for x86-64-v2 and -v3, chosen at run time (default: when the target CPU lacks AVX2)") orelse x86_below_v3;
    const build_options = b.addOptions();
    build_options.addOption(bool, "cpu_dispatch", cpu_dispatch);
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = if (strip) true else null,
        .imports = &.{
            .{ .name = "zg", .module = zg_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
        },
    });
    if (cpu_dispatch) {
        for ([_]struct { []const u8, *const std.Target.Cpu.Model }{
            .{ "zg_v2", &std.Target.x86.cpu.x86_64_v2 },
            .{ "zg_v3", &std.Target.x86.cpu.x86_64_v3 },
        }) |level| {
            const copy = b.addWriteFiles();
            const root = copy.addCopyFile(b.path("src/zg.zig"), b.fmt("{s}/zg.zig", .{level[0]}));
            _ = copy.addCopyFile(b.path("src/search.zig"), b.fmt("{s}/search.zig", .{level[0]}));
            var query = target.query;
            query.cpu_model = .{ .explicit = level[1] };
            query.cpu_features_add = .empty;
            query.cpu_features_sub = .empty;
            exe_mod.addImport(level[0], b.createModule(.{
                .root_source_file = root,
                .target = b.resolveTargetQuery(query),
                .optimize = optimize,
                .strip = if (strip) true else null,
            }));
        }
    }
    const exe = b.addExecutable(.{ .name = "zg", .root_module = exe_mod });

    // `zig build` (the default step) puts zg and the benchmark tools in zig-out/bin, where
    // `compare` looks for zg. `zig build install` is for installing zg itself: only zg,
    // into ~/.local/bin, or into `-Dbin-dir=PATH`.
    const dev = b.step("dev", "Build zg and the benchmark tools into zig-out/bin (the default)");
    b.default_step = dev;
    const dev_dir: std.Build.InstallDir = .{ .custom = "bin" };
    dev.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = dev_dir } }).step);
    const bin_dir = b.option([]const u8, "bin-dir", "Where `zig build install` puts zg (default: ~/.local/bin)") orelse
        if (b.graph.environ_map.get("HOME")) |home| b.pathJoin(&.{ home, ".local", "bin" }) else null;
    b.install_tls.description = "Install zg (only zg) into ~/.local/bin, or -Dbin-dir=PATH";
    if (bin_dir) |dir| {
        b.exe_dir = dir;
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{}).step);
    } else {
        const fail = b.addFail("zig build install: HOME is not set; give the directory with -Dbin-dir=PATH");
        b.getInstallStep().dependOn(&fail.step);
    }

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zg").dependOn(&run.step);

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
    dev.dependOn(&b.addInstallArtifact(bench, .{ .dest_dir = .{ .override = dev_dir } }).step);
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
    dev.dependOn(&b.addInstallArtifact(stress, .{ .dest_dir = .{ .override = dev_dir } }).step);
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
        dev.dependOn(&b.addInstallArtifact(tool, .{ .dest_dir = .{ .override = dev_dir } }).step);
        const tool_run = b.addRunArtifact(tool);
        if (b.args) |args| tool_run.addArgs(args);
        b.step(name, b.fmt("Run bench/{s}.zig", .{name})).dependOn(&tool_run.step);
    }

    // Tests keep runtime safety checks (overflow, bounds, ...) on, unlike the release binary.
    const test_optimize = b.option(std.builtin.OptimizeMode, "test-optimize", "Optimization mode for tests (default: ReleaseSafe)") orelse .ReleaseSafe;
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zg.zig"),
            .target = target,
            .optimize = test_optimize,
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The tests once per x86-64 level that a portable build carries a core for (v1, v2,
    // v3), as far as the build machine runs them: `test` covers only the level it is built
    // for. On other machines this is `test`.
    const levels_step = b.step("test-levels", "Run the unit tests compiled for each x86-64 level (v1, v2, v3) this machine supports");
    const host = b.graph.host.result;
    if (host.cpu.arch == .x86_64) {
        const x86 = std.Target.x86;
        for ([_]struct { *const std.Target.Cpu.Model, []const x86.Feature }{
            .{ &x86.cpu.x86_64, &.{.sse2} },
            .{ &x86.cpu.x86_64_v2, &.{ .cx16, .popcnt, .sahf, .sse4_2 } },
            .{ &x86.cpu.x86_64_v3, &.{ .cx16, .popcnt, .sahf, .sse4_2, .avx2, .bmi, .bmi2, .f16c, .fma, .lzcnt, .movbe, .xsave } },
        }) |level| {
            const supported = for (level[1]) |f| {
                if (!host.cpu.features.isEnabled(@intFromEnum(f))) break false;
            } else true;
            if (!supported) continue;
            const level_tests = b.addTest(.{
                .name = b.fmt("test-{s}", .{level[0].name}),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/zg.zig"),
                    .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = host.os.tag, .abi = host.abi, .cpu_model = .{ .explicit = level[0] } }),
                    .optimize = test_optimize,
                }),
            });
            levels_step.dependOn(&b.addRunArtifact(level_tests).step);
        }
    } else levels_step.dependOn(test_step);
}
