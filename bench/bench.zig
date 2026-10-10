//! In-process benchmark for zg's core: `zig build bench -- FILE PATTERN [options]`.
//! Times `zg.run` only (no process start-up), several times, and reports the median.
const std = @import("std");
const builtin = @import("builtin");

/// As in the command line tool (src/main.zig): no alternate signal stack per thread
/// outside Debug builds, which makes starting a thread several times cheaper.
pub const std_options: std.Options = .{
    .signal_stack_size = if (builtin.mode == .debug) 1 << 18 else null,
};
const Io = std.Io;
const zg = @import("zg");

const usage =
    \\usage: bench FILE PATTERN [-n] [-c] [-j=N] [--io=M] [--mem=S] [--sink=null|file|mem] [--chunk=S] [--runs=N] [--alloc=page]
    \\
;

const Sink = enum { null, file, mem };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var gpa = init.gpa;

    var opts: zg.Options = .{ .pattern = "" };
    var path: ?[]const u8 = null;
    var sink: Sink = .null;
    var runs: usize = 15;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-n")) {
            opts.line_numbers = true;
        } else if (std.mem.eql(u8, a, "-c")) {
            opts.count_only = true;
        } else if (std.mem.startsWith(u8, a, "--io=")) {
            opts.io = std.meta.stringToEnum(zg.IoChoice, a[5..]) orelse return error.BadArgument;
        } else if (std.mem.startsWith(u8, a, "--sink=")) {
            sink = std.meta.stringToEnum(Sink, a[7..]) orelse return error.BadArgument;
        } else if (std.mem.startsWith(u8, a, "--mem=")) {
            opts.memory_limit = zg.parseSize(a[6..]) orelse return error.BadArgument;
        } else if (std.mem.eql(u8, a, "--alloc=page")) {
            gpa = std.heap.page_allocator;
        } else if (std.mem.startsWith(u8, a, "--chunk=")) {
            opts.chunk_size = zg.parseSize(a[8..]) orelse return error.BadArgument;
        } else if (std.mem.startsWith(u8, a, "--runs=")) {
            runs = try std.fmt.parseInt(usize, a[7..], 10);
        } else if (std.mem.eql(u8, a, "-j")) {
            return error.UseJEquals; // keep the parser trivial: -j=N
        } else if (std.mem.startsWith(u8, a, "-j=")) {
            opts.threads = try std.fmt.parseInt(usize, a[3..], 10);
        } else if (path == null) {
            path = a;
        } else {
            opts.pattern = a;
        }
    }
    if (path == null or opts.pattern.len == 0) {
        std.debug.print("{s}", .{usage});
        return error.BadArgument;
    }

    const file = try Io.Dir.cwd().openFile(io, path.?, .{});
    defer file.close(io);

    const times = try gpa.alloc(f64, runs);
    defer gpa.free(times);
    var matches: usize = 0;
    var out_bytes: usize = 0;
    for (0..runs + 1) |i| { // the first run warms the page cache and is dropped
        const start = Io.Timestamp.now(io, .awake);
        switch (sink) {
            .mem => {
                var out: Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                matches = try zg.run(io, gpa, file, opts, &out.writer);
                out_bytes = out.written().len;
            },
            .null, .file => {
                const name = if (sink == .null) "/dev/null" else ".zg-bench.tmp";
                const dest = try Io.Dir.cwd().createFile(io, name, .{});
                defer dest.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var fw = dest.writerStreaming(io, &buf);
                matches = try zg.run(io, gpa, file, opts, &fw.interface);
                try fw.interface.flush();
            },
        }
        const ms = @as(f64, @floatFromInt(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds)) / 1e6;
        if (i > 0) times[i - 1] = ms;
    }
    if (sink == .file) Io.Dir.cwd().deleteFile(io, ".zg-bench.tmp") catch {};
    std.mem.sort(f64, times, {}, std.sort.asc(f64));
    std.debug.print("{s} {s}: median {d:.1} ms  min {d:.1} ms  ({d} matching lines", .{
        path.?, opts.pattern, times[times.len / 2], times[0], matches,
    });
    if (sink == .mem) std.debug.print(", {d} output bytes", .{out_bytes});
    std.debug.print(")\n", .{});
}
