//! Bandwidth experiment for the shapes behind Linux `Access.read`.
//!
//! On Linux, zg's positional path (`--io=pread`) is already `io_uring` at depth one
//! (`readAt` in `src/zg.zig`). This bench keeps a synchronous `pread` row as the
//! baseline and varies queue depth, registered buffers, SQPOLL and `O_DIRECT`, to
//! see what fills each pipe.
//!
//! Reads are into a page-aligned buffer (zg's `readAt` rounds the start down to a
//! page because a copy whose source and destination sit at different offsets in a
//! cache line is several times slower on x86). io_uring rows use `IORING_OP_READ`
//! (or `IORING_OP_READ_FIXED` when the buffers fit in the locked-memory limit).
//!
//! Three ceilings, measured apart because they are different pipes:
//! - warm: the file is in the page cache. The limit is the copy out of it.
//! - cold: `POSIX_FADV_DONTNEED` before each run. The limit is the SSD through the
//!   page cache. `ru_inblock` says whether the drop happened; `ru_majflt` did not move.
//! - direct: `O_DIRECT`, so the drive's own ceiling, not the page cache.
//!
//! `scan` is the warm read plus a SIMD pass over every byte returned, the way a
//! search has to touch what it read. io_uring can overlap that pass with reads that
//! are still in flight; a synchronous `pread` cannot.
//!
//! Measured 2026-10-13 on the Ryzen 7 7735U and Samsung SSD 980 this tree's Linux
//! numbers come from (2 GiB, median of 5 rounds, rows rotated). Full table in
//! bench/uring-results.md.
//!
//! - Warm page cache, 8 threads, 256 KB or 1 MB, one buffer each: pread 34.3 GB/s.
//!   The same shape over io_uring was 25.5 GB/s, and 8 threads at 1 MB with 16 in
//!   flight fell to 11.5 GB/s. A deep queue of large buffers does not fit in L2,
//!   so the copy destination misses to DRAM. One L2-sized buffer per thread is
//!   the shape that fills the memory pipe, which is the shape zg already uses.
//! - Cold, after POSIX_FADV_DONTNEED (`ru_inblock` was the whole file): one pread
//!   thread 1.96 GB/s, one io_uring thread at queue depth 32 2.62 GB/s, and 4 or
//!   8 threads of either about 2.65 GB/s. The ring gets one thread up to the
//!   plateau the extra threads already reach. It does not raise the plateau.
//! - O_DIRECT, one thread, 1 MB, queue depth 32 or 128: 3.16 GB/s, the drive's
//!   rated 3100 MB/s. Several threads, pread or io_uring, sit at 2.7 GB/s.
//!   IOPOLL returned EOPNOTSUPP. SQPOLL, DEFER_TASKRUN and registered buffers
//!   (capped by an 8 MB memlock) did not move either ceiling.
//!
//! The warm search path is not an io_uring path. O_DIRECT is a different access
//! method, and the cold buffered plateau does not move.
//!
//! Rounds rotate the order of the rows. A laptop's clocks follow the order of the
//! runs, so one setting after another is not a comparison.
//!
//! ```
//! zig build uring -- --bytes=2G --rounds=5 --out=bench/uring-results.md
//! ```
//!
//! Linux only.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

pub const std_options: std.Options = .{
    .signal_stack_size = if (builtin.mode == .debug) 1 << 18 else null,
};

const max_rounds = 9;
const max_lanes = 16;
const max_qd = 256;
const max_block = 4 << 20;

const Kind = enum { pread, uring, fixed };

const Cfg = struct {
    kind: Kind,
    threads: u32,
    block: u64,
    qd: u32 = 1,
    iopoll: bool = false,
    sqpoll: bool = false,
    defer_run: bool = false,
};

const Gate = struct {
    go: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(u32) = .init(0),
    fail: std.atomic.Value(u32) = .init(0),
};

const Lane = struct {
    cfg: Cfg,
    fd: linux.fd_t,
    lo: u64,
    hi: u64,
    scan: bool,
    gate: *Gate,
    sum: u64 = 0,
    newlines: u64 = 0,
    bytes: u64 = 0,
    end_ns: u64 = 0,
};

const Obs = struct {
    ns: u64 = 0,
    user_us: u64 = 0,
    sys_us: u64 = 0,
    majflt: u64 = 0,
    inblock: u64 = 0,
    sum: u64 = 0,
    newlines: u64 = 0,
    ok: bool = false,
};

const Row = struct {
    phase: []const u8,
    kind: []const u8,
    threads: u32,
    block: u64,
    qd: u32,
    flags: []const u8,
    ms: f64 = 0,
    min_ms: f64 = 0,
    max_ms: f64 = 0,
    gbps: f64 = 0,
    cpu: f64 = 0,
    kern: f64 = 0,
    majflt: u64 = 0,
    inblock: u64 = 0,
    ok: bool = false,
};

// Warm: the copy out of the page cache. Block sizes are zg's chunk (256 KB on this
// machine's L2), a small read where the syscall shows, and a large one.
const warm_cfgs = [_]Cfg{
    .{ .kind = .pread, .threads = 1, .block = 64 << 10 },
    .{ .kind = .uring, .threads = 1, .block = 64 << 10, .qd = 64 },
    .{ .kind = .uring, .threads = 1, .block = 64 << 10, .qd = 64, .defer_run = true },
    .{ .kind = .pread, .threads = 1, .block = 256 << 10 },
    .{ .kind = .uring, .threads = 1, .block = 256 << 10, .qd = 32 },
    .{ .kind = .pread, .threads = 1, .block = 4 << 20 },
    .{ .kind = .uring, .threads = 1, .block = 4 << 20, .qd = 32 },
    .{ .kind = .uring, .threads = 1, .block = 4 << 20, .qd = 128 },
    .{ .kind = .pread, .threads = 8, .block = 256 << 10 },
    .{ .kind = .uring, .threads = 8, .block = 256 << 10, .qd = 8 },
    .{ .kind = .pread, .threads = 8, .block = 1 << 20 },
    .{ .kind = .uring, .threads = 8, .block = 1 << 20, .qd = 16 },
    .{ .kind = .pread, .threads = 8, .block = 4 << 20 },
    .{ .kind = .uring, .threads = 8, .block = 4 << 20, .qd = 8 },
    .{ .kind = .pread, .threads = 16, .block = 256 << 10 },
    .{ .kind = .uring, .threads = 16, .block = 256 << 10, .qd = 4 },
    .{ .kind = .pread, .threads = 16, .block = 4 << 20 },
    .{ .kind = .uring, .threads = 16, .block = 4 << 20, .qd = 4 },
    .{ .kind = .fixed, .threads = 1, .block = 1 << 20, .qd = 4 },
};

// Cold page cache, and O_DIRECT. Queue depth is the variable that can fill an NVMe.
const disk_cfgs = [_]Cfg{
    .{ .kind = .pread, .threads = 1, .block = 1 << 20 },
    .{ .kind = .uring, .threads = 1, .block = 1 << 20, .qd = 32 },
    .{ .kind = .uring, .threads = 1, .block = 1 << 20, .qd = 128 },
    .{ .kind = .uring, .threads = 1, .block = 1 << 20, .qd = 128, .defer_run = true },
    .{ .kind = .pread, .threads = 4, .block = 1 << 20 },
    .{ .kind = .uring, .threads = 4, .block = 1 << 20, .qd = 32 },
    .{ .kind = .pread, .threads = 8, .block = 1 << 20 },
    .{ .kind = .uring, .threads = 8, .block = 1 << 20, .qd = 16 },
    .{ .kind = .pread, .threads = 8, .block = 4 << 20 },
    .{ .kind = .uring, .threads = 8, .block = 4 << 20, .qd = 8 },
    .{ .kind = .fixed, .threads = 1, .block = 1 << 20, .qd = 4 },
};

const scan_cfgs = [_]Cfg{
    .{ .kind = .pread, .threads = 1, .block = 256 << 10 },
    .{ .kind = .uring, .threads = 1, .block = 256 << 10, .qd = 16 },
    .{ .kind = .pread, .threads = 8, .block = 256 << 10 },
    .{ .kind = .uring, .threads = 8, .block = 256 << 10, .qd = 8 },
    .{ .kind = .pread, .threads = 8, .block = 4 << 20 },
    .{ .kind = .uring, .threads = 8, .block = 4 << 20, .qd = 8 },
    .{ .kind = .pread, .threads = 16, .block = 256 << 10 },
    .{ .kind = .uring, .threads = 16, .block = 256 << 10, .qd = 4 },
};

fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn prefault(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 4096) buf[i] = 0;
}

const Consumed = struct { xor: u64, nl: u64 };

fn consume(buf: []const u8) Consumed {
    var vacc: @Vector(4, u64) = @splat(0);
    var nl: u64 = 0;
    var i: usize = 0;
    // Blocks are multiples of 32. A tail would still be correct, but every size this
    // bench uses is a multiple of the page, so the tail is a bug if it runs.
    std.debug.assert(buf.len % 32 == 0);
    while (i + 32 <= buf.len) : (i += 32) {
        const p: *const @Vector(32, u8) = @ptrCast(@alignCast(buf.ptr + i));
        const bytes = p.*;
        vacc ^= @as(@Vector(4, u64), @bitCast(bytes));
        const eq = bytes == @as(@Vector(32, u8), @splat('\n'));
        const ones: @Vector(32, u8) = @select(u8, eq, @as(@Vector(32, u8), @splat(1)), @as(@Vector(32, u8), @splat(0)));
        nl += @reduce(.Add, ones);
    }
    const lanes: [4]u64 = vacc;
    var x: u64 = 0;
    for (lanes) |v| x ^= v;
    std.mem.doNotOptimizeAway(x);
    std.mem.doNotOptimizeAway(nl);
    return .{ .xor = x, .nl = nl };
}

fn preadFull(fd: linux.fd_t, buf: []u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pread(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ShortRead;
                done += rc;
            },
            .INTR => continue,
            else => |e| {
                std.debug.print("pread: {s}\n", .{@tagName(e)});
                return error.Pread;
            },
        }
    }
}

fn pwriteFull(fd: linux.fd_t, buf: []const u8, offset: u64) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.pwrite(fd, buf.ptr + done, buf.len - done, @intCast(offset + done));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ShortWrite;
                done += rc;
            },
            .INTR => continue,
            else => |e| {
                std.debug.print("pwrite: {s}\n", .{@tagName(e)});
                return error.Pwrite;
            },
        }
    }
}

fn ringEntries(qd: u32) u16 {
    var n: u32 = 8;
    while (n < qd) n <<= 1;
    return @intCast(n);
}

fn ringFlags(cfg: Cfg) u32 {
    var f: u32 = 0;
    if (cfg.iopoll) f |= linux.IORING_SETUP_IOPOLL;
    if (cfg.sqpoll) f |= linux.IORING_SETUP_SQPOLL;
    if (cfg.defer_run) {
        f |= linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_COOP_TASKRUN | linux.IORING_SETUP_DEFER_TASKRUN;
    }
    return f;
}

fn submitRing(ring: *linux.IoUring) !void {
    while (true) {
        if (ring.submit()) |_| {
            return;
        } else |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        }
    }
}

fn copySome(ring: *linux.IoUring, cqes: []linux.io_uring_cqe, wait: bool) !u32 {
    while (true) {
        if (ring.copy_cqes(cqes, if (wait) 1 else 0)) |n| {
            return n;
        } else |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        }
    }
}

fn readPread(lane: *Lane, buf: []u8) !void {
    const block: usize = @intCast(lane.cfg.block);
    var off = lane.lo;
    while (off < lane.hi) {
        if (lane.gate.fail.load(.monotonic) != 0) return error.Aborted;
        try preadFull(lane.fd, buf[0..block], off);
        if (lane.scan) {
            const c = consume(buf[0..block]);
            lane.sum ^= c.xor;
            lane.newlines += c.nl;
        }
        off += block;
        lane.bytes += block;
    }
}

fn readUring(lane: *Lane, slab: []u8) !void {
    const qd = lane.cfg.qd;
    const block: usize = @intCast(lane.cfg.block);
    std.debug.assert(qd <= max_qd and qd > 0);

    var ring = try linux.IoUring.init(ringEntries(qd), ringFlags(lane.cfg));
    defer ring.deinit();

    var iovs: [max_qd]posix.iovec = undefined;
    var registered = false;
    defer if (registered) ring.unregister_buffers() catch {};
    if (lane.cfg.kind == .fixed) {
        for (0..qd) |s| {
            iovs[s] = .{ .base = slab.ptr + s * block, .len = block };
        }
        try ring.register_buffers(iovs[0..qd]);
        registered = true;
    }

    var free_ids: [max_qd]u32 = undefined;
    var free_n: u32 = qd;
    for (0..qd) |s| free_ids[s] = @intCast(s);

    var next = lane.lo;
    // Submitted operations only. Unflushed SQEs are dropped with the ring; closing
    // the ring fd cancels anything the kernel already has.
    var inflight: u32 = 0;
    errdefer {
        var pending: [64]linux.io_uring_cqe = undefined;
        while (inflight > 0) {
            const n = ring.copy_cqes(&pending, 0) catch break;
            if (n == 0) break;
            inflight -= @min(inflight, n);
        }
    }

    var cqes: [128]linux.io_uring_cqe = undefined;
    while (lane.bytes < lane.hi - lane.lo) {
        if (lane.gate.fail.load(.monotonic) != 0) return error.Aborted;
        var queued: u32 = 0;
        while (next < lane.hi and free_n > 0) {
            free_n -= 1;
            const slot = free_ids[free_n];
            const buf = slab[@as(usize, slot) * block ..][0..block];
            if (lane.cfg.kind == .fixed) {
                _ = try ring.read_fixed(slot, lane.fd, &iovs[slot], next, @intCast(slot));
            } else {
                _ = try ring.read(slot, lane.fd, .{ .buffer = buf }, next);
            }
            next += block;
            queued += 1;
        }
        if (queued > 0) {
            submitRing(&ring) catch |err| {
                inflight += queued;
                return err;
            };
            inflight += queued;
        }
        if (inflight == 0) break;
        const n = try copySome(&ring, &cqes, true);
        if (n == 0) return error.NoCompletion;
        for (cqes[0..n]) |cqe| {
            inflight -= 1;
            if (cqe.res != @as(i32, @intCast(block))) {
                if (cqe.res < 0) std.debug.print("cqe: {s}\n", .{@tagName(cqe.err())});
                return error.Cqe;
            }
            const slot: usize = @intCast(cqe.user_data);
            if (lane.scan) {
                const part = slab[slot * block ..][0..block];
                const c = consume(part);
                lane.sum ^= c.xor;
                lane.newlines += c.nl;
            }
            free_ids[free_n] = @intCast(slot);
            free_n += 1;
            lane.bytes += block;
        }
    }
}

fn failLane(lane: *Lane, err: anyerror) void {
    if (lane.gate.fail.cmpxchgStrong(0, 1, .monotonic, .monotonic) == null) {
        std.debug.print("uring: {s}\n", .{@errorName(err)});
    }
}

fn laneMain(lane: *Lane) void {
    runLane(lane) catch |err| failLane(lane, err);
}

fn runLane(lane: *Lane) !void {
    const qd: usize = if (lane.cfg.kind == .pread) 1 else lane.cfg.qd;
    const block: usize = @intCast(lane.cfg.block);
    const slab = std.heap.page_allocator.alloc(u8, block * qd) catch |err| {
        _ = lane.gate.ready.fetchAdd(1, .release);
        return err;
    };
    defer std.heap.page_allocator.free(slab);
    prefault(slab);
    _ = lane.gate.ready.fetchAdd(1, .release);
    while (lane.gate.go.load(.acquire) == 0) std.atomic.spinLoopHint();
    if (lane.gate.fail.load(.acquire) != 0) return;
    if (lane.cfg.kind == .pread) {
        try readPread(lane, slab);
    } else {
        try readUring(lane, slab);
    }
    lane.end_ns = nowNs();
}

fn fitThreads(span: u64, asked: u32, block: u64) u32 {
    if (block == 0 or span < block) return 0;
    const blocks: u32 = @intCast(@min(span / block, std.math.maxInt(u32)));
    return @min(asked, blocks);
}

fn rangeOf(span: u64, n: u32, block: u64, i: u32) struct { lo: u64, hi: u64 } {
    const blocks = span / block;
    const base = blocks / n;
    const extra = blocks % n;
    var lo: u64 = 0;
    for (0..i) |j| lo += (base + @intFromBool(j < extra)) * block;
    const nb = base + @intFromBool(i < extra);
    return .{ .lo = lo, .hi = lo + nb * block };
}

const UsageSnap = struct { user_us: u64, sys_us: u64, majflt: u64, inblock: u64 };

fn snapUsage() UsageSnap {
    var u: linux.rusage = std.mem.zeroes(linux.rusage);
    _ = linux.getrusage(0, &u);
    return .{
        .user_us = @intCast(@max(u.utime.sec, 0) * 1_000_000 + @max(u.utime.usec, 0)),
        .sys_us = @intCast(@max(u.stime.sec, 0) * 1_000_000 + @max(u.stime.usec, 0)),
        .majflt = @intCast(@max(u.majflt, 0)),
        .inblock = @intCast(@max(u.inblock, 0)),
    };
}

fn runOnce(fd: linux.fd_t, span: u64, cfg: Cfg, scan: bool, cold: bool) !Obs {
    const n = fitThreads(span, cfg.threads, cfg.block);
    if (n == 0) return error.TooSmall;

    var gate = Gate{};
    var lanes: [max_lanes]Lane = undefined;
    var threads: [max_lanes]std.Thread = undefined;
    for (0..n) |i| {
        const r = rangeOf(span, n, cfg.block, @intCast(i));
        lanes[i] = .{
            .cfg = cfg,
            .fd = fd,
            .lo = r.lo,
            .hi = r.hi,
            .scan = scan,
            .gate = &gate,
        };
    }

    var spawned: usize = 0;
    for (0..n) |i| {
        threads[i] = std.Thread.spawn(.{}, laneMain, .{&lanes[i]}) catch {
            gate.fail.store(1, .release);
            break;
        };
        spawned += 1;
    }
    if (spawned != n) {
        gate.go.store(1, .release);
        for (threads[0..spawned]) |t| t.join();
        return error.Spawn;
    }

    while (gate.ready.load(.acquire) < n) std.atomic.spinLoopHint();
    if (cold) {
        const rc = linux.fadvise(fd, 0, 0, linux.POSIX_FADV.DONTNEED);
        if (linux.errno(rc) != .SUCCESS) std.debug.print("fadvise: {s}\n", .{@tagName(linux.errno(rc))});
    }
    if (gate.fail.load(.acquire) != 0) {
        gate.go.store(1, .release);
        for (threads[0..n]) |t| t.join();
        return Obs{};
    }

    const before = snapUsage();
    const t0 = nowNs();
    gate.go.store(1, .release);
    for (threads[0..n]) |t| t.join();
    var t1 = t0;
    var sum: u64 = 0;
    var newlines: u64 = 0;
    var bytes: u64 = 0;
    for (lanes[0..n]) |ln| {
        if (ln.end_ns > t1) t1 = ln.end_ns;
        sum ^= ln.sum;
        newlines += ln.newlines;
        bytes += ln.bytes;
    }
    const after = snapUsage();
    if (gate.fail.load(.acquire) != 0 or bytes != span) return Obs{};
    return .{
        .ns = t1 - t0,
        .user_us = after.user_us -| before.user_us,
        .sys_us = after.sys_us -| before.sys_us,
        .majflt = after.majflt -| before.majflt,
        .inblock = after.inblock -| before.inblock,
        .sum = sum,
        .newlines = newlines,
        .ok = true,
    };
}

fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .pread => "pread",
        .uring => "uring",
        .fixed => "fixed",
    };
}

fn flagName(cfg: Cfg) []const u8 {
    if (cfg.iopoll) return "iopoll";
    if (cfg.sqpoll) return "sqpoll";
    if (cfg.defer_run) return "defer";
    return "-";
}

fn fmtBlock(block: u64, buf: []u8) []const u8 {
    if (block % (1 << 20) == 0) return std.fmt.bufPrint(buf, "{d}M", .{block >> 20}) catch "?";
    if (block % (1 << 10) == 0) return std.fmt.bufPrint(buf, "{d}K", .{block >> 10}) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{block}) catch "?";
}

fn gbpsOf(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns));
}

fn medianOf(samples: []Obs) ?Obs {
    var idx: [max_rounds]usize = undefined;
    var n: usize = 0;
    for (samples, 0..) |s, i| if (s.ok) {
        idx[n] = i;
        n += 1;
    };
    if (n == 0) return null;
    // Insertion sort by time. A few rounds, and the index is what the other fields follow.
    var k: usize = 1;
    while (k < n) : (k += 1) {
        const v = idx[k];
        var j = k;
        while (j > 0 and samples[idx[j - 1]].ns > samples[v].ns) : (j -= 1) idx[j] = idx[j - 1];
        idx[j] = v;
    }
    return samples[idx[n / 2]];
}

fn spreadMs(samples: []Obs) struct { min: f64, max: f64 } {
    var lo: u64 = std.math.maxInt(u64);
    var hi: u64 = 0;
    for (samples) |s| if (s.ok) {
        lo = @min(lo, s.ns);
        hi = @max(hi, s.ns);
    };
    return .{ .min = @as(f64, @floatFromInt(lo)) / 1e6, .max = @as(f64, @floatFromInt(hi)) / 1e6 };
}

fn checkErrno(rc: usize, what: []const u8) !usize {
    switch (linux.errno(rc)) {
        .SUCCESS => return rc,
        else => |e| {
            std.debug.print("{s}: {s}\n", .{ what, @tagName(e) });
            return error.Errno;
        },
    }
}

fn openPath(path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) !linux.fd_t {
    var with = flags;
    with.NOATIME = true;
    const rc = linux.open(path, with, mode);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .PERM, .ACCES => {
            const rc2 = try checkErrno(linux.open(path, flags, mode), "open");
            return @intCast(rc2);
        },
        else => |e| {
            std.debug.print("open: {s}\n", .{@tagName(e)});
            return error.Open;
        },
    }
}

fn fileSize(path: [*:0]const u8) ?u64 {
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    var mask: linux.STATX = linux.STATX.BASIC_STATS;
    mask.DIOALIGN = true;
    const rc = linux.statx(linux.AT.FDCWD, path, 0, mask, &stx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return stx.size;
}

fn dioAlign(fd: linux.fd_t) struct { mem: u32, off: u32 } {
    var stx: linux.Statx = std.mem.zeroes(linux.Statx);
    const mask: linux.STATX = .{ .DIOALIGN = true };
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &stx);
    if (linux.errno(rc) != .SUCCESS or !stx.mask.DIOALIGN or stx.dio_mem_align == 0) {
        return .{ .mem = 4096, .off = 4096 };
    }
    return .{ .mem = stx.dio_mem_align, .off = if (stx.dio_offset_align == 0) stx.dio_mem_align else stx.dio_offset_align };
}

fn ensureFile(fd: linux.fd_t, path: [*:0]const u8, span: u64) !void {
    if (fileSize(path)) |sz| if (sz >= span) {
        std.debug.print("reusing {d} bytes on disk (file is {d})\n", .{ span, sz });
        _ = linux.fsync(fd);
        return;
    };
    std.debug.print("writing {d} bytes\n", .{span});
    const chunk = try std.heap.page_allocator.alloc(u8, 1 << 20);
    defer std.heap.page_allocator.free(chunk);
    // A fixed byte, then a newline every 64 bytes. The newline count is then span/64,
    // so a short or doubled read cannot pass the check. A patterned fill can itself
    // be 0x0a and hide that.
    @memset(chunk, 'x');
    var k: usize = 63;
    while (k < chunk.len) : (k += 64) chunk[k] = '\n';

    var off: u64 = 0;
    var next_report: u64 = 256 << 20;
    while (off < span) {
        const n: usize = @intCast(@min(chunk.len, span - off));
        try pwriteFull(fd, chunk[0..n], off);
        off += n;
        if (off >= next_report) {
            std.debug.print("  wrote {d} MiB\n", .{off >> 20});
            next_report += 256 << 20;
        }
    }
    const rc = try checkErrno(linux.fsync(fd), "fsync");
    _ = rc;
    std.debug.print("synced\n", .{});
}

fn sqpollOk() bool {
    var ring = linux.IoUring.init(8, linux.IORING_SETUP_SQPOLL) catch return false;
    ring.deinit();
    return true;
}

fn readShort(path: [*:0]const u8, buf: []u8) []const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return "";
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return "";
    return buf[0..@min(n, buf.len)];
}

fn cpuModel(buf: []u8) []const u8 {
    const text = readShort("/proc/cpuinfo", buf);
    const key = "model name";
    const at = std.mem.indexOf(u8, text, key) orelse return "unknown";
    var line = text[at..];
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
        var rest = line[colon + 1 ..];
        while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
        return rest;
    }
    return "unknown";
}

fn parseSize(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var end = text.len;
    var mul: u64 = 1;
    if (std.ascii.isAlphabetic(text[text.len - 1])) {
        end -= 1;
        mul = switch (std.ascii.toLower(text[text.len - 1])) {
            'k' => 1 << 10,
            'm' => 1 << 20,
            'g' => 1 << 30,
            else => return null,
        };
    }
    const n = std.fmt.parseInt(u64, text[0..end], 10) catch return null;
    return std.math.mul(u64, n, mul) catch return null;
}

fn zpath(buf: []u8, text: []const u8) ![*:0]const u8 {
    if (text.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return buf[0..text.len :0].ptr;
}

const usage =
    \\usage: uring [PATH] [--bytes=2G] [--rounds=5] [--out=FILE] [--phase=all|warm|cold|direct|scan]
    \\
    \\  Page-aligned pread against io_uring, warm page cache, cold (fadvise DONTNEED)
    \\  and O_DIRECT. PATH must be on the disk under test, not a tmpfs.
    \\  Default PATH is bench-corpus/uring.bin. Rounds rotate row order.
    \\
;

const PhaseSel = enum { all, warm, cold, direct, scan };

fn want(sel: PhaseSel, phase: []const u8) bool {
    if (sel == .all) return true;
    return std.mem.eql(u8, @tagName(sel), phase);
}

fn runPhase(
    rows: *std.ArrayList(Row),
    gpa: std.mem.Allocator,
    fd: linux.fd_t,
    span: u64,
    phase: []const u8,
    cfgs: []const Cfg,
    rounds: usize,
    scan: bool,
    cold: bool,
    align_to: u32,
) !void {
    if (cfgs.len == 0) return;
    // samples[k][r] is always cfgs[k], round r. The inner walk starts at r so the
    // row order rotates and a clock that follows the order does not favour one row.
    var samples: [64][max_rounds]Obs = std.mem.zeroes([64][max_rounds]Obs);
    const ncfg = cfgs.len;
    if (ncfg > samples.len) return error.TooManyCfgs;
    const page = std.heap.pageSize();

    for (0..rounds) |r| {
        for (0..ncfg) |step| {
            const k = (step + r) % ncfg;
            const cfg = cfgs[k];
            if (align_to != 0 and (cfg.block % align_to != 0 or page < align_to)) {
                if (r == 0) std.debug.print("skip {s} {s} block {d} (O_DIRECT align {d})\n", .{ phase, kindName(cfg.kind), cfg.block, align_to });
                continue;
            }
            var bbuf: [16]u8 = undefined;
            std.debug.print("run {s} {s} t={d} b={s} qd={d} {s}\n", .{
                phase, kindName(cfg.kind), cfg.threads, fmtBlock(cfg.block, &bbuf), cfg.qd, flagName(cfg),
            });
            if (runOnce(fd, span, cfg, scan, cold)) |obs| {
                samples[k][r] = obs;
            } else |err| {
                std.debug.print("  {s}\n", .{@errorName(err)});
                samples[k][r] = .{};
            }
            const s = samples[k][r];
            if (s.ok) {
                std.debug.print("  {d:.1} ms  {d:.2} GB/s\n", .{
                    @as(f64, @floatFromInt(s.ns)) / 1e6, gbpsOf(span, s.ns),
                });
            } else std.debug.print("  failed\n", .{});
        }
    }

    for (cfgs, 0..) |cfg, k| {
        const med = medianOf(samples[k][0..rounds]);
        var row = Row{
            .phase = phase,
            .kind = kindName(cfg.kind),
            .threads = fitThreads(span, cfg.threads, cfg.block),
            .block = cfg.block,
            .qd = if (cfg.kind == .pread) 0 else cfg.qd,
            .flags = flagName(cfg),
        };
        if (med) |m| {
            const sp = spreadMs(samples[k][0..rounds]);
            const wall_us = @as(f64, @floatFromInt(m.ns)) / 1000;
            const cpu_us: f64 = @floatFromInt(m.user_us + m.sys_us);
            row.ms = @as(f64, @floatFromInt(m.ns)) / 1e6;
            row.min_ms = sp.min;
            row.max_ms = sp.max;
            row.gbps = gbpsOf(span, m.ns);
            row.cpu = if (wall_us == 0) 0 else cpu_us / wall_us;
            row.kern = if (cpu_us == 0) 0 else @as(f64, @floatFromInt(m.sys_us)) / cpu_us * 100;
            row.majflt = m.majflt;
            row.inblock = m.inblock;
            row.ok = true;
        }
        try rows.append(gpa, row);
    }
}

fn printRow(row: Row) void {
    var bbuf: [16]u8 = undefined;
    if (!row.ok) {
        std.debug.print("{s:<7} {s:<5} t={d:<2} {s:<4} qd={d:<3} {s:<6} failed\n", .{
            row.phase, row.kind, row.threads, fmtBlock(row.block, &bbuf), row.qd, row.flags,
        });
        return;
    }
    std.debug.print("{s:<7} {s:<5} t={d:<2} {s:<4} qd={d:<3} {s:<6} {d:>8.1} ms  {d:>6.2} GB/s  ({d:.1}-{d:.1})  cpu {d:.1}x  kern {d:.0}%  maj {d}  inb {d}\n", .{
        row.phase, row.kind, row.threads, fmtBlock(row.block, &bbuf), row.qd, row.flags,
        row.ms, row.gbps, row.min_ms, row.max_ms, row.cpu, row.kern, row.majflt, row.inblock,
    });
}

fn writeReport(
    path: []const u8,
    body: []const u8,
) !void {
    var zbuf: [4096]u8 = undefined;
    const path_z = try zpath(&zbuf, path);
    const rc = try checkErrno(linux.open(path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o644), "open out");
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < body.len) {
        const n = linux.write(fd, body.ptr + off, body.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return error.ShortWrite;
                off += n;
            },
            .INTR => continue,
            else => return error.Write,
        }
    }
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) {
        std.debug.print("uring: Linux only\n", .{});
        return error.UnsupportedOs;
    }
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var path: []const u8 = "bench-corpus/uring.bin";
    var bytes: u64 = 2 << 30;
    var rounds: usize = 5;
    var out_path: ?[]const u8 = null;
    var phase_sel: PhaseSel = .all;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.startsWith(u8, a, "--bytes=")) {
            bytes = parseSize(a["--bytes=".len..]) orelse return error.BadArgument;
        } else if (std.mem.startsWith(u8, a, "--rounds=")) {
            rounds = try std.fmt.parseInt(usize, a["--rounds=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--out=")) {
            out_path = a["--out=".len..];
        } else if (std.mem.startsWith(u8, a, "--phase=")) {
            phase_sel = std.meta.stringToEnum(PhaseSel, a["--phase=".len..]) orelse return error.BadArgument;
        } else if (a.len > 0 and a[0] == '-') {
            std.debug.print("{s}", .{usage});
            return error.BadArgument;
        } else path = a;
    }
    if (rounds == 0 or rounds > max_rounds) return error.BadArgument;
    if (bytes > 8 << 30) return error.TooBig;
    const span = bytes / max_block * max_block;
    if (span == 0) return error.TooSmall;

    if (std.mem.eql(u8, path, "bench-corpus/uring.bin")) {
        const rc = linux.mkdir("bench-corpus", 0o755);
        switch (linux.errno(rc)) {
            .SUCCESS, .EXIST => {},
            else => |e| {
                std.debug.print("mkdir: {s}\n", .{@tagName(e)});
                return error.Mkdir;
            },
        }
    }

    var path_buf: [4096]u8 = undefined;
    const path_z = try zpath(&path_buf, path);
    const fd = try openPath(path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o644);
    defer _ = linux.close(fd);
    try ensureFile(fd, path_z, span);

    var direct_fd: ?linux.fd_t = null;
    var align_to: u32 = 4096;
    if (openPath(path_z, .{ .ACCMODE = .RDONLY, .DIRECT = true, .CLOEXEC = true }, 0)) |d| {
        direct_fd = d;
        const al = dioAlign(d);
        align_to = @max(al.mem, al.off);
        std.debug.print("O_DIRECT align mem {d} off {d}\n", .{ al.mem, al.off });
    } else |err| std.debug.print("O_DIRECT unavailable: {s}\n", .{@errorName(err)});
    defer if (direct_fd) |d| {
        _ = linux.close(d);
    };

    const sqpoll = sqpollOk();
    var cpu_buf: [8192]u8 = undefined;
    const model = cpuModel(&cpu_buf);
    std.debug.print("file {s}  span {d}  rounds {d}  sqpoll {s}  cpu {s}\n", .{
        path, span, rounds, if (sqpoll) "yes" else "no", model,
    });

    // One buffered pread and one io_uring scan must see the same bytes. The file has a
    // newline every 64 bytes, so the count is fixed too. This also loads the page cache.
    const check_cfg = Cfg{ .kind = .pread, .threads = 4, .block = 1 << 20 };
    const check_uring = Cfg{ .kind = .uring, .threads = 4, .block = 1 << 20, .qd = 16 };
    const a = try runOnce(fd, span, check_cfg, true, false);
    const b = try runOnce(fd, span, check_uring, true, false);
    if (!a.ok or !b.ok or a.sum != b.sum or a.newlines != b.newlines or a.newlines != span / 64) {
        std.debug.print("verify failed pread ok={any} nl={d} sum={x} uring ok={any} nl={d} sum={x} want {d}\n", .{
            a.ok, a.newlines, a.sum, b.ok, b.newlines, b.sum, span / 64,
        });
        std.process.exit(1);
    }
    std.debug.print("verify pread == uring  newlines {d}\n", .{a.newlines});
    if (direct_fd) |d| {
        if (align_to <= std.heap.pageSize() and (1 << 20) % align_to == 0) {
            const c = try runOnce(d, span, check_cfg, true, false);
            const e = try runOnce(d, span, check_uring, true, false);
            if (!c.ok or !e.ok or c.sum != a.sum or e.sum != a.sum) {
                std.debug.print("verify O_DIRECT mismatch\n", .{});
                std.process.exit(1);
            }
            std.debug.print("verify O_DIRECT matches\n", .{});
        }
    }

    var cold_list: [disk_cfgs.len + 2]Cfg = undefined;
    var cold_n: usize = disk_cfgs.len;
    @memcpy(cold_list[0..disk_cfgs.len], &disk_cfgs);
    if (sqpoll) {
        cold_list[cold_n] = .{ .kind = .uring, .threads = 1, .block = 1 << 20, .qd = 128, .sqpoll = true };
        cold_n += 1;
    }

    var direct_list: [disk_cfgs.len + 4]Cfg = undefined;
    var direct_n: usize = 0;
    for (disk_cfgs) |cfg| {
        direct_list[direct_n] = cfg;
        direct_n += 1;
    }
    direct_list[direct_n] = .{ .kind = .uring, .threads = 1, .block = 1 << 20, .qd = 64, .iopoll = true };
    direct_n += 1;
    if (sqpoll) {
        direct_list[direct_n] = .{ .kind = .uring, .threads = 1, .block = 1 << 20, .qd = 128, .sqpoll = true };
        direct_n += 1;
    }

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(init.gpa);
    if (want(phase_sel, "warm")) try runPhase(&rows, init.gpa, fd, span, "warm", &warm_cfgs, rounds, false, false, 0);
    if (want(phase_sel, "scan")) try runPhase(&rows, init.gpa, fd, span, "scan", &scan_cfgs, rounds, true, false, 0);
    if (want(phase_sel, "cold")) try runPhase(&rows, init.gpa, fd, span, "cold", cold_list[0..cold_n], rounds, false, true, 0);
    if (want(phase_sel, "direct")) if (direct_fd) |d| {
        try runPhase(&rows, init.gpa, d, span, "direct", direct_list[0..direct_n], rounds, false, false, align_to);
    };

    std.debug.print("\n", .{});
    for (rows.items) |row| printRow(row);

    std.debug.print("\nmatched against pread, same phase, threads and block (GB/s ratio)\n", .{});
    for (rows.items) |row| {
        if (!row.ok or std.mem.eql(u8, row.kind, "pread")) continue;
        const base = for (rows.items) |other| {
            if (other.ok and std.mem.eql(u8, other.kind, "pread") and std.mem.eql(u8, other.phase, row.phase) and other.threads == row.threads and other.block == row.block) break other;
        } else continue;
        var bbuf: [16]u8 = undefined;
        std.debug.print("  {s} {s} t={d} {s} qd={d} {s}  {d:.2}x  ({d:.2} vs {d:.2} GB/s)\n", .{
            row.phase, row.kind, row.threads, fmtBlock(row.block, &bbuf), row.qd, row.flags,
            row.gbps / base.gbps, row.gbps, base.gbps,
        });
    }

    if (out_path) |op| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(init.gpa);
        try body.print(init.gpa, "file {s}\nspan {d}\nrounds {d}\nsqpoll {s}\ncpu {s}\nalign {d}\n\n", .{
            path, span, rounds, if (sqpoll) "yes" else "no", model, align_to,
        });
        try body.print(init.gpa, "phase kind threads block qd flags ms min max GB/s cpu kern majflt inblock\n", .{});
        for (rows.items) |row| {
            var bbuf: [16]u8 = undefined;
            if (!row.ok) {
                try body.print(init.gpa, "{s} {s} {d} {s} {d} {s} fail\n", .{
                    row.phase, row.kind, row.threads, fmtBlock(row.block, &bbuf), row.qd, row.flags,
                });
            } else {
                try body.print(init.gpa, "{s} {s} {d} {s} {d} {s} {d:.1} {d:.1} {d:.1} {d:.2} {d:.2} {d:.0} {d} {d}\n", .{
                    row.phase, row.kind, row.threads, fmtBlock(row.block, &bbuf), row.qd, row.flags,
                    row.ms, row.min_ms, row.max_ms, row.gbps, row.cpu, row.kern, row.majflt, row.inblock,
                });
            }
        }
        try writeReport(op, body.items);
        std.debug.print("wrote {s}\n", .{op});
    }
}
