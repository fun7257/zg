//! Concurrent searches on one engine, the way a server runs them:
//!   zig build stress -- [--engine=shared|oneshot] [--threads=N] [--rounds=N] BIG_FILE SMALL_FILE
//!
//! 1. Scaling: 1, 2, 4, 8 and 16 callers search BIG_FILE at once; total throughput and
//!    latency per search.
//! 2. Mixed load: one caller keeps running a search with a lot of output on BIG_FILE while
//!    four callers search SMALL_FILE; latency of the small searches, against the same
//!    small searches on an idle engine.
//! Then the peak memory footprint of the process (macOS: what it allocated itself, not the
//! mapped file pages, which every concurrent search of the same file maps again).
const std = @import("std");
const builtin = @import("builtin");

/// As in the command line tool (src/main.zig): no alternate signal stack per thread
/// outside Debug builds, which makes starting a thread several times cheaper.
pub const std_options: std.Options = .{
    .signal_stack_size = if (builtin.mode == .Debug) 1 << 18 else null,
};
const Io = std.Io;
const zg = @import("zg");

const Which = enum { shared, oneshot };

const Engine = struct {
    which: Which,
    shared: zg.Engine(.shared) = undefined,
    oneshot: zg.Engine(.oneshot) = undefined,

    fn search(e: *Engine, file: Io.File, opts: zg.Options, w: *Io.Writer) !usize {
        return switch (e.which) {
            .shared => e.shared.search(.{ .file = file }, opts, w),
            .oneshot => e.oneshot.search(.{ .file = file }, opts, w),
        };
    }
};

const Caller = struct {
    engine: *Engine,
    file: Io.File,
    opts: zg.Options,
    io: Io,
    /// Searches to run, or until `stop` is set if 0.
    rounds: usize,
    stop: *std.atomic.Value(bool),
    lat_ms: std.ArrayList(f64) = .empty,
    gpa: std.mem.Allocator,

    fn run(c: *Caller) void {
        var k: usize = 0;
        while (if (c.rounds != 0) k < c.rounds else !c.stop.load(.acquire)) : (k += 1) {
            const t0 = Io.Timestamp.now(c.io, .awake);
            var w: Io.Writer.Discarding = .init(&.{});
            _ = c.engine.search(c.file, c.opts, &w.writer) catch |err| std.debug.panic("search: {t}", .{err});
            const ms = @as(f64, @floatFromInt(t0.durationTo(Io.Timestamp.now(c.io, .awake)).nanoseconds)) / 1e6;
            c.lat_ms.append(c.gpa, ms) catch @panic("oom");
        }
    }
};

const Stats = struct { n: usize, p50: f64, p99: f64, max: f64 };

fn stats(all: []f64) Stats {
    std.mem.sort(f64, all, {}, std.sort.asc(f64));
    const n = all.len;
    return .{ .n = n, .p50 = all[n / 2], .p99 = all[@min(n - 1, n * 99 / 100)], .max = all[n - 1] };
}

/// Runs `callers` with the same options at once; returns the wall time and the latencies.
fn runCallers(gpa: std.mem.Allocator, io: Io, engine: *Engine, specs: []const struct { file: Io.File, opts: zg.Options, rounds: usize }, counts: []const usize) !struct { wall_ms: f64, callers: []Caller } {
    var total: usize = 0;
    for (counts) |c| total += c;
    const callers = try gpa.alloc(Caller, total);
    const threads = try gpa.alloc(std.Thread, total);
    defer gpa.free(threads);
    var stop: std.atomic.Value(bool) = .init(false);
    var k: usize = 0;
    for (specs, counts) |spec, count| for (0..count) |_| {
        callers[k] = .{ .engine = engine, .file = spec.file, .opts = spec.opts, .io = io, .rounds = spec.rounds, .stop = &stop, .gpa = gpa };
        k += 1;
    };
    const t0 = Io.Timestamp.now(io, .awake);
    for (callers, threads) |*c, *t| t.* = try std.Thread.spawn(.{}, Caller.run, .{c});
    // Callers with a round count end on their own; the others run until those are done.
    for (callers, threads) |c, t| if (c.rounds != 0) t.join();
    stop.store(true, .release);
    for (callers, threads) |c, t| if (c.rounds == 0) t.join();
    const wall = @as(f64, @floatFromInt(t0.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds)) / 1e6;
    return .{ .wall_ms = wall, .callers = callers };
}

fn freeCallers(gpa: std.mem.Allocator, callers: []Caller) void {
    for (callers) |*c| c.lat_ms.deinit(gpa);
    gpa.free(callers);
}

fn latencies(gpa: std.mem.Allocator, callers: []const Caller, want: zg.Options) ![]f64 {
    var all: std.ArrayList(f64) = .empty;
    for (callers) |c| if (std.mem.eql(u8, c.opts.pattern, want.pattern) and c.opts.count_only == want.count_only) try all.appendSlice(gpa, c.lat_ms.items);
    return all.toOwnedSlice(gpa);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var which: Which = .shared;
    var rounds: usize = 10;
    var threads: usize = 0;
    var paths: [2][]const u8 = undefined;
    var np: usize = 0;
    for (argv[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--engine=")) {
            which = std.meta.stringToEnum(Which, a["--engine=".len..]) orelse return error.BadArgument;
        } else if (std.mem.startsWith(u8, a, "--threads=")) {
            threads = try std.fmt.parseInt(usize, a["--threads=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--rounds=")) {
            rounds = try std.fmt.parseInt(usize, a["--rounds=".len..], 10);
        } else if (np < 2) {
            paths[np] = a;
            np += 1;
        } else return error.BadArgument;
    }
    if (np != 2) {
        std.debug.print("usage: stress [--engine=shared|oneshot] [--threads=N] [--rounds=N] BIG_FILE SMALL_FILE\n", .{});
        return error.BadArgument;
    }
    const big = try Io.Dir.cwd().openFile(io, paths[0], .{});
    defer big.close(io);
    const small = try Io.Dir.cwd().openFile(io, paths[1], .{});
    defer small.close(io);

    var engine: Engine = .{ .which = which };
    switch (which) {
        .shared => engine.shared = try .init(io, gpa, .{ .threads = threads }),
        .oneshot => engine.oneshot = .init(io, gpa),
    }
    defer if (which == .shared) engine.shared.deinit();

    const count: zg.Options = .{ .pattern = "needle_zz", .count_only = true };
    // Warm-up: the page cache, and the engine's threads and allocations.
    for ([_]Io.File{ big, small }) |f| {
        var w: Io.Writer.Discarding = .init(&.{});
        _ = try engine.search(f, count, &w.writer);
    }
    std.debug.print("engine: {t}\n\n1. {d} searches per caller of `-c needle_zz` on {s}\n", .{ which, rounds, paths[0] });
    std.debug.print("| callers | wall ms | ms per search (wall / searches) | vs 1 caller | latency p50 | p99 | max |\n|---|---|---|---|---|---|---|\n", .{});
    var base: f64 = 0;
    for ([_]usize{ 1, 2, 4, 8, 16 }) |n| {
        const r = try runCallers(gpa, io, &engine, &.{.{ .file = big, .opts = count, .rounds = rounds }}, &.{n});
        defer freeCallers(gpa, r.callers);
        const lat = try latencies(gpa, r.callers, count);
        defer gpa.free(lat);
        const st = stats(lat);
        const per = r.wall_ms / @as(f64, @floatFromInt(st.n));
        if (n == 1) base = per;
        std.debug.print("| {d} | {d:.0} | {d:.2} | {d:.2}x | {d:.1} | {d:.1} | {d:.1} |\n", .{ n, r.wall_ms, per, base / per, st.p50, st.p99, st.max });
    }

    // 2. Mixed load.
    const heavy: zg.Options = .{ .pattern = "the" };
    const light: zg.Options = .{ .pattern = "needle_zz", .count_only = true };
    const small_rounds = rounds * 5;
    const alone = try runCallers(gpa, io, &engine, &.{.{ .file = small, .opts = light, .rounds = small_rounds }}, &.{4});
    defer freeCallers(gpa, alone.callers);
    const lat_alone = try latencies(gpa, alone.callers, light);
    defer gpa.free(lat_alone);
    const mixed = try runCallers(gpa, io, &engine, &.{
        .{ .file = big, .opts = heavy, .rounds = 0 },
        .{ .file = small, .opts = light, .rounds = small_rounds },
    }, &.{ 1, 4 });
    defer freeCallers(gpa, mixed.callers);
    const lat_mixed = try latencies(gpa, mixed.callers, light);
    defer gpa.free(lat_mixed);
    const heavy_lat = try latencies(gpa, mixed.callers, heavy);
    defer gpa.free(heavy_lat);
    const a = stats(lat_alone);
    const m = stats(lat_mixed);
    std.debug.print("\n2. 4 callers x {d} searches of `-c needle_zz` on {s}, alone and next to `the` (all lines) on {s} ({d} heavy searches meanwhile)\n", .{ small_rounds, paths[1], paths[0], heavy_lat.len });
    std.debug.print("| small searches | p50 ms | p99 ms | max ms |\n|---|---|---|---|\n| alone | {d:.2} | {d:.2} | {d:.2} |\n| next to the heavy search | {d:.2} | {d:.2} | {d:.2} |\n", .{ a.p50, a.p99, a.max, m.p50, m.p99, m.max });

    if (@import("builtin").os.tag.isDarwin()) {
        std.debug.print("\npeak of the memory zg allocated (anonymous, without mapped file pages): {d:.0} MB\n", .{anonymousPeak() / (1 << 20)});
    } else {
        const ru = std.posix.getrusage(0);
        std.debug.print("\npeak resident set (maxrss, with mapped file pages): {d:.0} MB\n", .{@as(f64, @floatFromInt(ru.maxrss)) / 1024});
    }
}

/// `task_vm_info` up to `phys_footprint` (mach/task_info.h, revision 1).
const TaskVmInfo = extern struct {
    virtual_size: u64,
    region_count: i32,
    page_size: i32,
    resident_size: u64,
    resident_size_peak: u64,
    device: u64,
    device_peak: u64,
    internal: u64,
    internal_peak: u64,
    // The rest of revision 1: the kernel wants room for all of it.
    external: u64,
    external_peak: u64,
    reusable: u64,
    reusable_peak: u64,
    purgeable_volatile_pmap: u64,
    purgeable_volatile_resident: u64,
    purgeable_volatile_virtual: u64,
    compressed: u64,
    compressed_peak: u64,
    compressed_lifetime: u64,
    phys_footprint: u64,
};

extern "c" fn task_info(task: std.c.mach_port_t, flavor: c_int, info: *TaskVmInfo, count: *u32) c_int;

fn anonymousPeak() f64 {
    var info: TaskVmInfo = undefined;
    var count: u32 = @sizeOf(TaskVmInfo) / @sizeOf(u32);
    const task_vm_info = 22;
    if (task_info(std.c.mach_task_self(), task_vm_info, &info, &count) != 0) return 0;
    return @floatFromInt(info.internal_peak);
}
