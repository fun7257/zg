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
    .signal_stack_size = if (builtin.mode == .debug) 1 << 18 else null,
};

const usage =
    \\usage: zg [-n] [-c] [-m N] [-j N] [--io=M] [--mem=S] [--] PATTERN [FILE]
    \\       zg --version
    \\  Case-sensitive literal, line-oriented search (SIMD + multi-threaded).
    \\  FILE     the file to search; without it, or as -, standard input
    \\  -n       prefix matching lines with line numbers
    \\  -c       print only the number of matching lines
    \\  -m N     stop after N matching lines
    \\  -j N     number of threads (default: as many as pay off, up to all cores)
    \\  --io=M   how to read the file: auto (default), mmap or pread
    \\  --mem=S  cap on the memory zg allocates, e.g. 64M or 1G (default: a few times
    \\           what the threads need, about 150 MB on 16 threads; below that, searches
    \\           that print much are slower)
    \\  -F, -a   accepted and ignored (zg searches for a literal in bytes)
    \\  Standard input that is a pipe (and any other file that is not a regular one) is
    \\  read into memory first, up to half of the memory (or --mem); a regular file given as standard
    \\  input (zg PATTERN < file) is searched in place, from its beginning.
    \\  Exit status: 0 if a line matched, 1 if none did, 2 on errors.
    \\
;

fn Cli(comptime Zg: type) type {
    return struct {
        opts: Zg.Options,
        /// The file to search; null: standard input.
        path: ?[]const u8,
        /// `--version`: print what this build is and runs, nothing else.
        version: bool = false,
        /// `--help`: print the usage on standard output.
        help: bool = false,
    };
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zg: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// What an error means to a user: the system's wording for the common ones, else the name of
/// the error as words ("MemoryMappingNotSupported": "memory mapping not supported").
fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files",
        error.OutOfMemory => "Out of memory",
        error.InputOutput => "Input/output error",
        error.BrokenPipe => "Broken pipe",
        error.FileTooLarge => "File too large for this system",
        error.FileChanged => "the file changed while it was being searched",
        else => words(err),
    };
}

var words_buf: [128]u8 = undefined;

fn words(err: anyerror) []const u8 {
    const name = @errorName(err);
    var n: usize = 0;
    for (name, 0..) |c, i| {
        if (n + 2 >= words_buf.len) break;
        if (std.ascii.isUpper(c)) {
            if (i != 0) {
                words_buf[n] = ' ';
                n += 1;
            }
            words_buf[n] = std.ascii.toLower(c);
        } else words_buf[n] = c;
        n += 1;
    }
    return words_buf[0..n];
}

/// Letters of grep and ripgrep options that zg does not have: say so, instead of "unknown
/// option".
const unsupported_letters = "ivorREPGwxlLHhqszbBACeSTUZ";

const unsupported_long = [_][]const u8{
    "--ignore-case",         "--invert-match",  "--only-matching", "--recursive",      "--regexp",
    "--extended-regexp",     "--perl-regexp",   "--word-regexp",   "--line-regexp",    "--files-with-matches",
    "--files-without-match", "--with-filename", "--no-filename",   "--quiet",          "--silent",
    "--color",               "--colour",        "--after-context", "--before-context", "--context",
    "--null",                "--null-data",     "--byte-offset",   "--smart-case",
};

fn unsupportedOption(comptime fmt_name: []const u8, name: anytype) noreturn {
    fail("option '" ++ fmt_name ++ "' is not supported: zg searches for a case-sensitive literal in one file or standard input (zg --help)", .{name});
}

fn parseArgs(comptime Zg: type, argv: []const [:0]const u8) Cli(Zg) {
    var opts: Zg.Options = .{ .pattern = "", .truncation_guard = true };
    var positional: [2][]const u8 = undefined;
    var np: usize = 0;
    var i: usize = 1;
    var flags_done = false; // after `--`, everything is positional
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (flags_done or a.len == 0 or a[0] != '-' or a.len == 1) {
            if (np == 2) fail("too many arguments: zg searches one file (or standard input)\n{s}", .{usage});
            positional[np] = a;
            np += 1;
        } else if (std.mem.eql(u8, a, "--")) {
            flags_done = true;
        } else if (std.mem.eql(u8, a, "--fixed-strings") or std.mem.eql(u8, a, "--text")) {
            // zg always searches for a literal, in bytes
        } else if (std.mem.startsWith(u8, a, "--io=")) {
            opts.io = std.meta.stringToEnum(Zg.IoChoice, a["--io=".len..]) orelse fail("bad --io value '{s}' (auto, mmap or pread)", .{a["--io=".len..]});
        } else if (std.mem.startsWith(u8, a, "--mem=")) {
            opts.memory_limit = Zg.parseSize(a["--mem=".len..]) orelse fail("bad --mem value '{s}' (examples: 512M, 4G)", .{a["--mem=".len..]});
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            return .{ .opts = opts, .path = null, .version = true };
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return .{ .opts = opts, .path = null, .help = true };
        } else if (a[1] == '-') {
            for (unsupported_long) |l| if (std.mem.startsWith(u8, a, l)) unsupportedOption("{s}", a);
            fail("unknown option '{s}' (use -- before a pattern that starts with '-'; zg --help)", .{a});
        } else {
            // Short options, alone or together (-nc, -m5, -nm 5): the ones with a value take
            // the rest of the argument, or the next argument.
            var k: usize = 1;
            while (k < a.len) : (k += 1) {
                switch (a[k]) {
                    'n' => opts.line_numbers = true,
                    'c' => opts.count_only = true,
                    'F', 'a' => {}, // zg always searches for a literal, in bytes
                    'm', 'j' => |letter| {
                        var value: []const u8 = a[k + 1 ..];
                        if (value.len == 0) {
                            i += 1;
                            if (i >= argv.len) fail("-{c} needs a value", .{letter});
                            value = argv[i];
                        }
                        if (letter == 'm') {
                            opts.max_matches = std.fmt.parseInt(usize, value, 10) catch fail("bad match count '{s}'", .{value});
                            if (opts.max_matches == 0) std.process.exit(1); // no line wanted: none matches (as grep -m 0)
                        } else {
                            opts.threads = std.fmt.parseInt(usize, value, 10) catch fail("bad thread count '{s}'", .{value});
                        }
                        break;
                    },
                    else => |c| {
                        if (std.mem.indexOfScalar(u8, unsupported_letters, c) != null) unsupportedOption("-{c}", c);
                        fail("unknown option '-{c}' (use -- before a pattern that starts with '-'; zg --help)", .{c});
                    },
                }
            }
        }
    }
    if (np == 0) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    opts.pattern = positional[0];
    const path: ?[]const u8 = if (np == 2 and !std.mem.eql(u8, positional[1], "-")) positional[1] else null;
    return .{ .opts = opts, .path = path };
}

pub fn main(init: std.process.Init) !void {
    // `ZG_CPU_LEVEL=v1|v2` runs a lower level than the CPU's (for testing those builds).
    var level = cpuLevel();
    if (init.environ_map.get("ZG_CPU_LEVEL")) |text| {
        if (std.meta.stringToEnum(Level, text)) |asked| level = @enumFromInt(@min(@intFromEnum(asked), @intFromEnum(level)));
    }
    if (build_options.cpu_dispatch) switch (level) {
        .v3 => return run(levels.v3, init, .v3),
        .v2 => return run(levels.v2, init, .v2),
        .v1 => return run(zg, init, .v1),
    };
    return run(zg, init, null);
}

/// What to search: the file, or the contents of standard input (or of a pipe, device or
/// other file that is not a regular one) read into memory. `name` is how errors name it.
fn openInput(comptime Zg: type, init: std.process.Init, path: ?[]const u8, cap: usize, name: *[]const u8) Zg.Source {
    const io = init.io;
    name.* = path orelse "standard input";
    const file = if (path) |p|
        Io.Dir.cwd().openFile(io, p, .{}) catch |err| fail("{s}: {s}", .{ p, describe(err) })
    else
        Io.File.stdin();
    const st = file.stat(io) catch |err| fail("{s}: {s}", .{ name.*, describe(err) });
    switch (st.kind) {
        .directory => fail("{s}: Is a directory (zg searches one file; use grep -r or rg for a tree)", .{name.*}),
        // A regular file is searched in place. (Size 0 can be an empty file, or one the
        // system makes up as it is read, like those in /proc: read it.)
        .file => if (st.size > 0) return .{ .file = file },
        else => {},
    }
    if (path == null and (file.isTty(io) catch false)) {
        fail("no FILE given and standard input is a terminal\n{s}", .{usage});
    }
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const data = reader.interface.allocRemaining(init.gpa, .limited(cap)) catch |err| switch (err) {
        error.StreamTooLong => fail("{s}: more than {d} MB of input, which zg holds in memory (the limit is half of the memory, or --mem): save it to a file and search that", .{ name.*, cap >> 20 }),
        error.ReadFailed => fail("{s}: {s}", .{ name.*, describe(reader.err orelse error.InputOutput) }),
        error.OutOfMemory => fail("{s}: Out of memory reading the input", .{name.*}),
    };
    return .{ .bytes = data };
}

/// The command line tool on the core `Zg` (`zg`, or one of its copies in `levels`), the
/// one for `level` in a build with several.
fn run(comptime Zg: type, init: std.process.Init, level: ?Level) !void {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = parseArgs(Zg, argv);
    if (cli.version) {
        printVersion(io, level);
        std.process.exit(0);
    }
    if (cli.help) {
        var hbuf: [2048]u8 = undefined;
        var hw = Io.File.stdout().writerStreaming(io, &hbuf);
        hw.interface.writeAll(usage) catch {};
        hw.interface.flush() catch {};
        std.process.exit(0);
    }

    // Standard input is held in memory up to --mem if given, else half of the physical
    // memory: it is the input, not the working memory the default limit is sized for.
    const cap = if (cli.opts.memory_limit != 0) cli.opts.memory_limit else (std.process.totalSystemMemory() catch 2 << 30) / 2;
    var name: []const u8 = undefined;
    const source = openInput(Zg, init, cli.path, cap, &name);

    var out_buf: [64 * 1024]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &out_buf);
    // A one-shot engine: the search starts its threads and works out its memory limit.
    var engine: Zg.Engine(.oneshot) = .init(io, init.gpa);
    const total = engine.search(source, cli.opts, &fw.interface) catch |err| switch (err) {
        // A closed stdout (e.g. `| head`) is not an error: stop quietly.
        error.WriteFailed => std.process.exit(0),
        error.EmptyPattern => fail("the pattern is empty", .{}),
        error.PatternHasNewline => fail("the pattern contains a newline: zg searches line by line", .{}),
        else => fail("{s}: {s}", .{ name, describe(err) }),
    };
    std.process.exit(if (total > 0) 0 else 1);
}

/// `zg --version`: the version, the target, and for a portable x86-64 build the level it
/// runs on this CPU, e.g.
///
///     zg 0.1.0
///     x86_64-linux, built for x86_64 with cores for x86-64 v1, v2, v3; running v3
fn printVersion(io: Io, level: ?Level) void {
    var buf: [256]u8 = undefined;
    var fw = Io.File.stdout().writerStreaming(io, &buf);
    const w = &fw.interface;
    w.print("zg {s}\n{t}-{t}, built for {s}", .{ build_options.version, builtin.target.cpu.arch, builtin.target.os.tag, builtin.target.cpu.model.name }) catch return;
    if (level) |l| w.print(" with cores for x86-64 v1, v2, v3; running {t}", .{l}) catch return;
    w.writeAll("\n") catch return;
    w.flush() catch {};
}

const Level = enum { v1, v2, v3 };

/// The x86-64 microarchitecture level the CPU supports, as Zig's x86_64_v2 and x86_64_v3
/// models define them (each feature they enable is checked: the compiler may use any), and
/// for v3 with the AVX state enabled by the operating system.
fn cpuLevel() Level {
    if (builtin.target.cpu.arch != .x86_64) return .v1;
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
