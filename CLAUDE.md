# zg: notes for agents

zg is a single-file, line-oriented, case-sensitive literal search in Zig 0.17 (SIMD inside chunks,
all cores across them), as a command line tool and as a library. README.md says what it does and how
it works; this file is what is not obvious from the code.

## Layout

- `src/search.zig`: SIMD primitives (filter, Two-Way fallback, newline scans).
- `src/zg.zig`: the engine (chunks, access methods, writer, one-shot and shared engines, thread
  ramp, caches). Tests are in the same file; `zig build test` runs them.
- `src/main.zig`: the command line (options, standard input, error wording), `--version`, and the
  choice of CPU level at start-up.
- `bench/`: `gen` (corpora), `compare` (zg against rg, A/B of two zg builds), `bench` (in-process),
  `stress` (shared engine under concurrency). `bench/results.md` (Apple Silicon) and
  `bench/results-x86-linux.md` (Ryzen) hold the measurements behind the numbers in the README.
- `.github/`: `workflows/ci.yml` (tests), `workflows/bench.yml` (performance), `smoke.sh` (output
  against `grep -F`), `cli-tests.sh` (standard input, error messages, options, truncation), `bench.sh` (one benchmark run; works by hand too), `package.sh` (build, test and pack a release binary), `bench-variants.sh` (every CPU level of
  a platform, one run each), `summarize.py` (merges the reports).

## Build and test

```
zig build                    # zg and the bench tools in zig-out/bin (compare looks for zg there)
zig build test               # ReleaseSafe; add -Dtest-optimize=debug for Debug
zig build test-levels        # the tests for x86-64 v1, v2, v3, as far as the machine runs them
zig build -Dcpu=baseline     # the portable x86-64 build (cores for v2 and v3 inside)
.github/smoke.sh zig-out/bin/zg [v1 v2 v3]   # output against grep -F (levels: portable build)
.github/cli-tests.sh zig-out/bin/zg          # the command line's behaviour (run from the repo root)
```

Before a push: ReleaseSafe and Debug tests, and `test-levels` on x86-64. Cross-compile checks
(`-Dtarget=aarch64-macos`, `aarch64-linux`) are cheap and catch OS-specific code. CI runs Linux
x86-64, Linux aarch64 and macOS.

**Concurrency bugs are flaky.** The shared engine had a use-after-free (`Job.leave` read the job
after dropping `inflight`, which lets `Pool.remove` free it) that showed in 1 of 25 full runs on
4 CPUs. After a change to the shared engine, thread start/stop or the pool, run the tests many times
on few CPUs, e.g. `zig test src/zg.zig -OReleaseSafe --test-filter "shared engine" --test-no-exec
-femit-bin=t` and then `taskset -c 0-3 ./t` in a loop (hundreds of runs). Since Zig 0.17 the filter
is given to the compiler: the test binary rejects `--test-filter` ("unrecognized command line
argument") and every run aborts.

## Things that break quietly

- **The CPU-level copies.** The portable build compiles `src/zg.zig` and `src/search.zig` again for
  x86-64 v2 and v3 as copies in other modules (`build.zig`). Zig takes the target CPU per module,
  and a file belongs to one module. So `zg.zig` may import only `search.zig` (plus std/builtin): a
  new source file has to be added to the copy list in `build.zig`, or the portable build fails.
- **Command line behaviour is tested in `cli-tests.sh`**, not only the output: a change to options,
  messages, standard input or exit statuses goes with a check there. Standard input that is not a
  regular file is read into memory (`openInput` in `main.zig`); the search then runs on
  `Source.bytes`. Messages: `describe` maps the common errors to the system's wording, the rest
  to the error's name as words.
- **The command line sets `Options.truncation_guard`** (the SIGBUS handler for one-shot
  searches). Without it a file truncated during an `mmap` search kills the process.
- **Root files set `std_options.signal_stack_size = null`** outside Debug (main, bench, stress):
  the default 256 KB signal stack per thread made a thread start ~7x slower (130 vs 17 us).
- **Memory is small on purpose.** More memory does not make zg faster: its speed is the file in the
  page cache, which the system keeps. The default limit is `threads * memoryPerThread * 3` (at
  least 32 MB), about 150 MB on 16 threads; each thread reserves 12 chunks while it renders output
  (2 while counting), and chunks are at most a thread's share of L2, so the numbers follow the CPU.
  Below roughly 40 % of that default, searches that print millions of lines get slower, because
  `threadsFor` allows fewer threads; to move the numbers, sweep `--mem` over the standard cases that
  print much (`the`, `-n a`, short.txt `a`) and watch the time and, with `--io=pread`, the peak RSS.
  Do not tie the default to the machine's memory: a container does not tell (it was killed).
- **Zig 0.17.0 compiler crash**: `zig build -Dcpu=baseline -Dstrip=true` (the whole dev step) kills
  the compiler with SIGSEGV while building `bench` and `stress`; `zg` itself, `zig build install`
  (what `package.sh` runs) and the same build without `-Dstrip` are fine. A `.zig-cache` left
  behind by such a crash fails later builds with `FileNotFound` on files in `.zig-cache/o`: delete it.
- **Zig 0.17 renames this code uses**: `std.lang.Optimize` (`.debug/.safe/.fast/.small`,
  `-Dtest-optimize=debug`), `builtin.target.cpu/os` (the old `builtin.cpu/os` go in 0.18), `@Int`
  (`std.meta.Int` is gone), `@splat` (no `**`), `addPassthruArgs`. `zig build install` can no longer
  set its directory in `build.zig`: use `--prefix-exe-dir PATH`.
- **Thread count comes from measured costs, not a file size** (`StartCost`, `threadsForWork`, `Ramp`
  in `zg.zig`). A thread started with the search times starting a thread; after the first chunk the
  caller picks the n of the least T(n) = [W + (n-1)(L+s) + s n (n-1)/2] / n, in two steps: the
  measured costs are a lower bound whose distance from the truth depends on the machine (the
  factor that fits was 2.5 to 2.9 on x86-64 runners and the Ryzen, 0.6 to 0.9 on arm64), so the
  first step starts threads only if the measured costs say they pay, and no more than the costs
  times `start_cost_upper` allow (it can only start too few); the first thread started times its
  own first chunk and `.learn` starts the rest from that. The costs are not constants: a thread
  starts 70 to 320 us after the cores were idle and 22 to 73 us when they were busy, so a
  threshold fitted on back-to-back benchmark runs is wrong for an interactive run. To check or
  retune: the Performance workflow (`only_threads`) runs `.github/thread-sweep.py` on the
  three platforms; it reports the kappa that fits each. The model ignores memory bandwidth (more
  than about 4 threads do not help a 10 GB/s-per-thread scan) and the writer. Shared engines and
  `-m` do not use it. **Measure such things with the builds alternating in rotating order, never
  one setting after another**: a first table (each thread count in a block of its own) was wrong
  because the clock rate followed the order of the blocks.
- **Vector width** is 16 bytes without AVX2 (SSE2, NEON), 32 with: 32 on SSE2 was twice as slow.
- **Linux specifics**, each measured (see results-x86-linux.md): `pread` from page boundaries (a
  copy offset by a byte is 3-6x slower); chunk size is at most a thread's share of L2, read from
  sysfs/sysctl; the mapped access methods are charged for unmapping (14 ms for 540 MB, serial);
  shared engines read files above 256 MB with `pread` only (unmapping blocks the process's address
  space lock for the other searches).
- **Shared engine caches** (`MapCache`, `TuneCache`) are keyed by inode, size and mtime. A `BusGuard`
  hit marks every search on the mapping.
- Nothing about a `Job` may be read after `inflight` is dropped (see above).

## Measuring performance

- Compare builds **alternating on the same machine** (`compare --sections ab --zg OLD --zg-b NEW`,
  or `.github/bench.sh --base OLD`). Keep a copy of the old binary before changing code. Back-to-back
  measurements are biased on laptops (clocks ramp up, then drop at the power limit); that misled a
  thread-count heuristic once.
- Read the geometric mean over cases, not single cells (identical builds: 1-2 % apart on Linux
  runners, single cells 0.82x-1.20x on the macOS runner).
- Corpora (`zig build gen -- DIR`, about 2.4 GB) live outside the repo; `bench-corpus` is ignored.
- Stress tail latencies need `stress --rounds=150` (3000 samples); the default 200 gives a "p99"
  that is nearly the maximum.
- No `perf` here; `strace -f -c`, `strace -k` and per-thread `getrusage` found most problems. No
  root, so no I/O throttling to simulate slow disks.
- Say what was measured, on which machine, in comments and docs. Code comments record the numbers
  behind a choice (and what was tried and dropped); keep doing that.

## Performance workflow

To measure a change in CI, **merge it into the `perf` branch** (create it from `main` if it does not
exist). A push or merge into `perf` runs `bench.yml`: three platform jobs, each running
`.github/bench.sh` for every CPU level of its platform, then `Report` merges them (`.github/summarize.py`: headline table, CPU time,
change against the base, a few cases side by side, the machines; plus `results.csv`).

- One job per platform, and in it every CPU level one after the other (`.github/bench-variants.sh`):
  hosted runners are a different CPU model from job to job (EPYC 7763, EPYC 9V74, Xeon 8573C and
  6973P-C were seen), so levels measured in different jobs cannot be compared.
- Linux x86-64: v1, v2, v3 (the portable build's three cores, run in turn with `ZG_CPU_LEVEL`); v4
  (`-Dcpu=x86_64_v4`, only where the CPU has AVX-512, else a "skipped" report); native.
  Linux arm64: baseline; native. macOS arm64: native only (Zig's baseline there is the M1).
- Each measures zg against rg (39 standard cases, 54 stress cases, all cores and one thread, small
  files and `-m`; the native runs also memory, and on Linux the cold read), and the new `perf`
  against the one before the push, alternating. It fails when the geometric mean over the 39 cases
  is more than 15 % slower. Pull requests do not trigger it. By hand: the `Performance` workflow with
  `base_ref` (any ref to compare with).
- Adding a platform is a matrix entry in `bench.yml` plus a case in `bench-variants.sh`; a level is
  a line in the case of its platform there. `summarize.py` reads `compare`'s text (the `## ` headings and the
  `speedup over N cells` lines): change them together. `compare` has a built-in `worst` section.
- zg has no AVX-512 or SVE code. Some hosted x86-64 runners have AVX-512 (EPYC 9V74, Xeon 8573C;
  not the EPYC 7763), and the arm64 runner is a Neoverse N2 (SVE2): that is where such a kernel could
  be checked.

## Releasing

A release is a tag `vX.Y.Z` on `main`, where `X.Y.Z` is the `.version` in `build.zig.zon` (the
workflow refuses a tag that differs, and so does `zg --version`). To cut one:

1. Raise `.version` in `build.zig.zon` in a pull request, and merge it.
2. Tag the merge commit and push the tag: `git tag -a vX.Y.Z -m "zg X.Y.Z" && git push origin vX.Y.Z`.
3. `release.yml` builds, tests and packs each system on a runner of its own kind
   (`.github/package.sh`), then publishes the release: `zg-X.Y.Z-SYSTEM.tar.gz` for x86_64-linux
   (portable build, cores for v1, v2, v3), aarch64-linux and aarch64-macos, with `SHA256SUMS` and
   the text of `.github/release-notes.md` plus the list of merged pull requests.

Releases are stripped (`-Dstrip=true`), and the arm64 ones are generic ARMv8-A (`-Dcpu=baseline`),
never built for the runner's CPU (a Neoverse N2 build uses SVE2). Check the numbers quoted in
`release-notes.md` against `bench/results*.md` before a release. A pull request that changes the
workflow, `package.sh` or `build.zig` runs everything but the publishing. Not built: Windows, and
macOS on Intel.

## Conventions

- Work on a branch and open a pull request; the repository merges with merge commits. Do not push to
  `main`.
- Commit messages say what changed and what was measured.
- `README.md` and `README.zh-CN.md` say the same; change both. Keep the numbers in them in step with
  `bench/results*.md`.
- Don't drop temporary instrumentation with `git checkout FILE` when the file also has real changes
  (it once erased an unrelated option); keep a copy and restore that.
