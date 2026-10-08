//! Deterministic benchmark corpora: `zig build gen -- DIR` writes
//!   DIR/words.txt  ~540 MB of English-like text (3 to 14 pseudo-words per line),
//!   DIR/log.txt    ~514 MB of application log lines.
//! Stress corpora for worst cases:
//!   DIR/long.txt   ~512 MB, lines of 20 KB to 600 KB
//!   DIR/short.txt  ~300 MB, lines of 0 to 3 characters (most are empty or tiny)
//!   DIR/random.bin ~512 MB of random bytes (NULs, newlines every ~256 bytes)
//! A few patterns are planted so that every benchmark case has a known frequency:
//! `needle_zz` once, `zebra` in 1000 lines, `xq` in 2000 lines (words.txt), and
//! `unique_token_7731` once (log.txt).
const std = @import("std");
const Io = std.Io;

const words_bytes: usize = 540_000_000;
const log_bytes: usize = 514_000_000;

/// Syllables with a rough English flavour; common ones ("the", "ing", ...) are repeated so
/// they come up often, like in real text.
const syllables = [_][]const u8{
    "the", "the", "ing", "ing", "tion", "er", "er", "an",  "an", "re", "in",  "in",  "on",  "at",  "en",
    "es",  "or",  "ar",  "st",  "nd",   "to", "it", "is",  "ou", "ve", "al",  "le",  "co",  "de",  "di",
    "pro", "con", "per", "ex",  "ka",   "mi", "zo", "qua", "vi", "ju", "wy",  "ba",  "fo",  "gu",  "ha",
    "lo",  "ma",  "ne",  "pa",  "ri",   "su", "ta", "ul",  "ve", "ze", "bra", "cli", "dra", "spl", "str",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 2) {
        std.debug.print("usage: gen DIR\n", .{});
        return error.BadArgument;
    }
    var dir = try Io.Dir.cwd().createDirPathOpen(io, argv[1], .{});
    defer dir.close(io);

    try genWords(io, gpa, dir);
    try genLog(io, dir);
    try genLong(io, gpa, dir);
    try genShort(io, dir);
    try genRandom(io, dir);
}

fn genLong(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) !void {
    var prng = std.Random.DefaultPrng.init(3);
    const rnd = prng.random();
    const file = try dir.createFile(io, "long.txt", .{});
    defer file.close(io);
    var buf: [1 << 20]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;
    const text = try gpa.alloc(u8, 4 << 20); // reusable text: random words
    defer gpa.free(text);
    for (text) |*c| c.* = if (rnd.uintLessThan(u8, 6) == 0) ' ' else syllables[rnd.uintLessThan(usize, syllables.len)][0];
    var written: usize = 0;
    var n: usize = 0;
    while (written < 512_000_000) : (n += 1) {
        const len = rnd.intRangeAtMost(usize, 20_000, 600_000);
        const at = rnd.uintLessThan(usize, text.len - len);
        try w.writeAll(text[at..][0..len]);
        try w.writeByte('\n');
        written += len + 1;
    }
    try w.writeAll("needle_zz\n");
    try w.flush();
}

fn genShort(io: Io, dir: Io.Dir) !void {
    var prng = std.Random.DefaultPrng.init(4);
    const rnd = prng.random();
    const file = try dir.createFile(io, "short.txt", .{});
    defer file.close(io);
    var buf: [1 << 20]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;
    const alphabet = "ab c";
    var written: usize = 0;
    while (written < 300_000_000) {
        const len = rnd.uintLessThan(usize, 4);
        for (0..len) |_| try w.writeByte(alphabet[rnd.uintLessThan(usize, alphabet.len)]);
        try w.writeByte('\n');
        written += len + 1;
    }
    try w.writeAll("needle_zz\n");
    try w.flush();
}

fn genRandom(io: Io, dir: Io.Dir) !void {
    var prng = std.Random.DefaultPrng.init(5);
    const rnd = prng.random();
    const file = try dir.createFile(io, "random.bin", .{});
    defer file.close(io);
    var buf: [1 << 20]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;
    var block: [1 << 20]u8 = undefined;
    for (0..512) |_| {
        rnd.bytes(&block);
        try w.writeAll(&block);
    }
    try w.writeAll("needle_zz\n");
    try w.flush();
}

fn genWords(io: Io, gpa: std.mem.Allocator, dir: Io.Dir) !void {
    var prng = std.Random.DefaultPrng.init(1);
    const rnd = prng.random();

    // A vocabulary of 60k words; text then draws from it uniformly.
    const vocab_len = 60_000;
    const vocab = try gpa.alloc([]u8, vocab_len);
    defer {
        for (vocab) |w| gpa.free(w);
        gpa.free(vocab);
    }
    for (vocab) |*slot| {
        var word: std.ArrayList(u8) = .empty;
        for (0..rnd.intRangeAtMost(usize, 1, 4)) |_| try word.appendSlice(gpa, syllables[rnd.uintLessThan(usize, syllables.len)]);
        slot.* = try word.toOwnedSlice(gpa);
    }

    const file = try dir.createFile(io, "words.txt", .{});
    defer file.close(io);
    var buf: [1 << 20]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;

    // Rough line count: 3 to 14 words of ~6 letters plus spaces.
    const approx_lines = words_bytes / 60;
    const zebra_every = approx_lines / 1000;
    const xq_every = approx_lines / 2000;
    var written: usize = 0;
    var line_no: usize = 0;
    while (written < words_bytes) : (line_no += 1) {
        const n = rnd.intRangeAtMost(usize, 3, 14);
        const planted: []const u8 = if (line_no % zebra_every == 7) "zebra" else if (line_no % xq_every == 11) "xq" else "";
        const planted_at = rnd.uintLessThan(usize, n);
        for (0..n) |k| {
            if (k != 0) try w.writeByte(' ');
            const word = if (k == planted_at and planted.len != 0) planted else vocab[rnd.uintLessThan(usize, vocab_len)];
            try w.writeAll(word);
            written += word.len + 1;
        }
        try w.writeByte('\n');
    }
    try w.writeAll("no newline at end needle_zz");
    try w.flush();
}

fn genLog(io: Io, dir: Io.Dir) !void {
    var prng = std.Random.DefaultPrng.init(2);
    const rnd = prng.random();
    const levels = [_][]const u8{ "INFO", "DEBUG", "WARN", "ERROR" };
    const mods = [_][]const u8{ "auth", "db", "http", "cache", "sched" };

    const file = try dir.createFile(io, "log.txt", .{});
    defer file.close(io);
    var buf: [1 << 20]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    const w = &fw.interface;

    var written: usize = 0;
    var i: usize = 0;
    while (written < log_bytes) : (i += 1) {
        var line: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "2026-10-05T12:{d:0>2}:{d:0>2}.{d:0>3} {s} [{s}] req={x:0>12} user={d} latency={d}ms path=/api/v{d}/items/{d}\n", .{
            i / 60 % 60,
            i % 60,
            rnd.uintLessThan(u32, 1000),
            levels[rnd.uintLessThan(usize, levels.len)],
            mods[rnd.uintLessThan(usize, mods.len)],
            rnd.int(u48),
            rnd.intRangeAtMost(u32, 1, 99999),
            rnd.intRangeAtMost(u32, 1, 2000),
            rnd.intRangeAtMost(u32, 1, 3),
            rnd.intRangeAtMost(u32, 1, 9999),
        });
        try w.writeAll(text);
        written += text.len;
    }
    try w.writeAll("2026-10-05 FATAL deadbeefcafe unique_token_7731\n");
    try w.flush();
}
