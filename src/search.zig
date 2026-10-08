//! SIMD literal search primitives. All functions operate on in-memory slices.
const std = @import("std");
const builtin = @import("builtin");

/// Vector width in bytes: one register. NEON and x86 without AVX2 (SSE2 only) have 16-byte
/// registers; 32 maps to one AVX2 register. On SSE2, 32-byte vectors are split in two and the
/// lane masks put back together, which cost twice the time: one thread, `-c needle_zz` on a
/// 540 MB cached file, 154 ms with 32 and 74 ms with 16 (68 ms with AVX2).
pub const vec_len = if (builtin.cpu.arch.isAARCH64() or (builtin.cpu.arch == .x86_64 and !std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))) 16 else 32;
const Vec = @Vector(vec_len, u8);
const neon = builtin.cpu.arch.isAARCH64();

/// Bitmask of lane hits. x86 uses one bit per lane (movemask); NEON has no
/// movemask, so lanes are narrowed to one nibble each (the `shrn` trick).
const Mask = if (neon) u64 else std.meta.Int(.unsigned, vec_len);
const bits_per_lane = if (neon) 4 else 1;
const lane_bits: Mask = if (neon) 0x1111_1111_1111_1111 else std.math.maxInt(Mask);

inline fn toMask(eq: @Vector(vec_len, bool)) Mask {
    if (!neon) return @bitCast(eq);
    const bytes: Vec = @select(u8, eq, @as(Vec, @splat(0xff)), @as(Vec, @splat(0)));
    const wide: @Vector(vec_len / 2, u16) = @bitCast(bytes);
    const narrow: @Vector(vec_len / 2, u8) = @truncate(wide >> @as(@Vector(vec_len / 2, u4), @splat(4)));
    return @bitCast(narrow);
}

/// Index of the lowest-set lane.
inline fn firstLane(m: Mask) usize {
    return @ctz(m) / bits_per_lane;
}

/// Index of the highest-set lane.
inline fn lastLane(m: Mask) usize {
    return (@bitSizeOf(Mask) - 1 - @clz(m)) / bits_per_lane;
}

/// Byte frequency ranks (higher = more common), the background distribution
/// used by ripgrep's memchr crate for its packed-pair prefilter.
const rank = [256]u8{
    55,  52,  51,  50,  49,  48,  47,  46,  45,  103, 242, 66,  67,  229, 44,  43,
    42,  41,  40,  39,  38,  37,  36,  35,  34,  33,  56,  32,  31,  30,  29,  28,
    255, 148, 164, 149, 136, 160, 155, 173, 221, 222, 134, 122, 232, 202, 215, 224,
    208, 220, 204, 187, 183, 179, 177, 168, 178, 200, 226, 195, 154, 184, 174, 126,
    120, 191, 157, 194, 170, 189, 162, 161, 150, 193, 142, 137, 171, 176, 185, 167,
    186, 112, 175, 192, 188, 156, 140, 143, 123, 133, 128, 147, 138, 146, 114, 223,
    151, 249, 216, 238, 236, 253, 227, 218, 230, 247, 135, 180, 241, 233, 246, 244,
    231, 139, 245, 243, 251, 235, 201, 196, 240, 214, 152, 182, 205, 181, 127, 27,
    212, 211, 210, 213, 228, 197, 169, 159, 131, 172, 105, 80,  98,  96,  97,  81,
    207, 145, 116, 115, 144, 130, 153, 121, 107, 132, 109, 110, 124, 111, 82,  108,
    118, 141, 113, 129, 119, 125, 165, 117, 92,  106, 83,  72,  99,  93,  65,  79,
    166, 237, 163, 199, 190, 225, 209, 203, 198, 217, 219, 206, 234, 248, 158, 239,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
};

/// When the two rarest bytes are still this common (sum of their ranks), the
/// pair filter lets through many false candidates, so a third byte is added.
const weak_pair_rank_sum = 400;

/// Verification work (bytes compared) allowed per byte scanned, plus a slack of
/// `verify_slack` needle lengths, before the scan falls back to Two-Way.
const max_verify_ratio = 2;
const verify_slack = 64;

/// How many bytes beyond the pair a weak filter adds (so at most four filter bytes).
const max_extra_filter_bytes = 2;

/// How many needle bytes the SIMD prefilter compares.
/// `two_wide` is `two` with a wider scan step, for pairs that almost never hit (`tune`).
const Filter = enum { one, two, two_wide, three, four };

/// Two-Way string matching (Crochemore and Perrin, 1991): O(n + m) time and O(1) space in
/// the worst case. The SIMD scan below is much faster on ordinary text, but candidates that
/// pass its filter are verified in O(m) each, which an adversarial input can make happen at
/// every position; the scan then hands over to this. Same construction as glibc's
/// `str-two-way.h` and the `memchr` crate.
pub const TwoWay = struct {
    needle: []const u8,
    /// Critical position: the needle is split into needle[0..crit] and needle[crit..].
    crit: usize,
    period: usize,
    /// needle[0..crit] repeats with `period`: a match failure can then only advance by the
    /// period, and `memory` avoids rescanning the part already known to match.
    periodic: bool,

    pub fn init(needle: []const u8) TwoWay {
        const a = maxSuffix(needle, false);
        const b = maxSuffix(needle, true);
        const ms = if (a.pos +% 1 >= b.pos +% 1) a else b; // the later of the two
        const crit = ms.pos +% 1;
        const periodic = ms.period + crit <= needle.len and
            std.mem.eql(u8, needle[0..crit], needle[ms.period..][0..crit]);
        return .{
            .needle = needle,
            .crit = crit,
            .period = if (periodic) ms.period else @max(crit, needle.len - crit) + 1,
            .periodic = periodic,
        };
    }

    const Suffix = struct { pos: usize, period: usize };

    /// Maximal suffix of `x` for the byte order (`reversed` flips it). `pos` is the index
    /// before the suffix, with maxInt(usize) standing for -1, as in the paper.
    fn maxSuffix(x: []const u8, reversed: bool) Suffix {
        var ms: usize = std.math.maxInt(usize);
        var j: usize = 0;
        var k: usize = 1;
        var p: usize = 1;
        while (j + k < x.len) {
            const a = x[j + k];
            const b = x[ms +% k];
            const less = if (reversed) b < a else a < b;
            if (less) {
                j += k;
                k = 1;
                p = j -% ms;
            } else if (a == b) {
                if (k != p) {
                    k += 1;
                } else {
                    j += p;
                    k = 1;
                }
            } else {
                ms = j;
                j += 1;
                k = 1;
                p = 1;
            }
        }
        return .{ .pos = ms, .period = p };
    }

    /// First occurrence of the needle in `hay` at or after `from`, or null.
    pub fn find(tw: *const TwoWay, hay: []const u8, from: usize) ?usize {
        const n = tw.needle;
        const m = n.len;
        if (hay.len < m) return null;
        var j = from;
        if (tw.periodic) {
            var memory: usize = 0;
            while (j <= hay.len - m) {
                var i = @max(tw.crit, memory);
                while (i < m and n[i] == hay[i + j]) i += 1;
                if (i >= m) {
                    i = tw.crit -% 1;
                    while (memory < i +% 1 and n[i] == hay[i + j]) i -%= 1;
                    if (i +% 1 < memory +% 1) return j;
                    j += tw.period;
                    memory = m - tw.period;
                } else {
                    j += i - tw.crit + 1;
                    memory = 0;
                }
            }
        } else {
            while (j <= hay.len - m) {
                var i = tw.crit;
                while (i < m and n[i] == hay[i + j]) i += 1;
                if (i >= m) {
                    i = tw.crit -% 1;
                    while (i != std.math.maxInt(usize) and n[i] == hay[i + j]) i -%= 1;
                    if (i == std.math.maxInt(usize)) return j;
                    j += tw.period;
                } else {
                    j += i - tw.crit + 1;
                }
            }
        }
        return null;
    }
};

/// A compiled literal pattern: up to four filter bytes at fixed offsets plus the full needle.
pub const Searcher = struct {
    needle: []const u8,
    o1: usize,
    o2: usize,
    o3: usize,
    o4: usize,
    filter: Filter,
    /// The filter bytes cover the whole needle, so a filter hit is a match.
    exact: bool,
    /// The two rarest bytes are still common, so extra filter bytes may pay off (`tune`).
    weak: bool,
    /// Linear-time fallback for when verifying candidates becomes the dominant work.
    two_way: TwoWay,

    pub fn init(needle: []const u8) Searcher {
        std.debug.assert(needle.len > 0);
        if (needle.len == 1) return .{ .needle = needle, .o1 = 0, .o2 = 0, .o3 = 0, .o4 = 0, .filter = .one, .exact = true, .weak = false, .two_way = .init(needle) };
        // Pick the two rarest bytes at distinct offsets (same rule as memchr's packed pair).
        var p1: usize = 0;
        var p2: usize = 1;
        if (rank[needle[1]] < rank[needle[0]]) std.mem.swap(usize, &p1, &p2);
        for (needle[2..], 2..) |b, i| {
            if (rank[b] < rank[needle[p1]]) {
                p2 = p1;
                p1 = i;
            } else if (b != needle[p1] and rank[b] < rank[needle[p2]]) {
                p2 = i;
            }
        }
        const weak = @as(usize, rank[needle[p1]]) + rank[needle[p2]] >= weak_pair_rank_sum;
        // A weak pair lets many false candidates through, so further bytes are added: the
        // rarest of the remaining ones each time.
        const extra: usize = if (!weak) 0 else @min(needle.len - 2, max_extra_filter_bytes);
        var p3 = p2;
        var p4 = p2;
        var taken = [_]usize{ p1, p2, 0, 0 };
        for (0..extra) |k| {
            var best: u8 = 255;
            var pick: usize = p2;
            for (needle, 0..) |b, i| {
                if (std.mem.indexOfScalar(usize, taken[0 .. 2 + k], i) == null and rank[b] <= best) {
                    best = rank[b];
                    pick = i;
                }
            }
            if (k == 0) p3 = pick else p4 = pick;
            taken[2 + k] = pick;
        }
        const filter: Filter = switch (extra) {
            0 => .two,
            1 => .three,
            else => .four,
        };
        return .{
            .needle = needle,
            .o1 = p1,
            .o2 = p2,
            .o3 = p3,
            .o4 = p4,
            .filter = filter,
            .exact = needle.len <= 2 + extra,
            .weak = weak,
            .two_way = .init(needle),
        };
    }

    /// Cost model behind `tune`, from A/B measurements on a 540 MB text: an extra filter
    /// byte costs about 0.03 ns per input byte (one more load and compare per vector); a
    /// candidate that passes the filter but is not a match costs about 29 ns.
    const false_candidate_ns = 29.0;
    const filter_ns_per_byte = 0.028;
    /// Checking a candidate against the whole needle; not needed when the filter bytes
    /// already cover the needle.
    const verify_ns = 5.0;
    /// A pair counts as sparse (wide scan step) below one candidate per this many bytes.
    const sparse_pair_bytes = 4096;

    /// Re-picking the filter bytes (`repick`) looks at this much of the sample...
    const repick_sample_bytes = 64 * 1024;
    /// ...and only happens when the static pair lets more than one position per this many
    /// bytes through.
    const repick_pair_bytes = 2048;
    /// Offsets considered when re-picking: the ones with the rarest bytes in the sample.
    const repick_offsets = 6;

    /// Adapts the filter to a `sample` of the data. The filter bytes are first re-picked
    /// when the static pair turns out to be common in the sample (`repick`). Then, for a
    /// weak pattern, the number of filter bytes is chosen by counting how many positions
    /// each level lets through, and taking the level with the lowest estimated cost
    /// (candidates plus extra loads).
    pub fn tune(s: *Searcher, sample: []const u8) void {
        if (s.needle.len < 2 or sample.len < s.needle.len) return;
        const n = s.needle;
        if (n.len > 2) s.repick(sample[0..@min(sample.len, repick_sample_bytes)]);
        const levels = @min(n.len, 4);
        // passed[k]: positions where the first k + 2 filter bytes match (the deeper levels
        // only matter to a weak pattern).
        const offsets = [_]usize{ s.o1, s.o2, s.o3, s.o4 };
        var passed = [_]usize{ s.hitsAt(sample, offsets[0..2]), 0, 0 };
        if (s.weak) for (3..levels + 1) |l| {
            passed[l - 2] = s.hitsAt(sample, offsets[0..l]);
        };
        if (!s.weak or n.len <= 2) {
            // Only the step width to decide: wide when the pair almost never hits.
            if (s.filter == .two and passed[0] * sparse_pair_bytes < sample.len) s.filter = .two_wide;
            return;
        }
        // Cost of a level: its false candidates, the verification of all its candidates when
        // the filter bytes do not cover the whole needle, and the loads of its extra bytes.
        // The matches that pass the deepest level are taken as the true ones.
        const true_matches: f64 = @floatFromInt(passed[levels - 2]);
        var level: usize = 2;
        var best_cost: f64 = std.math.inf(f64);
        for (2..levels + 1) |l| {
            const candidates: f64 = @floatFromInt(passed[l - 2]);
            const verified: f64 = if (n.len <= l) 0 else candidates;
            const loads = filter_ns_per_byte * @as(f64, @floatFromInt(sample.len)) * @as(f64, @floatFromInt(l - 2));
            const cost = (candidates - true_matches) * false_candidate_ns + verified * verify_ns + loads;
            if (cost < best_cost) {
                best_cost = cost;
                level = l;
            }
        }
        s.filter = switch (level) {
            2 => if (passed[0] * sparse_pair_bytes < sample.len) .two_wide else .two,
            3 => .three,
            else => .four,
        };
        s.exact = n.len <= level;
    }

    /// Positions of `sample` where the needle bytes at all `offsets` match.
    fn hitsAt(s: *const Searcher, sample: []const u8, offsets: []const usize) usize {
        const n = s.needle;
        const span = sample.len - n.len + 1;
        const lanes = 32;
        const Bits = std.meta.Int(.unsigned, lanes);
        var hits: usize = 0;
        var i: usize = 0;
        while (i + lanes <= span) : (i += lanes) {
            var bits: Bits = ~@as(Bits, 0);
            for (offsets) |o| {
                const v: @Vector(lanes, u8) = sample[i + o ..][0..lanes].*;
                bits &= @bitCast(v == @as(@Vector(lanes, u8), @splat(n[o])));
            }
            hits += @popCount(bits);
        }
        for (i..span) |j| {
            var ok = true;
            for (offsets) |o| ok = ok and sample[j + o] == n[o];
            hits += @intFromBool(ok);
        }
        return hits;
    }

    /// The static rank can be far off for the data at hand: in a log, the bytes of
    /// `latency=` are on every line, and bytes that look rare one by one can come together
    /// (a `y` there is always followed by digits). So when the static pair lets too many
    /// positions through on `sample`, the pair that lets the fewest through is looked for
    /// among the offsets with the rarest bytes in the sample, by counting; a third and
    /// fourth byte are then added the same way, and `tune` decides how many to use. The
    /// static pair stays unless another one lets at most 4/5 as many positions through.
    fn repick(s: *Searcher, sample: []const u8) void {
        const n = s.needle;
        if (n.len <= 2 or sample.len < n.len) return;
        const static_hits = s.hitsAt(sample, &.{ s.o1, s.o2 });
        if (static_hits * repick_pair_bytes <= sample.len) return;

        var hist: [256]u32 = @splat(0);
        for (sample) |b| hist[b] += 1;
        var cand: [repick_offsets]usize = undefined;
        const nc = @min(n.len, repick_offsets);
        for (0..nc) |k| {
            var best: u64 = std.math.maxInt(u64);
            for (n, 0..) |b, i| {
                if (std.mem.indexOfScalar(usize, cand[0..k], i) != null) continue;
                const score = (@as(u64, hist[b]) << 8) | rank[b]; // the static rank breaks ties
                if (score < best) {
                    best = score;
                    cand[k] = i;
                }
            }
        }

        var taken = [_]usize{ s.o1, s.o2, 0, 0 };
        var best_hits = static_hits * 4 / 5;
        var changed = false;
        for (0..nc) |a| for (a + 1..nc) |b| {
            const hits = s.hitsAt(sample, &.{ cand[a], cand[b] });
            if (hits < best_hits) {
                best_hits = hits;
                taken[0] = cand[a];
                taken[1] = cand[b];
                changed = true;
            }
        };
        if (!changed) return;

        const extra = @min(nc - 2, max_extra_filter_bytes);
        for (0..extra) |k| {
            var best: usize = std.math.maxInt(usize);
            var pick = cand[0];
            for (cand[0..nc]) |o| {
                if (std.mem.indexOfScalar(usize, taken[0 .. 2 + k], o) != null) continue;
                taken[2 + k] = o;
                const hits = s.hitsAt(sample, taken[0 .. 3 + k]);
                if (hits < best) {
                    best = hits;
                    pick = o;
                }
            }
            taken[2 + k] = pick;
        }
        s.o1 = taken[0];
        s.o2 = taken[1];
        s.o3 = taken[2];
        s.o4 = if (extra == 2) taken[3] else taken[2];
        s.weak = true;
        s.filter = .two;
        s.exact = false;
    }

    /// Index of the first occurrence at position >= `from`, or null.
    pub fn find(s: *const Searcher, hay: []const u8, from: usize) ?usize {
        var first: FirstMatch = .{};
        s.forEachMatch(false, hay, from, &first) catch unreachable;
        return first.pos;
    }

    /// Like `find`, but also reports in `newlines.*` how many '\n' bytes lie in
    /// `hay[from..p)` (`p` being the result), or in `hay[from..]` when there is no match.
    /// The count is gathered from the vectors the scan loop loads anyway, which is much
    /// cheaper than a separate pass over the same bytes.
    pub fn findCounting(s: *const Searcher, hay: []const u8, from: usize, newlines: *usize) ?usize {
        var first: FirstMatch = .{};
        s.forEachMatch(true, hay, from, &first) catch unreachable;
        newlines.* = first.nl;
        return first.pos;
    }

    const FirstMatch = struct {
        pos: ?usize = null,
        nl: usize = 0,

        pub fn match(c: *FirstMatch, p: usize, nl: usize) error{}!usize {
            c.pos = p;
            c.nl = nl;
            return std.math.maxInt(usize); // ends the scan
        }

        pub fn done(c: *FirstMatch, nl: usize) void {
            if (c.pos == null) c.nl = nl;
        }
    };

    /// Scans `hay` from `from` and calls `ctx.match(p, nl)` for every match at `p`; it returns
    /// the position to continue from (a position past the end stops the scan). `nl` is the
    /// number of '\n' bytes since the previous resume position if `counting`, else 0. When the
    /// scan ends `ctx.done(nl)` is called with the newlines between the last resume position
    /// and the end.
    ///
    /// Driving the whole scan from here, instead of returning to the caller after every
    /// match, keeps the set-up of the vectors out of the per-match path; with dense matches
    /// (hundreds of thousands of matching lines per second of input) that is the difference
    /// between a loop and a call per line.
    pub fn forEachMatch(s: *const Searcher, comptime counting: bool, hay: []const u8, from: usize, ctx: anytype) !void {
        return switch (s.filter) {
            inline else => |f| s.scan(f, counting, hay, from, ctx),
        };
    }

    /// '\n' count of hay[from..i), given that `counted` is the count of the first-filter
    /// windows hay[from + o1 .. i + o1) that the scan loop went over.
    fn newlinesBefore(s: *const Searcher, hay: []const u8, from: usize, i: usize, counted: usize) usize {
        if (i == from) return 0;
        return counted + countNewlinesIn(hay, from, from + s.o1) - countNewlinesIn(hay, i, i + s.o1);
    }

    fn scan(s: *const Searcher, comptime filter: Filter, comptime counting: bool, hay: []const u8, from0: usize, ctx: anytype) !void {
        const m = s.needle.len;
        const b1: Vec = @splat(s.needle[s.o1]);
        const b2: Vec = @splat(s.needle[s.o2]);
        const b3: Vec = @splat(s.needle[s.o3]);
        const b4: Vec = @splat(s.needle[s.o4]);
        const ptr1 = hay.ptr + s.o1;
        const ptr2 = hay.ptr + s.o2;
        const ptr3 = hay.ptr + s.o3;
        const ptr4 = hay.ptr + s.o4;
        // Vectors per iteration; one reduction covers all of them. When the filter almost
        // never hits, a wider step saves branches; when hits are frequent it means more work
        // per hit (one thread, 540 MB: rare pairs 6 to 9% faster, frequent ones 1 to 3% slower).
        const unroll = if (filter == .two_wide) 4 else 2;
        const newline: Vec = @splat('\n');
        const zero: Vec = @splat(0);
        // Per-lane u8 counters gain at most `unroll` per iteration; flush well before 255.
        const flush_every = 120;

        // Bytes compared verifying candidates. If that outgrows the bytes scanned by more
        // than `max_verify_ratio`, the input defeats the filter (each candidate costs O(m))
        // and the rest is searched with Two-Way, which is linear whatever the input.
        var work: usize = 0;
        var from = from0;
        outer: while (true) {
            if (hay.len < m or from > hay.len - m) {
                ctx.done(if (counting and from <= hay.len) countNewlines(hay[from..]) else 0);
                return;
            }
            const last = hay.len - m; // last valid start
            var acc: Vec = zero;
            var acc_iters: usize = 0;
            var counted: usize = 0;
            var i = from;
            while (i + unroll * vec_len <= last + 1) : (i += unroll * vec_len) {
                var xs: [unroll]Vec = undefined;
                var hits: [unroll]@Vector(vec_len, bool) = undefined;
                inline for (0..unroll) |k| {
                    xs[k] = (ptr1 + i + k * vec_len)[0..vec_len].*;
                    hits[k] = xs[k] == b1;
                    if (filter != .one) {
                        const y: Vec = (ptr2 + i + k * vec_len)[0..vec_len].*;
                        hits[k] = hits[k] & (y == b2);
                    }
                    if (filter == .three or filter == .four) {
                        const z: Vec = (ptr3 + i + k * vec_len)[0..vec_len].*;
                        hits[k] = hits[k] & (z == b3);
                    }
                    if (filter == .four) {
                        const w: Vec = (ptr4 + i + k * vec_len)[0..vec_len].*;
                        hits[k] = hits[k] & (w == b4);
                    }
                }
                var any = hits[0];
                inline for (1..unroll) |k| any = any | hits[k];
                if (@reduce(.Or, any)) {
                    inline for (0..unroll) |k| {
                        if (s.verifyMask(hay, i + k * vec_len, toMask(hits[k]), &work)) |r| {
                            var nl: usize = 0;
                            if (counting) {
                                counted += @reduce(.Add, @as(@Vector(vec_len, u16), acc));
                                nl = s.newlinesBefore(hay, from, i, counted) + countNewlinesIn(hay, i, r);
                            }
                            from = try ctx.match(r, nl);
                            continue :outer;
                        }
                    }
                    if (!s.exact and work > max_verify_ratio * (i - from0) + verify_slack * m) {
                        return s.scanTwoWay(counting, hay, from, ctx);
                    }
                }
                if (counting) {
                    inline for (0..unroll) |k| acc -%= @select(u8, xs[k] == newline, @as(Vec, @splat(0xff)), zero);
                    acc_iters += 1;
                    if (acc_iters == flush_every) {
                        counted += @reduce(.Add, @as(@Vector(vec_len, u16), acc));
                        acc = zero;
                        acc_iters = 0;
                    }
                }
            }
            const i_end = i; // the scalar loop below takes over from here
            if (counting) counted += @reduce(.Add, @as(@Vector(vec_len, u16), acc));
            var j = i_end;
            while (j <= last) : (j += 1) {
                if (hay[j + s.o1] == s.needle[s.o1] and hay[j + s.o2] == s.needle[s.o2] and
                    hay[j + s.o3] == s.needle[s.o3] and hay[j + s.o4] == s.needle[s.o4] and
                    (s.exact or eqlAt(hay.ptr + j, s.needle)))
                {
                    const nl: usize = if (counting) s.newlinesBefore(hay, from, i_end, counted) + countNewlinesIn(hay, i_end, j) else 0;
                    from = try ctx.match(j, nl);
                    continue :outer;
                }
            }
            ctx.done(if (counting) s.newlinesBefore(hay, from, i_end, counted) + countNewlines(hay[i_end..]) else 0);
            return;
        }
    }

    inline fn verifyMask(s: *const Searcher, hay: []const u8, base: usize, mask: Mask, work: *usize) ?usize {
        var bits = mask & lane_bits;
        while (bits != 0) : (bits &= bits - 1) {
            const pos = base + firstLane(bits);
            if (s.exact) return pos;
            work.* += s.needle.len;
            if (eqlAt(hay.ptr + pos, s.needle)) return pos;
        }
        return null;
    }

    /// The rest of `scan` with Two-Way: same contract, with the newline counts taken by a
    /// separate pass between matches (this only runs on inputs built to defeat the filter).
    fn scanTwoWay(s: *const Searcher, comptime counting: bool, hay: []const u8, from0: usize, ctx: anytype) !void {
        var from = from0;
        while (true) {
            const p = (if (from <= hay.len) s.two_way.find(hay, from) else null) orelse {
                ctx.done(if (counting and from <= hay.len) countNewlines(hay[from..]) else 0);
                return;
            };
            from = try ctx.match(p, if (counting) countNewlines(hay[from..p]) else 0);
        }
    }
};

/// Compares `needle` with the bytes at `p` (the caller guarantees they are in
/// bounds) using a few fixed-size, possibly overlapping loads instead of a
/// byte loop, which is much cheaper than `std.mem.eql` for short needles.
inline fn eqlAt(p: [*]const u8, needle: []const u8) bool {
    const n = needle.len;
    const q = needle.ptr;
    if (n >= 16) {
        var k: usize = 0;
        while (k + 16 < n) : (k += 16) {
            const a: @Vector(16, u8) = (p + k)[0..16].*;
            const b: @Vector(16, u8) = (q + k)[0..16].*;
            if (!@reduce(.And, a == b)) return false;
        }
        const a: @Vector(16, u8) = (p + n - 16)[0..16].*;
        const b: @Vector(16, u8) = (q + n - 16)[0..16].*;
        return @reduce(.And, a == b);
    }
    if (n >= 8) return load(u64, p) == load(u64, q) and load(u64, p + n - 8) == load(u64, q + n - 8);
    if (n >= 4) return load(u32, p) == load(u32, q) and load(u32, p + n - 4) == load(u32, q + n - 4);
    if (n >= 2) return load(u16, p) == load(u16, q) and load(u16, p + n - 2) == load(u16, q + n - 2);
    return p[0] == q[0];
}

inline fn load(comptime T: type, p: [*]const u8) T {
    return std.mem.readInt(T, p[0..@sizeOf(T)], .little);
}

/// Index of the first '\n' at or after `from`, or `hay.len`. Lines are mostly short, so the
/// first 64 bytes are tested vector by vector (returning at the first hit, no reduction in
/// between); past them the line is long and the loop tests 64 bytes per branch, combining
/// the four vectors first.
pub fn nextNewline(hay: []const u8, from: usize) usize {
    const nl: Vec = @splat('\n');
    var i = from;
    const unroll = 4;
    if (i + unroll * vec_len <= hay.len) {
        inline for (0..unroll) |k| {
            const m = toMask(@as(Vec, hay[i + k * vec_len ..][0..vec_len].*) == nl);
            if (m != 0) return i + k * vec_len + firstLane(m);
        }
        i += unroll * vec_len;
        while (i + unroll * vec_len <= hay.len) : (i += unroll * vec_len) {
            var eq: [unroll]@Vector(vec_len, bool) = undefined;
            inline for (0..unroll) |k| eq[k] = @as(Vec, hay[i + k * vec_len ..][0..vec_len].*) == nl;
            var any = eq[0];
            inline for (1..unroll) |k| any = any | eq[k];
            if (!@reduce(.Or, any)) continue;
            inline for (0..unroll) |k| {
                const m = toMask(eq[k]);
                if (m != 0) return i + k * vec_len + firstLane(m);
            }
        }
    }
    while (i + vec_len <= hay.len) : (i += vec_len) {
        const m = toMask(@as(Vec, hay[i..][0..vec_len].*) == nl);
        if (m != 0) return i + firstLane(m);
    }
    while (i < hay.len) : (i += 1) if (hay[i] == '\n') return i;
    return hay.len;
}

/// Number of '\n' in hay[a..b]; short ranges (a match is usually near the start of the
/// block it was found in) take one or two vector loads instead of the general loop.
pub fn countNewlinesIn(hay: []const u8, a: usize, b: usize) usize {
    const n = b - a;
    if (n == 0) return 0;
    if (n <= 2 * vec_len and a + 2 * vec_len <= hay.len) {
        const nl: Vec = @splat('\n');
        const lo: Vec = hay[a..][0..vec_len].*;
        var m0 = toMask(lo == nl) & lane_bits;
        if (n <= vec_len) {
            if (n < vec_len) m0 &= (@as(Mask, 1) << @intCast(n * bits_per_lane)) - 1;
            return @popCount(m0);
        }
        const hi: Vec = hay[a + vec_len ..][0..vec_len].*;
        var m1 = toMask(hi == nl) & lane_bits;
        if (n < 2 * vec_len) m1 &= (@as(Mask, 1) << @intCast((n - vec_len) * bits_per_lane)) - 1;
        return @popCount(m0) + @popCount(m1);
    }
    return countNewlines(hay[a..b]);
}

/// Appends `line` and a '\n' to `out`, whose capacity the caller has reserved. Short lines
/// (up to 128 bytes) are copied with a couple of overlapping fixed-size moves rather than a
/// `memcpy` call.
pub fn appendLine(out: *std.ArrayList(u8), line: []const u8) void {
    const n = line.len;
    const dst = out.items.ptr + out.items.len;
    const src = line.ptr;
    if (n > 64 and n <= 128) {
        @memcpy(dst[0..64], src[0..64]);
        @memcpy((dst + n - 64)[0..64], (src + n - 64)[0..64]);
    } else if (n <= 64 and n >= 16) {
        if (n > 32) {
            @memcpy(dst[0..32], src[0..32]);
            @memcpy((dst + n - 32)[0..32], (src + n - 32)[0..32]);
        } else {
            @memcpy(dst[0..16], src[0..16]);
            @memcpy((dst + n - 16)[0..16], (src + n - 16)[0..16]);
        }
    } else if (n >= 8 and n < 16) {
        @memcpy(dst[0..8], src[0..8]);
        @memcpy((dst + n - 8)[0..8], (src + n - 8)[0..8]);
    } else if (n >= 4 and n < 8) {
        @memcpy(dst[0..4], src[0..4]);
        @memcpy((dst + n - 4)[0..4], (src + n - 4)[0..4]);
    } else {
        @memcpy(dst[0..n], src[0..n]); // < 4 bytes, or > 128 where a memcpy call pays off
    }
    dst[n] = '\n';
    out.items.len += n + 1;
}

/// Index of the last '\n' in hay[0..end], or null.
pub fn lastNewline(hay: []const u8, end: usize) ?usize {
    const nl: Vec = @splat('\n');
    var e = end;
    while (e >= vec_len) {
        const v: Vec = hay[e - vec_len ..][0..vec_len].*;
        const mask = toMask(v == nl);
        if (mask != 0) return e - vec_len + lastLane(mask);
        e -= vec_len;
    }
    while (e > 0) {
        e -= 1;
        if (hay[e] == '\n') return e;
    }
    return null;
}

/// Number of '\n' bytes in `buf`.
pub fn countNewlines(buf: []const u8) usize {
    const nl: Vec = @splat('\n');
    const zero: Vec = @splat(0);
    const unroll = 4; // vectors per iteration, to keep several loads in flight
    var total: usize = 0;
    var i: usize = 0;
    while (i + unroll * vec_len <= buf.len) {
        // Each lane counter gains at most `unroll` per iteration; u8 absorbs 63 iterations.
        var acc: Vec = zero;
        var n: usize = 0;
        while (n < 63 and i + unroll * vec_len <= buf.len) : ({
            n += 1;
            i += unroll * vec_len;
        }) {
            inline for (0..unroll) |k| {
                const v: Vec = buf[i + k * vec_len ..][0..vec_len].*;
                // equal lanes are 0xff; subtracting wraps to +1
                acc -%= @select(u8, v == nl, @as(Vec, @splat(0xff)), zero);
            }
        }
        total += @reduce(.Add, @as(@Vector(vec_len, u16), acc));
    }
    for (buf[i..]) |c| total += @intFromBool(c == '\n');
    return total;
}

test "find agrees with std.mem.indexOfPos" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var buf: [1000]u8 = undefined;
    // Common letters exercise the three-byte filter, rare ones the two-byte filter.
    for ([_][]const u8{ "abc\n", "qzxj\n" }) |alphabet| {
        for (0..4000) |iter| {
            for (&buf) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            const hl = rnd.intRangeAtMost(usize, 1, buf.len);
            const len = rnd.intRangeAtMost(usize, 1, @min(hl, 40));
            var nb: [40]u8 = undefined;
            if (iter % 2 == 0) {
                // A needle copied from the haystack is guaranteed to occur at least once.
                const at = rnd.intRangeAtMost(usize, 0, hl - len);
                @memcpy(nb[0..len], buf[at..][0..len]);
            } else {
                for (nb[0..len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len - 1)];
            }
            const from = rnd.intRangeAtMost(usize, 0, hl);
            const s = Searcher.init(nb[0..len]);
            try std.testing.expectEqual(std.mem.indexOfPos(u8, buf[0..hl], from, nb[0..len]), s.find(buf[0..hl], from));
        }
    }
}

test "pair selection picks distinct offsets" {
    for ([_][]const u8{ "ab", "aaaa", "the", "needle_zz", "zz", "ing ", "the ", "ing the", "e t" }) |n| {
        const s = Searcher.init(n);
        try std.testing.expect(s.o1 != s.o2);
        try std.testing.expect(s.o1 < n.len and s.o2 < n.len and s.o3 < n.len and s.o4 < n.len);
        if (s.filter == .three or s.filter == .four) try std.testing.expect(s.o3 != s.o1 and s.o3 != s.o2);
        if (s.filter == .four) try std.testing.expect(s.o4 != s.o1 and s.o4 != s.o2 and s.o4 != s.o3);
    }
}

test "newline helpers" {
    var buf: [3000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for (&buf) |*c| c.* = if (prng.random().uintLessThan(u8, 5) == 0) '\n' else 'x';
    for ([_]usize{ 0, 1, 31, 32, 33, 1000, 3000 }) |n| {
        var cnt: usize = 0;
        for (buf[0..n]) |c| cnt += @intFromBool(c == '\n');
        try std.testing.expectEqual(cnt, countNewlines(buf[0..n]));
        try std.testing.expectEqual(std.mem.lastIndexOfScalar(u8, buf[0..n], '\n'), lastNewline(buf[0..n], n));
    }
}

test "findCounting agrees with find and counts the newlines it passes" {
    var prng = std.Random.DefaultPrng.init(99);
    const rnd = prng.random();
    var buf: [3000]u8 = undefined;
    // Common letters take the three-byte filter, rare ones the two-byte filter; a single
    // byte takes the one-byte filter. Newlines are frequent so every window contains some.
    for ([_][]const u8{ "ab\n", "qzx\n\n\n" }) |alphabet| {
        for (0..3000) |_| {
            for (&buf) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            const hl = rnd.intRangeAtMost(usize, 1, buf.len);
            const len = rnd.intRangeAtMost(usize, 1, @min(hl, 40));
            var needle: [40]u8 = undefined;
            for (needle[0..len]) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len - 1)]; // no '\n' in the needle
            const from = rnd.intRangeAtMost(usize, 0, hl);
            const s = Searcher.init(needle[0..len]);
            var nl: usize = undefined;
            const got = s.findCounting(buf[0..hl], from, &nl);
            try std.testing.expectEqual(s.find(buf[0..hl], from), got);
            var want: usize = 0;
            for (buf[from .. got orelse hl]) |c| want += @intFromBool(c == '\n');
            try std.testing.expectEqual(want, nl);
        }
    }
}

test "findCounting over many iterations flushes its counters" {
    // 1 MB of newlines with the needle only at the very end: far more than 120 iterations.
    const gpa = std.testing.allocator;
    const data = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(data);
    @memset(data, '\n');
    @memcpy(data[data.len - 3 ..], "abc");
    const s = Searcher.init("abc");
    var nl: usize = undefined;
    try std.testing.expectEqual(@as(?usize, data.len - 3), s.findCounting(data, 0, &nl));
    try std.testing.expectEqual(data.len - 3, nl);
    try std.testing.expectEqual(@as(?usize, null), s.findCounting(data[0 .. data.len - 1], 5, &nl));
    // the slice ends in "ab": two of its bytes are not newlines
    try std.testing.expectEqual(data.len - 1 - 5 - 2, nl);
}

test "nextNewline, countNewlinesIn and appendLine agree with the obvious versions" {
    var prng = std.Random.DefaultPrng.init(123);
    const rnd = prng.random();
    var buf: [700]u8 = undefined;
    for (0..4000) |_| {
        // Newlines at a random density, from every byte to almost none.
        const density = rnd.intRangeAtMost(u8, 1, 60);
        for (&buf) |*c| c.* = if (rnd.uintLessThan(u8, density) == 0) '\n' else 'x';
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        const hay = buf[0..len];
        const from = rnd.intRangeAtMost(usize, 0, len);
        try std.testing.expectEqual(std.mem.indexOfScalarPos(u8, hay, from, '\n') orelse len, nextNewline(hay, from));
        const b = rnd.intRangeAtMost(usize, from, len);
        var want: usize = 0;
        for (hay[from..b]) |c| want += @intFromBool(c == '\n');
        try std.testing.expectEqual(want, countNewlinesIn(hay, from, b));
    }
    // appendLine for every length around the copy-strategy boundaries
    const gpa = std.testing.allocator;
    var line: [130]u8 = undefined;
    for (&line, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
    for (0..130) |n| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.ensureTotalCapacity(gpa, 200);
        appendLine(&out, line[0..n]);
        try std.testing.expectEqualSlices(u8, line[0..n], out.items[0..n]);
        try std.testing.expectEqual(@as(u8, '\n'), out.items[n]);
        try std.testing.expectEqual(n + 1, out.items.len);
    }
}

test "every filter level finds the same matches, and tune picks a valid one" {
    var prng = std.Random.DefaultPrng.init(2024);
    const rnd = prng.random();
    var buf: [1500]u8 = undefined;
    for (0..1500) |_| {
        for (&buf) |*c| c.* = "abcde \n"[rnd.uintLessThan(usize, 7)];
        const hl = rnd.intRangeAtMost(usize, 3, buf.len);
        const len = rnd.intRangeAtMost(usize, 3, @min(hl, 12));
        var needle: [12]u8 = undefined;
        for (needle[0..len]) |*c| c.* = "abcde "[rnd.uintLessThan(usize, 6)];
        const from = rnd.intRangeAtMost(usize, 0, hl);
        var s = Searcher.init(needle[0..len]);
        const want = std.mem.indexOfPos(u8, buf[0..hl], from, needle[0..len]);
        const max_level: usize = @min(len, 4);
        for (2..max_level + 1) |level| {
            s.filter = switch (level) {
                2 => .two,
                3 => .three,
                else => .four,
            };
            s.exact = len <= level;
            try std.testing.expectEqual(want, s.find(buf[0..hl], from));
            if (level == 2) {
                s.filter = .two_wide;
                try std.testing.expectEqual(want, s.find(buf[0..hl], from));
            }
        }
        s.tune(buf[0..hl]);
        try std.testing.expectEqual(want, s.find(buf[0..hl], from));
    }
}

test "repick finds a rarer pair on log-like data and keeps a good static one" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    while (text.items.len < 200_000) {
        var line: [96]u8 = undefined;
        const l = try std.fmt.bufPrint(&line, "INFO [auth] user={d} latency={d}ms path=/api/v{d}/items\n", .{
            rnd.intRangeAtMost(u32, 1, 99999), rnd.intRangeAtMost(u32, 1, 2000), rnd.intRangeAtMost(u32, 1, 3),
        });
        try text.appendSlice(gpa, l);
    }
    const hay = text.items;
    for ([_][]const u8{ "latency=1999ms", "[auth] user=7", "user=4242 ", "/api/v2/items", "zzz" }) |needle| {
        const static: Searcher = .init(needle);
        var s = static;
        s.tune(hay);
        const sample = hay[0..@min(hay.len, Searcher.repick_sample_bytes)];
        const before = static.hitsAt(sample, &.{ static.o1, static.o2 });
        const after = s.hitsAt(sample, &.{ s.o1, s.o2 });
        if (s.o1 != static.o1 or s.o2 != static.o2) {
            try std.testing.expect(after * 5 <= before * 4);
        } else {
            try std.testing.expectEqual(before, after);
        }
        const offs = [_]usize{ s.o1, s.o2, s.o3 };
        try std.testing.expect(offs[0] != offs[1]);
        if (s.filter == .three or s.filter == .four) try std.testing.expect(offs[2] != offs[0] and offs[2] != offs[1]);
        if (s.filter == .four) try std.testing.expect(s.o4 != s.o1 and s.o4 != s.o2 and s.o4 != s.o3);
        // Every match is still found, at the right place.
        var at: usize = 0;
        while (true) {
            const want = std.mem.indexOfPos(u8, hay, at, needle);
            try std.testing.expectEqual(want, s.find(hay, at));
            at = (want orelse break) + 1;
        }
    }
    // The pair of `latency=1999ms` is the case this exists for: it must be re-picked.
    var s: Searcher = .init("latency=1999ms");
    const static = s;
    s.tune(hay);
    try std.testing.expect(s.o1 != static.o1 or s.o2 != static.o2);
}

test "TwoWay agrees with indexOfPos, periodic needles included" {
    var prng = std.Random.DefaultPrng.init(31337);
    const rnd = prng.random();
    var buf: [600]u8 = undefined;
    for ([_][]const u8{ "ab", "abc", "a" }) |alphabet| {
        for (0..6000) |iter| {
            for (&buf) |*c| c.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            const hl = rnd.intRangeAtMost(usize, 1, buf.len);
            const len = rnd.intRangeAtMost(usize, 1, @min(hl, 30));
            var needle: [30]u8 = undefined;
            if (iter % 2 == 0) {
                const at = rnd.intRangeAtMost(usize, 0, hl - len);
                @memcpy(needle[0..len], buf[at..][0..len]);
            } else {
                // Periodic needles: repetitions of a short block.
                const block = rnd.intRangeAtMost(usize, 1, 4);
                for (needle[0..len], 0..) |*c, i| c.* = if (i < block) alphabet[rnd.uintLessThan(usize, alphabet.len)] else needle[i - block];
            }
            const from = rnd.intRangeAtMost(usize, 0, hl);
            const tw = TwoWay.init(needle[0..len]);
            try std.testing.expectEqual(std.mem.indexOfPos(u8, buf[0..hl], from, needle[0..len]), tw.find(buf[0..hl], from));
        }
    }
}

test "the scan stays correct when adversarial input forces the Two-Way fallback" {
    const gpa = std.testing.allocator;
    // Every window holds a 'b' but the needle is all 'a': each position is a candidate that
    // fails late, the case the work counter is there for.
    const unit = 300;
    const data = try gpa.alloc(u8, 200 * unit);
    defer gpa.free(data);
    for (data, 0..) |*c, i| c.* = if (i % unit == unit - 1) 'b' else 'a';
    // Plant one real match, and a few newlines so that the counting variant is exercised.
    @memset(data[50_000..][0..400], 'a');
    data[10_000] = '\n';
    data[57_000] = '\n';
    var needle: [350]u8 = undefined;
    @memset(&needle, 'a');
    const s = Searcher.init(&needle);
    for ([_]usize{ 0, 1, 9_999, 10_001, 49_000, 50_001 }) |from| {
        try std.testing.expectEqual(std.mem.indexOfPos(u8, data, from, &needle), s.find(data, from));
        var nl: usize = undefined;
        const got = s.findCounting(data, from, &nl);
        try std.testing.expectEqual(std.mem.indexOfPos(u8, data, from, &needle), got);
        var want: usize = 0;
        for (data[from .. got orelse data.len]) |c| want += @intFromBool(c == '\n');
        try std.testing.expectEqual(want, nl);
    }
}
