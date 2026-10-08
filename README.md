# zg

[中文说明](README.zh-CN.md)

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
like `grep -F` or `rg -F` on a single file. On an 8-core Apple Silicon Mac with the file in
the page cache, it is 1.9 to 17x faster than ripgrep with all cores, and up to 3.6x faster
on one thread (details in [Performance](#performance)).

Scope: one file (or a buffer in memory), literal patterns. No regular expressions, no
case folding, no directory walking.

## Command line

```
zg [-n] [-c] [-m N] [-j N] [--io=auto|mmap|pread] [--mem=SIZE] [--] PATTERN FILE
```

| option | |
|---|---|
| `-n` | prefix matching lines with their line numbers |
| `-c` | print only the number of matching lines |
| `-m N` | stop after N matching lines |
| `-j N` | threads (default: one per CPU, fewer if the memory limit cannot carry them) |
| `--io=` | how to read the file: `auto` (default, measured while searching), `mmap` or `pread` |
| `--mem=SIZE` | cap on the memory zg allocates, e.g. `512M`, `4G` (default: what the system can hand out without swapping, at most half of the physical memory) |

Exit status: 0 if a line matched, 1 if none did, 2 on errors. A closed output (`| head`)
ends the search quietly. One difference from ripgrep: `-c` with no match prints `0` (as
grep does), where ripgrep prints nothing.

## Building

Requires [Zig 0.16.0](https://ziglang.org/download/).

```
zig build                  # zig-out/bin/zg, ReleaseFast
zig build test             # tests, in ReleaseSafe (-Dtest-optimize=Debug for Debug)
```

Developed and measured on macOS (Apple Silicon). Linux on aarch64 and x86_64 builds, and the
tests compile for it, but they have not been run there. The x86 code path has no tuning of
its own yet. Windows is not supported (zg uses `mmap`).

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
  other); above, the per-chunk choice starts from earlier measurements instead of a warm-up.
- Truncated files: a file that shrinks while it is mapped raises SIGBUS (on Linux; on macOS
  zg's private mapping keeps showing the old contents). A handler turns that into
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
- **Chunks**: the file is cut into byte ranges that threads search independently. A chunk
  owns the lines that start in it; a line running into later chunks is decided by the
  writer from what those chunks found. A line of any length thus costs no memory, and its
  work is spread over the threads. `-n` line numbers come from newline counts gathered by
  the scan itself and published chunk by chunk, in order.
- **Reading**: per chunk, through the mapping with `MADV_WILLNEED`, through the plain
  mapping, or with `pread`. Which is fastest depends on the state of the system, not only on
  whether the file is cached, so the threads time the methods on the file itself and keep
  using the fastest, with regular re-checks. Small files go by a sampled `mincore` instead.
- **Output**: each chunk renders its lines into a buffer, and the writer writes the chunks in
  order as they complete, working on chunks itself meanwhile. Lines of 16 KB and more are
  written from the mapping (or the chunk's `pread` buffer) instead of being copied.
- **Memory**: a cap (see `--mem`), two thirds of it as the budget for buffered output.
  Beyond it, threads stop taking new chunks until the writer catches up (the chunks right
  behind the writer always go on), and drained buffers are freed rather than kept.

## Performance

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

### Reproducing

```
zig build gen -- corpus                     # the corpora above (about 2.4 GB)
zig build compare -- --dir corpus           # against rg: warm, one thread, memory, cold cache
zig build bench -- corpus/words.txt the -n  # in-process timing of one search
zig build stress -- corpus/words.txt small.txt   # concurrent searches on a shared engine
```

`compare --sections ab --zg A --zg-b B` alternates two zg builds instead, for A/B
comparisons. On macOS, run a fresh binary once before timing it (its first run is scanned
by the system), and note that the state of the page cache can move single-thread numbers by
a lot (see bench/results.md).

## Limitations and roadmap

- `-m` with a small N is about 3 ms slower than ripgrep on all cores (every thread first
  searches a whole 2 MB chunk); on one thread they are even.
- `searchLines` gives line numbers but not byte offsets yet.
- Next to a large search producing much output, small searches on a shared engine wait up
  to the time of one large chunk (about 1.4 ms) for a thread.
- Not yet tried: the SIGBUS handling on Linux (built only), the shared engine with an evented
  `Io`, tuning for x86.
- Possible: caching the tuned filter per pattern on shared engines (tuning takes 0.02 to
  0.5 ms).

## License

[Apache License 2.0](LICENSE)
