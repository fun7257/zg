//! Core of zg: a case-sensitive, line-oriented literal search over one file, using
//! SIMD (`search.zig`) within chunks and all cores across chunks.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const search = @import("search.zig");

pub const IoChoice = enum { auto, mmap, pread };

pub const Options = struct {
    pattern: []const u8,
    line_numbers: bool = false,
    count_only: bool = false,
    /// 0 means one thread per CPU.
    threads: usize = 0,
    io: IoChoice = .auto,
    /// Bytes per chunk; 0 derives it from the file size and thread count. Tests set tiny
    /// values to exercise the chunk boundary logic.
    chunk_size: usize = 0,
    /// Cap in bytes on the memory zg allocates (0: sized by the threads and the chunks, a few
    /// times what the threads need: about 150 MB on 16 threads of a core with 512 KB of L2, at
    /// least 32 MB, and never more than the system has; see `defaultMemoryLimit`). Two thirds of
    /// it is the accounted budget, see "Memory budget" below.
    memory_limit: usize = 0,
    /// Lets another thread stop the search (`Cancel.request`); it then fails with
    /// `error.Canceled`.
    cancel: ?*Cancel = null,
    /// Nanoseconds the search may take (0: no limit); past that it fails with
    /// `error.Timeout`. Checked between chunks, so it ends a few chunks' time late at most.
    timeout_ns: u64 = 0,
    /// Stop after this many matching lines (0: no limit), like `grep -m`: only the first
    /// ones are written, and with `count_only` the count is at most this. (A cap on the
    /// output's size can be had from the writer: one that fails past the cap stops the
    /// search at once, with `error.WriteFailed`.)
    max_matches: usize = 0,
    /// A file that shrinks while it is mapped (another process truncates it) raises SIGBUS on
    /// the pages past its new end, which kills the process. With this set, the search catches
    /// the signal and ends with `error.FileChanged`, as searches on a shared engine always do.
    /// Off by default for one-shot searches because the handler is process-wide: it is installed
    /// by the first search that asks, stays installed, and passes SIGBUS from anywhere else on to
    /// the handler that was there before. The command line tool sets it.
    truncation_guard: bool = false,
};

/// What a search reads: a file, or bytes already in memory (a request body, say).
pub const Source = union(enum) {
    file: Io.File,
    bytes: []const u8,
};

/// Gets the matching lines of `searchLines` one by one, in file order: the 1-based line
/// number and the line without its newline (valid during the call only). An error ends
/// the search with it.
pub const OnLine = *const fn (ctx: ?*anyopaque, number: usize, line: []const u8) anyerror!void;

/// Stops a running search from another thread, e.g. when the client of a request went
/// away. One `Cancel` serves one search at a time.
pub const Cancel = struct {
    requested: std.atomic.Value(bool) = .init(false),
    /// The search using it while it runs, so that `request` can wake its waiting threads.
    job: ?*Job = null,
    lock: std.atomic.Value(bool) = .init(false),

    /// The search stops handing out chunks and returns `error.Canceled` once the chunks in
    /// progress are done; a search that has not started yet fails at once.
    pub fn request(c: *Cancel) void {
        c.requested.store(true, .release);
        c.acquire();
        defer c.lock.store(false, .release);
        if (c.job) |job| job.stop(error.Canceled);
    }

    fn acquire(c: *Cancel) void {
        while (c.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn attach(c: *Cancel, job: ?*Job) void {
        c.acquire();
        defer c.lock.store(false, .release);
        c.job = job;
    }
};

// Memory budget
//
// The budget covers what zg allocates itself: rendered output waiting for the writer and
// recycled output buffers. The mapped file is page cache that the kernel can drop at any
// time, so it is not counted. Beyond the budget:
//
//  1. Backpressure: workers stop claiming new chunks while the accounted memory is at
//     the budget; only chunks right behind the writer are always allowed, so the
//     writer is never starved.
//  2. A drained output buffer is freed instead of recycled if recycling would exceed it.
//
// Line length costs no memory: a line that runs past the chunk it starts in is written
// straight from the mapping by the writer (see "Chunks" below).
//
// The limit is `memory_limit`; by default a few times what the threads need
// (`defaultMemoryLimit`), the least that costs no speed: more memory did not make zg faster,
// and a reader that stalls is held back by the limit, not by the machine running out (a
// container with a memory limit of its own was killed before). The accounted budget is two
// thirds of it, the rest covers what the accounting cannot see. Each thread also carries an
// overhead of a few chunks while it works on output (`memoryPerThread`), so unless `-j` is
// given the thread count shrinks to what the limit can carry (`threadsFor`). Measured with `a`
// over a 539 MB file (5.95 million matching lines) and a stalled reader, the peak footprint
// then stayed below the limit for limits from 32 MB to 1 GB, with and without `-n`; with
// the default, 110 MB however much is printed (588 MB for 400 MB of output before).

// Chunks
//
// The file is cut into byte ranges [lo, hi) of `chunk_size`. A chunk searches the match
// starts in its range (reading up to hi + m - 1 for the matches that end beyond it) and
// owns the lines that start in its range. A line that runs past `hi` is "pending": the
// chunks it extends into each report only whether a match starts in their part of it
// (`cont_found`), and the writer, which goes through the chunks in order anyway, decides
// the line and writes it from the mapping. So the work on a huge line is spread over all
// the chunks it covers, and no chunk ever needs more than its range in memory.

/// How workers get at file contents. Page-cache-resident files are fastest through mmap;
/// cold files are read about 1.7x faster with large sequential `pread`s, because
/// page faults only trigger small readaheads.
const IoMode = enum { mmap, pread };

/// How one chunk is accessed. Which is fastest depends on the state of the system's memory,
/// not just on whether the file is cached: on the same cached 512 MB file, one thread took
/// 44 ms through the mapping and 51 ms with `pread` at one moment; 42, 28 (with
/// `MADV_WILLNEED`) and 45 ms at another; 48, 62 and 45 ms at a third, after memory pressure.
/// So the workers measure the methods on chunks of the file itself and keep using the
/// fastest (`AccessStats`).
const Access = enum { map_advise, map, read };

/// Per-method timing, shared by the workers: the first chunks try every allowed method,
/// later ones use the lowest time per byte, with an occasional run of chunks on another
/// method so that a change in the system is noticed. How the methods are tried depends on
/// the number of threads (`Policy`).
const AccessStats = struct {
    ns: [3]std.atomic.Value(u64) = @splat(.init(0)),
    bytes: [3]std.atomic.Value(u64) = @splat(.init(0)),
    /// Warm-up runs handed out per method; reserved when picked, so that threads starting
    /// together do not all try the same method before any timing has come back.
    warm: [3]std.atomic.Value(u32) = @splat(.init(0)),
    /// Chunks recorded per method, for `Policy.skip_first`.
    seen: [3]std.atomic.Value(u32) = @splat(.init(0)),
    claims: std.atomic.Value(u32) = .init(0),
    rechecks: std.atomic.Value(u32) = .init(0),
    allowed: [3]bool,
    policy: Policy,
    /// What came from a shared engine's priors (`Pool.seed`), not from this search's
    /// chunks: bytes per method, and nanoseconds of each.
    seeded: usize = 0,
    seeded_ns: [3]u64 = @splat(0),
    /// Picoseconds per byte added to the mapped methods for the unmapping that their pages
    /// cost later (`unmapCost`).
    unmap_ps: u64 = 0,

    const Policy = struct {
        /// Chunks in a run on one method, given to one worker.
        burst: u8,
        /// Chunks at the start of a worker's run on one method that do not count.
        settle: u32,
        /// The first chunk recorded for each method does not count.
        skip_first: bool,
        /// Warm-up runs per method.
        warm_runs: u32,
        /// How often (in claims) one of the other methods gets a run again.
        recheck_every: u32,
        /// Files with fewer chunks are not worth the warm-up: the residency guess
        /// (`chooseIo`) decides alone.
        min_chunks: usize,

        /// One thread. The first chunks after a switch of method are slow for reasons that
        /// are not the method's: on a cached 512 MB file, a lone `pread` chunk between
        /// mapped ones took 0.10 to 0.13 ns per byte, a run of them 0.065, reached after 4
        /// to 6 chunks when the buffers go to the writer (each chunk then reads into another
        /// buffer of the pool). Judged on lone chunks, `pread` lost to the mapping while it
        /// was the faster one. So methods are tried on runs of chunks, without their first
        /// ones; trying a slower method costs a few tens of microseconds per chunk.
        const one_thread: Policy = .{ .burst = 6, .settle = 2, .skip_first = false, .warm_runs = 1, .recheck_every = 128, .min_chunks = 48 };
        /// Several threads: the chunks share the memory bandwidth, and a worker held on a
        /// slower method for a run of chunks finishes late, which costs all-core runs about
        /// 1 ms (3 to 8 % in A/B runs). Single chunks are tried instead.
        const threads: Policy = .{ .burst = 1, .settle = 0, .skip_first = true, .warm_runs = 2, .recheck_every = 64, .min_chunks = 24 };

        fn of(nthreads: usize) Policy {
            return if (nthreads == 1) one_thread else threads;
        }
    };

    /// One worker's state: the method of its previous chunks and how many in a row used
    /// it, and what is left of the run it was given.
    const Streak = struct {
        last: ?Access = null,
        in_row: u32 = 0,
        method: Access = .map,
        left: u8 = 0,
    };

    fn startRun(st: *const AccessStats, streak: *Streak, a: Access) Access {
        streak.method = a;
        streak.left = st.policy.burst - 1;
        return a;
    }

    fn pick(st: *AccessStats, streak: *Streak) Access {
        var only: ?Access = null;
        var n_allowed: usize = 0;
        for (st.allowed, 0..) |ok, k| if (ok) {
            n_allowed += 1;
            only = @enumFromInt(k);
        };
        if (n_allowed == 1) return only.?;
        if (streak.left != 0) {
            streak.left -= 1;
            return streak.method;
        }
        const claim = st.claims.fetchAdd(1, .monotonic);
        const warm_runs = st.policy.warm_runs;
        for (st.allowed, 0..) |ok, k| {
            if (ok and st.warm[k].load(.monotonic) < warm_runs and st.warm[k].fetchAdd(1, .monotonic) < warm_runs) return st.startRun(streak, @enumFromInt(k));
        }
        const fastest = st.best();
        const every = st.policy.recheck_every;
        if (claim % every == every - 1) {
            // Re-check the other methods in turn, so that each one gets measured again.
            const turn = st.rechecks.fetchAdd(1, .monotonic);
            var others: [3]Access = undefined;
            var n: usize = 0;
            for (st.allowed, 0..) |ok, k| if (ok and k != @intFromEnum(fastest)) {
                others[n] = @enumFromInt(k);
                n += 1;
            };
            if (n != 0) return st.startRun(streak, others[turn % n]);
        }
        return fastest;
    }

    /// The method with the lowest time per byte; before any is measured, the first allowed.
    fn best(st: *AccessStats) Access {
        var b: Access = for (st.allowed, 0..) |ok, k| {
            if (ok) break @enumFromInt(k);
        } else .read;
        var b_rate: f64 = std.math.inf(f64);
        for (st.allowed, 0..) |ok, k| if (ok) {
            const bytes = st.bytes[k].load(.monotonic);
            if (bytes == 0) continue;
            const rate = @as(f64, @floatFromInt(st.ns[k].load(.monotonic))) / @as(f64, @floatFromInt(bytes));
            if (rate < b_rate) {
                b_rate = rate;
                b = @enumFromInt(k);
            }
        };
        return b;
    }

    fn record(st: *AccessStats, streak: *Streak, a: Access, ns: u64, bytes: u64) void {
        streak.in_row = if (streak.last == a) streak.in_row + 1 else 1;
        streak.last = a;
        if (streak.in_row <= st.policy.settle) return;
        const k = @intFromEnum(a);
        if (st.policy.skip_first and st.seen[k].fetchAdd(1, .monotonic) == 0) return;
        const unmap = if (a == .read) 0 else bytes * st.unmap_ps / 1000;
        _ = st.ns[k].fetchAdd(ns + unmap, .monotonic);
        _ = st.bytes[k].fetchAdd(bytes, .monotonic);
    }
};

/// The share of the L2 cache one hardware thread has (L2 size over the hardware threads
/// sharing it), read from the system once. A chunk read with `pread` must still be in the
/// cache when it is scanned, while the mapped methods hardly care, so this bounds the chunk
/// size. Apple M1 (12 MB of L2 for 4 cores, 3 MB each): one thread, 512 MB cached file,
/// 40.6 ms with 1 to 2 MB reads, 45.6 ms with 8 MB ones. Ryzen 7735U (512 KB for 2
/// hardware threads, 256 KB each): 16 threads, 540 MB cached file, `-c` took 21.6 ms with
/// 256 KB chunks, 22.3 ms with 512 KB and 62.4 ms with 2 MB; printing 4.7 M lines, 35, 72
/// and 120 ms. Unknown: 256 KB on x86 (its cores have little L2, often shared by two
/// threads), 2 MB elsewhere.
fn l2PerThread(io: Io) usize {
    const S = struct {
        var cached: std.atomic.Value(usize) = .init(0);
    };
    const c = S.cached.load(.monotonic);
    if (c != 0) return c;
    const share = readL2PerThread(io) orelse if (builtin.target.cpu.arch.isX86()) 256 * 1024 else 2 * 1024 * 1024;
    S.cached.store(share, .monotonic);
    return share;
}

/// Physical cores (hardware threads over the threads per core), read from the system once;
/// all CPUs when unknown. Apple Silicon has one thread per core.
fn physicalCores(io: Io) usize {
    const S = struct {
        var cached: std.atomic.Value(usize) = .init(0);
    };
    const c = S.cached.load(.monotonic);
    if (c != 0) return c;
    const cpus = std.Thread.getCpuCount() catch 1;
    const cores = readPhysicalCores(io, cpus) orelse cpus;
    S.cached.store(@max(cores, 1), .monotonic);
    return @max(cores, 1);
}

fn readPhysicalCores(io: Io, cpus: usize) ?usize {
    switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => return sysctlInt("hw.physicalcpu"),
        .linux => {
            var buf: [256]u8 = undefined;
            const text = sysfsText(io, "/sys/devices/system/cpu/cpu0/topology/", "thread_siblings_list", &buf) orelse return null;
            const per_core = countCpuList(text) orelse return null;
            return @max(1, cpus / per_core);
        },
        else => return null,
    }
}

fn readL2PerThread(io: Io) ?usize {
    switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // The performance cores' L2 (perflevel0), else the one L2 of older systems.
            const size = sysctlInt("hw.perflevel0.l2cachesize") orelse sysctlInt("hw.l2cachesize") orelse return null;
            const sharing = sysctlInt("hw.perflevel0.cpusperl2") orelse 1;
            return size / @max(sharing, 1);
        },
        .linux => {
            var k: usize = 0;
            while (k < 8) : (k += 1) {
                var path_buf: [64]u8 = undefined;
                var buf: [256]u8 = undefined;
                const dir = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu0/cache/index{d}/", .{k}) catch return null;
                const level = sysfsText(io, dir, "level", &buf) orelse return null;
                if (!std.mem.eql(u8, level, "2")) continue;
                if (std.mem.eql(u8, sysfsText(io, dir, "type", &buf) orelse return null, "Instruction")) continue;
                const size = parseCacheSize(sysfsText(io, dir, "size", &buf) orelse return null) orelse return null;
                const sharing = countCpuList(sysfsText(io, dir, "shared_cpu_list", &buf) orelse return null) orelse return null;
                return size / @max(sharing, 1);
            }
            return null;
        },
        else => return null,
    }
}

fn sysctlInt(name: [*:0]const u8) ?usize {
    var v: u64 = 0;
    var len: usize = @sizeOf(u64);
    if (std.c.sysctlbyname(name, &v, &len, null, 0) != 0 or len == 0) return null;
    // A 32-bit value fills the low bytes (little-endian).
    return if (v == 0) null else @intCast(v);
}

/// The trimmed contents of `dir ++ name`, in `buf`.
fn sysfsText(io: Io, dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ dir, name }) catch return null;
    const text = Io.Dir.cwd().readFile(io, path, buf) catch return null;
    return std.mem.trim(u8, text, " \n");
}

/// "512K", "1024K", "2M" (sysfs cache sizes).
fn parseCacheSize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    const unit: usize = switch (text[text.len - 1]) {
        'K' => 1024,
        'M' => 1024 * 1024,
        '0'...'9' => 1,
        else => return null,
    };
    const digits = if (unit == 1) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(usize, digits, 10) catch return null;
    return if (n == 0) null else n * unit;
}

/// Number of CPUs in a list like "0-1,8-9" or "3".
fn countCpuList(text: []const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ',');
    while (it.next()) |range| {
        if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
            const a = std.fmt.parseInt(usize, range[0..dash], 10) catch return null;
            const b = std.fmt.parseInt(usize, range[dash + 1 ..], 10) catch return null;
            if (b < a) return null;
            n += b - a + 1;
        } else {
            _ = std.fmt.parseInt(usize, range, 10) catch return null;
            n += 1;
        }
    }
    return if (n == 0) null else n;
}

test "cache sizes and CPU lists from sysfs" {
    try testing.expectEqual(@as(?usize, 512 * 1024), parseCacheSize("512K"));
    try testing.expectEqual(@as(?usize, 2 * 1024 * 1024), parseCacheSize("2M"));
    try testing.expectEqual(@as(?usize, null), parseCacheSize("K"));
    try testing.expectEqual(@as(?usize, null), parseCacheSize(""));
    try testing.expectEqual(@as(?usize, 2), countCpuList("0-1"));
    try testing.expectEqual(@as(?usize, 4), countCpuList("0-1,8-9"));
    try testing.expectEqual(@as(?usize, 1), countCpuList("3"));
    try testing.expectEqual(@as(?usize, null), countCpuList("2-1"));
    const share = l2PerThread(testing.io);
    try testing.expect(share >= 16 * 1024 and share <= 64 * 1024 * 1024);
    const cores = physicalCores(testing.io);
    try testing.expect(cores >= 1 and cores <= try std.Thread.getCpuCount());
}

/// What unmapping the pages that the mapped methods touched costs, in picoseconds per
/// chunk byte. On Linux every page a mapped chunk faulted in has to be unmapped again at the
/// end, by one thread while the others are done: on a Ryzen 7735U, 13.8 ms for 540 MB
/// (about 100 ns per 4 KB page), against 17 ms for the whole search on 8 threads before
/// it. The chunk timings do not see it; spread over the chunks, it is a cost per byte for
/// each of the threads it holds back. (Not seen on macOS.)
fn unmapCost(nthreads: usize) u64 {
    if (builtin.target.os.tag != .linux) return 0;
    return 100 * 1000 / std.heap.pageSize() * nthreads;
}

/// Unmaps `m` a slice at a time. Unmapping holds the process's address space lock for
/// writing, and for pages that were faulted in it takes long (14 ms for 540 MB on a Ryzen
/// 7735U), during which every other search in the process (a server's) waits to map,
/// unmap or fault in a page. Between slices they get the lock.
fn unmapInSlices(m: []align(std.heap.page_size_min) u8) void {
    const slice = 8 << 20;
    var at: usize = 0;
    while (m.len - at > slice) : (at += slice) std.posix.munmap(@alignCast(m[at..][0..slice]));
    std.posix.munmap(@alignCast(m[at..]));
}

/// Files with at least this fraction (in percent) of pages in the page cache use mmap.
const mmap_resident_percent = 90;

/// A matching line of the chunk being processed (offsets are < 4 GiB: a chunk is at most
/// `chunk_size` plus a needle).
const Match = struct {
    start: u32,
    end: u32,
    line: u32, // 0-based line index within the chunk
};

/// Per-thread buffers reused from chunk to chunk.
const Scratch = struct {
    /// The chunk's bytes in `pread` mode.
    read: std.ArrayList(u8) = .empty,
    /// Matches of the current chunk while the line numbers are not known yet.
    matches: std.ArrayList(Match) = .empty,
    /// This worker's state in the choice of access method.
    streak: AccessStats.Streak = .{},
    /// Nanoseconds the current chunk spent waiting for earlier chunks (`firstLine`).
    waited: u64 = 0,

    fn deinit(sc: *Scratch, gpa: std.mem.Allocator) void {
        sc.read.deinit(gpa);
        sc.matches.deinit(gpa);
    }
};

/// A very long output line that is not copied: the writer takes the `len` bytes at `src` and
/// puts them at offset `at` of the chunk's `out`.
const Ref = struct {
    at: usize,
    /// The line's bytes: in the mapping, or in the chunk's own `pread` buffer (`ChunkResult.buf`).
    src: [*]const u8,
    len: usize,
};

/// Output lines at least this long are written straight from the mapping instead of being
/// copied into the chunk's output buffer: past a few KB a copy costs more than the
/// bookkeeping, and with huge lines it is a whole extra pass over the matched bytes.
const zero_copy_min_len = 16 * 1024;

/// The last line of a chunk when it runs past the chunk's range.
const Pending = struct {
    /// File offset of the line start.
    start: usize,
    /// 0-based line number (only with `-n`).
    line: usize,
    /// A match starts in the part of the line inside the owning chunk.
    found: bool,
};

const ChunkResult = struct {
    /// Output text of this chunk, ready to be written as is, except for the `refs`.
    out: std.ArrayList(u8) = .empty,
    refs: std.ArrayList(Ref) = .empty,
    /// The `pread` buffer that `refs`, `tail` and `cont` point into, handed over by the
    /// worker (empty if the chunk was mapped or none of them is used).
    buf: std.ArrayList(u8) = .empty,
    /// Or copies of `tail` and `cont`, when they are short (`Job.handOver`).
    pieces: std.ArrayList(u8) = .empty,
    /// `pread` chunks: the part of the pending line inside the chunk ([pending.start, hi))...
    tail: []const u8 = &.{},
    /// ...and the chunk's part of a line that began earlier ([lo, end of that line or hi)),
    /// so that the writer can put a pending line together without reading it again.
    cont: []const u8 = &.{},
    count: usize = 0,
    /// File offset of the first line that starts in the chunk's range, if any.
    first_start: ?usize = null,
    /// A match starts in the chunk's range, inside a line that began in an earlier chunk.
    cont_found: bool = false,
    pending: ?Pending = null,
};

/// The accounted memory of "Memory budget" above. One search has its own; the searches of
/// a shared `Engine` share one, so that together they stay within the engine's limit.
const Memory = struct {
    budget: usize,
    /// Accounted bytes: finished output not yet written (its length) and recycled buffers
    /// (their capacity). Approximate: it ignores what the allocator keeps around and what
    /// the threads are working on right now.
    queued: std.atomic.Value(usize) = .init(0),
    pool_bytes: std.atomic.Value(usize) = .init(0),

    fn accounted(m: *const Memory) usize {
        return m.queued.load(.monotonic) + m.pool_bytes.load(.monotonic);
    }
};

/// Buffers kept for reuse, in the accounting of `Memory.pool_bytes`. One search has its
/// own; a shared engine keeps them from one search to the next, so that a search starts
/// with buffers whose pages are already in.
/// A lock for short critical sections that several threads enter at every chunk (the
/// buffer pools, a shared engine's list of searches). It spins a little, then sleeps on a
/// futex, where a pure spin lock (as before) lets the threads waiting for a holder that was
/// descheduled spin for the rest of their time slice; a shared engine runs more threads
/// than cores (its pool, and every search's caller). It did not change the latency of small
/// searches next to a large one in `zig build stress`.
const Lock = struct {
    m: Io.Mutex = .init,

    /// Tries before sleeping: about a microsecond and a half of pauses on current x86.
    const spins = 64;

    fn acquire(l: *Lock, io: Io) void {
        for (0..spins) |_| {
            if (l.m.tryLock()) return;
            std.atomic.spinLoopHint();
        }
        l.m.lockUncancelable(io);
    }

    fn release(l: *Lock, io: Io) void {
        l.m.unlock(io);
    }
};

const Buffers = struct {
    /// Output buffers the writer has drained: allocating a fresh buffer for every chunk
    /// would page-fault in (and hoard) memory for the whole output.
    out: std.ArrayList(std.ArrayList(u8)) = .empty,
    /// `pread` buffers handed over with their chunks come back here (separately from the
    /// output buffers, whose pages may never have been touched): a buffer taken from here
    /// is ready, so its first use measures the method and not page faults.
    read: std.ArrayList(std.ArrayList(u8)) = .empty,
    lock: Lock = .{},

    fn acquire(b: *Buffers, io: Io) void {
        b.lock.acquire(io);
    }

    fn release(b: *Buffers, io: Io) void {
        b.lock.release(io);
    }

    /// Frees buffers until at most `keep` bytes are left. Each buffer is freed outside the
    /// lock: freeing unmaps memory, and the workers take and give back buffers under the
    /// lock at every chunk.
    fn trim(b: *Buffers, io: Io, gpa: std.mem.Allocator, mem: *Memory, keep: usize) void {
        while (true) {
            var victim: std.ArrayList(u8) = blk: {
                b.acquire(io);
                defer b.release(io);
                var held: usize = 0;
                for ([_]*std.ArrayList(std.ArrayList(u8)){ &b.read, &b.out }) |list| {
                    for (list.items, 0..) |buf, k| {
                        if (buf.capacity != 0 and held + buf.capacity <= keep) {
                            held += buf.capacity;
                            continue;
                        }
                        _ = mem.pool_bytes.fetchSub(buf.capacity, .monotonic);
                        break :blk list.swapRemove(k);
                    }
                }
                if (b.read.items.len == 0) b.read.clearAndFree(gpa);
                if (b.out.items.len == 0) b.out.clearAndFree(gpa);
                return;
            };
            victim.deinit(gpa);
        }
    }
};

const Job = struct {
    data: []const u8, // the mmap; in `pread` mode only lines longer than a chunk are written from it
    access: AccessStats,
    /// Null when the search is over bytes in memory (then only `.map` is used).
    file: ?Io.File,
    searcher: search.Searcher,
    chunk_size: usize,
    nchunks: usize,
    line_numbers: bool,
    count_only: bool,
    /// Set `ready[i]` once chunk `i` holds its final output, so the writer can take it
    /// while later chunks are still being worked on.
    stream: bool = false,
    ready: []std.atomic.Value(bool),
    next: std.atomic.Value(usize) = .init(0),
    /// Recycled buffers: the search's own, or a shared engine's.
    bufs: *Buffers,
    results: []ChunkResult,
    gpa: std.mem.Allocator,
    mem: *Memory,
    /// Threads working on chunks, the main thread included.
    nthreads: usize,
    /// `-n`: `line_end[i]` is the number of newlines in chunks 0..i, valid once
    /// `published` > i. Chunks publish in order, which gives each one the line number its
    /// first line starts at; they are in flight together, so the wait is short.
    line_end: []std.atomic.Value(usize),
    published: std.atomic.Value(u32) = .init(0),
    /// Number of chunks the writer has written so far.
    written: std.atomic.Value(usize) = .init(0),
    /// A chunk the writer waits for to decide a pending line; claims up to it are allowed
    /// even over the budget, like those right behind the writer.
    need: std.atomic.Value(usize) = .init(0),
    std_io: Io,
    /// Futex words so that idle threads sleep instead of spinning: `progress` changes when
    /// the writer has freed memory (gated workers wait on it), `completed` when a chunk
    /// became ready (the writer waits on it).
    progress: std.atomic.Value(u32) = .init(0),
    completed: std.atomic.Value(u32) = .init(0),
    /// Threads asleep (or about to be) on `progress`, `completed` and `published`
    /// (`sleepOn`, `wakeOn`).
    progress_sleepers: std.atomic.Value(u32) = .init(0),
    completed_sleepers: std.atomic.Value(u32) = .init(0),
    published_sleepers: std.atomic.Value(u32) = .init(0),
    /// First error raised by any worker (`@intFromError`), or 0.
    err: std.atomic.Value(u16) = .init(0),
    /// Shared engines only: the pool whose threads work on this job, the number of them on
    /// it right now (a futex word: the owner waits for it to drop to zero before freeing
    /// the job), and how many may be on it at once.
    shared: ?*Pool = null,
    inflight: std.atomic.Value(u32) = .init(0),
    max_workers: std.atomic.Value(u32) = .init(0),
    /// A cancel handle or a deadline is set (`checkStop` has something to check).
    watched: bool = false,
    cancel: ?*Cancel = null,
    deadline: ?Io.Timestamp = null,
    /// The mapping's `BusGuard` slot (shared engines, and one-shot searches with
    /// `Options.truncation_guard`).
    bus_slot: ?usize = null,
    /// `Options.max_matches`; with `count_only`, the matching lines of finished chunks so
    /// far, to stop as soon as there are enough.
    max_matches: usize = 0,
    found: std.atomic.Value(usize) = .init(0),
    /// No more chunks are handed out: the search has its result (`max_matches`) or failed.
    halted: std.atomic.Value(bool) = .init(false),
    /// One-shot searches: the threads are started as they pay off (`Ramp`).
    ramp: ?*Ramp = null,
    /// Chunks done (for `Ramp`).
    done_chunks: std.atomic.Value(u32) = .init(0),
    /// Time `pread` chunks spent reading, and working on what they read (for `Ramp`).
    read_ns: std.atomic.Value(u64) = .init(0),
    work_ns: std.atomic.Value(u64) = .init(0),

    fn takeBuffer(job: *Job) std.ArrayList(u8) {
        job.bufs.acquire(job.std_io);
        defer job.bufs.release(job.std_io);
        const buf = job.bufs.out.pop() orelse return .empty;
        _ = job.mem.pool_bytes.fetchSub(buf.capacity, .monotonic);
        return buf;
    }

    /// A `pread` buffer of at least `n` bytes with all its pages touched.
    fn takeReadBuffer(job: *Job, n: usize) !std.ArrayList(u8) {
        var buf: std.ArrayList(u8) = blk: {
            job.bufs.acquire(job.std_io);
            defer job.bufs.release(job.std_io);
            const b = job.bufs.read.pop() orelse break :blk .empty;
            _ = job.mem.pool_bytes.fetchSub(b.capacity, .monotonic);
            break :blk b;
        };
        errdefer buf.deinit(job.gpa);
        if (buf.capacity < n) {
            try buf.ensureTotalCapacity(job.gpa, n);
            @memset(buf.allocatedSlice(), 0); // fault the pages in now, not while timed
        }
        return buf;
    }

    fn giveReadBuffer(job: *Job, buf: std.ArrayList(u8)) void {
        var b = buf;
        b.clearRetainingCapacity();
        if (job.mem.accounted() + b.capacity > job.mem.budget) return b.deinit(job.gpa);
        job.bufs.acquire(job.std_io);
        defer job.bufs.release(job.std_io);
        job.bufs.read.append(job.gpa, b) catch return b.deinit(job.gpa);
        _ = job.mem.pool_bytes.fetchAdd(b.capacity, .monotonic);
    }

    fn giveBuffer(job: *Job, buf: std.ArrayList(u8)) void {
        if (buf.capacity == 0) return;
        var b = buf;
        b.clearRetainingCapacity();
        if (job.mem.accounted() + b.capacity > job.mem.budget) return b.deinit(job.gpa);
        job.bufs.acquire(job.std_io);
        defer job.bufs.release(job.std_io);
        job.bufs.out.append(job.gpa, b) catch return b.deinit(job.gpa);
        _ = job.mem.pool_bytes.fetchAdd(b.capacity, .monotonic);
    }

    /// Ends the search with `err`: no more chunks are handed out, and every thread that
    /// waits for something (the writer, workers held back by the budget, the pool) wakes up
    /// to see it. Chunks in progress are finished.
    fn stop(job: *Job, err: anyerror) void {
        _ = job.err.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);
        job.halt();
    }

    /// No more chunks are handed out, and waiting threads wake up to see it.
    fn halt(job: *Job) void {
        job.halted.store(true, .release);
        job.next.store(job.nchunks, .monotonic);
        _ = job.completed.fetchAdd(1, .release);
        job.std_io.futexWake(u32, &job.completed.raw, std.math.maxInt(u32));
        job.madeProgress();
    }

    /// Stops the search if it was canceled or ran out of time; true if it is stopped.
    fn checkStop(job: *Job) bool {
        if (job.err.load(.monotonic) != 0) return true;
        if (job.cancel) |c| if (c.requested.load(.acquire)) {
            job.stop(error.Canceled);
            return true;
        };
        if (job.deadline) |d| if (Io.Timestamp.now(job.std_io, .awake).nanoseconds >= d.nanoseconds) {
            job.stop(error.Timeout);
            return true;
        };
        if (job.bus_slot) |k| if (BusGuard.hit[k].load(.acquire)) {
            job.stop(error.FileChanged);
            return true;
        };
        return false;
    }

    /// The writer freed memory or moved on: workers held back by the budget re-check.
    fn madeProgress(job: *Job) void {
        _ = job.progress.fetchAdd(1, .seq_cst);
        job.wakeOn(&job.progress, &job.progress_sleepers, @intCast(job.nthreads));
        if (job.shared) |p| p.wake();
    }

    /// Sleeps while `word` holds `seen`. The sleeper is counted in `sleepers` first, so
    /// that `wakeOn` can skip the system call when nobody sleeps: the writer and the chunks
    /// signal once or twice per chunk, mostly to no one (16 threads, 2000 chunks: 14 000
    /// futex calls in a search with one matching line, a few dozen with this).
    /// Both sides are sequentially consistent: either the sleeper sees the new value of
    /// `word`, or the waker sees the sleeper.
    fn sleepOn(job: *Job, word: *std.atomic.Value(u32), sleepers: *std.atomic.Value(u32), seen: u32) void {
        _ = sleepers.fetchAdd(1, .seq_cst);
        if (word.load(.seq_cst) == seen) job.std_io.futexWaitUncancelable(u32, &word.raw, seen);
        _ = sleepers.fetchSub(1, .monotonic);
    }

    /// Wakes up to `n` sleepers of `word`, after a sequentially consistent change of it.
    fn wakeOn(job: *Job, word: *std.atomic.Value(u32), sleepers: *std.atomic.Value(u32), n: u32) void {
        if (sleepers.load(.seq_cst) != 0) job.std_io.futexWake(u32, &word.raw, n);
    }

    /// Whether a chunk could be claimed now without waiting (pool threads skip the job
    /// otherwise): the same rule as the wait in `workOne`.
    fn mayClaim(job: *const Job) bool {
        const nx = job.next.load(.monotonic);
        if (nx >= job.nchunks) return false;
        if (!job.stream or job.mem.accounted() < job.mem.budget) return true;
        const head = @max(job.written.load(.acquire), job.need.load(.acquire));
        return nx <= head + job.nthreads;
    }

    /// Ends a pool thread's stint on the job: its `pread` buffer goes back to the job's
    /// pool, and its access-method streak, which was about this job, starts over.
    fn leave(job: *Job, sc: *Scratch) void {
        if (sc.read.capacity != 0) job.giveReadBuffer(sc.read);
        sc.read = .empty;
        sc.streak = .{};
        // Once `inflight` drops, the search's caller may see no thread on the job and free it
        // (`Pool.remove`): nothing of the job is read after that. Waking its futex word then
        // is harmless (at worst a spurious wake-up for whatever lives there next).
        const io = job.std_io;
        const pool = job.shared;
        if (job.inflight.fetchSub(1, .release) == 1) io.futexWake(u32, &job.inflight.raw, 1);
        if (pool) |p| p.wake(); // another thread may take the freed slot
    }

    /// A worker of a search whose threads `Ramp` starts.
    fn rampWorker(job: *Job) void {
        var sc: Scratch = .{};
        defer sc.deinit(job.gpa);
        while (job.workOne(&sc, true)) {}
    }

    /// Claims and processes the next chunk of the current phase; false when none is left.
    /// With `block` false it also returns false, without claiming, while the memory budget
    /// forbids taking on more work (the writer calls it that way, it has to keep writing).
    fn workOne(job: *Job, sc: *Scratch, block: bool) bool {
        if (job.watched and job.checkStop()) return false;
        if (job.stream) {
            while (true) {
                // Snapshot first: a change after this point makes the wait below return at once.
                const seen = job.progress.load(.acquire);
                if (job.mem.accounted() < job.mem.budget) break;
                const nx = job.next.load(.monotonic);
                // Chunks right behind the writer always proceed, or nothing could drain.
                const head = @max(job.written.load(.acquire), job.need.load(.acquire));
                if (nx >= job.nchunks or nx <= head + job.nthreads) break;
                if (!block) return false;
                job.sleepOn(&job.progress, &job.progress_sleepers, seen);
            }
        }
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.nchunks) return false;
        defer if (job.ramp != null) {
            _ = job.done_chunks.fetchAdd(1, .release);
        };
        job.doChunk(i, sc) catch |err| {
            _ = job.err.cmpxchgStrong(0, @intFromError(err), .monotonic, .monotonic);
            // Chunks waiting for this one's line count must see the error instead.
            job.std_io.futexWake(u32, &job.published.raw, @intCast(job.nthreads));
        };
        // Also on error, or the writer would wait for this chunk forever.
        if (job.stream) {
            job.ready[i].store(true, .release);
            _ = job.completed.fetchAdd(1, .seq_cst);
            job.wakeOn(&job.completed, &job.completed_sleepers, 1);
        }
        return true;
    }

    fn chunkMode(job: *const Job) Mode {
        if (job.count_only) return .count;
        return if (job.line_numbers) .numbered else .text;
    }

    /// Line number (0-based) the first line of chunk `i` has, given that the chunk holds
    /// `newlines` newlines; publishes the chunk's end for the next one. Waits for chunk
    /// `i - 1` to have published (chunks are claimed in order and are in flight together,
    /// so it has normally just finished).
    /// The time spent waiting for the previous chunks is added to `sc.waited`: it is not
    /// part of the cost of the chunk's access method.
    fn firstLine(job: *Job, i: usize, newlines: usize, sc: *Scratch) !usize {
        var wait_start: ?Io.Timestamp = null;
        while (true) {
            // Snapshot first: a publication after this point makes the wait return at once.
            const seen = job.published.load(.acquire);
            if (seen == i) break;
            if (job.err.load(.monotonic) != 0) return error.Aborted;
            if (wait_start == null) wait_start = Io.Timestamp.now(job.std_io, .awake);
            job.sleepOn(&job.published, &job.published_sleepers, seen);
        }
        if (wait_start) |t| sc.waited += @intCast(@max(0, t.durationTo(Io.Timestamp.now(job.std_io, .awake)).nanoseconds));
        const first: usize = if (i == 0) 0 else job.line_end[i - 1].load(.monotonic);
        job.line_end[i].store(first + newlines, .monotonic);
        job.published.store(@intCast(i + 1), .seq_cst);
        job.wakeOn(&job.published, &job.published_sleepers, @intCast(job.nthreads));
        return first;
    }

    /// Processes chunk `i`: see "Chunks" at the top of the file.
    fn doChunk(job: *Job, i: usize, sc: *Scratch) !void {
        const res = &job.results[i];
        const size = job.data.len;
        const m = job.searcher.needle.len;
        const lo = i * job.chunk_size;
        const hi = @min(lo + job.chunk_size, size);
        // Match starts in [lo, hi) need the bytes up to hi + m - 1; the byte before lo tells
        // whether lo starts a line.
        const v_lo = if (i == 0) 0 else lo - 1;
        const v_hi = @min(hi + m - 1, size);
        const access = job.access.pick(&sc.streak);
        // `pread` starts at a page boundary: the kernel copies from the page cache into the
        // buffer, and with source and destination at different offsets within a cache line
        // the copy is several times slower on x86 (2 MB from offset 2097151: 0.6 to 1.2 ms,
        // against 0.2 ms from offset 0).
        const r_lo = v_lo / std.heap.pageSize() * std.heap.pageSize();
        if (access == .read and sc.read.capacity < v_hi - r_lo) {
            // Readied before the clock starts: buffer set-up is not part of the method.
            if (sc.read.capacity != 0) job.giveReadBuffer(sc.read);
            sc.read = try job.takeReadBuffer(v_hi - r_lo);
        }
        sc.waited = 0;
        const t0 = Io.Timestamp.now(job.std_io, .awake);
        var read_ns: u64 = 0;
        defer {
            const ns: u64 = @intCast(@max(0, t0.durationTo(Io.Timestamp.now(job.std_io, .awake)).nanoseconds));
            job.access.record(&sc.streak, access, ns -| sc.waited, hi - lo);
            if (access == .read and job.ramp != null) {
                _ = job.read_ns.fetchAdd(read_ns, .monotonic);
                _ = job.work_ns.fetchAdd(ns -| sc.waited -| read_ns, .monotonic);
            }
        }
        const view: []const u8 = switch (access) {
            .map_advise => blk: {
                job.adviseWillNeed(v_lo, v_hi);
                break :blk job.data[v_lo..v_hi];
            },
            .map => job.data[v_lo..v_hi],
            .read => blk: {
                sc.read.items.len = v_hi - r_lo; // capacity readied above
                try readAt(job.std_io, job.file.?, sc.read.items, r_lo);
                read_ns = @intCast(@max(0, t0.durationTo(Io.Timestamp.now(job.std_io, .awake)).nanoseconds));
                break :blk sc.read.items[v_lo - r_lo ..];
            },
        };
        // The first line starting in [lo, hi) follows a newline in [lo - 1, hi - 1).
        const first: ?usize = if (i == 0)
            0
        else if (std.mem.indexOfScalar(u8, view[0 .. hi - 1 - v_lo], '\n')) |nl|
            v_lo + nl + 1
        else
            null;
        // Matches starting in [lo, first) belong to a line that began in an earlier chunk:
        // only whether there is one matters, the writer decides that line.
        var cont_found = false;
        var cont: []const u8 = &.{};
        if (i != 0) {
            // A match cannot contain the newline ending that line.
            const c_end = if (first) |f| f - 1 else v_hi;
            if (c_end > lo) cont_found = job.searcher.find(view[lo - v_lo .. c_end - v_lo], 0) != null;
            // The line's bytes in this chunk's range, for the writer.
            const part_end = if (first) |f| f - 1 else hi;
            if (part_end > lo) cont = view[lo - v_lo .. part_end - v_lo];
        }
        try job.runChunk(res, view, v_lo, lo, hi, first, cont_found, cont, i, sc);
    }

    /// Asks the kernel to map in the chunk's pages up front. For pages already in the page
    /// cache that is one call instead of a soft page fault per 16 KB page, and it is done by
    /// each worker for its own chunk, so in parallel. Measured on a 540 MB cached file: a
    /// plain read through the mapping took 42 ms on one thread and 23 ms on eight, 29 ms and
    /// 21 ms with this. Advising the whole file once instead was slower with eight threads
    /// (26 ms), as it serializes what the threads' faults do in parallel.
    fn adviseWillNeed(job: *const Job, lo: usize, hi: usize) void {
        const page = std.heap.pageSize();
        const start = lo / page * page;
        if (hi <= start) return;
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(@constCast(job.data.ptr) + start));
        std.posix.madvise(ptr, hi - start, std.posix.MADV.WILLNEED) catch {};
    }

    /// Writes a chunk's output: its text, with the referenced lines taken from the mapping.
    fn writeChunk(_: *const Job, w: *Io.Writer, r: *const ChunkResult) Io.Writer.Error!void {
        var pos: usize = 0;
        for (r.refs.items) |ref| {
            try w.writeAll(r.out.items[pos..ref.at]);
            try w.writeAll(ref.src[0..ref.len]);
            pos = ref.at;
        }
        try w.writeAll(r.out.items[pos..]);
    }

    /// Writes ready chunk `i` and, if it ends in a pending line, decides and writes that.
    fn writeOne(job: *Job, i: usize, w: *Io.Writer, sc: *Scratch) !void {
        const r = &job.results[i];
        try job.writeChunk(w, r);
        if (r.pending) |pd| try job.resolvePending(i, pd, w, sc);
    }

    /// Writes the first `lines` lines of ready chunk `i` (fewer than it has).
    fn writeLines(job: *Job, i: usize, w: *Io.Writer, lines: usize) !void {
        const r = &job.results[i];
        var left = lines;
        var pos: usize = 0;
        for (r.refs.items) |ref| {
            if (try writeUpTo(w, r.out.items[pos..ref.at], &left)) return;
            // A reference can hold several lines (`appendLineText`); the newline after its
            // last one is in `out`.
            if (try writeUpTo(w, ref.src[0..ref.len], &left)) return;
            pos = ref.at;
        }
        _ = try writeUpTo(w, r.out.items[pos..], &left);
    }

    /// Waits until chunk `j` is done, working on chunks meanwhile (writer side).
    fn waitReady(job: *Job, j: usize, sc: *Scratch) !void {
        job.need.store(j, .release);
        job.madeProgress();
        while (true) {
            const seen = job.completed.load(.acquire);
            if (job.ready[j].load(.acquire)) return;
            // Stopped: chunks no longer handed out would never be ready.
            if (job.err.load(.acquire) != 0) return checkErr(job);
            if (!job.workOne(sc, false)) job.sleepOn(&job.completed, &job.completed_sleepers, seen);
        }
    }

    /// Keeps what the writer needs of a `pread` chunk: the worker's buffer goes to the chunk's
    /// result (the worker takes another), unless all that is needed is a few short pieces of
    /// lines (no `refs`), which are copied instead. Nearly every chunk ends inside a line, so
    /// handing over the buffer would make the workers allocate (and fault in) a new one per
    /// chunk while the writer catches up: on 16 threads with 256 KB chunks, 1300 buffers for
    /// 2000 chunks, and plain output of one matching line 33.5 ms against 26.8 ms with the
    /// pieces copied.
    fn handOver(job: *Job, res: *ChunkResult, sc: *Scratch, has_refs: bool, tail: []const u8, cont: []const u8) void {
        if (!has_refs and tail.len + cont.len <= zero_copy_min_len) copy: {
            var pieces: std.ArrayList(u8) = .empty;
            pieces.ensureTotalCapacityPrecise(job.gpa, tail.len + cont.len) catch break :copy;
            pieces.appendSliceAssumeCapacity(tail);
            pieces.appendSliceAssumeCapacity(cont);
            res.pieces = pieces;
            res.tail = pieces.items[0..tail.len];
            res.cont = pieces.items[tail.len..];
            _ = job.mem.queued.fetchAdd(pieces.items.len, .monotonic);
            return;
        }
        res.buf = sc.read;
        res.tail = tail;
        res.cont = cont;
        sc.read = .empty;
        _ = job.mem.queued.fetchAdd(res.buf.items.len, .monotonic);
    }

    /// Writes file bytes [a, b): from the mapping, or read in pieces while the mapping is
    /// the slow way in (`AccessStats` found `pread` fastest).
    fn writeRange(job: *Job, out: *Io.Writer, a: usize, b: usize) !void {
        if (job.access.best() != .read) return out.writeAll(job.data[a..b]);
        var piece: [256 * 1024]u8 = undefined;
        var off = a;
        while (off < b) {
            const n = @min(b - off, piece.len);
            try readAt(job.std_io, job.file.?, piece[0..n], off);
            try out.writeAll(piece[0..n]);
            off += n;
        }
    }

    /// Writes the part of `piece` (file bytes from `start`) that lies in [pos, e), after
    /// any gap before it; returns the new position.
    fn writePiece(job: *Job, out: *Io.Writer, piece: []const u8, start: usize, pos: usize, e: usize) !usize {
        if (piece.len == 0) return pos;
        const pe = @min(start + piece.len, e);
        if (pe <= pos) return pos;
        if (pos < start) try job.writeRange(out, pos, start);
        const from = @max(pos, start);
        try out.writeAll(piece[from - start .. pe - start]);
        return pe;
    }

    /// Decides the pending last line of chunk `i` from the chunks it runs into, and writes
    /// it (straight from the mapping) if it matches. With `w` null (counting) the chunks are
    /// all done already; otherwise this waits for the ones it needs.
    fn resolvePending(job: *Job, i: usize, pd: Pending, w: ?*Io.Writer, sc: ?*Scratch) !void {
        const size = job.data.len;
        var matched = pd.found;
        var end: ?usize = null;
        var j = i + 1;
        var last = job.nchunks - 1; // the last chunk the line reaches into
        while (j < job.nchunks) : (j += 1) {
            if (sc) |s| try job.waitReady(j, s);
            const rj = &job.results[j];
            if (rj.cont_found) matched = true;
            if (rj.first_start) |fs| {
                end = fs - 1; // the newline before the next line
                last = j;
                break;
            }
        }
        // No later line start: the line runs to the end, minus a final newline.
        const e = end orelse if (size > pd.start and job.data[size - 1] == '\n') size - 1 else size;
        if (!matched) return;
        job.results[i].count += 1;
        const out = w orelse return;
        if (job.line_numbers) {
            try writeUint(out, pd.line + 1);
            try out.writeByte(':');
        }
        // The line from the pieces the `pread` chunks kept, the gaps from the file.
        var pos = try job.writePiece(out, job.results[i].tail, pd.start, pd.start, e);
        var k = i + 1;
        while (k <= last and k < job.nchunks) : (k += 1) {
            pos = try job.writePiece(out, job.results[k].cont, k * job.chunk_size, pos, e);
        }
        if (pos < e) try job.writeRange(out, pos, e);
        try out.writeByte('\n');
    }

    /// Whether `hay` lies inside the mapping (not in a `pread` buffer), so that lines of it
    /// can be referenced by file offset.
    fn isMapped(job: *const Job, hay: []const u8) bool {
        const lo = @intFromPtr(job.data.ptr);
        const p = @intFromPtr(hay.ptr);
        return p >= lo and p + hay.len <= lo + job.data.len;
    }

    /// At the first matching line of a chunk: an output buffer for all of it. Reserved in
    /// one go: growing by reallocation leaves freed blocks behind in the allocator, which
    /// would show up as memory well beyond the budget. Reserved but untouched pages cost
    /// nothing. Not before a match: chunks without one would each hold a buffer until the
    /// writer gets to them, and with many small chunks the pool runs dry and the workers
    /// keep mapping new ones (16 threads, 2000 chunks: 460 buffers for one matching line).
    noinline fn reserveOut(job: *Job, out: *std.ArrayList(u8), n: usize) !void {
        @branchHint(.cold);
        out.* = job.takeBuffer();
        try out.ensureTotalCapacity(job.gpa, n);
    }

    /// Appends the line `hay[ls..le]` and its newline to `out`; a very long line is recorded
    /// in `refs` instead of being copied (a `pread` chunk then hands its buffer over).
    inline fn appendLineText(job: *Job, out: *std.ArrayList(u8), refs: *std.ArrayList(Ref), hay: []const u8, ls: usize, le: usize) !void {
        if (out.capacity == 0) try job.reserveOut(out, hay.len + 1);
        const n = le - ls;
        if (n >= zero_copy_min_len) {
            const start = hay.ptr + ls;
            try out.ensureUnusedCapacity(job.gpa, 1);
            // A line that directly follows the previous referenced one, with nothing but the
            // newline in between, extends that reference: the file holds the same bytes, and
            // the writer then needs one write instead of two.
            if (refs.items.len != 0) {
                const last = &refs.items[refs.items.len - 1];
                if (out.items.len == last.at + 1 and last.src + last.len + 1 == start) {
                    out.items.len -= 1; // the newline is now part of the reference
                    last.len = @intFromPtr(start + n) - @intFromPtr(last.src);
                    out.appendAssumeCapacity('\n');
                    return;
                }
            }
            try refs.append(job.gpa, .{ .at = out.items.len, .src = start, .len = n });
            out.appendAssumeCapacity('\n');
        } else {
            try out.ensureUnusedCapacity(job.gpa, n + 1);
            search.appendLine(out, hay[ls..le]);
        }
    }

    /// Searches and renders the lines that start in [lo, hi). `view` holds the file bytes
    /// from offset `v_lo`; `first` is the first line start in the range, if any.
    fn runChunk(job: *Job, res: *ChunkResult, view: []const u8, v_lo: usize, lo: usize, hi: usize, first: ?usize, cont_found: bool, cont: []const u8, chunk: usize, sc: *Scratch) !void {
        const mode = job.chunkMode();
        const sr = job.searcher; // a local copy: the compiler then knows nothing else touches it
        const m = sr.needle.len;
        const at_eof = v_lo + view.len == job.data.len;
        // Accumulate in locals and publish once: `res` shares cache lines with the
        // results of neighbouring chunks that other threads are writing.
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(job.gpa);
        var refs: std.ArrayList(Ref) = .empty;
        errdefer refs.deinit(job.gpa);
        var count: usize = 0;
        var pending: ?Pending = null;
        var own_newlines: usize = 0; // in [first, hi)
        var own_base_offset: usize = 0; // first's offset from lo, as a line count: 1 if lo is mid-line
        const f = first orelse {
            // No line starts here: we are inside a line that began earlier. The only newline
            // the range can hold is at hi - 1 (it ends that line).
            const newlines: usize = @intFromBool(hi > lo and view[hi - 1 - v_lo] == '\n');
            if (mode == .numbered) _ = try job.firstLine(chunk, newlines, sc);
            res.* = .{ .cont_found = cont_found };
            if (mode != .count and !job.isMapped(view) and cont.len != 0) job.handOver(res, sc, false, &.{}, cont);
            return;
        };
        own_base_offset = @intFromBool(f > lo);
        const hay = view[f - v_lo ..]; // file bytes [f, v_lo + view.len)
        const own_end = hi - f; // match starts below this are ours
        std.debug.assert(hay.len <= std.math.maxInt(u32));
        if (mode == .numbered) {
            // At most one match per m + 1 bytes.
            sc.matches.clearRetainingCapacity();
            try sc.matches.ensureTotalCapacity(job.gpa, hay.len / (m + 1) + 1);
        }
        // With line numbers the search also counts the newlines it passes over (cheaper than
        // a second pass).
        switch (mode) {
            inline else => |md| {
                var sink: LineSink(md) = .{ .job = job, .hay = hay, .out = &out, .refs = &refs, .sc = sc, .m = m, .open_end = !at_eof };
                try sr.forEachMatch(md == .numbered, hay, 0, &sink);
                count = sink.count;
                if (sink.pending) |pl| {
                    // The scan stopped at a match in a line that runs past the view; there
                    // are no newlines after it within the view.
                    pending = .{ .start = f + pl.start, .line = pl.line, .found = true };
                    own_newlines = pl.line;
                } else {
                    // Newlines counted in [hi, end of view) are not ours.
                    own_newlines = sink.nl_at_pos + sink.tail_nl;
                    if (md == .numbered and hay.len > own_end) own_newlines -= search.countNewlinesIn(hay, own_end, hay.len);
                    // The last line starting in the range, if it runs past the view, is
                    // pending without a match of ours.
                    const ls = if (search.lastNewline(hay, own_end)) |prev| prev + 1 else 0;
                    if (!at_eof and ls < own_end and search.nextNewline(hay, ls) == hay.len) {
                        pending = .{ .start = f + ls, .line = own_newlines, .found = false };
                    }
                }
            },
        }
        if (mode == .numbered) {
            // The chunk is still in the cache: as soon as the numbering of its first line is
            // known, render it instead of coming back to it after the whole file was searched.
            const base = try job.firstLine(chunk, own_base_offset + own_newlines, sc);
            const first_line = base + own_base_offset;
            if (pending) |*pd| pd.line += first_line;
            out = job.takeBuffer();
            var cap: usize = 0;
            for (sc.matches.items) |mt| {
                const n = mt.end - mt.start;
                cap += max_prefix + 1 + if (n >= zero_copy_min_len) 0 else n;
            }
            try out.ensureTotalCapacity(job.gpa, cap);
            // The capacity reserved above covers every line, so no checks in the loop.
            for (sc.matches.items) |mt| {
                appendPrefix(&out, first_line + mt.line + 1);
                if (mt.end - mt.start >= zero_copy_min_len) {
                    try refs.append(job.gpa, .{ .at = out.items.len, .src = hay.ptr + mt.start, .len = mt.end - mt.start });
                    out.appendAssumeCapacity('\n');
                } else {
                    search.appendLine(&out, hay[mt.start..mt.end]);
                }
            }
        }
        res.* = .{ .out = out, .refs = refs, .count = count, .first_start = f, .cont_found = cont_found, .pending = pending };
        _ = job.mem.queued.fetchAdd(out.items.len, .monotonic);
        if (mode == .count and job.max_matches != 0 and job.found.fetchAdd(count, .monotonic) + count >= job.max_matches) job.halt();
        // References into a `pread` buffer, and the pieces of lines that the writer will put
        // together, keep the buffer alive until the writer is done with it.
        if (mode != .count and !job.isMapped(view)) {
            const tail: []const u8 = if (pending) |pd| view[pd.start - v_lo .. hi - v_lo] else &.{};
            if (refs.items.len != 0 or tail.len != 0 or cont.len != 0) job.handOver(res, sc, refs.items.len != 0, tail, cont);
        }
    }
};

/// What a chunk produces: nothing (`-c`), output text, or output text with line numbers.
const Mode = enum { count, text, numbered };

/// Handles the matches the scan finds in one chunk: renders the line (`.text`), records it
/// for numbering (`.numbered`) or just counts it (`.count`), and tells the scan where to
/// resume, the start of the next line. A match in a line that runs past the end of the
/// view (`open_end`) ends the scan: that line is decided by the writer.
fn LineSink(comptime mode: Mode) type {
    return struct {
        job: *Job,
        hay: []const u8,
        out: *std.ArrayList(u8),
        refs: *std.ArrayList(Ref),
        sc: *Scratch,
        m: usize,
        /// The view ends before the file does.
        open_end: bool,
        count: usize = 0,
        /// Newlines before the resume position (counted with `.numbered` only).
        nl_at_pos: usize = 0,
        /// Newlines between the last resume position and the end of the view.
        tail_nl: usize = 0,
        /// Set when a match was found in a line running past the view: its start (relative to
        /// `hay`) and its index among the chunk's lines.
        pending: ?struct { start: usize, line: usize } = null,

        /// Inlined into the scan loop on purpose: as a call it costs a few ns per match, which
        /// is measurable with millions of matching lines.
        pub inline fn match(k: *@This(), p: usize, nl: usize) !usize {
            const le = search.nextNewline(k.hay, p + k.m);
            if (le == k.hay.len and k.open_end) return k.stopAt(p, nl);
            k.count += 1;
            const ls = if (mode == .count) 0 else if (search.lastNewline(k.hay, p)) |prev| prev + 1 else 0;
            switch (mode) {
                .count => {},
                .numbered => k.sc.matches.appendAssumeCapacity(.{
                    .start = @intCast(ls),
                    .end = @intCast(le),
                    .line = @intCast(k.nl_at_pos + nl),
                }),
                .text => try k.job.appendLineText(k.out, k.refs, k.hay, ls, le),
            }
            if (mode == .numbered) k.nl_at_pos += nl + @intFromBool(le < k.hay.len);
            return le + 1;
        }

        /// The match at `p` is in a line that runs past the view: record it and end the scan.
        /// Kept out of `match` so that `match` stays small enough to be inlined into the scan.
        noinline fn stopAt(k: *@This(), p: usize, nl: usize) usize {
            @branchHint(.cold);
            const ls = if (search.lastNewline(k.hay, p)) |prev| prev + 1 else 0;
            k.pending = .{ .start = ls, .line = k.nl_at_pos + nl };
            return std.math.maxInt(usize);
        }

        pub fn done(k: *@This(), nl: usize) void {
            k.tail_nl = nl;
        }
    };
}

/// Room for a line number: 20 digits of a u64 plus ':'.
const max_prefix = 21;

/// "00" .. "99", for writing two digits per division.
const digit_pairs = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + i / 10;
        t[2 * i + 1] = '0' + i % 10;
    }
    break :blk t;
};

/// Appends "<n>:"; the caller has reserved `max_prefix` bytes.
fn appendPrefix(out: *std.ArrayList(u8), number: usize) void {
    var tmp: [max_prefix]u8 = undefined;
    var k: usize = tmp.len - 1;
    tmp[k] = ':';
    var n = number;
    while (n >= 100) {
        const pair = n % 100;
        n /= 100;
        k -= 2;
        tmp[k] = digit_pairs[2 * pair];
        tmp[k + 1] = digit_pairs[2 * pair + 1];
    }
    if (n >= 10) {
        k -= 2;
        tmp[k] = digit_pairs[2 * n];
        tmp[k + 1] = digit_pairs[2 * n + 1];
    } else {
        k -= 1;
        tmp[k] = '0' + @as(u8, @intCast(n));
    }
    out.appendSliceAssumeCapacity(tmp[k..]);
}

test "appendPrefix formats numbers" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try out.ensureTotalCapacity(testing.allocator, 8 * max_prefix);
    for ([_]usize{ 1, 9, 10, 99, 100, 101, 999, 1000, 12345, 9_999_999, 18446744073709551615 }) |n| {
        out.clearRetainingCapacity();
        appendPrefix(&out, n);
        var want: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{d}:", .{n}), out.items);
    }
}

/// Fills `dest` from file offset `offset` (positional read: threads share the file).
fn readAt(io: Io, file: Io.File, dest: []u8, offset: usize) !void {
    const n = try file.readPositionalAll(io, dest, offset);
    if (n != dest.len) return error.FileChanged; // the file shrank while we were reading it
}

/// The access methods the workers may choose from. `--io=mmap` and `--io=pread` restrict
/// them; with few chunks (`Policy.min_chunks`) the residency guess (`chooseIo`) decides
/// alone: with each method tried on some chunks, the slower ones would be a large share of
/// the work.
fn allowedAccess(choice: IoChoice, guess: IoMode, nchunks: usize, policy: AccessStats.Policy) [3]bool {
    return switch (choice) {
        .mmap => .{ true, true, false },
        .pread => .{ false, false, true },
        .auto => if (nchunks < policy.min_chunks) switch (guess) {
            .mmap => .{ true, false, false },
            .pread => .{ false, false, true },
        } else .{ true, true, true },
    };
}

/// Picks mmap when (nearly) the whole file is already in the page cache.
///
/// Asking the kernel about every page costs milliseconds on a large file, and many
/// small `mincore` calls on a cold file measurably slow the reads that follow, so a
/// handful of evenly spaced runs of pages is sampled instead.
fn chooseIo(mapped: []align(std.heap.page_size_min) u8) IoMode {
    const page = std.heap.pageSize();
    const pages = (mapped.len + page - 1) / page;
    const span: usize = @min(pages, 32); // pages per sample
    const samples: usize = @min(pages / span, 8);
    var resident: usize = 0;
    var vec: [32]u8 = undefined;
    for (0..samples) |k| {
        const first = k * (pages - span) / @max(samples - 1, 1);
        std.posix.mincore(@alignCast(mapped.ptr + first * page), span * page, &vec) catch return .mmap;
        for (vec[0..span]) |v| resident += v & 1;
    }
    return if (resident * 100 >= samples * span * mmap_resident_percent) .mmap else .pread;
}

/// Default memory limit: what the `threads` need (`per_thread` each) times
/// `default_limit_factor`, at least `min_default_limit`; and never more than what can be
/// allocated now without pushing the system into swap, nor than half of the physical memory.
fn defaultMemoryLimit(io: Io, threads: usize, per_thread: usize) usize {
    const wanted = @max(min_default_limit, threads * per_thread * default_limit_factor);
    const half = (std.process.totalSystemMemory() catch 2 << 30) / 2;
    const available = availableMemory(io) orelse return @min(half, wanted);
    return @intCast(@min(@min(half, available), wanted));
}

/// The default limit is `default_limit_factor` times what the threads need (`memoryPerThread`),
/// at least `min_default_limit`: more memory than that did not make zg faster. Cases of the
/// standard set that print millions of lines to /dev/null (16 threads, 3 MB each, Zen 3; time at
/// the limit against the time with the whole of the memory): 32 MB, up to 22 % slower; 64 MB,
/// up to 7 %; 128 MB, none. The factor 3 puts the default (144 MB there) at twice the point
/// where nothing is lost. The count mode needs a tenth (the floor applies). The limit used to
/// be what the system could hand out, at most half of the physical memory: gigabytes, which
/// only a reader slower than the search ever used, and which a container with a memory limit
/// of its own (the system does not tell zg) could not give.
const default_limit_factor = 3;
const min_default_limit = 32 << 20;

/// Memory the system can hand out right now without swapping: free pages plus pages it
/// reclaims cheaply (clean page cache, speculative and purgeable pages). Null if unknown.
fn availableMemory(io: Io) ?u64 {
    switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // `vm_statistics64` up to the fields we need; the kernel fills as many fields
            // as `count` says, so the prefix is enough on any OS version.
            const VmStats = extern struct {
                free_count: u32,
                active_count: u32,
                inactive_count: u32,
                wire_count: u32,
                zero_fill_count: u64,
                reactivations: u64,
                pageins: u64,
                pageouts: u64,
                faults: u64,
                cow_faults: u64,
                lookups: u64,
                hits: u64,
                purges: u64,
                purgeable_count: u32,
                speculative_count: u32,
            };
            const host_vm_info64 = 4;
            const S = struct {
                extern "c" fn host_statistics64(host: std.c.mach_port_t, flavor: c_int, info: *VmStats, count: *u32) c_int;
            };
            var st: VmStats = undefined;
            var count: u32 = @sizeOf(VmStats) / @sizeOf(u32);
            if (S.host_statistics64(std.c.mach_host_self(), host_vm_info64, &st, &count) != 0) return null;
            const page: u64 = std.heap.pageSize();
            return (@as(u64, st.free_count) + st.inactive_count + st.speculative_count + st.purgeable_count) * page;
        },
        .linux => {
            // MemAvailable from /proc/meminfo, the kernel's own estimate of the same thing.
            var buf: [4096]u8 = undefined;
            const text = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buf) catch return null;
            const key = "MemAvailable:";
            const at = std.mem.indexOf(u8, text, key) orelse return null;
            var it = std.mem.tokenizeAny(u8, text[at + key.len ..], " \n");
            const kb = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
            return kb * 1024;
        },
        else => return null,
    }
}

test "availableMemory is plausible" {
    const total = try std.process.totalSystemMemory();
    if (availableMemory(testing.io)) |a| {
        try testing.expect(a > 0 and a <= total);
    }
    try testing.expect(defaultMemoryLimit(testing.io, 16, memoryPerThread(testing.io, .{ .pattern = "x" })) <= total / 2);
}

test "the default memory limit follows the threads and the chunk size, not the machine's memory" {
    const mib = 1 << 20;
    const total = (std.process.totalSystemMemory() catch 2 << 30) / 2;
    const per_thread = memoryPerThread(testing.io, .{ .pattern = "x" });
    // The floor, for few threads.
    try testing.expect(defaultMemoryLimit(testing.io, 1, per_thread) >= @min(min_default_limit, total));
    // Threads times what each needs, times the factor, as far as the machine has the memory.
    const want = 16 * per_thread * default_limit_factor;
    try testing.expect(defaultMemoryLimit(testing.io, 16, per_thread) <= @max(want, min_default_limit));
    if (want <= total and want < 8 * 1024 * mib) {
        const got = defaultMemoryLimit(testing.io, 16, per_thread);
        try testing.expect(got <= want);
        // availableMemory may be lower on a busy machine, but never lower than the floor's order.
        try testing.expect(got >= @min(want, 16 * mib));
    }
    // Counting needs less per thread than rendering.
    try testing.expect(defaultMemoryLimit(testing.io, 16, memoryPerThread(testing.io, .{ .pattern = "x", .count_only = true })) <= defaultMemoryLimit(testing.io, 16, per_thread));
    // A search with the default limit gives the reference output.
    const gpa = testing.allocator;
    const data = try genText(gpa, 32, 3000, "abc ", 0, true);
    defer gpa.free(data);
    for ([_]bool{ false, true }) |numbered| {
        try expectMatchesReference(data, .{ .pattern = "ab", .line_numbers = numbered, .chunk_size = 256 });
    }
}

/// Bytes of the file's beginning used to choose the filter of a weak pattern.
const tune_sample_bytes = 256 * 1024;

/// The searcher for `pattern`, its filter tuned on the start of the file (how many bytes for
/// weak patterns, the scan step for the others). In `pread` mode the sample is read rather than mapped, so as not to
/// touch cold pages through the mapping.
fn tunedSearcher(io: Io, pattern: []const u8, mapped: []const u8, io_mode: IoMode, file: ?Io.File) search.Searcher {
    var s = search.Searcher.init(pattern);
    if (pattern.len < 2) return s;
    const n = @min(mapped.len, tune_sample_bytes);
    switch (io_mode) {
        .mmap => s.tune(mapped[0..n]),
        .pread => {
            var buf: [tune_sample_bytes]u8 = undefined;
            readAt(io, file.?, buf[0..n], 0) catch return s;
            s.tune(buf[0..n]);
        },
    }
    return s;
}

/// Chunks are at least this many bytes, whatever the memory limit.
const min_chunk = 256 * 1024;

/// The largest a chunk gets: a thread's share of the L2 cache, at most 2 MB (`l2PerThread`).
fn chunkCeiling(io: Io) usize {
    return @max(min_chunk, @min(l2PerThread(io), 2 * 1024 * 1024));
}

/// Memory each thread needs on top of the accounted budget, in chunks: measured with a
/// stalled reader (peak footprint beyond the budget, per thread) it is about 4 chunks when
/// the thread renders output, with or without line numbers (a chunk's output buffer, its
/// matches, its `pread` buffer), of which three times is reserved; counting only needs the
/// thread's own working set, about a chunk, of which twice is reserved. With the 2 MB chunks
/// of the Mac that is 24 MB and 4 MB (as it was, as a constant, before chunks followed the
/// cache); with the 256 KB chunks of a Zen 3 core, 3 MB and 512 KB, and 16 threads then
/// allocated 12 to 30 MB in all (`--io=pread`, measured), not the 384 MB the old constant
/// reserved.
fn memoryPerThread(io: Io, opts: Options) usize {
    return chunkCeiling(io) * @as(usize, if (opts.count_only) 2 else 12);
}

const max_threads = 1024;

/// Number of threads to use: an explicit request is honoured; otherwise one per CPU, but
/// no more than the memory limit can carry (at least one).
fn threadsFor(requested: usize, cpus: usize, limit: usize, per_thread: usize) usize {
    const n = if (requested != 0) requested else @min(cpus, @max(1, limit / per_thread));
    return std.math.clamp(n, 1, max_threads);
}

/// Searches `file` and writes the matching lines (or, with `count_only`, just their
/// number) to `w`, in file order. Returns the number of matching lines. The same as a
/// search on an `Engine(.oneshot)`.
pub fn run(io: Io, gpa: std.mem.Allocator, file: Io.File, opts: Options, w: *Io.Writer) !usize {
    var engine: Engine(.oneshot) = .init(io, gpa);
    return engine.search(.{ .file = file }, opts, w);
}

pub const Kind = enum {
    /// Each search starts its own threads and works out its own memory limit, like the
    /// command line tool.
    oneshot,
    /// A long-lived engine, for a server: one pool of threads and one memory limit for all
    /// the searches running at a time, which take turns on the threads chunk by chunk.
    shared,
};

/// Settings of a shared engine.
pub const Config = struct {
    /// Threads working on chunks, the calling threads of the searches included (each
    /// search's caller writes its output and helps with its chunks): the pool has one
    /// fewer. 0 means one per CPU, fewer if the memory limit cannot carry them.
    threads: usize = 0,
    /// Cap on the memory all searches together allocate; 0 as for `Options.memory_limit`.
    memory_limit: usize = 0,
};

/// The search engine. Both kinds run the same code on the chunks of a search; they differ
/// in where the threads and the memory budget come from.
///
///     var engine: zg.Engine(.shared) = try .init(io, gpa, .{});
///     defer engine.deinit();
///     const matches = try engine.search(.{ .file = file }, .{ .pattern = "needle" }, writer);
pub fn Engine(comptime kind: Kind) type {
    return switch (kind) {
        .oneshot => struct {
            io: Io,
            gpa: std.mem.Allocator,

            pub fn init(io: Io, gpa: std.mem.Allocator) @This() {
                return .{ .io = io, .gpa = gpa };
            }

            pub fn search(e: *@This(), src: Source, opts: Options, w: *Io.Writer) !usize {
                return searchFile(.oneshot, e.io, e.gpa, {}, src, opts, w);
            }

            /// Like `search`, but hands each matching line to `on_line` instead of
            /// writing it (`count_only` and `line_numbers` are not used).
            pub fn searchLines(e: *@This(), src: Source, opts: Options, ctx: ?*anyopaque, on_line: OnLine) !usize {
                return linesOf(e, e.gpa, src, opts, ctx, on_line);
            }
        },
        .shared => struct {
            pool: *Pool,

            pub fn init(io: Io, gpa: std.mem.Allocator, config: Config) !@This() {
                return .{ .pool = try Pool.create(io, gpa, config) };
            }

            /// Waits for the pool's threads to stop; no search may be running.
            pub fn deinit(e: *@This()) void {
                e.pool.destroy();
            }

            /// Like `run`; may be called from several threads at once. `opts.threads`, if
            /// not 0, caps the threads on this search (the caller's included);
            /// `opts.memory_limit` is not used, the engine's limit applies.
            pub fn search(e: *@This(), src: Source, opts: Options, w: *Io.Writer) !usize {
                return searchFile(.shared, e.pool.io, e.pool.gpa, e.pool, src, opts, w);
            }

            /// Like `search`, but hands each matching line to `on_line` instead of
            /// writing it (`count_only` and `line_numbers` are not used).
            pub fn searchLines(e: *@This(), src: Source, opts: Options, ctx: ?*anyopaque, on_line: OnLine) !usize {
                return linesOf(e, e.pool.gpa, src, opts, ctx, on_line);
            }
        },
    };
}

/// `searchLines`: a numbered search whose output is split back into lines.
fn linesOf(engine: anytype, gpa: std.mem.Allocator, src: Source, opts: Options, ctx: ?*anyopaque, on_line: OnLine) !usize {
    var o = opts;
    o.line_numbers = true;
    o.count_only = false;
    var buf: [64 * 1024]u8 = undefined;
    var ls: LineSplitter = .{ .w = .{ .vtable = &.{ .drain = LineSplitter.drain }, .buffer = &buf }, .gpa = gpa, .ctx = ctx, .on_line = on_line };
    defer ls.partial.deinit(gpa);
    return engine.search(src, o, &ls.w) catch |err| {
        if (err == error.WriteFailed) if (ls.err) |e| return e;
        return err;
    };
}

/// A writer that takes numbered output ("N:line\n") and calls `on_line` for each line.
const LineSplitter = struct {
    w: Io.Writer,
    gpa: std.mem.Allocator,
    ctx: ?*anyopaque,
    on_line: OnLine,
    /// The start of a line whose end has not come yet.
    partial: std.ArrayList(u8) = .empty,
    /// The error `on_line` returned (the search sees `error.WriteFailed`).
    err: ?anyerror = null,

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const ls: *LineSplitter = @alignCast(@fieldParentPtr("w", w));
        try ls.feed(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try ls.feed(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try ls.feed(last);
        return n + last.len * splat;
    }

    fn feed(ls: *LineSplitter, bytes: []const u8) Io.Writer.Error!void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            if (ls.partial.items.len == 0) {
                try ls.emit(rest[0..nl]);
            } else {
                ls.partial.appendSlice(ls.gpa, rest[0..nl]) catch return error.WriteFailed;
                try ls.emit(ls.partial.items);
                ls.partial.clearRetainingCapacity();
            }
            rest = rest[nl + 1 ..];
        }
        ls.partial.appendSlice(ls.gpa, rest) catch return error.WriteFailed;
    }

    fn emit(ls: *LineSplitter, line: []const u8) Io.Writer.Error!void {
        const colon = std.mem.indexOfScalar(u8, line, ':').?; // the prefix has no ':' in it
        const number = std.fmt.parseInt(usize, line[0..colon], 10) catch unreachable;
        ls.on_line(ls.ctx, number, line[colon + 1 ..]) catch |err| {
            ls.err = err;
            return error.WriteFailed;
        };
    }
};

/// The threads of a shared engine and the searches they work on.
const Pool = struct {
    io: Io,
    gpa: std.mem.Allocator,
    threads: []std.Thread,
    /// The engine's memory limit, and the accounted part of it that its searches share.
    limit: usize,
    mem: Memory,
    /// Buffers kept from one search to the next; while no search runs, at most `retain`
    /// bytes of them.
    bufs: Buffers = .{},
    retain: usize,
    /// Searches with work for the pool, under `lock`; `turn` rotates through them, so that
    /// every search gets threads and a small one is not stuck behind a large one.
    jobs: std.ArrayList(*Job) = .empty,
    lock: Lock = .{},
    turn: usize = 0,
    /// Number of `jobs`, readable without the lock.
    njobs: std.atomic.Value(usize) = .init(0),
    /// Pool threads on a search right now. Each search's caller works on its chunks too,
    /// so with `n` searches running only `threads.len + 1 - n` pool threads (at least one)
    /// take work: more threads than cores made the operating system share cores between
    /// them in slices of milliseconds. With a large search producing much output and four
    /// small ones, the small ones' p99 latency was 6.6 ms on 7 pool threads, 4.4 ms on 4 and
    /// 1.6 ms on 2, against 2.0 ms without the large search.
    busy: std.atomic.Value(usize) = .init(0),
    /// Futex word, bumped whenever there may be new work: a search was added, a writer
    /// moved on, a thread left a search.
    signal: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    /// What earlier searches measured of the access methods, per file size class
    /// (`sizeClass`), under `lock`, so that a search does not have to find out again.
    priors: [size_classes]Priors = @splat(.{}),
    maps: MapCache = .{},
    tunes: TuneCache = .{},

    /// Files up to 4 MB, 32 MB, 256 MB, larger.
    const size_classes = 4;
    /// Below this class a search uses one method throughout, chosen from the whole-search
    /// times of earlier ones (`plan`); from it on, the chunks keep choosing (`seed`).
    ///
    /// Per-chunk timing needs chunks: on files of a few MB all of them run while the
    /// threads start, and the measured rates misled. Searching cached files with a shared
    /// engine (count, all threads, µs, the first method with per-chunk choice between
    /// `map_advise` and `map`):
    ///
    ///     size        mapped   pread   per-chunk choice of all three
    ///     2 MB          111     136     150
    ///     8 MB          275     247     357
    ///     64 MB        2028    2340    2140
    ///     256 MB       8033   10525    8278
    const chunk_choice_class = 3;

    fn sizeClass(size: usize) usize {
        if (size <= 4 << 20) return 0;
        if (size <= 32 << 20) return 1;
        if (size <= 256 << 20) return 2;
        return 3;
    }

    const Priors = struct {
        /// Nanoseconds per byte; 0 while unknown. Below `chunk_choice_class`: of whole
        /// searches that used `Plan.methods[k]`; from it on: of chunks with access method k.
        rate: [3]f64 = @splat(0),
        searches: u32 = 0,

        /// One search in this many tries something else than the best known, so that the
        /// priors follow changes of the system.
        const explore_every = 16;
        /// Weight of a new measurement against the priors.
        const weight = 0.3;

        /// A measurement under half the prior replaces it: a first search of a file that
        /// was not in the page cache measured rates a hundred times the warm ones, and
        /// averaging that away took a dozen searches with the wrong method.
        fn update(r: *f64, rate: f64) void {
            r.* = if (r.* == 0 or rate < r.* / 2) rate else r.* + weight * (rate - r.*);
        }
    };

    /// How a search below `chunk_choice_class` reads the file: mapped (choosing between
    /// `map_advise` and `map` per chunk) or with `pread`.
    const Plan = struct {
        const methods = [_]IoChoice{ .mmap, .pread };
        index: usize,
        class: usize,
        start: Io.Timestamp,
    };

    /// The method for a search of a file in `class`: the one with the best whole-search
    /// time, except for the searches that measure the others. Null from
    /// `chunk_choice_class` on.
    fn plan(p: *Pool, class: usize) ?Plan {
        if (class >= chunk_choice_class) return null;
        p.acquire();
        defer p.release();
        const pr = &p.priors[class];
        defer pr.searches +%= 1;
        const n = Plan.methods.len;
        var best: usize = 0;
        for (pr.rate[0..n], 0..) |r, k| {
            if (r == 0) return .{ .index = k, .class = class, .start = Io.Timestamp.now(p.io, .awake) };
            if (r < pr.rate[best]) best = k;
        }
        const k = if (pr.searches % Priors.explore_every == 0) (best + 1 + pr.searches / Priors.explore_every % (n - 1)) % n else best;
        return .{ .index = k, .class = class, .start = Io.Timestamp.now(p.io, .awake) };
    }

    /// Records how long a planned search of `size` bytes took, start to end.
    fn learnPlan(p: *Pool, pl: Plan, size: usize) void {
        const ns: f64 = @floatFromInt(pl.start.durationTo(Io.Timestamp.now(p.io, .awake)).nanoseconds);
        const rate = ns / @as(f64, @floatFromInt(size));
        p.acquire();
        defer p.release();
        Priors.update(&p.priors[pl.class].rate[pl.index], rate);
    }

    /// From `chunk_choice_class` on: starts `st` from the priors of the class instead of
    /// trying every method (except in the searches that refresh the priors). The priors
    /// count as `chunk_bytes` bytes measured per method, so the search's own chunks soon
    /// outweigh them.
    fn seed(p: *Pool, st: *AccessStats, class: usize, chunk_bytes: usize) void {
        p.acquire();
        defer p.release();
        const pr = &p.priors[class];
        defer pr.searches +%= 1;
        if (pr.searches % Priors.explore_every == 0) return;
        for (st.allowed, pr.rate) |ok, r| if (ok and r == 0) return;
        for (st.allowed, pr.rate, 0..) |ok, r, k| if (ok) {
            st.seeded_ns[k] = @intFromFloat(r * @as(f64, @floatFromInt(chunk_bytes)));
            st.ns[k].store(st.seeded_ns[k], .monotonic);
            st.bytes[k].store(chunk_bytes, .monotonic);
            st.warm[k].store(st.policy.warm_runs, .monotonic);
            st.seen[k].store(1, .monotonic);
        };
        st.seeded = chunk_bytes;
    }

    /// Folds the per-chunk rates of a finished search into the priors of its class.
    fn learn(p: *Pool, st: *const AccessStats, class: usize) void {
        p.acquire();
        defer p.release();
        const pr = &p.priors[class];
        for (&pr.rate, 0..) |*r, k| {
            const bytes = st.bytes[k].load(.monotonic) -| st.seeded;
            if (!st.allowed[k] or bytes == 0) continue;
            const ns = st.ns[k].load(.monotonic) -| st.seeded_ns[k];
            Priors.update(r, @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(bytes)));
        }
    }

    fn create(io: Io, gpa: std.mem.Allocator, config: Config) !*Pool {
        const cpus = std.Thread.getCpuCount() catch 1;
        const wanted_threads = if (config.threads != 0) config.threads else cpus;
        const limit = if (config.memory_limit != 0) config.memory_limit else defaultMemoryLimit(io, wanted_threads, memoryPerThread(io, .{ .pattern = "" }));
        const n = threadsFor(config.threads, cpus, limit, memoryPerThread(io, .{ .pattern = "" }));
        BusGuard.install();
        const p = try gpa.create(Pool);
        errdefer gpa.destroy(p);
        p.* = .{ .io = io, .gpa = gpa, .threads = &.{}, .limit = limit, .mem = .{ .budget = limit / 3 * 2 }, .retain = @min(64 << 20, limit / 4) };
        const threads = try gpa.alloc(std.Thread, n - 1);
        errdefer gpa.free(threads);
        for (threads, 0..) |*t, k| {
            t.* = std.Thread.spawn(.{}, work, .{p}) catch |err| {
                p.stop(threads[0..k]);
                return err;
            };
        }
        p.threads = threads;
        return p;
    }

    fn destroy(p: *Pool) void {
        std.debug.assert(p.jobs.items.len == 0);
        p.stop(p.threads);
        p.bufs.trim(p.io, p.gpa, &p.mem, 0);
        p.maps.deinit();
        p.tunes.deinit(p.gpa);
        p.jobs.deinit(p.gpa);
        p.gpa.free(p.threads);
        p.gpa.destroy(p);
    }

    fn stop(p: *Pool, threads: []std.Thread) void {
        p.stopping.store(true, .release);
        p.wake();
        for (threads) |t| t.join();
    }

    fn acquire(p: *Pool) void {
        p.lock.acquire(p.io);
    }

    fn release(p: *Pool) void {
        p.lock.release(p.io);
    }

    fn wake(p: *Pool) void {
        _ = p.signal.fetchAdd(1, .seq_cst);
        if (p.sleepers.load(.seq_cst) != 0) p.io.futexWake(u32, &p.signal.raw, std.math.maxInt(u32));
    }

    fn add(p: *Pool, job: *Job) !void {
        {
            p.acquire();
            defer p.release();
            try p.jobs.append(p.gpa, job);
            p.njobs.store(p.jobs.items.len, .monotonic);
        }
        p.wake();
    }

    /// Takes the search off the pool and waits until no pool thread is on it any more.
    fn remove(p: *Pool, job: *Job) void {
        {
            p.acquire();
            defer p.release();
            const k = std.mem.indexOfScalar(*Job, p.jobs.items, job).?;
            _ = p.jobs.swapRemove(k);
            p.njobs.store(p.jobs.items.len, .monotonic);
            p.turn = 0;
        }
        p.wake(); // one search fewer: more pool threads may work
        while (true) {
            const n = job.inflight.load(.acquire);
            if (n == 0) break;
            p.io.futexWaitUncancelable(u32, &job.inflight.raw, n);
        }
    }

    /// The next search, in turn, that has a chunk to claim and room for another thread.
    fn take(p: *Pool) ?*Job {
        p.acquire();
        defer p.release();
        const n = p.jobs.items.len;
        if (p.busy.load(.monotonic) >= @max(1, (p.threads.len + 1) -| n)) return null;
        for (0..n) |k| {
            const i = (p.turn + k) % n;
            const job = p.jobs.items[i];
            if (job.inflight.load(.monotonic) >= job.max_workers.load(.monotonic) or !job.mayClaim()) continue;
            _ = job.inflight.fetchAdd(1, .acquire);
            _ = p.busy.fetchAdd(1, .monotonic);
            p.turn = i + 1;
            return job;
        }
        return null;
    }

    fn work(p: *Pool) void {
        var sc: Scratch = .{};
        defer sc.deinit(p.gpa);
        while (true) {
            // Snapshot first: new work after this point makes the wait below return at once.
            const seen = p.signal.load(.seq_cst);
            if (p.stopping.load(.acquire)) return;
            const job = p.take() orelse {
                // Idle with no search running: keep at most `retain` bytes of buffers. Done
                // here rather than by the search that ends last, which on a busy engine is
                // as likely a small one: freeing what a large search with much output
                // left (hundreds of MB) took 20 ms and more.
                if (p.njobs.load(.monotonic) == 0 and p.mem.pool_bytes.load(.monotonic) > p.retain) {
                    p.bufs.trim(p.io, p.gpa, &p.mem, p.retain);
                    continue;
                }
                _ = p.sleepers.fetchAdd(1, .seq_cst);
                p.io.futexWaitUncancelable(u32, &p.signal.raw, seen);
                _ = p.sleepers.fetchSub(1, .seq_cst);
                continue;
            };
            // Alone, a search keeps its threads as in a one-shot run; with others waiting,
            // the threads go round after every chunk.
            while (job.workOne(&sc, false)) {
                if (p.njobs.load(.monotonic) > 1) break;
            }
            _ = p.busy.fetchSub(1, .monotonic);
            job.leave(&sc); // wakes the pool: the slot is free again
        }
    }
};

/// Which file a cached mapping or tuning is of: the file's inode, size and modification
/// time. A file written to (or truncated, or grown) gets another key. Inodes are only
/// unique within a file system (`Io.File.Stat` has no device): two files of different file
/// systems with the same inode number, size and modification time to the nanosecond would
/// be taken for one.
const FileKey = struct {
    inode: Io.File.INode,
    size: u64,
    mtime: i96,

    fn of(io: Io, file: Io.File) ?FileKey {
        const st = file.stat(io) catch return null;
        return .{ .inode = st.inode, .size = st.size, .mtime = st.mtime.nanoseconds };
    }

    fn eql(a: FileKey, b: FileKey) bool {
        return a.inode == b.inode and a.size == b.size and a.mtime == b.mtime;
    }
};

/// Shared engines: mappings of files kept from one search of the file to the next. A
/// search through a fresh mapping faults its pages in and unmaps them at the end, which on
/// an 8 MB cached file is a third of the search (unmapping alone 170 us of 0.5 ms on a
/// Ryzen 7735U); through a kept mapping it only reads. Files up to `Pool.chunk_choice_class`
/// only (256 MB): larger ones are read with `pread` on Linux (see `searchFile`). At most
/// `max_entries`, the least recently used unused one making room; a kept mapping keeps its
/// file, so a deleted file's space comes back when its mapping is dropped.
const MapCache = struct {
    const max_entries = 32;

    const Entry = struct {
        key: FileKey,
        map: []align(std.heap.page_size_min) u8,
        refs: u32,
        used: u64,
        /// A search saw the file shrink under it (`BusGuard`): no new search gets it, and it
        /// is unmapped when the last one is done.
        poisoned: bool = false,
    };

    entries: [max_entries]Entry = undefined,
    n: usize = 0,
    clock: u64 = 0,
    lock: Lock = .{},

    /// A mapping of the file with `key` (`size` bytes, `size` > 0): the cached one, or a
    /// new one, cached if there is room. To be given back with `release`.
    fn acquire(c: *MapCache, io: Io, file: Io.File, size: usize, key: FileKey) ![]align(std.heap.page_size_min) u8 {
        {
            c.lock.acquire(io);
            defer c.lock.release(io);
            c.clock += 1;
            for (c.entries[0..c.n]) |*e| if (!e.poisoned and e.key.eql(key)) {
                e.refs += 1;
                e.used = c.clock;
                return e.map;
            };
        }
        const map = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0);
        var victim: ?[]align(std.heap.page_size_min) u8 = null;
        defer if (victim) |v| unmapInSlices(v);
        c.lock.acquire(io);
        defer c.lock.release(io);
        const entry: ?*Entry = if (c.n < max_entries) blk: {
            c.n += 1;
            break :blk &c.entries[c.n - 1];
        } else blk: {
            var lru: ?*Entry = null;
            for (c.entries[0..c.n]) |*e| if (e.refs == 0 and (lru == null or e.used < lru.?.used)) {
                lru = e;
            };
            if (lru) |e| victim = e.map;
            break :blk lru;
        };
        // All in use: this one is the search's own.
        const e = entry orelse return map;
        e.* = .{ .key = key, .map = map, .refs = 1, .used = c.clock };
        return map;
    }

    /// Gives back `map` (from `acquire`); `poisoned` if the search saw the file shrink.
    fn release(c: *MapCache, io: Io, map: []align(std.heap.page_size_min) u8, poisoned: bool) void {
        var unmap = true;
        defer if (unmap) unmapInSlices(map);
        c.lock.acquire(io);
        defer c.lock.release(io);
        for (c.entries[0..c.n], 0..) |*e, k| if (e.map.ptr == map.ptr) {
            e.refs -= 1;
            if (poisoned) e.poisoned = true;
            if (e.poisoned and e.refs == 0) {
                c.entries[k] = c.entries[c.n - 1];
                c.n -= 1;
            } else unmap = false;
            return;
        };
        // Not cached (all entries were in use): unmapped.
    }

    fn deinit(c: *MapCache) void {
        for (c.entries[0..c.n]) |e| unmapInSlices(e.map);
        c.n = 0;
    }
};

/// Shared engines: tuned searchers (`tunedSearcher`) by pattern and file, kept from one
/// search to the next. Tuning reads the start of the file and tries filters on it: 16 to
/// 70 us of a 0.5 to 1 ms search of an 8 MB file. At most `max_entries`, replaced in turn.
const TuneCache = struct {
    const max_entries = 64;

    const Entry = struct {
        key: FileKey,
        /// The pattern, owned; `searcher` refers to the caller's copy only while it is used.
        pattern: []u8,
        searcher: search.Searcher,
    };

    entries: [max_entries]?Entry = @splat(null),
    next: usize = 0,
    lock: Lock = .{},

    fn get(c: *TuneCache, io: Io, key: FileKey, pattern: []const u8) ?search.Searcher {
        c.lock.acquire(io);
        defer c.lock.release(io);
        for (c.entries) |entry| if (entry) |e| {
            if (!e.key.eql(key) or !std.mem.eql(u8, e.pattern, pattern)) continue;
            var s = e.searcher;
            s.needle = pattern;
            s.two_way.needle = pattern;
            return s;
        };
        return null;
    }

    fn put(c: *TuneCache, io: Io, gpa: std.mem.Allocator, key: FileKey, pattern: []const u8, s: search.Searcher) void {
        const owned = gpa.dupe(u8, pattern) catch return;
        c.lock.acquire(io);
        defer c.lock.release(io);
        if (c.entries[c.next]) |old| gpa.free(old.pattern);
        var kept = s;
        kept.needle = owned;
        kept.two_way.needle = owned;
        c.entries[c.next] = .{ .key = key, .pattern = owned, .searcher = kept };
        c.next = (c.next + 1) % max_entries;
    }

    fn deinit(c: *TuneCache, gpa: std.mem.Allocator) void {
        for (&c.entries) |*entry| if (entry.*) |e| {
            gpa.free(e.pattern);
            entry.* = null;
        };
    }
};

/// Shared engines only. A file that shrinks while it is mapped (another process truncates
/// it) raises SIGBUS on the pages past its new end on Linux, which would bring the whole
/// server down. (On macOS the private mapping zg uses keeps showing the old contents;
/// shared mappings fault there too.) The mappings of running searches are registered here; on a SIGBUS inside one, the
/// handler maps a page of zeros over the faulting page, so that the access completes, and
/// marks the search, which then stops with `error.FileChanged` (the zeros are never
/// reported as file contents: the search fails). A SIGBUS anywhere else gets the action
/// that was installed before, as if this handler had never been there.
const BusGuard = struct {
    const slots = 1024;
    /// Registered ranges [lo, hi); lo 0 marks a free slot.
    var lo: [slots]std.atomic.Value(usize) = @splat(.init(0));
    var hi: [slots]std.atomic.Value(usize) = @splat(.init(0));
    var hit: [slots]std.atomic.Value(bool) = @splat(.init(false));
    /// 0: not installed, 1: being installed, 2: installed.
    var state: std.atomic.Value(u8) = .init(0);
    var previous: std.posix.Sigaction = undefined;

    fn install() void {
        if (state.load(.acquire) == 2) return;
        if (state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
            _ = std.heap.pageSize(); // known before any fault: the handler only reads it
            const act: std.posix.Sigaction = .{
                .handler = .{ .sigaction = handle },
                .mask = std.posix.sigemptyset(),
                .flags = std.posix.SA.SIGINFO | std.posix.SA.RESTART | std.posix.SA.ONSTACK,
            };
            std.posix.sigaction(.BUS, &act, &previous);
            state.store(2, .release);
        }
        while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
    }

    fn register(mapped: []const u8) !usize {
        const start = @intFromPtr(mapped.ptr);
        for (0..slots) |k| {
            if (lo[k].load(.monotonic) != 0) continue;
            hit[k].store(false, .monotonic);
            if (lo[k].cmpxchgStrong(0, start, .acq_rel, .monotonic) == null) {
                hi[k].store(start + mapped.len, .release);
                return k;
            }
        }
        return error.TooManySearches;
    }

    fn unregister(k: usize) void {
        hi[k].store(0, .release);
        lo[k].store(0, .release);
    }

    fn handle(sig: std.posix.SIG, info: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
        const addr: usize = switch (builtin.target.os.tag) {
            .linux => @intFromPtr(info.fields.sigfault.addr),
            else => @intFromPtr(info.addr),
        };
        // Every search on the mapping is marked: searches of the same file share a cached
        // mapping (`MapCache`), and one that is not marked would take the zeros for the file.
        var ours = false;
        for (0..slots) |k| {
            const l = lo[k].load(.acquire);
            if (l == 0 or addr < l or addr >= hi[k].load(.acquire)) continue;
            hit[k].store(true, .release);
            ours = true;
        }
        if (ours) {
            const page = std.heap.pageSize();
            const at: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(addr / page * page);
            if (std.posix.mmap(at, page, .{ .READ = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = true }, -1, 0)) |_| {
                return; // the access is retried, and reads zeros
            } else |_| {}
        }
        // Not one of ours (or no page could be put in): what would have happened without us.
        if (previous.flags & std.posix.SA.SIGINFO != 0) {
            if (previous.handler.sigaction) |f| return f(sig, info, ctx);
        }
        std.posix.sigaction(.BUS, &previous, null);
        // Returning retries the access, which faults again under the previous action.
    }
};

/// One search, on the threads and budget of `kind`; `pool` is the shared engine's.
fn searchFile(comptime kind: Kind, io: Io, gpa: std.mem.Allocator, pool: if (kind == .shared) *Pool else void, src: Source, opts: Options, w: *Io.Writer) !usize {
    const deadline: ?Io.Timestamp = if (opts.timeout_ns == 0) null else .{ .nanoseconds = Io.Timestamp.now(io, .awake).nanoseconds + opts.timeout_ns };
    if (opts.cancel) |c| if (c.requested.load(.acquire)) return error.Canceled;
    if (opts.pattern.len == 0) return error.EmptyPattern;
    if (std.mem.indexOfScalar(u8, opts.pattern, '\n') != null) return error.PatternHasNewline;

    const file: ?Io.File = switch (src) {
        .file => |f| f,
        .bytes => null,
    };
    const size = if (file) |f| std.math.cast(usize, try f.length(io)) orelse return error.FileTooLarge else src.bytes.len;
    if (size == 0) {
        if (opts.count_only) {
            try w.writeAll("0\n");
            try w.flush();
        }
        return 0;
    }

    // Shared engines, `auto`: below `Pool.chunk_choice_class` the method comes from what
    // earlier searches took; the time of this one (to after the unmapping) is learned.
    const planned: ?Pool.Plan = if (kind == .shared) (if (opts.io == .auto and file != null) pool.plan(Pool.sizeClass(size)) else null) else null;
    var succeeded = false;
    defer if (kind == .shared) if (planned) |pl| if (succeeded) pool.learnPlan(pl, size);
    const io_choice: IoChoice = if (planned) |pl| Pool.Plan.methods[pl.index] else opts.io;

    // Bytes in memory are searched where they are, like a mapping that never faults.
    // Shared engines keep the mappings and tunings of files below the size where they read
    // with `pread` (`MapCache`, `TuneCache`).
    const cache_key: ?FileKey = if (kind == .shared and Pool.sizeClass(size) < Pool.chunk_choice_class) (if (file) |f| FileKey.of(io, f) else null) else null;
    var poisoned = false; // set from the `BusGuard` slot before it is given back
    const mapping: ?[]align(std.heap.page_size_min) u8 = if (file) |f|
        (if (cache_key) |key| try pool.maps.acquire(io, f, size, key) else try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, f.handle, 0))
    else
        null;
    defer if (mapping) |m| if (cache_key != null) pool.maps.release(io, m, poisoned) else unmapInSlices(m);
    const mapped: []const u8 = mapping orelse src.bytes;
    const guard_slot: ?usize = if (kind == .shared or opts.truncation_guard) blk: {
        const m = mapping orelse break :blk null;
        BusGuard.install(); // shared engines did at creation; the first guarded one-shot search does
        break :blk try BusGuard.register(m);
    } else null;
    defer if (guard_slot) |k| {
        poisoned = BusGuard.hit[k].load(.acquire);
        BusGuard.unregister(k);
    };

    // The limit is a cap on everything zg allocates. Only part of it is spent on accounted
    // results; the rest absorbs what the accounting does not see (allocator slack, chunks
    // being worked on right now), which measured up to ~40% on top of the accounted bytes.
    var own_mem: Memory = undefined;
    var own_bufs: Buffers = .{};
    const limit: usize, const ncpu: usize, const mem: *Memory = switch (kind) {
        .oneshot => blk: {
            const cpus = std.Thread.getCpuCount() catch 1;
            const wanted_threads = if (opts.threads != 0) opts.threads else cpus;
            const limit = if (opts.memory_limit != 0) opts.memory_limit else defaultMemoryLimit(io, wanted_threads, memoryPerThread(io, opts));
            own_mem = .{ .budget = limit / 3 * 2 };
            break :blk .{ limit, threadsFor(opts.threads, cpus, limit, memoryPerThread(io, opts)), &own_mem };
        },
        .shared => .{ pool.limit, pool.threads.len + 1, &pool.mem },
    };

    // Small chunks balance load across heterogeneous cores; they stay < 4 GiB for u32
    // offsets. Every thread works on one chunk at a time, so with a small memory limit the
    // chunks shrink too (but not below `min_chunk`, where per-chunk overhead starts to show).
    const max_chunk = @max(min_chunk, @min(chunkCeiling(io), limit / (ncpu * 16)));
    const chunk_size = if (opts.chunk_size != 0) opts.chunk_size else std.math.clamp(size / (ncpu * 16), min_chunk, max_chunk);
    const nchunks = (size + chunk_size - 1) / chunk_size;

    const results = try gpa.alloc(ChunkResult, nchunks);
    defer gpa.free(results);
    @memset(results, .{});
    defer for (results) |*r| {
        // Output never written (a failed writer) leaves the accounting with the rest.
        _ = mem.queued.fetchSub(r.out.items.len + r.buf.items.len + r.pieces.items.len, .monotonic);
        r.out.deinit(gpa);
        r.refs.deinit(gpa);
        r.buf.deinit(gpa);
        r.pieces.deinit(gpa);
    };
    const ready = try gpa.alloc(std.atomic.Value(bool), nchunks);
    defer gpa.free(ready);
    @memset(ready, .init(false));
    const line_end = try gpa.alloc(std.atomic.Value(usize), nchunks);
    defer gpa.free(line_end);
    @memset(line_end, .init(0));

    const io_mode: IoMode = if (mapping) |m| switch (io_choice) {
        .auto => chooseIo(m),
        .mmap => .mmap,
        .pread => .pread,
    } else .mmap;
    // Threads on this search, its caller's included.
    const nthreads = switch (kind) {
        .oneshot => @min(ncpu, nchunks),
        .shared => @min(if (opts.threads != 0) @min(opts.threads, ncpu) else ncpu, nchunks),
    };
    var job: Job = .{
        .data = mapped,
        .access = .{
            .allowed = if (mapping == null) .{ false, true, false } else if (kind == .shared and builtin.target.os.tag == .linux and io_choice == .auto and Pool.sizeClass(size) >= Pool.chunk_choice_class)
                // Shared engines on Linux, large files: `pread` only. Unmapping the pages a
                // mapped search faulted in takes the process's address space lock for long
                // (14 ms for 540 MB), and every other search's `mmap`, `munmap` and page
                // faults wait for it; the search's own chunk timings cannot see that. Small
                // searches next to one printing much output on a 540 MB file (3000 of them):
                // longest 25.6 to 27.4 ms when that one could map, 18.6 to 19.9 ms on
                // `pread` only (p99 about 11 ms either way).
                .{ false, false, true }
            else
                allowedAccess(io_choice, io_mode, nchunks, .of(nthreads)),
            .policy = .of(nthreads),
            .unmap_ps = unmapCost(nthreads),
        },
        .file = file,
        .searcher = if (cache_key) |key| pool.tunes.get(io, key, opts.pattern) orelse blk: {
            const tuned = tunedSearcher(io, opts.pattern, mapped, io_mode, file);
            pool.tunes.put(io, gpa, key, opts.pattern, tuned);
            break :blk tuned;
        } else tunedSearcher(io, opts.pattern, mapped, io_mode, file),
        .chunk_size = chunk_size,
        .nchunks = nchunks,
        .line_numbers = opts.line_numbers and !opts.count_only,
        .count_only = opts.count_only,
        .stream = !opts.count_only,
        .ready = ready,
        .line_end = line_end,
        .results = results,
        .gpa = gpa,
        .std_io = io,
        .mem = mem,
        .bufs = switch (kind) {
            .oneshot => &own_bufs,
            .shared => &pool.bufs,
        },
        .nthreads = nthreads,
        .watched = kind == .shared or guard_slot != null or opts.cancel != null or deadline != null,
        .cancel = opts.cancel,
        .deadline = deadline,
        .bus_slot = guard_slot,
        .max_matches = opts.max_matches,
    };
    if (opts.cancel) |c| c.attach(&job);
    defer if (opts.cancel) |c| c.attach(null);
    // A shared engine keeps the buffers, down to what it retains while idle.
    defer switch (kind) {
        .oneshot => own_bufs.trim(io, gpa, mem, 0),
        .shared => {}, // an idle pool thread trims (`Pool.work`)
    };

    switch (kind) {
        .oneshot => {
            const handles = try gpa.alloc(std.Thread, nthreads - 1);
            defer gpa.free(handles);
            // A thread count asked for is used as is.
            var ramp: Ramp = .init(handles, nthreads, physicalCores(io), opts.threads != 0);
            if (ramp.state != .done) job.ramp = &ramp;
            ramp.start(&job, ramp.initial(nchunks, opts.max_matches));
            if (opts.count_only) try runPhase(&job, &ramp) else try runStreaming(&job, &ramp, w);
        },
        .shared => {
            job.shared = pool;
            // The pool's threads join as the search pays for them, as in a one-shot search
            // (`Ramp`): bandwidth-bound searches leave the second thread of each core to the
            // others. A thread count asked for is used as is.
            var ramp: Ramp = .init(&.{}, nthreads, physicalCores(io), opts.threads != 0);
            ramp.pool = pool;
            if (ramp.state != .done) job.ramp = &ramp;
            ramp.start(&job, ramp.initial(nchunks, opts.max_matches));
            const class = Pool.sizeClass(size);
            const chunk_priors = class >= Pool.chunk_choice_class;
            if (chunk_priors) pool.seed(&job.access, class, chunk_size);
            defer if (chunk_priors) pool.learn(&job.access, class);
            try pool.add(&job);
            const result = runOnPool(&job, w);
            pool.remove(&job); // from here on no pool thread is on the job
            try result;
        },
    }
    try checkErr(&job); // a stopped count is incomplete
    if (guard_slot) |k| if (BusGuard.hit[k].load(.acquire)) return error.FileChanged;
    // A count stopped at `max_matches` has enough lines; the pending lines it left
    // undecided cannot change that.
    const enough = job.halted.load(.acquire);
    if (opts.count_only and !enough) {
        for (0..nchunks) |i| if (results[i].pending) |pd| try job.resolvePending(i, pd, null, null);
    }

    var total: usize = 0;
    for (results) |r| total += r.count;
    if (opts.max_matches != 0) total = @min(total, opts.max_matches);
    if (opts.count_only) {
        try writeUint(w, total);
        try w.writeByte('\n');
        try w.flush();
    }
    succeeded = true;
    return total;
}

/// Writes `bytes` up to and including its `left.*`-th newline (all of it if it has fewer),
/// counting `left` down; true once it is 0.
fn writeUpTo(w: *Io.Writer, bytes: []const u8, left: *usize) Io.Writer.Error!bool {
    var at: usize = 0;
    while (left.* != 0) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, at, '\n') orelse break;
        at = nl + 1;
        left.* -= 1;
    }
    try w.writeAll(bytes[0..if (left.* == 0) at else bytes.len]);
    return left.* == 0;
}

fn writeUint(w: *Io.Writer, v: usize) Io.Writer.Error!void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var x = v;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        if (x == 0) break;
    }
    try w.writeAll(buf[i..]);
}

fn checkErr(job: *const Job) !void {
    const err_code = job.err.load(.monotonic);
    if (err_code != 0) return @errorFromInt(err_code);
}

/// Runs every chunk of the job, on the caller and the threads `ramp` starts.
fn runPhase(job: *Job, ramp: *Ramp) !void {
    var sc: Scratch = .{};
    defer sc.deinit(job.gpa);
    while (job.workOne(&sc, true)) ramp.step(job); // the main thread works too
    for (ramp.handles[0..ramp.spawned]) |h| h.join();
    try checkErr(job);
}

/// Runs the job and writes each chunk's output, in file order, as soon as that
/// chunk is ready. While the next chunk is not ready the main thread works on chunks
/// itself, so writing overlaps with searching and rendering.
fn runStreaming(job: *Job, ramp: *Ramp, w: *Io.Writer) !void {
    var sc: Scratch = .{};
    defer sc.deinit(job.gpa);
    const written = writeChunks(job, &sc, w);
    for (ramp.handles[0..ramp.spawned]) |h| h.join();
    try written;
    try checkErr(job);
    try w.flush();
}

/// How many threads a one-shot search runs, found while it runs. More threads only help
/// while the work is not held up by memory bandwidth, and where that ends depends on the
/// machine and on the search: on a Ryzen 7735U (8 cores, 16 hardware threads), 540 MB
/// cached files, one thread per core against two (milliseconds, runs alternating):
///
///     -c needle_zz 24.3 / 26.4   ERROR 21.2 / 24.5   long.txt th 23.2 / 42.3
///     the 41.1 / 32.6            -n a 67.3 / 47.8    -c the 30.4 / 25.4
///
/// The threads are started in two parts. Up to one per core they are not measured, only
/// paced: too few threads cost far more than too many (2x on compute-bound searches,
/// against CPU time on bandwidth-bound ones). A search with `-m` starts on the caller alone
/// and doubles its threads each time every thread has done a chunk, since it often stops
/// early; others start on one thread per core, fewer for small files (8 chunks each).
///
/// The second thread per core is the step that pays or not, and it is decided the way
/// bandwidth-aware threading decides (Suleman et al., ASPLOS 2008): by whether the work is
/// bandwidth bound, here the share of the `pread` chunks' time spent on what they read
/// (scanning, rendering) rather than in the read (the copy from the page cache), over a
/// window of chunks on one thread per core. At `smt_share` or more the extra threads have
/// compute to overlap and start; below, they would only compete for the bandwidth. The
/// shares measured on the cases above: 0.09 to 0.48 where one thread per core was faster,
/// 0.52 to 0.94 where two were. Comparing throughputs before and after starting them
/// instead was unreliable: the measurements come one after the other, while the clock rate
/// rises after the start and drops under the power limit with all threads busy, so the
/// later one mostly looked better. A share is measured on the same chunks at the same time.
/// Without `pread` chunks to measure (mapped access), or for a search too short for the
/// window, all threads start.
/// Only the caller steps the ramp and starts threads, so it can join them all at the end.
const Ramp = struct {
    handles: []std.Thread,
    /// On a shared engine: its pool, whose threads the search lets in (`Job.max_workers`)
    /// instead of starting its own.
    pool: ?*Pool = null,
    /// Threads started, not counting the caller.
    spawned: u32 = 0,
    /// Threads working, the caller included.
    active: u32 = 1,
    max: u32,
    /// One thread per physical core (`physicalCores`), at most `max`.
    cores: u32,
    state: enum { pace, settle, measure, done },
    /// `job.done_chunks` when the current phase started; read and work times when the
    /// measurement started.
    mark_chunks: u32 = 0,
    mark_read: u64 = 0,
    mark_work: u64 = 0,

    const smt_share = 0.5;
    /// A share this high already over the settling chunks decides at once: the search is
    /// plainly compute bound (0.84 to 0.94 counting `a` in short.txt, where waiting out the
    /// measurement cost 4 ms of 30), and the highest share where one thread per core was
    /// faster was 0.48 (0.55 over the shorter window of the settling chunks).
    const early_share = 0.75;
    /// Chunks per thread before the measurement (the first ones after a start are slower:
    /// buffers, access methods tried), and in it.
    const settle_per_thread = 2;
    const measure_per_thread = 4;

    /// A ramp over `max` threads in all, adaptive unless `fixed`.
    fn init(handles: []std.Thread, max: usize, cores: usize, fixed: bool) Ramp {
        return .{
            .handles = handles,
            .max = @intCast(max),
            .cores = @intCast(std.math.clamp(cores, 1, max)),
            .state = if (fixed or max == 1) .done else .pace,
        };
    }

    /// The threads to start with: all of them for a fixed count; the caller alone with
    /// `-m`; otherwise one per core, fewer for small files (8 chunks each at least).
    fn initial(r: *const Ramp, nchunks: usize, max_matches: usize) u32 {
        if (r.state == .done) return r.max;
        if (max_matches != 0) return 1;
        return @intCast(@max(1, @min(r.cores, nchunks / 8)));
    }

    fn start(r: *Ramp, job: *Job, n: u32) void {
        job.next.store(0, .monotonic);
        r.spawnUpTo(job, n);
        r.mark_chunks = 0;
    }

    fn spawnUpTo(r: *Ramp, job: *Job, n: u32) void {
        if (r.pool) |p| {
            job.max_workers.store(n - 1, .monotonic);
            r.active = n;
            p.wake();
            return;
        }
        while (r.active < n) {
            r.handles[r.spawned] = std.Thread.spawn(.{}, Job.rampWorker, .{job}) catch {
                r.state = .done;
                return;
            };
            r.spawned += 1;
            r.active += 1;
        }
    }

    /// Called by the caller between chunks; cheap once the count is settled.
    fn step(r: *Ramp, job: *Job) void {
        if (r.state == .done) return;
        const next = job.next.load(.monotonic);
        if (job.halted.load(.monotonic) or next >= job.nchunks) {
            r.state = .done;
            return;
        }
        const done = job.done_chunks.load(.acquire);
        switch (r.state) {
            .pace => {
                if (done -% r.mark_chunks < r.active) return;
                if (r.active < r.cores) {
                    r.spawnUpTo(job, @min(2 * r.active, r.cores));
                    r.mark_chunks = job.done_chunks.load(.acquire);
                } else if (r.active == r.max) {
                    r.state = .done;
                } else if (job.nchunks - next < 2 * (settle_per_thread + measure_per_thread) * r.active) {
                    // Too short to measure: all threads.
                    r.spawnUpTo(job, r.max);
                    r.state = .done;
                } else {
                    r.mark_chunks = done;
                    r.mark_read = job.read_ns.load(.monotonic);
                    r.mark_work = job.work_ns.load(.monotonic);
                    r.state = .settle;
                }
            },
            .settle => {
                if (done -% r.mark_chunks < settle_per_thread * r.active) return;
                const read: f64 = @floatFromInt(job.read_ns.load(.monotonic) - r.mark_read);
                const work: f64 = @floatFromInt(job.work_ns.load(.monotonic) - r.mark_work);
                if (read != 0 and work / (read + work) >= early_share) {
                    r.spawnUpTo(job, r.max);
                    r.state = .done;
                    return;
                }
                r.mark_chunks = done;
                r.mark_read = job.read_ns.load(.monotonic);
                r.mark_work = job.work_ns.load(.monotonic);
                r.state = .measure;
            },
            .measure => {
                if (done -% r.mark_chunks < measure_per_thread * r.active) return;
                const read: f64 = @floatFromInt(job.read_ns.load(.monotonic) - r.mark_read);
                const work: f64 = @floatFromInt(job.work_ns.load(.monotonic) - r.mark_work);
                if (read == 0 or work / (read + work) >= smt_share) r.spawnUpTo(job, r.max);
                r.state = .done;
            },
            .done => {},
        }
    }
};

/// The caller's part of a search on a shared engine: the pool's threads take chunks as
/// they go round; the caller works on chunks too, and writes the output.
fn runOnPool(job: *Job, w: *Io.Writer) !void {
    var sc: Scratch = .{};
    defer sc.deinit(job.gpa);
    if (job.count_only) {
        while (job.workOne(&sc, true)) if (job.ramp) |r| r.step(job);
        // Chunks still held by pool threads are done once `Pool.remove` returns.
        return;
    }
    try writeChunks(job, &sc, w);
    try checkErr(job);
    try w.flush();
}

/// Writes each chunk's output in file order as soon as it is ready, working on chunks
/// while the next one is not. On a write error, stops handing out chunks.
fn writeChunks(job: *Job, sc: *Scratch, w: *Io.Writer) !void {
    var next_write: usize = 0;
    var lines: usize = 0; // written so far, for `max_matches`
    while (next_write < job.nchunks) {
        if (job.ramp) |r| r.step(job);
        if (job.watched and job.checkStop()) return checkErr(job);
        // Snapshot first: a chunk finishing after this point makes the wait below return at once.
        const seen = job.completed.load(.acquire);
        if (job.ready[next_write].load(.acquire)) {
            const r = &job.results[next_write];
            if (job.max_matches != 0 and r.count >= job.max_matches - lines) {
                // The chunk has the last lines wanted: write those, and that is all.
                job.writeLines(next_write, w, job.max_matches - lines) catch |err| {
                    job.stop(err);
                    return err;
                };
                job.halt();
                return checkErr(job);
            }
            job.writeOne(next_write, w, sc) catch |err| {
                // Stop handing out chunks; workers finish the ones they hold, and those
                // waiting for the writer are released to see there is no work left.
                job.stop(err);
                return err;
            };
            _ = job.mem.queued.fetchSub(r.out.items.len, .monotonic);
            job.giveBuffer(r.out);
            r.out = .empty;
            r.refs.deinit(job.gpa);
            r.refs = .empty;
            if (r.buf.capacity != 0) {
                _ = job.mem.queued.fetchSub(r.buf.items.len, .monotonic);
                job.giveReadBuffer(r.buf);
                r.buf = .empty;
            }
            if (r.pieces.capacity != 0) {
                _ = job.mem.queued.fetchSub(r.pieces.items.len, .monotonic);
                r.pieces.deinit(job.gpa);
                r.pieces = .empty;
            }
            next_write += 1;
            job.written.store(next_write, .release);
            // Memory was freed and the head of the line moved: let gated workers re-check.
            job.madeProgress();
            if (job.max_matches != 0) {
                lines += r.count; // with the pending line, if it matched
                if (lines >= job.max_matches) {
                    job.halt();
                    return checkErr(job);
                }
            }
        } else if (job.err.load(.acquire) != 0) {
            // A chunk failed or the search was stopped: what was not handed out yet would
            // never be ready.
            job.stop(error.Aborted); // keeps the first error
            return checkErr(job);
        } else if (!job.workOne(sc, false)) {
            // Nothing to claim right now: sleep until a chunk completes.
            job.sleepOn(&job.completed, &job.completed_sleepers, seen);
        }
    }
}

/// Parses a size such as "4096", "512K", "64M", "4G" or "1T" (powers of 1024).
pub fn parseSize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    const shift: u6 = switch (std.ascii.toUpper(text[text.len - 1])) {
        'K' => 10,
        'M' => 20,
        'G' => 30,
        'T' => 40,
        else => 0,
    };
    const digits = if (shift == 0) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(usize, digits, 10) catch return null;
    return std.math.shlExact(usize, n, shift) catch null;
}

// ---------------------------------------------------------------------------
// Tests: `zig build test`. Every configuration is checked against a naive
// reference implementation, with tiny chunks so that chunk boundaries (including
// lines that span many chunks) are exercised on small inputs.
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    _ = search;
}

/// Straightforward reference: split into lines, `indexOf` each.
fn expectedOutput(gpa: std.mem.Allocator, data: []const u8, opts: Options) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var count: usize = 0;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        // A trailing '\n' leaves an empty last piece that is not a line.
        if (it.index == null and line.len == 0) break;
        line_no += 1;
        if (std.mem.indexOf(u8, line, opts.pattern) == null) continue;
        if (opts.max_matches != 0 and count == opts.max_matches) break;
        count += 1;
        if (opts.count_only) continue;
        if (opts.line_numbers) try out.writer.print("{d}:", .{line_no});
        try out.writer.writeAll(line);
        try out.writer.writeByte('\n');
    }
    if (opts.count_only) try out.writer.print("{d}\n", .{count});
    return out.toOwnedSlice();
}

fn expectedCount(data: []const u8, pattern: []const u8) usize {
    return expectedCountUpTo(data, pattern, 0);
}

fn expectedCountUpTo(data: []const u8, pattern: []const u8, max: usize) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (it.index == null and line.len == 0) break;
        if (std.mem.indexOf(u8, line, pattern) != null) count += 1;
        if (max != 0 and count == max) break;
    }
    return count;
}

/// Writes `data` to a temporary file and runs zg on it with an engine of `kind`, returning
/// its output. A shared engine gets `opts.threads` and `opts.memory_limit` as its own.
fn runOnData(comptime kind: Kind, gpa: std.mem.Allocator, data: []const u8, opts: Options) !struct { out: []u8, total: usize } {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data });
    const file = try tmp.dir.openFile(testing.io, "input.txt", .{});
    defer file.close(testing.io);

    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const total = switch (kind) {
        .oneshot => try run(testing.io, gpa, file, opts, &out.writer),
        .shared => blk: {
            var engine: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = opts.threads, .memory_limit = opts.memory_limit });
            defer engine.deinit();
            break :blk try engine.search(.{ .file = file }, opts, &out.writer);
        },
    };
    return .{ .out = try out.toOwnedSlice(), .total = total };
}

/// Checks the output of both kinds of engine against the reference.
fn expectMatchesReference(data: []const u8, opts: Options) !void {
    const gpa = testing.allocator;
    const want = try expectedOutput(gpa, data, opts);
    defer gpa.free(want);
    inline for (.{ Kind.oneshot, Kind.shared }) |kind| {
        const got = try runOnData(kind, gpa, data, opts);
        defer gpa.free(got.out);
        testing.expectEqualStrings(want, got.out) catch |err| {
            std.debug.print("{t}: pattern '{s}' -n={} -c={} io={t} threads={d} chunk={d} mem={d}\n", .{
                kind, opts.pattern, opts.line_numbers, opts.count_only, opts.io, opts.threads, opts.chunk_size, opts.memory_limit,
            });
            return err;
        };
        try testing.expectEqual(expectedCountUpTo(data, opts.pattern, opts.max_matches), got.total);
    }
}

/// Pseudo-random text: short lines, empty lines, and an occasional long line.
fn genText(gpa: std.mem.Allocator, seed: u64, lines: usize, alphabet: []const u8, long_line: usize, trailing_newline: bool) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    for (0..lines) |i| {
        var n: usize = if (rnd.uintLessThan(u8, 8) == 0) 0 else rnd.intRangeAtMost(usize, 1, 60);
        if (long_line != 0 and i == lines / 2) n = long_line;
        const is_long = long_line != 0 and i == lines / 2;
        for (0..n) |_| {
            var c = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            if (is_long and c == '\n') c = alphabet[0]; // the long line must stay one line
            try buf.append(gpa, c);
        }
        if (i + 1 < lines or trailing_newline) try buf.append(gpa, '\n');
    }
    return buf.toOwnedSlice(gpa);
}

const all_io = [_]IoChoice{ .mmap, .pread, .auto };
const all_chunks = [_]usize{ 1, 7, 64, 1000, 0 };

test "output matches the reference for every io mode, thread count and chunk size" {
    const gpa = testing.allocator;
    const specs = [_]struct { seed: u64, alphabet: []const u8, trailing: bool }{
        .{ .seed = 1, .alphabet = "abc ", .trailing = true },
        .{ .seed = 2, .alphabet = "abc ", .trailing = false },
        .{ .seed = 3, .alphabet = "qzxj_ ", .trailing = true }, // rare bytes: two-byte filter
    };
    const patterns = [_][]const u8{ "a", "ab", "abc", "c a", "qz", "xj_", "zzzzzz", "b b c", "q" };
    for (specs) |spec| {
        const data = try genText(gpa, spec.seed, 120, spec.alphabet, 0, spec.trailing);
        defer gpa.free(data);
        for (patterns) |pat| for (all_io) |io_choice| for ([_]usize{ 1, 3 }) |threads| for (all_chunks) |chunk| {
            // chunk 1 means a chunk per byte; keep that to the cheaper combinations
            if (chunk == 1 and (threads != 3 or io_choice == .auto)) continue;
            for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true } }) |flags| {
                try expectMatchesReference(data, .{
                    .pattern = pat,
                    .line_numbers = flags[0],
                    .count_only = flags[1],
                    .io = io_choice,
                    .threads = threads,
                    .chunk_size = chunk,
                });
            }
        };
    }
}

test "threads started as the search goes (no thread count given)" {
    const gpa = testing.allocator;
    // Enough small chunks for every phase of `Ramp`: paced starts, the measurement on one
    // thread per core, the decision on the rest.
    const data = try genText(gpa, 31, 20_000, "abc \n", 3000, true);
    defer gpa.free(data);
    for ([_][]const u8{ "a", "b c", "abcab" }) |pat| for (all_io) |io_choice| for ([_]usize{ 0, 1, 50 }) |max| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true } }) |flags| {
            try expectMatchesReference(data, .{
                .pattern = pat,
                .line_numbers = flags[0],
                .count_only = flags[1],
                .io = io_choice,
                .chunk_size = 1024,
                .max_matches = max,
            });
        }
    };
}

test "a shared engine keeps mappings and tunings, and sees files change" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var engine: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 3 });
    defer engine.deinit();
    const Check = struct {
        fn run(e: *Engine(.shared), dir: Io.Dir, data: []const u8, pattern: []const u8) !void {
            const file = try dir.openFile(testing.io, "f.txt", .{});
            defer file.close(testing.io);
            for ([_]bool{ false, true }) |numbered| {
                const opts: Options = .{ .pattern = pattern, .line_numbers = numbered, .chunk_size = 4096 };
                const want = try expectedOutput(gpa, data, opts);
                defer gpa.free(want);
                var out: Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                _ = try e.search(.{ .file = file }, opts, &out.writer);
                try testing.expectEqualStrings(want, out.written());
            }
        }
    };
    const data = try genText(gpa, 77, 30_000, "abc \n", 0, true);
    defer gpa.free(data);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = data });
    for (0..3) |_| try Check.run(&engine, tmp.dir, data, "ab c");
    try testing.expectEqual(@as(usize, 1), engine.pool.maps.n);
    // Grown: another key, another mapping.
    const grown = try std.mem.concat(gpa, u8, &.{ data, "zz ab c zz\n" });
    defer gpa.free(grown);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = grown });
    try Check.run(&engine, tmp.dir, grown, "ab c");
    // Rewritten in place with the same size.
    const same_size = try gpa.dupe(u8, grown);
    defer gpa.free(same_size);
    @memset(same_size[0..100], 'c');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.txt", .data = same_size });
    try Check.run(&engine, tmp.dir, same_size, "ab c");
    try Check.run(&engine, tmp.dir, same_size, "zz");
}

test "lines spanning many chunks" {
    const gpa = testing.allocator;
    // A 200 KB line spans from three to two hundred chunks.
    const data = try genText(gpa, 9, 40, "ab\n", 200_000, true);
    defer gpa.free(data);
    for ([_][]const u8{ "a", "ba", "abab", "bbbbbbbb" }) |pat| for (all_io) |io_choice| for ([_]usize{ 1000, 4096, 70_000 }) |chunk| {
        for ([_]bool{ false, true }) |numbered| {
            try expectMatchesReference(data, .{ .pattern = pat, .line_numbers = numbered, .io = io_choice, .threads = 4, .chunk_size = chunk });
        }
    };
}

test "needles longer than a vector and than the filter bytes" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 5, 200, "ab", 3000, true);
    defer gpa.free(data);
    var needle: [45]u8 = undefined;
    // Needles copied from the data are guaranteed to occur.
    for ([_]usize{ 2, 3, 16, 17, 31, 32, 33, 45 }) |len| {
        const at = std.mem.indexOfScalar(u8, data, '\n').? + 1;
        @memcpy(needle[0..len], data[at..][0..len]);
        if (std.mem.indexOfScalar(u8, needle[0..len], '\n') != null) continue;
        try expectMatchesReference(data, .{ .pattern = needle[0..len], .line_numbers = true, .threads = 3, .chunk_size = 64 });
    }
}

test "degenerate inputs" {
    const cases = [_][]const u8{
        "",
        "\n",
        "\n\n\n",
        "needle",
        "needle\n",
        "no match here\n",
        "needle\nneedle",
        "\nneedle\n\n",
        "xneedle needle needle\n",
    };
    for (cases) |data| for (all_io) |io_choice| for ([_]usize{ 1, 4, 0 }) |chunk| {
        try expectMatchesReference(data, .{ .pattern = "needle", .line_numbers = true, .io = io_choice, .threads = 2, .chunk_size = chunk });
        try expectMatchesReference(data, .{ .pattern = "needle", .io = io_choice, .threads = 2, .chunk_size = chunk });
        try expectMatchesReference(data, .{ .pattern = "needle", .count_only = true, .io = io_choice, .threads = 2, .chunk_size = chunk });
    };
}

test "a failing writer is reported and workers are joined without leaks" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 4, 2000, "ab ", 0, true);
    defer gpa.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data });
    const file = try tmp.dir.openFile(testing.io, "input.txt", .{});
    defer file.close(testing.io);

    var w = Io.Writer.failing;
    try testing.expectError(error.WriteFailed, run(testing.io, gpa, file, .{ .pattern = "a", .threads = 4, .chunk_size = 256 }, &w));
    try testing.expectError(error.WriteFailed, run(testing.io, gpa, file, .{ .pattern = "a", .line_numbers = true, .threads = 4, .chunk_size = 256 }, &w));
}

test "invalid patterns are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = "abc\n" });
    const file = try tmp.dir.openFile(testing.io, "input.txt", .{});
    defer file.close(testing.io);
    var w = Io.Writer.failing;
    try testing.expectError(error.EmptyPattern, run(testing.io, testing.allocator, file, .{ .pattern = "" }, &w));
    try testing.expectError(error.PatternHasNewline, run(testing.io, testing.allocator, file, .{ .pattern = "a\nb" }, &w));
}

test "parseSize" {
    try testing.expectEqual(@as(?usize, 4096), parseSize("4096"));
    try testing.expectEqual(@as(?usize, 512 << 10), parseSize("512k"));
    try testing.expectEqual(@as(?usize, 64 << 20), parseSize("64M"));
    try testing.expectEqual(@as(?usize, 4 << 30), parseSize("4G"));
    try testing.expectEqual(@as(?usize, null), parseSize(""));
    try testing.expectEqual(@as(?usize, null), parseSize("G"));
    try testing.expectEqual(@as(?usize, null), parseSize("12x"));
    try testing.expectEqual(@as(?usize, null), parseSize("99999999999999999T"));
}

const small_budgets = [_]usize{ 1 << 10, 4 << 10, 64 << 10 };

test "tiny memory budgets still produce exactly the reference output" {
    // Budgets this small force backpressure (workers waiting for the writer) and the
    // freeing of drained buffers instead of their reuse.
    const gpa = testing.allocator;
    const data = try genText(gpa, 21, 3000, "abc ", 0, true);
    defer gpa.free(data);
    for ([_][]const u8{ "a", "ab", "abc", "c a", "zz" }) |pat| {
        for (small_budgets) |budget| {
            for ([_]IoChoice{ .mmap, .pread }) |io_choice| {
                for ([_]usize{ 1, 4 }) |threads| {
                    for ([_]usize{ 64, 1000 }) |chunk| {
                        for ([_]bool{ false, true }) |numbered| {
                            try expectMatchesReference(data, .{
                                .pattern = pat,
                                .line_numbers = numbered,
                                .io = io_choice,
                                .threads = threads,
                                .chunk_size = chunk,
                                .memory_limit = budget,
                            });
                        }
                    }
                }
            }
        }
    }
}

test "a budget of one byte per chunk cannot deadlock" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 22, 2000, "ab ", 0, true);
    defer gpa.free(data);
    for ([_]bool{ false, true }) |numbered| for ([_]usize{ 1, 2, 8 }) |threads| {
        try expectMatchesReference(data, .{
            .pattern = "a",
            .line_numbers = numbered,
            .threads = threads,
            .chunk_size = 200,
            .memory_limit = 1,
        });
    };
}

test "lines far longer than a chunk and than the memory budget" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 23, 30, "ab\n", 1_000_000, true);
    defer gpa.free(data);
    // The 1 MB line spans hundreds of 4 KB chunks; the budgets are far below its size. The
    // line is decided from all the chunks it covers and written from the mapping.
    for ([_]IoChoice{ .mmap, .pread }) |io_choice| for ([_]usize{ 64 << 10, 1 << 10 }) |budget| {
        for ([_]bool{ false, true }) |numbered| {
            try expectMatchesReference(data, .{ .pattern = "ab", .line_numbers = numbered, .io = io_choice, .threads = 4, .chunk_size = 4096, .memory_limit = budget });
        }
        try expectMatchesReference(data, .{ .pattern = "ab", .count_only = true, .io = io_choice, .threads = 4, .chunk_size = 4096, .memory_limit = budget });
    };
}

test "a match only deep inside a line that spans many chunks" {
    const gpa = testing.allocator;
    // One 300 KB line of 'a's with a single match in its middle, between ordinary lines.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, "first xyz line\nno\n");
    const long_start = data.items.len;
    try data.appendNTimes(gpa, 'a', 300_000);
    @memcpy(data.items[long_start + 150_000 ..][0..3], "xyz");
    try data.appendSlice(gpa, "\nlast xyz\n");
    for ([_]IoChoice{ .mmap, .pread }) |io_choice| for ([_]usize{ 1, 7, 1000, 4096, 0 }) |chunk| {
        if (chunk == 1 and io_choice == .pread) continue; // one pread per byte: slow, covered by mmap
        for ([_]bool{ false, true }) |numbered| {
            try expectMatchesReference(data.items, .{ .pattern = "xyz", .line_numbers = numbered, .io = io_choice, .threads = 4, .chunk_size = chunk });
        }
        try expectMatchesReference(data.items, .{ .pattern = "xyz", .count_only = true, .io = io_choice, .threads = 4, .chunk_size = chunk });
        // A needle that crosses chunk boundaries inside the long line.
        try expectMatchesReference(data.items, .{ .pattern = "aaxyzaa", .line_numbers = true, .io = io_choice, .threads = 3, .chunk_size = chunk });
    };
}

test "threadsFor shrinks the thread count to fit the memory limit" {
    const mib = 1 << 20;
    // What a thread needs follows the chunk size; the arithmetic below is for the 2 MB chunks of
    // a core with a large L2.
    const rendering = 24 * mib;
    const counting = 4 * mib;
    try testing.expectEqual(memoryPerThread(testing.io, .{ .pattern = "x" }), memoryPerThread(testing.io, .{ .pattern = "x", .line_numbers = true }));
    try testing.expect(memoryPerThread(testing.io, .{ .pattern = "x", .count_only = true }) < memoryPerThread(testing.io, .{ .pattern = "x" }));
    try testing.expectEqual(12 * chunkCeiling(testing.io), memoryPerThread(testing.io, .{ .pattern = "x" }));

    // Plenty of memory: one thread per CPU, whatever the mode.
    for ([_]usize{ rendering, counting }) |per_thread| {
        try testing.expectEqual(@as(usize, 8), threadsFor(0, 8, 4096 * mib, per_thread));
        try testing.expectEqual(@as(usize, 64), threadsFor(0, 64, 4096 * mib, per_thread));
    }
    // Tight limits reduce it, but never below one.
    try testing.expectEqual(@as(usize, 5), threadsFor(0, 8, 128 * mib, rendering));
    try testing.expectEqual(@as(usize, 8), threadsFor(0, 8, 128 * mib, counting));
    try testing.expectEqual(@as(usize, 2), threadsFor(0, 8, 64 * mib, rendering));
    try testing.expectEqual(@as(usize, 1), threadsFor(0, 8, 1, rendering));
    // An explicit -j wins over the memory-based choice.
    try testing.expectEqual(@as(usize, 6), threadsFor(6, 8, 1, rendering));
    try testing.expectEqual(@as(usize, max_threads), threadsFor(100_000, 8, 4096 * mib, rendering));
}

test "automatic thread count under a tight limit still gives the reference output" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 31, 3000, "abc ", 0, true);
    defer gpa.free(data);
    for ([_]usize{ 1, 8 << 20, 200 << 20 }) |limit| {
        for ([_]bool{ false, true }) |numbered| {
            try expectMatchesReference(data, .{ .pattern = "ab", .line_numbers = numbered, .chunk_size = 256, .memory_limit = limit });
        }
    }
}

test "lines around the zero-copy threshold keep their order and content" {
    const gpa = testing.allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(77);
    const rnd = prng.random();
    // Matching lines just under, at and over the threshold, between short matching and
    // non-matching ones, the last without a trailing newline.
    const lens = [_]usize{ 10, zero_copy_min_len - 1, 5, zero_copy_min_len, zero_copy_min_len + 1, 30, 3 * zero_copy_min_len, 7, zero_copy_min_len };
    for (lens, 0..) |len, i| {
        try data.appendSlice(gpa, "x"); // keeps every line matching "xa"
        for (0..len) |_| try data.append(gpa, "abc"[rnd.uintLessThan(usize, 3)]);
        try data.appendSlice(gpa, "xa");
        if (i + 1 < lens.len) try data.append(gpa, '\n');
        if (i % 3 == 0) try data.appendSlice(gpa, "no match here\n");
    }
    for ([_]IoChoice{ .mmap, .pread, .auto }) |io_choice| for ([_]usize{ 1000, 20_000, 0 }) |chunk| {
        for ([_]bool{ false, true }) |numbered| {
            try expectMatchesReference(data.items, .{ .pattern = "xa", .line_numbers = numbered, .io = io_choice, .threads = 3, .chunk_size = chunk });
        }
    };
}

test "AccessStats tries every allowed method, then keeps the fastest, with either policy" {
    for ([_]AccessStats.Policy{ .one_thread, .threads }) |policy| {
        var st: AccessStats = .{ .allowed = .{ true, true, true }, .policy = policy };
        var streak: AccessStats.Streak = .{};
        var prev: ?Access = null;
        var in_row: u32 = 0;
        var used = [_]bool{ false, false, false };
        // `.map` is twice as fast per byte as the others. The chunks the policy does not
        // count are very slow, so that counting one would make the fastest method look like
        // the slowest.
        const Sim = struct {
            fn ns(p: AccessStats.Policy, a: Access, row: u32, first_use: bool) u64 {
                if (row <= p.settle or (p.skip_first and first_use)) return 1_000_000;
                return if (a == .map) 1000 else 2000;
            }
        };
        // Warm-up: every method gets its runs before any choice is made.
        var seen = [_]u32{ 0, 0, 0 };
        const warm_chunks = policy.burst * policy.warm_runs;
        for (0..warm_chunks * 3) |n| {
            const a = st.pick(&streak);
            seen[@intFromEnum(a)] += 1;
            if (n % policy.burst != 0) try testing.expectEqual(prev.?, a);
            in_row = if (prev == a) in_row + 1 else 1;
            st.record(&streak, a, Sim.ns(policy, a, in_row, !used[@intFromEnum(a)]), 1000);
            used[@intFromEnum(a)] = true;
            prev = a;
        }
        try testing.expectEqual([_]u32{ warm_chunks, warm_chunks, warm_chunks }, seen);
        var picks = [_]usize{ 0, 0, 0 };
        var other_runs: usize = 0;
        const total = policy.recheck_every * 4;
        for (0..total) |_| {
            const a = st.pick(&streak);
            picks[@intFromEnum(a)] += 1;
            if (a != .map and prev == .map) other_runs += 1;
            in_row = if (prev == a) in_row + 1 else 1;
            st.record(&streak, a, Sim.ns(policy, a, in_row, false), 1000);
            prev = a;
        }
        // All but the periodic re-checks go to the fastest method; the re-checks are whole
        // runs and alternate between the other two.
        try testing.expect(other_runs >= 3);
        try testing.expectEqual(other_runs * policy.burst, picks[@intFromEnum(Access.map_advise)] + picks[@intFromEnum(Access.read)]);
        try testing.expect(@max(picks[0], picks[2]) - @min(picks[0], picks[2]) <= policy.burst);
        try testing.expectEqual(total - other_runs * policy.burst, picks[@intFromEnum(Access.map)]);
        // A restriction is obeyed.
        var only_read: AccessStats = .{ .allowed = .{ false, false, true }, .policy = policy };
        try testing.expectEqual(Access.read, only_read.pick(&streak));
    }
}

test "a shared engine runs concurrent searches, each with the reference output" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    var datas: [names.len][]u8 = undefined;
    for (&datas, names, 0..) |*d, name, k| {
        d.* = try genText(gpa, 40 + k, 1500 + 700 * k, "abc \n", if (k == 2) 50_000 else 0, k != 1);
        try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = d.* });
    }
    defer for (datas) |d| gpa.free(d);
    var files: [names.len]Io.File = undefined;
    for (&files, names) |*f, name| f.* = try tmp.dir.openFile(testing.io, name, .{});
    defer for (files) |f| f.close(testing.io);

    const Caller = struct {
        engine: *Engine(.shared),
        files: []const Io.File,
        datas: []const []const u8,
        seed: u64,
        failed: *std.atomic.Value(bool),

        fn run(c: @This()) void {
            c.searches() catch |err| {
                std.debug.print("caller {d}: {t}\n", .{ c.seed, err });
                c.failed.store(true, .monotonic);
            };
        }

        fn searches(c: @This()) !void {
            var prng = std.Random.DefaultPrng.init(c.seed);
            const rnd = prng.random();
            const patterns = [_][]const u8{ "a", "ab", "c a", "abc", "zz", "b b" };
            for (0..12) |_| {
                const k = rnd.uintLessThan(usize, c.files.len);
                const opts: Options = .{
                    .pattern = patterns[rnd.uintLessThan(usize, patterns.len)],
                    .line_numbers = rnd.boolean(),
                    .count_only = rnd.uintLessThan(u8, 4) == 0,
                    .threads = rnd.uintLessThan(usize, 4), // 0: the whole pool
                    .chunk_size = ([_]usize{ 64, 1000, 4096 })[rnd.uintLessThan(usize, 3)],
                    .io = ([_]IoChoice{ .mmap, .pread, .auto })[rnd.uintLessThan(usize, 3)],
                };
                const want = try expectedOutput(testing.allocator, c.datas[k], opts);
                defer testing.allocator.free(want);
                var out: Io.Writer.Allocating = .init(testing.allocator);
                defer out.deinit();
                const total = try c.engine.search(.{ .file = c.files[k] }, opts, &out.writer);
                try testing.expectEqualStrings(want, out.written());
                try testing.expectEqual(expectedCount(c.datas[k], opts.pattern), total);
            }
            // A search whose writer fails ends with the error, without disturbing the others.
            var w = Io.Writer.failing;
            try testing.expectError(error.WriteFailed, c.engine.search(.{ .file = c.files[0] }, .{ .pattern = "a", .chunk_size = 256 }, &w));
        }
    };

    // Tight limits make the searches wait for their writers and skip each other.
    for ([_]usize{ 0, 64 << 10, 1 }) |limit| {
        var engine: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 4, .memory_limit = limit });
        defer engine.deinit();
        var failed: std.atomic.Value(bool) = .init(false);
        var callers: [6]std.Thread = undefined;
        for (&callers, 0..) |*t, k| {
            t.* = try std.Thread.spawn(.{}, Caller.run, .{Caller{ .engine = &engine, .files = &files, .datas = &datas, .seed = 100 * limit + k, .failed = &failed }});
        }
        for (callers) |t| t.join();
        try testing.expect(!failed.load(.monotonic));
        // Every search gave its memory back, but for the buffers the engine keeps.
        try testing.expectEqual(@as(usize, 0), engine.pool.mem.queued.load(.monotonic));
        try testing.expect(engine.pool.mem.pool_bytes.load(.monotonic) <= engine.pool.retain);
    }
}

/// A writer that waits `delay_us` before every write: a client that reads slowly. It keeps
/// what it is given in `out` and counts its writes.
const SlowWriter = struct {
    out: Io.Writer.Allocating,
    delay_us: u64,
    writes: std.atomic.Value(usize) = .init(0),
    w: Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn init(gpa: std.mem.Allocator, delay_us: u64) SlowWriter {
        return .{ .out = .init(gpa), .delay_us = delay_us };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const sw: *SlowWriter = @alignCast(@fieldParentPtr("w", w));
        const until = Io.Timestamp.now(testing.io, .awake).nanoseconds + sw.delay_us * std.time.ns_per_us;
        while (Io.Timestamp.now(testing.io, .awake).nanoseconds < until) std.atomic.spinLoopHint();
        _ = sw.writes.fetchAdd(1, .monotonic);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try sw.out.writer.writeAll(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| try sw.out.writer.writeAll(last);
        return n + last.len * splat;
    }
};

test "a search can be canceled or time out, before or while it runs" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 50, 4000, "ab ", 0, true);
    defer gpa.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data });
    const file = try tmp.dir.openFile(testing.io, "input.txt", .{});
    defer file.close(testing.io);

    var shared: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 4 });
    defer shared.deinit();
    var oneshot: Engine(.oneshot) = .init(testing.io, gpa);

    const Canceler = struct {
        fn run(c: *Cancel, sw: *SlowWriter) void {
            // Cancel once the search is under way.
            while (sw.writes.load(.monotonic) < 5) std.atomic.spinLoopHint();
            c.request();
        }
    };
    inline for (.{ Kind.oneshot, Kind.shared }) |kind| {
        const engine = if (kind == .shared) &shared else &oneshot;
        for ([_]bool{ false, true }) |numbered| {
            // Canceled before it starts.
            var early: Cancel = .{};
            early.request();
            var w0 = SlowWriter.init(gpa, 0);
            defer w0.out.deinit();
            try testing.expectError(error.Canceled, engine.search(.{ .file = file }, .{ .pattern = "a", .line_numbers = numbered, .cancel = &early }, &w0.w));
            try testing.expectEqual(@as(usize, 0), w0.writes.load(.monotonic));

            // Canceled while it runs: it stops well before the end (each write takes 1 ms,
            // the whole output would take hundreds).
            var cancel: Cancel = .{};
            var sw = SlowWriter.init(gpa, 1000);
            defer sw.out.deinit();
            const t = try std.Thread.spawn(.{}, Canceler.run, .{ &cancel, &sw });
            try testing.expectError(error.Canceled, engine.search(.{ .file = file }, .{ .pattern = "a", .line_numbers = numbered, .chunk_size = 256, .threads = 4, .cancel = &cancel }, &sw.w));
            t.join();
            try testing.expect(sw.writes.load(.monotonic) < 100);

            // Out of time.
            var slow = SlowWriter.init(gpa, 1000);
            defer slow.out.deinit();
            try testing.expectError(error.Timeout, engine.search(.{ .file = file }, .{ .pattern = "a", .line_numbers = numbered, .chunk_size = 256, .threads = 4, .timeout_ns = 20 * std.time.ns_per_ms }, &slow.w));
            try testing.expect(slow.writes.load(.monotonic) < 100);
        }
        // A count can be stopped too.
        var early: Cancel = .{};
        early.request();
        var w1 = SlowWriter.init(gpa, 0);
        defer w1.out.deinit();
        try testing.expectError(error.Canceled, engine.search(.{ .file = file }, .{ .pattern = "a", .count_only = true, .cancel = &early }, &w1.w));
    }
    // The stopped searches gave their memory back, but for the buffers the engine keeps.
    try testing.expectEqual(@as(usize, 0), shared.pool.mem.queued.load(.monotonic));
    try testing.expect(shared.pool.mem.pool_bytes.load(.monotonic) <= shared.pool.retain);
}

test "a slow reader does not hold up the other searches of a shared engine" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 51, 3000, "ab c", 0, true);
    defer gpa.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data });
    const file = try tmp.dir.openFile(testing.io, "input.txt", .{});
    defer file.close(testing.io);

    // A small limit: the slow search soon waits for its reader, with chunks left.
    var engine: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 4, .memory_limit = 64 << 10 });
    defer engine.deinit();

    const Slow = struct {
        fn run(e: *Engine(.shared), f: Io.File, want: []const u8, done: *std.atomic.Value(bool), ok: *std.atomic.Value(bool)) void {
            var sw = SlowWriter.init(testing.allocator, 2000);
            defer sw.out.deinit();
            _ = e.search(.{ .file = f }, .{ .pattern = "a", .chunk_size = 256 }, &sw.w) catch return;
            ok.store(std.mem.eql(u8, want, sw.out.written()), .monotonic);
            done.store(true, .release);
        }
    };
    const want_slow = try expectedOutput(gpa, data, .{ .pattern = "a" });
    defer gpa.free(want_slow);
    var slow_done: std.atomic.Value(bool) = .init(false);
    var slow_ok: std.atomic.Value(bool) = .init(false);
    const slow = try std.Thread.spawn(.{}, Slow.run, .{ &engine, file, want_slow, &slow_done, &slow_ok });

    // Meanwhile other searches go through, while the slow one is still writing.
    for (0..15) |k| {
        const opts: Options = .{ .pattern = ([_][]const u8{ "c a", "ab", "b c" })[k % 3], .line_numbers = k % 2 == 0, .chunk_size = 1000 };
        const want = try expectedOutput(gpa, data, opts);
        defer gpa.free(want);
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try engine.search(.{ .file = file }, opts, &out.writer);
        try testing.expectEqualStrings(want, out.written());
    }
    try testing.expect(!slow_done.load(.acquire));
    slow.join();
    try testing.expect(slow_ok.load(.monotonic));
}

test "BusGuard turns a SIGBUS in a registered mapping into a page of zeros and a mark" {
    BusGuard.install();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const len = 8 * std.heap.pageSize();
    const data = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(data);
    @memset(data, 'x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.bin", .data = data });
    const file = try tmp.dir.openFile(testing.io, "t.bin", .{ .mode = .read_write });
    defer file.close(testing.io);
    // A shared mapping: it faults past the end of a truncated file on every system.
    const m = try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, file.handle, 0);
    defer std.posix.munmap(m);
    const slot = try BusGuard.register(m);
    defer BusGuard.unregister(slot);
    try file.setLength(testing.io, 0);
    var nonzero: usize = 0;
    for (m) |c| nonzero += @intFromBool(c != 0);
    try testing.expectEqual(@as(usize, 0), nonzero);
    try testing.expect(BusGuard.hit[slot].load(.acquire));
}

test "a file truncated during a search never brings the process down" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 52, 60_000, "ab c", 0, true);
    defer gpa.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.txt", .data = data });
    const other = try tmp.dir.openFile(testing.io, "other.txt", .{});
    defer other.close(testing.io);

    var engine: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 4, .memory_limit = 64 << 10 });
    defer engine.deinit();

    const Truncate = struct {
        fn run(f: Io.File, sw: *SlowWriter) void {
            while (sw.writes.load(.monotonic) < 5) std.atomic.spinLoopHint();
            f.setLength(testing.io, 0) catch unreachable;
        }
    };
    for ([_]IoChoice{ .mmap, .pread }) |io_choice| for ([_]bool{ false, true }) |numbered| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data });
        const file = try tmp.dir.openFile(testing.io, "input.txt", .{ .mode = .read_write });
        defer file.close(testing.io);
        const opts: Options = .{ .pattern = "a", .line_numbers = numbered, .io = io_choice, .chunk_size = 4096 };
        var sw = SlowWriter.init(gpa, 500);
        defer sw.out.deinit();
        const t = try std.Thread.spawn(.{}, Truncate.run, .{ file, &sw });
        const result = engine.search(.{ .file = file }, opts, &sw.w);
        t.join();
        if (result) |_| {
            // Only a mapping that keeps showing the old contents (macOS) gets here, and
            // then the output is that of the old contents.
            try testing.expect(io_choice == .mmap and builtin.target.os.tag.isDarwin());
            const want = try expectedOutput(gpa, data, opts);
            defer gpa.free(want);
            try testing.expectEqualStrings(want, sw.out.written());
        } else |err| try testing.expectEqual(error.FileChanged, err);
    };
    try testing.expectEqual(@as(usize, 0), engine.pool.mem.queued.load(.monotonic));
    try testing.expect(engine.pool.mem.pool_bytes.load(.monotonic) <= engine.pool.retain);

    // The engine goes on working.
    const want = try expectedOutput(gpa, data, .{ .pattern = "c a", .line_numbers = true });
    defer gpa.free(want);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try engine.search(.{ .file = other }, .{ .pattern = "c a", .line_numbers = true }, &out.writer);
    try testing.expectEqualStrings(want, out.written());
}

test "a one-shot search with the truncation guard survives the file being truncated" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 53, 60_000, "ab c", 0, true);
    defer gpa.free(data);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const Truncate = struct {
        fn run(f: Io.File, sw: *SlowWriter) void {
            while (sw.writes.load(.monotonic) < 5) std.atomic.spinLoopHint();
            f.setLength(testing.io, 0) catch unreachable;
        }
    };
    var engine: Engine(.oneshot) = .init(testing.io, gpa);
    for ([_]IoChoice{ .mmap, .pread }) |io_choice| for ([_]bool{ false, true }) |numbered| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data });
        const file = try tmp.dir.openFile(testing.io, "input.txt", .{ .mode = .read_write });
        defer file.close(testing.io);
        const opts: Options = .{
            .pattern = "a",
            .line_numbers = numbered,
            .io = io_choice,
            .chunk_size = 4096,
            .threads = 4,
            .memory_limit = 64 << 10,
            .truncation_guard = true,
        };
        var sw = SlowWriter.init(gpa, 500);
        defer sw.out.deinit();
        const t = try std.Thread.spawn(.{}, Truncate.run, .{ file, &sw });
        const result = engine.search(.{ .file = file }, opts, &sw.w);
        t.join();
        if (result) |_| {
            // Only a mapping that keeps showing the old contents (macOS) gets here.
            try testing.expect(io_choice == .mmap and builtin.target.os.tag.isDarwin());
            const want = try expectedOutput(gpa, data, opts);
            defer gpa.free(want);
            try testing.expectEqualStrings(want, sw.out.written());
        } else |err| try testing.expectEqual(error.FileChanged, err);
    };
}

test "a shared engine plans small searches from earlier ones and keeps measuring the others" {
    var engine: Engine(.shared) = try .init(testing.io, testing.allocator, .{ .threads = 1 });
    defer engine.deinit();
    const p = engine.pool;
    const n = Pool.Plan.methods.len;
    // Methods never measured come first.
    for (0..n) |k| {
        const pl = p.plan(0).?;
        try testing.expectEqual(k, pl.index);
        p.priors[0].rate[pl.index] = @floatFromInt(k + 1); // the first one is fastest
    }
    // Then mostly the fastest, and every `explore_every`-th search another one.
    var picks: [n]usize = @splat(0);
    const rounds = Pool.Priors.explore_every * 8;
    for (0..rounds) |_| picks[p.plan(0).?.index] += 1;
    try testing.expectEqual(rounds - rounds / Pool.Priors.explore_every, picks[0]);
    try testing.expectEqual(rounds / Pool.Priors.explore_every, picks[1]);
    // Large files are left to the chunks.
    try testing.expect(p.plan(Pool.chunk_choice_class) == null);
    // A measurement moves the prior towards it: 1 ms for a byte is slower than the prior.
    p.priors[1].rate[0] = 1;
    const now = Io.Timestamp.now(testing.io, .awake);
    p.learnPlan(.{ .index = 0, .class = 1, .start = .{ .nanoseconds = now.nanoseconds - std.time.ns_per_ms } }, 1);
    try testing.expect(p.priors[1].rate[0] > 1);
}

test "max_matches writes or counts only the first lines, wherever the limit falls" {
    const gpa = testing.allocator;
    // Short lines, and long ones that are written by reference (coalesced when adjacent),
    // one of them spanning many chunks.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(61);
    const rnd = prng.random();
    for (0..400) |k| {
        const len: usize = switch (k % 23) {
            3, 4, 5 => zero_copy_min_len + rnd.uintLessThan(usize, 1000),
            11 => 70_000,
            else => rnd.uintLessThan(usize, 40),
        };
        for (0..len) |_| try data.append(gpa, "ab c"[rnd.uintLessThan(usize, 4)]);
        try data.append(gpa, '\n');
    }
    for ([_]usize{ 1, 2, 5, 17, 100, 1_000_000 }) |max| for ([_]IoChoice{ .mmap, .pread }) |io_choice| for ([_]usize{ 1000, 20_000, 0 }) |chunk| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true } }) |flags| {
            try expectMatchesReference(data.items, .{
                .pattern = "a",
                .line_numbers = flags[0],
                .count_only = flags[1],
                .io = io_choice,
                .threads = 3,
                .chunk_size = chunk,
                .max_matches = max,
            });
        }
    };
}

test "bytes in memory are searched like a file" {
    const gpa = testing.allocator;
    const data = try genText(gpa, 70, 3000, "abc \n", 40_000, false);
    defer gpa.free(data);
    var shared: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 3 });
    defer shared.deinit();
    var oneshot: Engine(.oneshot) = .init(testing.io, gpa);
    for ([_][]const u8{ "a", "ab", "c a", "zz", "b b c" }) |pat| for ([_]usize{ 64, 1000, 0 }) |chunk| {
        for ([_][2]bool{ .{ false, false }, .{ true, false }, .{ false, true } }) |flags| {
            const opts: Options = .{ .pattern = pat, .line_numbers = flags[0], .count_only = flags[1], .chunk_size = chunk, .threads = 3 };
            const want = try expectedOutput(gpa, data, opts);
            defer gpa.free(want);
            inline for (.{ &oneshot, &shared }) |engine| {
                var out: Io.Writer.Allocating = .init(gpa);
                defer out.deinit();
                const total = try engine.search(.{ .bytes = data }, opts, &out.writer);
                try testing.expectEqualStrings(want, out.written());
                try testing.expectEqual(expectedCount(data, pat), total);
            }
        }
    };
}

test "searchLines hands over every matching line with its number, in order" {
    const gpa = testing.allocator;
    // Short lines, lines over the splitter's 64 KB buffer (written by reference), and one
    // that spans many chunks.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(71);
    const rnd = prng.random();
    for (0..300) |k| {
        const len: usize = switch (k % 37) {
            5, 6 => 70_000 + rnd.uintLessThan(usize, 1000),
            20 => 300_000,
            else => rnd.uintLessThan(usize, 50),
        };
        for (0..len) |_| try data.append(gpa, "ab c:"[rnd.uintLessThan(usize, 5)]);
        try data.append(gpa, '\n');
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "input.txt", .data = data.items });
    const file = try tmp.dir.openFile(testing.io, "input.txt", .{});
    defer file.close(testing.io);

    const Collect = struct {
        lines: std.ArrayList(u8) = .empty,
        stop_after: usize = 0,
        seen: usize = 0,

        fn onLine(ctx: ?*anyopaque, number: usize, line: []const u8) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx.?));
            c.seen += 1;
            if (c.stop_after != 0 and c.seen > c.stop_after) return error.EnoughLines;
            var w: Io.Writer.Allocating = .fromArrayList(testing.allocator, &c.lines);
            defer c.lines = w.toArrayList();
            try w.writer.print("{d}:{s}\n", .{ number, line });
        }
    };
    var shared: Engine(.shared) = try .init(testing.io, gpa, .{ .threads = 3 });
    defer shared.deinit();
    var oneshot: Engine(.oneshot) = .init(testing.io, gpa);
    for ([_][]const u8{ "a", "c:", "zz" }) |pat| for ([_]usize{ 1000, 0 }) |chunk| {
        const opts: Options = .{ .pattern = pat, .chunk_size = chunk, .threads = 3 };
        // The reference: the numbered output.
        const want = try expectedOutput(gpa, data.items, .{ .pattern = pat, .line_numbers = true });
        defer gpa.free(want);
        inline for (.{ &oneshot, &shared }) |engine| for ([_]Source{ .{ .file = file }, .{ .bytes = data.items } }) |src| {
            var c: Collect = .{};
            defer c.lines.deinit(gpa);
            const total = try engine.searchLines(src, opts, &c, Collect.onLine);
            try testing.expectEqualStrings(want, c.lines.items);
            try testing.expectEqual(expectedCount(data.items, pat), total);
        };
    };
    // An error from the callback ends the search with it.
    inline for (.{ &oneshot, &shared }) |engine| {
        var c: Collect = .{ .stop_after = 3 };
        defer c.lines.deinit(gpa);
        try testing.expectError(error.EnoughLines, engine.searchLines(.{ .file = file }, .{ .pattern = "a", .chunk_size = 1000 }, &c, Collect.onLine));
    }
}
