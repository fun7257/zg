# zg

[中文说明](README.zh-CN.md) · [![CI](https://github.com/fun7257/zg/actions/workflows/ci.yml/badge.svg)](https://github.com/fun7257/zg/actions/workflows/ci.yml)

A fast, line-oriented literal search for one file, written in Zig 0.16. It uses SIMD within
chunks of the file and every core across them, and comes as a command line tool and as a
library that a server can embed.

```
$ zg -n ERROR app.log
2:2026-10-05T12:00:01.217 ERROR [http] req=04203afdc6de user=71909 latency=56ms path=/api/v3/items/31
13:2026-10-05T12:00:12.215 ERROR [sched] req=b5c34aff583d user=72210 latency=423ms path=/api/v1/items/422
...
```

zg searches for an exact, case-sensitive byte string and prints the lines that contain it,
like `grep -F` or `rg -F` on a single file. With the file in the page cache, it is 1.9 to
17x faster than ripgrep with all cores on an 8-core Apple Silicon Mac, 2.6 to 37x on an
8-core x86-64 Linux laptop, and on one thread up to 3.6x and 4.3x faster (details in
[Performance](#performance)).

Scope: one file (or a buffer in memory), literal patterns. No regular expressions, no
case folding, no directory walking.

## Command line

```
zg [-n] [-c] [-m N] [-j N] [--io=auto|mmap|pread] [--mem=SIZE] [--] PATTERN FILE
zg --version
```

| option | |
|---|---|
| `-n` | prefix matching lines with their line numbers |
| `-c` | print only the number of matching lines |
| `-m N` | stop after N matching lines |
| `-j N` | threads (default: as many as pay off, up to one per CPU; see [Threads](#how-it-works)) |
| `--io=` | how to read the file: `auto` (default, measured while searching), `mmap` or `pread` |
| `--mem=SIZE` | cap on the memory zg allocates, e.g. `512M`, `4G` (default: what the system can hand out without swapping, at most half of the physical memory) |
| `--version`, `-V` | the version, the target, and for a portable x86-64 build the level it runs on this CPU (`running v3`) |

Exit status: 0 if a line matched, 1 if none did, 2 on errors. A closed output (`| head`)
ends the search quietly. One difference from ripgrep: `-c` with no match prints `0` (as
grep does), where ripgrep prints nothing.

## Building

Requires [Zig 0.16.0](https://ziglang.org/download/).

```
zig build                  # zig-out/bin/zg and the benchmark tools, ReleaseFast, for this machine's CPU
zig build install          # install only zg, into ~/.local/bin (-Dbin-dir=PATH for elsewhere)
zig build -Dcpu=baseline   # a portable x86-64 binary (see below)
zig build test             # tests, in ReleaseSafe (-Dtest-optimize=Debug for Debug)
zig build test-levels      # the tests once per x86-64 level (v1, v2, v3) the machine runs
```

A build for an x86-64 CPU without AVX2 (`-Dcpu=baseline`, or any `-Dtarget` for
distribution) also carries the core compiled for x86-64-v2 and x86-64-v3, and runs the one
the CPU supports (checked with `cpuid`). Zig compiles every module for its own target CPU,
so the copies are the same source in other modules. On the Ryzen below, one thread
counting a rare pattern in a 540 MB cached file: 68 ms built for the machine, 69 ms in the
portable binary, 155 ms in a plain baseline build before this. `-Dcpu-dispatch=false` turns it
off; `ZG_CPU_LEVEL=v1` or `v2` runs a lower level, for testing. AVX-512 (x86-64-v4) is not
built: the code has not been run on a CPU that has it.

Developed on macOS (Apple Silicon); tested and measured there and on x86-64 Linux. CI
([.github/workflows/ci.yml](.github/workflows/ci.yml)) builds and tests on Linux x86-64,
Linux aarch64 and macOS (Apple Silicon), compares the output with `grep -F`, and on x86-64
runs the tests and that comparison at each level of the portable build. Windows is not
supported (zg uses `mmap`).

## Library

The package exports the module `zg`. Add it with

```
zig fetch --save git+https://github.com/fun7257/zg
```

and in `build.zig`:

```zig
const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zg", zg.module("zg"));
```

There are two kinds of engine, which run the same code on a search's chunks:

- `zg.Engine(.oneshot)`: each search starts its own threads and works out its own memory
  limit. The command line tool is a thin wrapper around it; `zg.run` is a shortcut.
- `zg.Engine(.shared)`: a long-lived engine for a server. One pool of threads and one memory
  limit serve all the searches running at a time; `search` may be called from several
  threads at once.

```zig
const std = @import("std");
const zg = @import("zg");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var engine: zg.Engine(.shared) = try .init(io, init.gpa, .{});
    defer engine.deinit();

    const file = try std.Io.Dir.cwd().openFile(io, "app.log", .{});
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const n = try engine.search(.{ .file = file }, .{ .pattern = "ERROR", .line_numbers = true }, &out.interface);
    std.debug.print("{d} matching lines\n", .{n});
}
```

- Input (`zg.Source`): `.{ .file = f }`, or `.{ .bytes = data }` for data already in
  memory, such as a request body.
- Output: any `*std.Io.Writer`, written in file order as the chunks complete (a chunked HTTP
  response, for instance). Long lines are written straight from the file mapping, without
  a copy. Or `searchLines(src, opts, ctx, on_line)`, which calls
  `on_line(ctx, line_number, line)` for each matching line, in order, e.g. to build JSON.
- `zg.Options`: `pattern`, `line_numbers`, `count_only`, `max_matches`, `threads` (on a
  shared engine: the most threads this search may use), `io`, `memory_limit` (one-shot
  engines), `cancel`, `timeout_ns`.
- Stopping a search: `cancel = &c` with a `zg.Cancel` that another thread can `request()`
  (the search then fails with `error.Canceled`), or `timeout_ns` (`error.Timeout`). A
  writer that fails (a client that went away, or a writer that enforces a size cap) stops
  the search at once with `error.WriteFailed`.
- Errors: `error.EmptyPattern`, `error.PatternHasNewline`, `error.FileChanged` (the file
  shrank during the search), `error.TooManySearches` (over 1024 at once on shared engines),
  and those of the writer, the file and the allocator. The library never exits the
  process or prints.

One-shot engines start threads as a search goes. Zig's standard library gives each thread a
256 KB alternate signal stack in thread-local storage (only used to print a stack trace on a
stack overflow), and clearing it makes a thread start about 7 times slower (130 against 17 us
on x86-64 Linux). The command line tool turns it off outside Debug builds; a program that
embeds zg can do the same in its root file:

```zig
pub const std_options: std.Options = .{ .signal_stack_size = null };
```

The shared engine's threads wait on futexes through the `Io` given to `init`: it is meant for
`std.Io.Threaded` (what `std.process.Init` provides), and has not been tried with an evented
`Io`.

What the shared engine adds over running one-shot searches side by side:

- No oversubscription: at most as many threads work as there are cores, counting the threads
  that called `search` (each of them writes its output and helps with its chunks).
- Fairness: the pool threads take chunks from the running searches in turn, and skip a
  search held back by its memory budget (a slow reader), so a slow client does not hold
  threads.
- One memory budget for all searches, and output and read buffers kept from one search to
  the next.
- What earlier searches measured: below 256 MB, a search reads the file the way that was
  fastest for files of its size (mapped or `pread`, with an occasional search that tries the
  other); above, the per-chunk choice starts from earlier measurements instead of a warm-up
  (on Linux, above 256 MB, `pread` only: unmapping the pages a mapped search faulted in
  holds the process's address space lock, and the other searches wait for it).
- Kept from one search of a file to the next (files below 256 MB): its mapping, with the
  pages already faulted in, and the filter tuned for each pattern on it. A file that changes
  (size or modification time) is mapped and tuned again. On the Ryzen, small searches of a
  cached 8 MB file went from 0.6 to 0.1 ms; next to a large search printing much output,
  their p99 went from 11 to 4 ms.
- Threads per search as they pay off, as in one-shot searches (below).
- Freeing buffers left by large searches is done by an idle pool thread, not by whichever
  search happens to end last.
- Truncated files: a file that shrinks while it is mapped raises SIGBUS (on Linux, where the
  tests truncate files under running searches; on macOS zg's private mapping keeps showing
  the old contents). A handler turns that into
  `error.FileChanged` for the search concerned instead of a crash; other SIGBUS go to the
  handler that was there before.

## How it works

- **Filter**: two rare bytes of the pattern at their offsets are compared a vector at a
  time (the packed-pair approach of memchr, with its byte frequency table), with up to two
  more bytes when the pair is common. The choice is checked on a 64 KB sample of the file:
  when the pair turns out to be common there (in a log, every line has `latency=`), a rarer
  combination is picked by counting. A cost model measured on the sample decides how many
  filter bytes to use.
- **Worst case**: when verifying candidates costs more than scanning, the search switches to
  Two-Way (Crochemore–Perrin), so it stays linear on adversarial input.
- **Chunks**: the file is cut into byte ranges that threads search independently, at most a
  thread's share of the L2 cache (read from the system: 2 MB on Apple Silicon, 256 KB on a
  Zen 3 core shared by two threads) so that bytes read with `pread` are scanned while still in
  the cache. A chunk
  owns the lines that start in it; a line running into later chunks is decided by the
  writer from what those chunks found. A line of any length thus costs no memory, and its
  work is spread over the threads. `-n` line numbers come from newline counts gathered by
  the scan itself and published chunk by chunk, in order.
- **Reading**: per chunk, through the mapping with `MADV_WILLNEED`, through the plain
  mapping, or with `pread`. Which is fastest depends on the state of the system, not only on
  whether the file is cached, so the threads time the methods on the file itself and keep
  using the fastest, with regular re-checks. On Linux the mapped methods are also charged for
  unmapping their pages at the end, a serial cost the chunk timings do not see (14 ms for
  540 MB), so cached files are mostly read with `pread` there, from page boundaries (a copy
  between different offsets within a cache line is several times slower on x86). Small files
  go by a sampled `mincore` instead.
- **Output**: each chunk renders its lines into a buffer, and the writer writes the chunks in
  order as they complete, working on chunks itself meanwhile. Lines of 16 KB and more are
  written from the mapping (or the chunk's `pread` buffer) instead of being copied.
- **Threads** (searches without `-j`; on a shared engine, the pool threads a search lets
  in): started as they pay off, after the
  bandwidth-aware threading of Suleman et al. (ASPLOS 2008). Up to one per physical core
  they start without measuring (with `-m`, from the caller alone, doubling as chunks get
  done, since such searches often stop early; small files get fewer). The second thread of
  each core starts only if the search has compute to overlap: when at least half of the time
  of the chunks read with `pread` goes to scanning and rendering rather than to the copy from
  the page cache. Otherwise the extra threads would only compete for memory bandwidth: a
  rare pattern in a cached 540 MB file takes 24.3 ms on 8 threads and 26.4 ms on 16 on an
  8-core Ryzen, while printing 4.7 M lines takes 41.1 and 32.6 ms. A share of 0.75 or more
  already over the first chunks decides at once.
- **Memory**: a cap (see `--mem`), two thirds of it as the budget for buffered output.
  Beyond it, threads stop taking new chunks until the writer catches up (the chunks right
  behind the writer always go on), and drained buffers are freed rather than kept.

## Performance

### Apple Silicon (macOS)

Medians of 15 runs, zg and ripgrep 15.2 (`rg -a -F --no-config`) alternating, page cache warm; 8-core Apple
Silicon, 8 GB, macOS. Corpora from `zig build gen`: 540 MB of words (3 to 14 per line), 514 MB
of log lines, 512 MB of lines of 20 to 600 KB (`long.txt`), 300 MB of lines of 0 to 3
characters (`short.txt`), 512 MB of random bytes. Output to `/dev/null`, identical to
ripgrep's in every case.

| | all cores: min / geometric mean | one thread: min / geometric mean |
|---|---|---|
| 39 standard cases (words, logs; plain, `-n`, `-c`) | 2.40x / 4.25x | 1.02x / 1.43x |
| 54 worst cases (common bytes, long patterns, stress corpora) | 1.91x / 4.03x | 0.93x / 1.49x |

| case | zg, all cores | ripgrep | zg, one thread | ripgrep |
|---|---|---|---|---|
| words, `needle_zz` (1 line) | 22.6 ms | 54.3 ms | 54.2 ms | 56.3 ms |
| words, `the` (4.7 M lines) | 46.2 ms | 376.8 ms | 228.2 ms | 380.1 ms |
| words, `a`, `-n` (9.3 M lines) | 64.8 ms | 1132.0 ms | 320.8 ms | 1137.4 ms |
| logs, `ERROR` (1.25 M lines) | 27.1 ms | 129.7 ms | 80.8 ms | 129.6 ms |
| `short.txt`, `a` (38 M lines) | 124.9 ms | 1546.5 ms | 746.5 ms | 1549.9 ms |
| `long.txt`, `th` (1655 lines) | 23.5 ms | 45.6 ms | 47.6 ms | 45.5 ms |

The cases where zg trails on one thread are `long.txt` with plain output or `-c`, measured
while macOS made mapped access to that file slow: zg then reads with `pread`, like ripgrep,
and both pay the same copy. On a cold page cache (first read from disk) both run at disk
speed. All tables, the adversarial inputs (zg 27 ms against ripgrep 489 ms) and the memory
footprint are in [bench/results.md](bench/results.md).

Shared engine, in-process (`zig build stress`): one search of 540 MB takes 17.7 ms; 2 to 16
concurrent searches take 14.3 to 15.4 ms each (total throughput holds); small 8 MB searches
next to a large search producing millions of lines: p50 0.65 ms, p99 2.0 ms.

These numbers predate the changes made for x86-64 Linux below, which also touch code that runs
on the Mac; it has not been measured again since.

### x86-64 Linux

The same matrix on an AMD Ryzen 7 7735U (8 cores, 16 threads), 20 GB, Debian 13 (Linux
6.12), ripgrep 14.1.1; output identical to ripgrep's in every case.

| | all cores: min / geometric mean | one thread: min / geometric mean |
|---|---|---|
| 39 standard cases | 3.16x / 5.48x | 1.00x / 1.50x |
| 54 worst cases | 2.64x / 5.45x | 1.01x / 1.58x |
| 10 small files (1 to 64 MB) and `-m` | 1.16x / 2.03x | |

| case | zg, all cores | ripgrep | zg, one thread | ripgrep |
|---|---|---|---|---|
| words, `needle_zz` (1 line) | 25.2 ms | 81.8 ms | 69.4 ms | 82.2 ms |
| words, `the` (4.7 M lines) | 30.9 ms | 378.4 ms | 203.1 ms | 383.8 ms |
| words, `a`, `-n` (9.3 M lines) | 45.9 ms | 1019.7 ms | 281.1 ms | 983.4 ms |
| logs, `ERROR` (1.25 M lines) | 21.8 ms | 126.9 ms | 81.3 ms | 126.2 ms |
| `short.txt`, `a` (38 M lines) | 65.8 ms | 1702.3 ms | 394.8 ms | 1693.3 ms |
| `long.txt`, `th` (1655 lines) | 24.2 ms | 63.9 ms | 56.2 ms | 63.4 ms |
| words, `the`, `-m 1` | 2.1 ms | 2.4 ms | | |

The portable build (`-Dcpu=baseline`) gives the same: one thread 1.03x / 1.50x on the
standard cases (the baseline build before was 0.49x / 0.78x, slower than ripgrep). Cold
page cache: 190 to 215 ms against 291 to 427 ms for ripgrep, near the 2.9 GB/s the SSD
reads at. Shared engine: one search of 540 MB takes 21.6 ms; small searches of an 8 MB file
take 0.1 ms (p50), and next to a large search printing much output 0.3 ms (p99 3.7 ms).
All tables, and the fixes that
took the first Linux run (all cores 2.92x, one thread 1.39x geometric mean) to these, are in
[bench/results-x86-linux.md](bench/results-x86-linux.md).

### Reproducing

```
zig build gen -- corpus                     # the corpora above (about 2.4 GB)
zig build compare -- --dir corpus           # against rg: warm, one thread, small files and -m, memory, cold cache
zig build bench -- corpus/words.txt the -n  # in-process timing of one search
zig build stress -- corpus/words.txt small.txt   # concurrent searches on a shared engine
```

`compare --sections ab --zg A --zg-b B` alternates two zg builds instead, for A/B
comparisons; `bench --chunk=SIZE` times a given chunk size. On macOS, run a fresh binary once before timing it (its first run is scanned
by the system), and note that the state of the page cache can move single-thread numbers by
a lot (see bench/results.md).

#### Performance CI

[`.github/workflows/bench.yml`](.github/workflows/bench.yml) runs `.github/bench.sh` on Linux
x86-64, Linux aarch64 and macOS (Apple Silicon): zg against ripgrep (the 39 standard cases and
the small-file and `-m` cases), and on pull requests that touch `src/`, `bench/` or
`build.zig`, the change against its base, both builds alternating on the same machine so that the
noise of a shared runner affects them alike. The report is in the job summary and the
artifacts. The check fails when the geometric mean over the 39 cases is more than 15 % slower
than the base (identical builds differ by about 1 % here); read single cases as indications
only. It also runs weekly on `main`, and by hand with `base_ref` (any branch, tag or commit to
compare with), `runs` and `threshold`. The same on your machine:

```
zig build
.github/bench.sh                          # against ripgrep
.github/bench.sh --base ./zg-old --fail-regression 10   # also against another build
```

## Limitations and roadmap

- `-m` with a small N was about 3 ms slower than ripgrep on all cores on the Mac (measured
  before threads were started as they pay off; on the Linux laptop zg is now ahead, 2.0
  against 2.6 ms).
- Searches that turn out compute bound reach all threads only after measuring on one per
  core: up to 4% slower than starting them all at once (`-c a` on short.txt); others are as
  fast or faster than with all threads.
- `searchLines` gives line numbers but not byte offsets yet.
- Next to a large search producing much output, small searches on a shared engine wait up
  to the time of one large chunk (about 1.4 ms on the Mac) for a thread; on the Linux laptop
  their p99 is 3.7 ms (0.73 ms alone), from waits for the process's address space lock
  that remain.
- Not yet tried: the shared engine with an evented `Io`, Linux on aarch64, x86 machines other
  than one Zen 3+ laptop.
- Possible: AVX-512 kernels (x86-64-v4), once they can be measured.

## License

[Apache License 2.0](LICENSE)
