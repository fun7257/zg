//! Compares zg with ripgrep by running both as child processes:
//!   zig build compare -- --dir DIR [--zg PATH] [--rg PATH] [--runs N]
//!       [--sections ab,warm,single,small,mem,cold] [--case FILE:PATTERN]... [--filter TEXT]
//!       [--outputs lines,-n,-c] [--zg-b PATH] [--threads N] [--no-verify]
//!       [--fail-regression PERCENT]
//! DIR must hold the corpora written by `zig build gen`. `--case` replaces the default
//! cases; the `ab` section alternates runs of `--zg` and `--zg-b` (on `--threads` threads)
//! instead of comparing with ripgrep, and ends with the geometric mean over its cells;
//! `--fail-regression PERCENT` makes `compare` exit with an error when B is slower than A by
//! more than that on that mean. The `small` section times its own cases (small files,
//! `-m`), where fixed costs weigh, with the CPU time of both tools.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Case = struct { file: []const u8, pattern: []const u8 };

const default_cases = [_]Case{
    .{ .file = "words.txt", .pattern = "needle_zz" },
    .{ .file = "words.txt", .pattern = "qzxjv" },
    .{ .file = "words.txt", .pattern = "zebra" },
    .{ .file = "words.txt", .pattern = "xq" },
    .{ .file = "words.txt", .pattern = "ing " },
    .{ .file = "words.txt", .pattern = "the" },
    .{ .file = "words.txt", .pattern = "a" },
    .{ .file = "log.txt", .pattern = "unique_token_7731" },
    .{ .file = "log.txt", .pattern = "ERROR" },
    .{ .file = "log.txt", .pattern = "latency=1999ms" },
    .{ .file = "log.txt", .pattern = "[auth]" },
    .{ .file = "log.txt", .pattern = "req=0000" },
    .{ .file = "log.txt", .pattern = "/api/v2/items/" },
};

/// Cases in use: `default_cases`, or the ones given with `--case FILE:PATTERN`.
var cases: []const Case = &default_cases;

const Output = enum {
    lines,
    numbered,
    count,

    fn flag(o: Output) ?[]const u8 {
        return switch (o) {
            .lines => null,
            .numbered => "-n",
            .count => "-c",
        };
    }

    fn name(o: Output) []const u8 {
        return switch (o) {
            .lines => "lines",
            .numbered => "-n",
            .count => "-c",
        };
    }
};

const Tool = enum { zg, rg };

const Config = struct {
    dir: []const u8 = "",
    zg: []const u8 = "zig-out/bin/zg",
    rg: []const u8 = "rg",
    runs: usize = 15,
    /// Threads for the `ab` section (0 = default).
    threads: usize = 0,
    sections: []const u8 = "warm,single,small,mem,cold",
    /// Only cases whose file or pattern contains this text (empty: all).
    filter: []const u8 = "",
    /// Which outputs to time: any of `lines`, `-n`, `-c`.
    outputs: []const u8 = "lines,-n,-c",
    /// Second zg build for the `ab` section (runs alternate between `zg` and `zg_b`).
    zg_b: []const u8 = "",
    /// `ab`: fail when B is slower than A by more than this many percent on the geometric
    /// mean of the cells (0: never).
    fail_regression: f64 = 0,
    /// Skip the check that zg and rg print the same (for experimental builds of zg).
    verify: bool = true,
};

const capture_allocator = std.heap.page_allocator;

const Sample = struct {
    wall_ms: f64,
    cpu_ms: f64,
    max_rss_mb: f64,
};

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    cfg: Config,

    fn selected(c: Ctx, cs: Case) bool {
        return c.cfg.filter.len == 0 or std.mem.indexOf(u8, cs.file, c.cfg.filter) != null or std.mem.indexOf(u8, cs.pattern, c.cfg.filter) != null;
    }

    fn path(c: Ctx, file: []const u8) ![]u8 {
        return std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ c.cfg.dir, file });
    }

    /// argv for one run of `tool`; `threads` 0 = default.
    fn argv(c: Ctx, list: *std.ArrayList([]const u8), tool: Tool, out: Output, threads: usize, extra: []const []const u8, pattern: []const u8, file: []const u8) !void {
        switch (tool) {
            .zg => try list.append(c.gpa, c.cfg.zg),
            .rg => try list.appendSlice(c.gpa, &.{ c.cfg.rg, "-a", "-F", "--no-config" }),
        }
        if (out.flag()) |f| try list.append(c.gpa, f);
        if (threads != 0) try list.appendSlice(c.gpa, &.{ "-j", try std.fmt.allocPrint(c.gpa, "{d}", .{threads}) });
        try list.appendSlice(c.gpa, extra);
        try list.appendSlice(c.gpa, &.{ "--", pattern, file });
    }

    fn run(c: Ctx, args: []const []const u8) !Sample {
        const start = Io.Timestamp.now(c.io, .awake);
        var child = try std.process.spawn(c.io, .{
            .argv = args,
            .stdout = .ignore,
            .stderr = .ignore,
            .request_resource_usage_statistics = true,
        });
        _ = try child.wait(c.io);
        const wall = start.durationTo(Io.Timestamp.now(c.io, .awake)).nanoseconds;
        const ru = child.resource_usage_statistics.rusage.?;
        const cpu_us = @as(i64, ru.utime.sec + ru.stime.sec) * 1_000_000 + ru.utime.usec + ru.stime.usec;
        return .{
            .wall_ms = @as(f64, @floatFromInt(wall)) / 1e6,
            .cpu_ms = @as(f64, @floatFromInt(cpu_us)) / 1e3,
            .max_rss_mb = @as(f64, @floatFromInt(child.resource_usage_statistics.getMaxRss() orelse 0)) / (1 << 20),
        };
    }

    /// Median wall time (and the matching CPU time) over `runs` runs after one warm-up.
    fn measure(c: Ctx, args: []const []const u8, runs: usize) !Sample {
        _ = try c.run(args);
        const samples = try c.gpa.alloc(Sample, runs);
        defer c.gpa.free(samples);
        for (samples) |*s| s.* = try c.run(args);
        std.mem.sort(Sample, samples, {}, struct {
            fn less(_: void, a: Sample, b: Sample) bool {
                return a.wall_ms < b.wall_ms;
            }
        }.less);
        return samples[samples.len / 2];
    }

    /// Runs `args` and returns everything it wrote to stdout, allocated with
    /// `capture_allocator` (free it with that). Not in the arena: outputs of hundreds of MB
    /// would stay, and a large parent makes every child slower to start and inflates its
    /// peak RSS on Linux, which counts what the process had before `exec`.
    fn capture(c: Ctx, args: []const []const u8) ![]u8 {
        var child = try std.process.spawn(c.io, .{ .argv = args, .stdout = .pipe, .stderr = .ignore });
        var buf: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(c.io, &buf);
        const text = try reader.interface.allocRemaining(capture_allocator, .unlimited);
        _ = try child.wait(c.io);
        return text;
    }

    /// Median runs of `a` and `b`, alternating between them (after one warm-up each) so
    /// that drift in the machine's state affects both alike.
    fn measurePair(c: Ctx, a: []const []const u8, b: []const []const u8, runs: usize) ![2]Sample {
        _ = try c.run(a);
        _ = try c.run(b);
        const sa = try c.gpa.alloc(Sample, runs);
        defer c.gpa.free(sa);
        const sb = try c.gpa.alloc(Sample, runs);
        defer c.gpa.free(sb);
        for (0..runs) |k| {
            sa[k] = try c.run(a);
            sb[k] = try c.run(b);
        }
        const by_wall = struct {
            fn less(_: void, x: Sample, y: Sample) bool {
                return x.wall_ms < y.wall_ms;
            }
        }.less;
        std.mem.sort(Sample, sa, {}, by_wall);
        std.mem.sort(Sample, sb, {}, by_wall);
        return .{ sa[runs / 2], sb[runs / 2] };
    }

    /// Peak memory in MB: the footprint reported by `/usr/bin/time -l` on macOS, the peak
    /// RSS from `wait4` elsewhere (which includes the pages of the file mapping touched).
    fn footprint(c: Ctx, args: []const []const u8) !f64 {
        if (!builtin.os.tag.isDarwin()) return (try c.run(args)).max_rss_mb;
        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(c.gpa);
        try list.appendSlice(c.gpa, &.{ "/usr/bin/time", "-l" });
        try list.appendSlice(c.gpa, args);
        var child = try std.process.spawn(c.io, .{ .argv = list.items, .stdout = .ignore, .stderr = .pipe });
        var buf: [4096]u8 = undefined;
        var reader = child.stderr.?.readerStreaming(c.io, &buf);
        const text = try reader.interface.allocRemaining(c.gpa, .limited(1 << 20));
        defer c.gpa.free(text);
        _ = try child.wait(c.io);
        const key = "peak memory footprint";
        const at = std.mem.indexOf(u8, text, key) orelse return error.NoFootprint;
        const line_start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |i| i + 1 else 0;
        const bytes = try std.fmt.parseInt(u64, std.mem.trim(u8, text[line_start..at], " \t"), 10);
        return @as(f64, @floatFromInt(bytes)) / (1 << 20);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    var cfg: Config = .{};
    var extra_cases: std.ArrayList(Case) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--case")) {
            if (i + 1 >= argv.len) return error.MissingValue;
            i += 1;
            const colon = std.mem.indexOfScalar(u8, argv[i], ':') orelse return error.BadCase;
            try extra_cases.append(gpa, .{ .file = argv[i][0..colon], .pattern = argv[i][colon + 1 ..] });
            continue;
        }
        if (std.mem.eql(u8, a, "--no-verify")) {
            cfg.verify = false;
            continue;
        }
        if (i + 1 >= argv.len) return error.MissingValue;
        i += 1;
        if (std.mem.eql(u8, a, "--dir")) cfg.dir = argv[i] else if (std.mem.eql(u8, a, "--zg")) cfg.zg = argv[i] else if (std.mem.eql(u8, a, "--rg")) cfg.rg = argv[i] else if (std.mem.eql(u8, a, "--runs")) cfg.runs = try std.fmt.parseInt(usize, argv[i], 10) else if (std.mem.eql(u8, a, "--threads")) cfg.threads = try std.fmt.parseInt(usize, argv[i], 10) else if (std.mem.eql(u8, a, "--sections")) cfg.sections = argv[i] else if (std.mem.eql(u8, a, "--zg-b")) cfg.zg_b = argv[i] else if (std.mem.eql(u8, a, "--filter")) cfg.filter = argv[i] else if (std.mem.eql(u8, a, "--outputs")) cfg.outputs = argv[i] else if (std.mem.eql(u8, a, "--fail-regression")) cfg.fail_regression = try std.fmt.parseFloat(f64, argv[i]) else return error.UnknownOption;
    }
    if (extra_cases.items.len != 0) cases = extra_cases.items;
    if (cfg.dir.len == 0) {
        std.debug.print("usage: compare --dir DIR [--zg PATH] [--rg PATH] [--runs N] [--sections ab,warm,single,small,mem,cold] [--case FILE:PATTERN]... [--filter TEXT] [--outputs lines,-n,-c] [--zg-b PATH] [--threads N] [--no-verify] [--fail-regression PERCENT]\n", .{});
        return error.BadArgument;
    }
    const c: Ctx = .{ .io = io, .gpa = gpa, .cfg = cfg };

    std.debug.print("# zg vs ripgrep\n\nruns per cell: {d} (median wall time, zg and rg alternating, after one warm-up); cores: {d}\n", .{ cfg.runs, std.Thread.getCpuCount() catch 1 });
    if (cfg.verify) try verify(c);
    if (has(cfg.sections, "ab")) try compareBuilds(c);
    if (has(cfg.sections, "warm")) try timing(c, "Warm cache, all cores", 0);
    if (has(cfg.sections, "single")) try timing(c, "Warm cache, one thread (-j 1 for both)", 1);
    if (has(cfg.sections, "small")) try small(c);
    if (has(cfg.sections, "mem")) try memory(c);
    if (has(cfg.sections, "cold")) try cold(c);
}

/// Both tools must print exactly the same thing, or the timings compare different work.
fn verify(c: Ctx) !void {
    var checked: usize = 0;
    for (cases) |cs| {
        const file = try c.path(cs.file);
        for ([_]Output{ .lines, .numbered, .count }) |out| {
            var zl: std.ArrayList([]const u8) = .empty;
            var rl: std.ArrayList([]const u8) = .empty;
            try c.argv(&zl, .zg, out, 0, &.{}, cs.pattern, file);
            try c.argv(&rl, .rg, out, 0, &.{}, cs.pattern, file);
            const z = try c.capture(zl.items);
            const r = try c.capture(rl.items);
            // `rg -c` prints nothing when there is no match, zg prints 0.
            const same = std.mem.eql(u8, z, r) or (out == .count and r.len == 0 and std.mem.eql(u8, z, "0\n"));
            if (!same) {
                std.debug.print("OUTPUT MISMATCH: {s} {s} {s} ({d} vs {d} bytes)\n", .{ cs.file, cs.pattern, out.name(), z.len, r.len });
                return error.OutputMismatch;
            }
            capture_allocator.free(z);
            capture_allocator.free(r);
            checked += 1;
        }
    }
    std.debug.print("\noutput verified identical to rg for all {d} cases\n", .{checked});
}

/// Alternates runs of two zg builds so that machine noise (other processes, frequency
/// changes) hits both alike; prints median and minimum wall time of each.
fn compareBuilds(c: Ctx) !void {
    std.debug.print("\n## A/B: `{s}` (A) vs `{s}` (B), alternating runs\n\n| file | pattern | output | A median | B median | A min | B min | B vs A (median) |\n|---|---|---|---|---|---|---|---|\n", .{ c.cfg.zg, c.cfg.zg_b });
    var ratios: std.ArrayList(f64) = .empty;
    for (cases) |cs| {
        if (!c.selected(cs)) continue;
        const file = try c.path(cs.file);
        for ([_]Output{ .lines, .numbered, .count }) |out| {
            if (!has(c.cfg.outputs, out.name())) continue;
            var a_args: std.ArrayList([]const u8) = .empty;
            var b_args: std.ArrayList([]const u8) = .empty;
            try c.argv(&a_args, .zg, out, c.cfg.threads, &.{}, cs.pattern, file);
            var cb = c;
            cb.cfg.zg = c.cfg.zg_b;
            try cb.argv(&b_args, .zg, out, c.cfg.threads, &.{}, cs.pattern, file);
            _ = try c.run(a_args.items);
            _ = try c.run(b_args.items);
            const a = try c.gpa.alloc(f64, c.cfg.runs);
            const b = try c.gpa.alloc(f64, c.cfg.runs);
            for (0..c.cfg.runs) |k| {
                a[k] = (try c.run(a_args.items)).wall_ms;
                b[k] = (try c.run(b_args.items)).wall_ms;
            }
            std.mem.sort(f64, a, {}, std.sort.asc(f64));
            std.mem.sort(f64, b, {}, std.sort.asc(f64));
            std.debug.print("| {s} | `{s}` | {s} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.2}x |\n", .{
                cs.file, cs.pattern, out.name(), a[a.len / 2], b[b.len / 2], a[0], b[0], a[a.len / 2] / b[b.len / 2],
            });
            try ratios.append(c.gpa, a[a.len / 2] / b[b.len / 2]);
        }
    }
    if (ratios.items.len == 0) return;
    // B vs A over all cells: above 1, B is faster.
    std.mem.sort(f64, ratios.items, {}, std.sort.asc(f64));
    var log_sum: f64 = 0;
    for (ratios.items) |r| log_sum += @log(r);
    const geo = @exp(log_sum / @as(f64, @floatFromInt(ratios.items.len)));
    const slower_by = (1 / geo - 1) * 100;
    var worse: usize = 0;
    for (ratios.items) |r| worse += @intFromBool(r < 0.95);
    std.debug.print("\nB vs A over {d} cells: geometric mean {d:.3}x ({s} {d:.1} %), median {d:.3}x, worst {d:.2}x, best {d:.2}x; {d} cells more than 5 % slower\n", .{
        ratios.items.len,                                        geo,
        if (slower_by > 0) "B slower by" else "B faster by",     @abs(slower_by),
        ratios.items[ratios.items.len / 2],                      ratios.items[0],
        ratios.items[ratios.items.len - 1],                      worse,
    });
    if (c.cfg.fail_regression > 0 and slower_by > c.cfg.fail_regression) {
        std.debug.print("REGRESSION: B is {d:.1} % slower than A on the geometric mean (limit {d:.1} %)\n", .{ slower_by, c.cfg.fail_regression });
        return error.Regression;
    }
}

fn has(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

fn timing(c: Ctx, title: []const u8, threads: usize) !void {
    std.debug.print("\n## {s}\n\n| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |\n|---|---|---|---|---|---|---|---|---|\n", .{title});
    var speedups: std.ArrayList(f64) = .empty;
    var cpu_log_sum: f64 = 0; // log of zg CPU over rg CPU, per cell
    for (cases) |cs| {
        if (!c.selected(cs)) continue;
        const file = try c.path(cs.file);
        var count_args: std.ArrayList([]const u8) = .empty;
        try c.argv(&count_args, .zg, .count, 0, &.{}, cs.pattern, file);
        const count_text = try c.capture(count_args.items);
        defer capture_allocator.free(count_text);
        const lines = std.mem.trim(u8, count_text, "\n");
        for ([_]Output{ .lines, .numbered, .count }) |out| {
            if (!has(c.cfg.outputs, out.name())) continue;
            var zl: std.ArrayList([]const u8) = .empty;
            var rl: std.ArrayList([]const u8) = .empty;
            try c.argv(&zl, .zg, out, threads, &.{}, cs.pattern, file);
            try c.argv(&rl, .rg, out, threads, &.{}, cs.pattern, file);
            const zr = try c.measurePair(zl.items, rl.items, c.cfg.runs);
            const z = zr[0];
            const r = zr[1];
            try speedups.append(c.gpa, r.wall_ms / z.wall_ms);
            cpu_log_sum += @log(@max(z.cpu_ms, 0.1) / @max(r.cpu_ms, 0.1));
            std.debug.print("| {s} | `{s}` | {s} | {s} | {d:.1} | {d:.1}x | {d:.1} | {d:.1}x | {d:.2}x |\n", .{
                cs.file,               cs.pattern,           lines,     out.name(),
                z.wall_ms,             z.cpu_ms / z.wall_ms, r.wall_ms, r.cpu_ms / r.wall_ms,
                r.wall_ms / z.wall_ms,
            });
        }
    }
    if (speedups.items.len == 0) return;
    std.mem.sort(f64, speedups.items, {}, std.sort.asc(f64));
    var log_sum: f64 = 0;
    for (speedups.items) |s| log_sum += @log(s);
    std.debug.print("\nspeedup over {d} cells: min {d:.2}x, median {d:.2}x, geometric mean {d:.2}x, max {d:.2}x\n", .{
        speedups.items.len,
        speedups.items[0],
        speedups.items[speedups.items.len / 2],
        @exp(log_sum / @as(f64, @floatFromInt(speedups.items.len))),
        speedups.items[speedups.items.len - 1],
    });
    std.debug.print("CPU time, zg over rg: geometric mean {d:.2}x\n", .{@exp(cpu_log_sum / @as(f64, @floatFromInt(speedups.items.len)))});
}

/// Cases where fixed costs weigh: small files and `-m` (all cores, default settings).
const small_cases = [_]struct { file: []const u8, pattern: []const u8, flags: []const []const u8 }{
    .{ .file = "w1m.txt", .pattern = "the", .flags = &.{} },
    .{ .file = "w1m.txt", .pattern = "needle_zz", .flags = &.{"-c"} },
    .{ .file = "w8m.txt", .pattern = "the", .flags = &.{} },
    .{ .file = "w8m.txt", .pattern = "needle_zz", .flags = &.{"-c"} },
    .{ .file = "w64m.txt", .pattern = "the", .flags = &.{} },
    .{ .file = "w64m.txt", .pattern = "the", .flags = &.{"-n"} },
    .{ .file = "w64m.txt", .pattern = "needle_zz", .flags = &.{"-c"} },
    .{ .file = "words.txt", .pattern = "the", .flags = &.{ "-m", "1" } },
    .{ .file = "words.txt", .pattern = "zebra", .flags = &.{ "-m", "10" } },
    .{ .file = "log.txt", .pattern = "ERROR", .flags = &.{ "-m", "1000" } },
};

fn small(c: Ctx) !void {
    std.debug.print("\n## Small files and -m (all cores)\n\n| file | pattern | flags | zg ms | zg CPU ms | rg ms | rg CPU ms | zg speedup |\n|---|---|---|---|---|---|---|---|\n", .{});
    var log_sum: f64 = 0;
    var cpu_log_sum: f64 = 0;
    for (small_cases) |cs| {
        const file = try c.path(cs.file);
        var zl: std.ArrayList([]const u8) = .empty;
        var rl: std.ArrayList([]const u8) = .empty;
        try c.argv(&zl, .zg, .lines, 0, cs.flags, cs.pattern, file);
        try c.argv(&rl, .rg, .lines, 0, cs.flags, cs.pattern, file);
        if (c.cfg.verify) {
            const z = try c.capture(zl.items);
            defer capture_allocator.free(z);
            const r = try c.capture(rl.items);
            defer capture_allocator.free(r);
            const counting = cs.flags.len != 0 and std.mem.eql(u8, cs.flags[0], "-c");
            if (!std.mem.eql(u8, z, r) and !(counting and r.len == 0 and std.mem.eql(u8, z, "0\n"))) {
                std.debug.print("OUTPUT MISMATCH: {s} {s} ({d} vs {d} bytes)\n", .{ cs.file, cs.pattern, z.len, r.len });
                return error.OutputMismatch;
            }
        }
        const zr = try c.measurePair(zl.items, rl.items, c.cfg.runs);
        log_sum += @log(zr[1].wall_ms / zr[0].wall_ms);
        cpu_log_sum += @log(@max(zr[0].cpu_ms, 0.1) / @max(zr[1].cpu_ms, 0.1));
        var flags_buf: [64]u8 = undefined;
        var fw: Io.Writer = .fixed(&flags_buf);
        for (cs.flags, 0..) |f, k| fw.print("{s}{s}", .{ if (k == 0) "" else " ", f }) catch {};
        std.debug.print("| {s} | `{s}` | {s} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.2}x |\n", .{
            cs.file, cs.pattern, fw.buffered(), zr[0].wall_ms, zr[0].cpu_ms, zr[1].wall_ms, zr[1].cpu_ms, zr[1].wall_ms / zr[0].wall_ms,
        });
    }
    const n: f64 = @floatFromInt(small_cases.len);
    std.debug.print("\nspeedup over {d} cells: geometric mean {d:.2}x; CPU time, zg over rg: geometric mean {d:.2}x\n", .{ small_cases.len, @exp(log_sum / n), @exp(cpu_log_sum / n) });
}

fn memory(c: Ctx) !void {
    const what = if (builtin.os.tag.isDarwin()) "Peak memory footprint (MB, from /usr/bin/time -l)" else "Peak RSS (MB, from wait4; includes the mapped file pages touched)";
    std.debug.print("\n## {s}\n\n| file | pattern | output | zg default | zg --mem=256M | zg -j 1 | rg |\n|---|---|---|---|---|---|---|\n", .{what});
    const picks = [_]Case{ default_cases[0], default_cases[5], default_cases[6], default_cases[8], default_cases[12] };
    for (picks) |cs| {
        const file = try c.path(cs.file);
        for ([_]Output{ .lines, .numbered }) |out| {
            var a: std.ArrayList([]const u8) = .empty;
            var b: std.ArrayList([]const u8) = .empty;
            var d: std.ArrayList([]const u8) = .empty;
            var r: std.ArrayList([]const u8) = .empty;
            try c.argv(&a, .zg, out, 0, &.{}, cs.pattern, file);
            try c.argv(&b, .zg, out, 0, &.{"--mem=256M"}, cs.pattern, file);
            try c.argv(&d, .zg, out, 1, &.{}, cs.pattern, file);
            try c.argv(&r, .rg, out, 0, &.{}, cs.pattern, file);
            std.debug.print("| {s} | `{s}` | {s} | {d:.0} | {d:.0} | {d:.0} | {d:.0} |\n", .{
                cs.file,                  cs.pattern,               out.name(),
                try c.footprint(a.items), try c.footprint(b.items), try c.footprint(d.items),
                try c.footprint(r.items),
            });
        }
    }
}

/// Cold page cache: every run reads a fresh copy of the file that was pushed out of the
/// cache beforehand: with `POSIX_FADV_DONTNEED` on Linux, elsewhere by reading a file
/// larger than RAM (`purge` needs root).
fn cold(c: Ctx) !void {
    std.debug.print("\n## Cold page cache (first read from disk)\n\n", .{});
    const src_name = "words.txt";
    const picks = [_]struct { pattern: []const u8, out: Output }{
        .{ .pattern = "needle_zz", .out = .count },
        .{ .pattern = "the", .out = .count },
    };
    const trials = 3;
    const tools = [_]Tool{ .zg, .rg };
    const copies = picks.len * tools.len * trials;

    const src = try c.path(src_name);
    var names: [copies][]u8 = undefined;
    for (&names, 0..) |*n, k| {
        n.* = try std.fmt.allocPrint(c.gpa, "{s}/cold-copy-{d}.txt", .{ c.cfg.dir, k });
        try Io.Dir.cwd().copyFile(src, Io.Dir.cwd(), n.*, c.io, .{});
    }
    defer for (names) |n| Io.Dir.cwd().deleteFile(c.io, n) catch {};

    if (builtin.os.tag == .linux) {
        // Dirty pages are not dropped: write the copies out first.
        for (names) |n| {
            const file = try Io.Dir.cwd().openFile(c.io, n, .{});
            defer file.close(c.io);
            try file.sync(c.io);
            _ = std.os.linux.fadvise(file.handle, 0, 0, std.os.linux.POSIX_FADV.DONTNEED);
        }
    } else {
        // Evict: stream through a file larger than RAM.
        const evict = try c.path("evict.tmp");
        defer Io.Dir.cwd().deleteFile(c.io, evict) catch {};
        const ram = std.process.totalSystemMemory() catch 8 << 30;
        try writeFiller(c, evict, ram + ram / 2);
        try readThrough(c, evict);
    }
    for (names) |n| {
        const frac = try residentFraction(c, n);
        if (frac > 0.05) std.debug.print("(warning: {s} is {d:.0}% cached; cold numbers are optimistic)\n", .{ n, frac * 100 });
    }

    std.debug.print("| pattern | output | zg ms | rg ms | zg speedup |\n|---|---|---|---|---|\n", .{});
    var k: usize = 0;
    for (picks) |pick| {
        var z: [trials]f64 = undefined;
        var r: [trials]f64 = undefined;
        for (0..trials) |t| {
            for (tools) |tool| {
                var list: std.ArrayList([]const u8) = .empty;
                try c.argv(&list, tool, pick.out, 0, &.{}, pick.pattern, names[k]);
                k += 1;
                const s = try c.run(list.items);
                if (tool == .zg) z[t] = s.wall_ms else r[t] = s.wall_ms;
            }
        }
        std.mem.sort(f64, &z, {}, std.sort.asc(f64));
        std.mem.sort(f64, &r, {}, std.sort.asc(f64));
        std.debug.print("| `{s}` | {s} | {d:.0} | {d:.0} | {d:.2}x |\n", .{ pick.pattern, pick.out.name(), z[trials / 2], r[trials / 2], r[trials / 2] / z[trials / 2] });
    }
}

fn writeFiller(c: Ctx, path: []const u8, bytes: usize) !void {
    const file = try Io.Dir.cwd().createFile(c.io, path, .{});
    defer file.close(c.io);
    const block = try c.gpa.alloc(u8, 1 << 20);
    @memset(block, 'e');
    var buf: [4096]u8 = undefined;
    var fw = file.writerStreaming(c.io, &buf);
    var left = bytes;
    while (left > 0) {
        const n = @min(left, block.len);
        try fw.interface.writeAll(block[0..n]);
        left -= n;
    }
    try fw.interface.flush();
}

fn readThrough(c: Ctx, path: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(c.io, path, .{});
    defer file.close(c.io);
    const block = try c.gpa.alloc(u8, 4 << 20);
    var off: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(c.io, block, off);
        if (n == 0) break;
        off += n;
    }
}

fn residentFraction(c: Ctx, path: []const u8) !f64 {
    const file = try Io.Dir.cwd().openFile(c.io, path, .{});
    defer file.close(c.io);
    const size: usize = @intCast(try file.length(c.io));
    const map = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0);
    defer std.posix.munmap(map);
    const page = std.heap.pageSize();
    const pages = (size + page - 1) / page;
    const vec = try c.gpa.alloc(u8, pages);
    defer c.gpa.free(vec);
    try std.posix.mincore(map.ptr, size, vec.ptr);
    var resident: usize = 0;
    for (vec) |v| resident += v & 1;
    return @as(f64, @floatFromInt(resident)) / @as(f64, @floatFromInt(pages));
}
