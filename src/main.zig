const std = @import("std");
const Io = std.Io;
const zg = @import("zg.zig");

const usage =
    \\usage: zg [-n] [-c] [-m N] [-j N] [--io=M] [--] PATTERN FILE
    \\  Case-sensitive literal, line-oriented search (SIMD + multi-threaded).
    \\  -n       prefix matching lines with line numbers
    \\  -c       print only the number of matching lines
    \\  -m N     stop after N matching lines
    \\  -j N     number of threads (default: all cores)
    \\  --io=M   how to read the file: auto (default), mmap or pread
    \\  --mem=S  cap on memory used for results, e.g. 512M or 4G (default: half of RAM)
    \\
;

const Cli = struct {
    opts: zg.Options,
    path: []const u8,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zg: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseArgs(argv: []const [:0]const u8) Cli {
    var opts: zg.Options = .{ .pattern = "" };
    var positional: [2][]const u8 = undefined;
    var np: usize = 0;
    var i: usize = 1;
    var flags_done = false; // after `--`, everything is positional
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (flags_done or a.len == 0 or a[0] != '-' or a.len == 1) {
            if (np == 2) fail("too many arguments\n{s}", .{usage});
            positional[np] = a;
            np += 1;
        } else if (std.mem.eql(u8, a, "--")) {
            flags_done = true;
        } else if (std.mem.eql(u8, a, "-n")) {
            opts.line_numbers = true;
        } else if (std.mem.eql(u8, a, "-c")) {
            opts.count_only = true;
        } else if (std.mem.eql(u8, a, "-m")) {
            i += 1;
            if (i >= argv.len) fail("-m needs a value", .{});
            opts.max_matches = std.fmt.parseInt(usize, argv[i], 10) catch fail("bad match count '{s}'", .{argv[i]});
            if (opts.max_matches == 0) std.process.exit(1); // no line wanted: none matches (as grep -m 0)
        } else if (std.mem.eql(u8, a, "-j")) {
            i += 1;
            if (i >= argv.len) fail("-j needs a value", .{});
            opts.threads = std.fmt.parseInt(usize, argv[i], 10) catch fail("bad thread count '{s}'", .{argv[i]});
        } else if (std.mem.startsWith(u8, a, "--io=")) {
            opts.io = std.meta.stringToEnum(zg.IoChoice, a["--io=".len..]) orelse fail("bad --io value '{s}'", .{a});
        } else if (std.mem.startsWith(u8, a, "--mem=")) {
            opts.memory_limit = zg.parseSize(a["--mem=".len..]) orelse fail("bad --mem value '{s}' (examples: 512M, 4G)", .{a});
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            fail("unknown option '{s}' (use -- before a pattern that starts with '-')\n{s}", .{ a, usage });
        }
    }
    if (np != 2) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    opts.pattern = positional[0];
    return .{ .opts = opts, .path = positional[1] };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = parseArgs(argv);

    const file = Io.Dir.cwd().openFile(io, cli.path, .{}) catch |err| fail("{s}: {t}", .{ cli.path, err });
    defer file.close(io);

    var out_buf: [64 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &out_buf);
    // A one-shot engine: the search starts its threads and works out its memory limit.
    var engine: zg.Engine(.oneshot) = .init(io, init.gpa);
    const total = engine.search(.{ .file = file }, cli.opts, &fw.interface) catch |err| switch (err) {
        // A closed stdout (e.g. `| head`) is not an error: stop quietly.
        error.WriteFailed => std.process.exit(0),
        else => fail("{s}: {t}", .{ cli.path, err }),
    };
    std.process.exit(if (total > 0) 0 else 1);
}

test {
    _ = zg;
    _ = @import("search.zig");
}
