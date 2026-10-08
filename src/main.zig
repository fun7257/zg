const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const zg = @import("zg");

/// In a build for x86-64 below v3, the core compiled for later levels too (see build.zig).
const levels = if (build_options.cpu_dispatch) struct {
    const v2 = @import("zg_v2");
    const v3 = @import("zg_v3");
} else struct {};

/// No per-thread alternate signal stack outside Debug builds. The standard library gives
/// every thread one (256 KB of thread-local storage), only to print a stack trace when a
/// thread overflows its stack, and every thread start clears it: on a Ryzen 7735U, 15
/// thread starts took 1.9 ms with it and 0.26 ms without, and 2.9 ms against 0.8 ms
/// while other threads allocate memory. zg starts its threads as a search needs them
/// (`Ramp` in zg.zig), so this is on the path of every search.
pub const std_options: std.Options = .{
    .signal_stack_size = if (builtin.mode == .Debug) 1 << 18 else null,
};

const usage =
    \\usage: zg [-n] [-c] [-m N] [-j N] [--io=M] [--mem=S] [--] PATTERN FILE
    \\  Case-sensitive literal, line-oriented search (SIMD + multi-threaded).
    \\  -n       prefix matching lines with line numbers
    \\  -c       print only the number of matching lines
    \\  -m N     stop after N matching lines
    \\  -j N     number of threads (default: as many as pay off, up to all cores)
    \\  --io=M   how to read the file: auto (default), mmap or pread
    \\  --mem=S  cap on the memory zg allocates, e.g. 512M or 4G (default: what the
    \\           system can give without swapping, at most half of RAM)
    \\
;

fn Cli(comptime Zg: type) type {
    return struct {
        opts: Zg.Options,
        path: []const u8,
    };
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zg: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn parseArgs(comptime Zg: type, argv: []const [:0]const u8) Cli(Zg) {
    var opts: Zg.Options = .{ .pattern = "" };
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
            opts.io = std.meta.stringToEnum(Zg.IoChoice, a["--io=".len..]) orelse fail("bad --io value '{s}'", .{a});
        } else if (std.mem.startsWith(u8, a, "--mem=")) {
            opts.memory_limit = Zg.parseSize(a["--mem=".len..]) orelse fail("bad --mem value '{s}' (examples: 512M, 4G)", .{a});
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
    // `ZG_CPU_LEVEL=v1|v2` runs a lower level than the CPU's (for testing those builds).
    var level = cpuLevel();
    if (init.environ_map.get("ZG_CPU_LEVEL")) |text| {
        if (std.meta.stringToEnum(Level, text)) |asked| level = @enumFromInt(@min(@intFromEnum(asked), @intFromEnum(level)));
    }
    if (build_options.cpu_dispatch) switch (level) {
        .v3 => return run(levels.v3, init),
        .v2 => return run(levels.v2, init),
        .v1 => {},
    };
    return run(zg, init);
}

/// The command line tool on the core `Zg` (`zg`, or one of its copies in `levels`).
fn run(comptime Zg: type, init: std.process.Init) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = parseArgs(Zg, argv);

    const file = Io.Dir.cwd().openFile(io, cli.path, .{}) catch |err| fail("{s}: {t}", .{ cli.path, err });
    defer file.close(io);

    var out_buf: [64 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &out_buf);
    // A one-shot engine: the search starts its threads and works out its memory limit.
    var engine: Zg.Engine(.oneshot) = .init(io, init.gpa);
    const total = engine.search(.{ .file = file }, cli.opts, &fw.interface) catch |err| switch (err) {
        // A closed stdout (e.g. `| head`) is not an error: stop quietly.
        error.WriteFailed => std.process.exit(0),
        else => fail("{s}: {t}", .{ cli.path, err }),
    };
    std.process.exit(if (total > 0) 0 else 1);
}

const Level = enum { v1, v2, v3 };

/// The x86-64 microarchitecture level the CPU supports, as Zig's x86_64_v2 and x86_64_v3
/// models define them (each feature they enable is checked: the compiler may use any), and
/// for v3 with the AVX state enabled by the operating system.
fn cpuLevel() Level {
    if (builtin.cpu.arch != .x86_64) return .v1;
    const max_leaf = cpuid(0, 0).eax;
    const max_ext = cpuid(0x8000_0000, 0).eax;
    if (max_leaf < 7 or max_ext < 0x8000_0001) return .v1;
    const l1 = cpuid(1, 0);
    const l7 = cpuid(7, 0);
    const ext = cpuid(0x8000_0001, 0);
    const bit = struct {
        fn has(reg: u32, n: u5) bool {
            return reg & (@as(u32, 1) << n) != 0;
        }
    }.has;
    // CMPXCHG16B, POPCNT, SSE4.2 (and the SSE3, SSSE3, SSE4.1 it builds on), LAHF/SAHF.
    const v2 = bit(l1.ecx, 13) and bit(l1.ecx, 23) and bit(l1.ecx, 20) and bit(l1.ecx, 19) and
        bit(l1.ecx, 9) and bit(l1.ecx, 0) and bit(ext.ecx, 0);
    if (!v2) return .v1;
    // AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, XSAVE, and AVX itself with OS support.
    const os_avx = bit(l1.ecx, 27) and bit(l1.ecx, 28) and xgetbv0() & 0b110 == 0b110;
    const v3 = os_avx and bit(l7.ebx, 5) and bit(l7.ebx, 3) and bit(l7.ebx, 8) and bit(l1.ecx, 29) and
        bit(l1.ecx, 12) and bit(ext.ecx, 5) and bit(l1.ecx, 22) and bit(l1.ecx, 26);
    return if (v3) .v3 else .v2;
}

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// XCR0: the register state the operating system saves (bit 1 SSE, bit 2 AVX).
fn xgetbv0() u32 {
    return asm volatile ("xgetbv"
        : [lo] "={eax}" (-> u32),
        : [xcr] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
}
