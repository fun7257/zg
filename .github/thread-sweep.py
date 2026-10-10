#!/usr/bin/env python3
"""How many threads a search should use, by file size, on this machine: a check of the model
behind `threadsForWork` in src/zg.zig (see "Thread count from measured costs" in
bench/results-x86-linux.md).

    thread-sweep.py --bin zig-out/bin --corpus bench-corpus [--out FILE] [--rounds N]

Needs zig-out/bin/{zg,bench} and DIR/words.txt (bench/gen). Writes Markdown. Two states of
the machine, because the cost of starting a thread depends on it: "warm" (a search on all
threads just before every run) and "cold" (0.3 s idle before every run). In each:

  A. what starting a thread costs (`bench --start-cost`, 40 samples);
  B. the gain of 2, 3 or 4 threads over one on files of 4 to 32 MB, observed against what
     the model predicts with the measured costs times kappa, and the kappa that makes the
     prediction closest to the observations (`start_cost_upper` in src/zg.zig is the factor
     the first decision may not exceed; the costs measured on a lone thread are lower bounds,
     kappa >= 1, and how far above depends on the machine);
  C. wall and CPU time of one thread, of the default, and of all threads at once, by size.

Every setting of a round runs once, in an order that rotates from round to round.
"""
import argparse
import math
import os
import resource
import statistics
import subprocess
import sys
import tempfile
import time

KB, MB = 1024, 1024 * 1024
START_COST_UPPER = 3.0
WORKLOADS = {"-c needle_zz": ["-c", "needle_zz"], "-c the": ["-c", "the"], "the (lines)": ["the"]}
FIT_ROWS = ("-c the", "the (lines)")  # the others saturate the memory bandwidth first


def sysctl(name):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return None


def chunk_bytes():
    """A thread's share of the L2 cache, 256 KB to 2 MB, as zg works it out."""
    share = None
    if sys.platform == "darwin":
        size, per = sysctl("hw.perflevel0.l2cachesize"), sysctl("hw.perflevel0.cpusperl2")
        if size and per:
            share = int(size) // max(1, int(per))
    else:
        base = "/sys/devices/system/cpu/cpu0/cache"
        try:
            for d in sorted(os.listdir(base)):
                if not d.startswith("index"):
                    continue
                if open(f"{base}/{d}/level").read().strip() != "2":
                    continue
                size = open(f"{base}/{d}/size").read().strip()
                mult = {"K": KB, "M": MB}.get(size[-1], 1)
                size = int(size.rstrip("KM")) * mult
                cpus = 0
                for part in open(f"{base}/{d}/shared_cpu_list").read().strip().split(","):
                    lo, _, hi = part.partition("-")
                    cpus += int(hi or lo) - int(lo) + 1
                share = size // max(1, cpus)
                break
        except Exception:
            pass
    if share is None:
        share = 256 * KB if os.uname().machine in ("x86_64", "AMD64") else 2 * MB
    return max(256 * KB, min(share, 2 * MB))


def geomean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def cpu_seconds():
    r = resource.getrusage(resource.RUSAGE_CHILDREN)
    return r.ru_utime + r.ru_stime


class Harness:
    def __init__(self, args):
        self.zg = os.path.join(args.bin, "zg")
        self.bench = os.path.join(args.bin, "bench")
        self.cpus = os.cpu_count() or 1
        self.rounds = args.rounds
        self.cold_sleep = args.cold_sleep
        self.work = tempfile.mkdtemp(prefix="thread-sweep-")
        words = os.path.join(args.corpus, "words.txt")
        self.files = {}
        with open(words, "rb") as f:
            for name, n in (("128K", 128 * KB), ("512K", 512 * KB), ("1M", MB), ("2M", 2 * MB), ("4M", 4 * MB),
                            ("8M", 8 * MB), ("16M", 16 * MB), ("32M", 32 * MB), ("64M", 64 * MB)):
                f.seek(0)
                data = f.read(n)
                data = data[: data.rfind(b"\n") + 1]
                path = os.path.join(self.work, f"w{name}.txt")
                with open(path, "wb") as g:
                    g.write(data)
                self.files[name] = path

    def precondition(self, regime):
        if regime == "cold":
            time.sleep(self.cold_sleep)
        else:  # every core busy a moment ago
            subprocess.run([self.zg, "--io=pread", "-j", str(self.cpus), "-c", "the", self.files["8M"]],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run(self, extra, args, name):
        c0, t0 = cpu_seconds(), time.perf_counter()
        subprocess.run([self.zg, "--io=pread"] + extra + args + [self.files[name]],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return (time.perf_counter() - t0) * 1000, (cpu_seconds() - c0) * 1000

    def start_cost(self, regime, samples=40):
        runs, bufs, spawns = [], [], []
        for _ in range(samples):
            self.precondition(regime)
            out = subprocess.run([self.bench, "--start-cost"], capture_output=True, text=True).stderr.split()
            if len(out) == 4:
                runs.append(int(out[0])), bufs.append(int(out[1])), spawns.append(int(out[2]))
        return statistics.median(runs) / 1e6, statistics.median(bufs) / 1e6, statistics.median(spawns) / 1e6

    def measure(self, regime, configs, name, workload_args, rounds=None):
        """configs: label -> extra zg options. Median wall ms and mean CPU ms of each."""
        labels = list(configs)
        wall = {k: [] for k in labels}
        cpu = {k: [] for k in labels}
        for rnd in range(rounds or self.rounds):
            order = labels[rnd % len(labels):] + labels[: rnd % len(labels)]
            for k in order:
                self.precondition(regime)
                w, c = self.run(configs[k], workload_args, name)
                wall[k].append(w)
                cpu[k].append(c)
        return {k: (statistics.median(wall[k]), statistics.mean(cpu[k])) for k in labels}


def best_kappa(rows, l, s):
    """The factor on the measured costs that gets the predicted gains closest (rms, ms) to the
    observed ones: rows are (W, j, gain). Returns kappa, rms."""
    best = None
    for k10 in range(0, 81):
        k = k10 / 10
        rms = rms_error(rows, l, s, k)
        if best is None or rms < best[1]:
            best = (k, rms)
    return best


def rms_error(rows, l, s, k):
    return math.sqrt(sum((predicted_gain(w, j, k * l, k * s) - g) ** 2 for w, j, g in rows) / len(rows))


def predicted_gain(w, j, l, s):
    return (j - 1) / j * (w - (l + s) - s * j / 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default="zig-out/bin")
    ap.add_argument("--corpus", default="bench-corpus")
    ap.add_argument("--out")
    ap.add_argument("--rounds", type=int, default=15)
    ap.add_argument("--cold-sleep", type=float, default=0.3)
    args = ap.parse_args()
    h = Harness(args)
    chunk = chunk_bytes()
    cpus = h.cpus
    js = sorted({1, 2, min(4, cpus)} | ({3} if cpus == 3 else set()))
    out = []
    p = out.append
    p("# Thread count by file size\n")
    p(f"{cpus} CPUs, chunks of {chunk // KB} KB, {args.rounds} rounds per setting, "
      f"cold = {args.cold_sleep} s idle before every run, warm = a search on all threads just before.\n")

    for regime in ("warm", "cold"):
        p(f"## {regime}\n")
        run_ms, buf_ms_per_kb, spawn_ms = h.start_cost(regime)
        l_meas = run_ms + buf_ms_per_kb * (chunk // KB)
        s_meas = 2 * spawn_ms
        p("### Starting a thread\n")
        p(f"Measured (median of 40): first instruction {run_ms * 1000:.0f} us after asking, a chunk-size buffer "
          f"{buf_ms_per_kb * (chunk // KB) * 1000:.0f} us, `spawn` call {spawn_ms * 1000:.0f} us. "
          f"So L = {l_meas:.3f} ms and s (spawn and join) = {s_meas:.3f} ms.\n")

        # B: gains of j threads over one
        p(f"### Gain of j threads over one thread (ms), observed / predicted with the measured costs times {START_COST_UPPER}\n")
        sizes_b = ["4M", "8M", "16M", "32M"]
        T = {}
        for name in ["128K"] + sizes_b:
            for wl, wa in WORKLOADS.items():
                T[(name, wl)] = h.measure(regime, {j: ["-j", str(j)] for j in js}, name, wa)
        rows_fit = []
        table = []
        for name in sizes_b:
            for wl in WORKLOADS:
                t1 = T[(name, wl)][1][0]
                w = t1 - T[("128K", wl)][1][0]
                cells = []
                for j in js[1:]:
                    obs = t1 - T[(name, wl)][j][0]
                    pred = predicted_gain(w, j, START_COST_UPPER * l_meas, START_COST_UPPER * s_meas)
                    cells.append(f"{obs:.2f} / {pred:.2f}")
                    if wl in FIT_ROWS:
                        rows_fit.append((w, j, obs))
                table.append((name, wl, w, cells))
        p("| size | search | W | " + " | ".join(f"{j} threads" for j in js[1:]) + " |")
        p("|---|---|---|" + "---|" * len(js[1:]))
        for name, wl, w, cells in table:
            p(f"| {name} | {wl} | {w:.2f} | " + " | ".join(cells) + " |")
        p("")
        if rows_fit:
            k, rms = best_kappa(rows_fit, l_meas, s_meas)
            p(f"Kappa that fits the observed gains of `-c the` and `the (lines)` best: {k:.1f} "
              f"(rms {rms:.2f} ms). Error of the predicted gain with the measured costs as they are "
              f"(kappa 1): {rms_error(rows_fit, l_meas, s_meas, 1.0):.2f} ms; with kappa {START_COST_UPPER}: "
              f"{rms_error(rows_fit, l_meas, s_meas, START_COST_UPPER):.2f} ms.\n")
        else:
            p("No rows to fit.\n")

        # C: one thread, the default, all threads at once
        p("### Wall ms (CPU ms) by size: one thread, the default, all threads at once\n")
        p("Geometric mean over `-c needle_zz`, `-c the` and `the (lines)`.\n")
        p("| size | one thread | default | all at once | default / one | default / all |")
        p("|---|---|---|---|---|---|")
        cfg = {"one": ["-j", "1"], "default": [], "all": ["-j", str(cpus)]}
        for name in ["512K", "1M", "2M", "4M", "8M", "16M", "32M", "64M"]:
            r = {k: ([], []) for k in cfg}
            for wl, wa in WORKLOADS.items():
                m = h.measure(regime, cfg, name, wa)
                for k in cfg:
                    r[k][0].append(m[k][0])
                    r[k][1].append(m[k][1])
            g = {k: (geomean(r[k][0]), geomean(r[k][1])) for k in cfg}
            p(f"| {name} | {g['one'][0]:.2f} ({g['one'][1]:.2f}) | {g['default'][0]:.2f} ({g['default'][1]:.2f}) | "
              f"{g['all'][0]:.2f} ({g['all'][1]:.2f}) | {g['default'][0] / g['one'][0]:.2f} | "
              f"{g['default'][0] / g['all'][0]:.2f} |")
        p("")
        sys.stdout.flush()

    text = "\n".join(out)
    print(text)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
