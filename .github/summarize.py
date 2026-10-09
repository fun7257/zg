#!/usr/bin/env python3
"""Merges the reports of .github/bench.sh (one per platform and CPU level) into one.

    summarize.py REPORT.md... > summary.md [--csv results.csv]

Prints the headline table (zg against ripgrep, geometric mean over the cases, per section), the
change against the base where the reports have one, a few single cases side by side, and for each
report its machine. With --csv, writes the rows of the timing tables (the memory table is only in
the reports). The tables are compare's: this
reads its text, so the two change together.
"""
import csv
import math
import re
import sys

SECTIONS = [
    ("warm", "Warm cache, all cores"),
    ("single", "Warm cache, one thread"),
    ("worst", "Worst cases, all cores"),
    ("worst1", "Worst cases, one thread"),
    ("small", "Small files and -m"),
]
# Cases shown side by side: (file, pattern, output) in the all-cores table.
HIGHLIGHTS = [
    ("words.txt", "needle_zz", "-c"),
    ("words.txt", "the", "lines"),
    ("words.txt", "a", "-n"),
    ("log.txt", "ERROR", "lines"),
    ("log.txt", "ERROR", "-c"),
    ("short.txt", "a", "lines"),
    ("long.txt", "th", "lines"),
]


def section_key(title):
    t = title.lower()
    if t.startswith("worst cases, all"):
        return "worst"
    if t.startswith("worst cases, one"):
        return "worst1"
    if t.startswith("warm cache, all"):
        return "warm"
    if t.startswith("warm cache, one"):
        return "single"
    if t.startswith("small files"):
        return "small"
    if t.startswith("cold"):
        return "cold"
    if t.startswith("peak"):
        return "mem"
    if t.startswith("a/b"):
        return "ab"
    return None


def cells(line):
    parts = [p.strip() for p in line.strip().strip("|").split("|")]
    return [p.strip("`") for p in parts]


def parse(path):
    r = {"path": path, "meta": {}, "stats": {}, "rows": [], "skipped": None}
    text = open(path, encoding="utf-8").read()
    block = re.search(r"```\n(.*?)\n```", text, re.S)
    if block:
        for line in block.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                r["meta"][k.strip()] = v.strip()
    r["skipped"] = r["meta"].get("skipped")
    section = None
    for line in text.splitlines():
        if line.startswith("## "):
            section = section_key(line[3:])
            continue
        m = re.match(r"speedup over (\d+) cells: min ([\d.]+)x, median ([\d.]+)x, geometric mean ([\d.]+)x, max ([\d.]+)x", line)
        if m and section:
            r["stats"].setdefault(section, {}).update(
                cells=int(m[1]), min=float(m[2]), median=float(m[3]), geo=float(m[4]), max=float(m[5]))
            continue
        m = re.match(r"CPU time, zg over rg: geometric mean ([\d.]+)x", line)
        if m and section:
            r["stats"].setdefault(section, {})["cpu"] = float(m[1])
            continue
        m = re.match(r"speedup over (\d+) cells: geometric mean ([\d.]+)x; CPU time, zg over rg: geometric mean ([\d.]+)x", line)
        if m and section:
            r["stats"].setdefault(section, {}).update(cells=int(m[1]), geo=float(m[2]), cpu=float(m[3]))
            continue
        m = re.match(r"B vs A over (\d+) cells: geometric mean ([\d.]+)x \(B (faster|slower) by ([\d.]+) %\), median ([\d.]+)x, worst ([\d.]+)x, best ([\d.]+)x; (\d+) cells", line)
        if m:
            r["stats"]["ab"] = dict(cells=int(m[1]), geo=float(m[2]), worst=float(m[6]), best=float(m[7]), slow=int(m[8]))
            continue
        if line.startswith("| ") and section and "---" not in line:
            c = cells(line)
            if section in ("warm", "single", "worst", "worst1") and len(c) == 9 and c[0] != "file":
                r["rows"].append((section, c))
            elif section == "small" and len(c) == 8 and c[0] != "file":
                r["rows"].append((section, c))
            elif section == "cold" and len(c) == 5 and c[0] != "pattern":
                r["rows"].append((section, c))
            elif section == "mem" and len(c) == 7 and c[0] != "file":
                r["rows"].append((section, c))
    return r


def x(v):
    return f"{v:.2f}x" if v is not None else "n/a"


def get(r, section, key):
    return r["stats"].get(section, {}).get(key)


def cold_speedup(r):
    sp = [float(c[4].rstrip("x")) for s, c in r["rows"] if s == "cold"]
    return f"{min(sp):.2f}x to {max(sp):.2f}x" if sp else "not measured"


def main(argv):
    csv_path = None
    paths = []
    it = iter(argv)
    for a in it:
        if a == "--csv":
            csv_path = next(it)
        else:
            paths.append(a)
    reports = [parse(p) for p in paths]
    reports.sort(key=lambda r: r["meta"].get("label", r["path"]))

    out = []
    out.append("# zg performance, all platforms\n")
    ran = [r for r in reports if not r["skipped"]]
    cpus = sorted({r["meta"].get("cpu", "?") for r in ran})
    skipped = len(reports) - len(ran)
    out.append(f"{len(ran)} runs" + (f" ({skipped} skipped)" if skipped else "") +
               f" on {len(cpus)} CPU model" + ("s" if len(cpus) != 1 else "") + "; "
               "every number is zg against ripgrep on the same machine, the median of the runs per case, "
               "and the geometric mean over the cases of the section. "
               "Read single cases as indications and the mean as the result.\n")

    out.append("## zg against ripgrep: how many times faster (geometric mean over the cases; the slowest case in brackets)\n")
    out.append("| platform and CPU level | machine | standard, all cores | standard, one thread | worst cases, all cores | worst cases, one thread | small files and `-m` | cold read |")
    out.append("|---|---|---|---|---|---|---|---|")
    for r in reports:
        label = r["meta"].get("label", r["path"])
        if r["skipped"]:
            out.append(f"| {label} | skipped: {r['skipped']} | | | | | | |")
            continue
        def cell(sec):
            g, m = get(r, sec, "geo"), get(r, sec, "min")
            return "n/a" if g is None else (f"**{g:.2f}x** ({m:.2f}x)" if m else f"**{g:.2f}x**")
        cpu = re.sub(r"\s*\(\d+ CPUs\)", "", r["meta"].get("cpu", ""))
        out.append(f"| {label} | {cpu} | {cell('warm')} | {cell('single')} | {cell('worst')} | {cell('worst1')} | {cell('small')} | {cold_speedup(r)} |")
    out.append("")

    out.append("## CPU time: zg over ripgrep (below 1: zg uses less CPU for the same search)\n")
    out.append("| platform and CPU level | standard, all cores | standard, one thread | worst, all cores | worst, one thread |")
    out.append("|---|---|---|---|---|")
    for r in ran:
        out.append(f"| {r['meta'].get('label', r['path'])} | " + " | ".join(x(get(r, s, 'cpu')) for s in ("warm", "single", "worst", "worst1")) + " |")
    out.append("")

    abs_ = [r for r in ran if "ab" in r["stats"]]
    if abs_:
        out.append("## This build against the base (alternating runs; above 1: faster than the base)\n")
        out.append("| platform and CPU level | geometric mean | worst case | best case | cases more than 5 % slower |")
        out.append("|---|---|---|---|---|")
        for r in abs_:
            a = r["stats"]["ab"]
            out.append(f"| {r['meta'].get('label', r['path'])} | **{a['geo']:.3f}x** | {a['worst']:.2f}x | {a['best']:.2f}x | {a['slow']} of {a['cells']} |")
        out.append("")

    out.append("## Single cases, all cores: zg ms / rg ms (speedup)\n")
    head = [r for r in ran]
    out.append("| case | " + " | ".join(r["meta"].get("label", r["path"]) for r in head) + " |")
    out.append("|---|" + "---|" * len(head))
    for f, p, o in HIGHLIGHTS:
        row = [f"{f} `{p}` {o}"]
        for r in head:
            hit = None
            for s, c in r["rows"]:
                if s in ("warm", "worst") and c[0] == f and c[1] == p and c[3] == o:
                    hit = c
                    break
            row.append(f"{hit[4]} / {hit[6]} ({hit[8]})" if hit else "")
        out.append("| " + " | ".join(row) + " |")
    out.append("")

    out.append("## Machines\n")
    out.append("| label | CPU | memory | instruction set extensions | zg |")
    out.append("|---|---|---|---|---|")
    for r in reports:
        m = r["meta"]
        if r["skipped"]:
            out.append(f"| {m.get('label', r['path'])} | skipped: {r['skipped']} | | | |")
            continue
        out.append(f"| {m.get('label', r['path'])} | {m.get('cpu', '')} | {m.get('memory', '')} | {m.get('features', '')} | {m.get('zg', '')}{' (' + m['level'] + ')' if 'level' in m else ''} |")
    out.append("")
    out.append("The levels of a platform ran one after the other on the same machine, so they can be compared with each other; platforms are not comparable with each other.\n")
    out.append("Each platform's full tables are in its own report (artifact `bench-*`) and every row of every "
               "table is in `results.csv`.\n")
    print("\n".join(out))

    if csv_path:
        with open(csv_path, "w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["label", "cpu", "section", "file", "pattern", "matches_or_flags", "output",
                        "zg_ms", "zg_cpu", "rg_ms", "rg_cpu", "speedup"])
            for r in ran:
                head = [r["meta"].get("label", ""), r["meta"].get("cpu", "")]
                for s, c in r["rows"]:
                    if s in ("warm", "single", "worst", "worst1"):
                        # zg_cpu and rg_cpu: CPU time over wall time (threads busy on average)
                        w.writerow(head + [s] + c)
                    elif s == "small":
                        # file, pattern, flags, zg ms, zg CPU ms, rg ms, rg CPU ms, speedup;
                        # here zg_cpu and rg_cpu are CPU milliseconds
                        w.writerow(head + [s, c[0], c[1], c[2], "", c[3], c[4], c[5], c[6], c[7]])
                    elif s == "cold":
                        # pattern, output, zg ms, rg ms, speedup (words.txt)
                        w.writerow(head + [s, "words.txt", c[0], "", c[1], c[2], "", c[3], "", c[4]])

if __name__ == "__main__":
    main(sys.argv[1:])
