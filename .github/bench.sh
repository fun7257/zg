#!/usr/bin/env bash
# Performance run for CI and by hand: zg against ripgrep on this machine and, with --base, the
# build under test against another build of zg (alternating runs, so noise on the machine
# affects both alike). Writes Markdown to stdout.
#
#   .github/bench.sh [--base ZG_BINARY] [--runs N] [--dir CORPUS] [--fail-regression PERCENT]
#                    [--bin DIR] [--sections LIST] [--level v1|v2|v3] [--label TEXT]
#
# Needs DIR/{zg,compare,gen} (default zig-out/bin, from `zig build`) and rg on the PATH. The
# corpus (about 2.4 GB) is generated in CORPUS (default: ./bench-corpus) if it is not there yet.
#
# Sections (compare's): warm and single (the 39 standard cases on all cores and on one thread),
# worst (54 stress cases, both ways), small (small files and -m), mem (peak memory) and cold
# (first read from disk; writes about 6.5 GB of copies). Default: warm,single,worst,small.
#
# --level runs a portable x86-64 build (`zig build -Dcpu=baseline`, which carries cores for
# x86-64 v1, v2 and v3) at that level, whatever the CPU supports.
set -euo pipefail

base=""
runs=11
dir=bench-corpus
fail=0
bin=zig-out/bin
sections=warm,single,worst,small
level=""
label=""
while [ $# -gt 0 ]; do
  case $1 in
    --base) base=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --fail-regression) fail=$2; shift 2 ;;
    --bin) bin=$2; shift 2 ;;
    --sections) sections=$2; shift 2 ;;
    --level) level=$2; shift 2 ;;
    --label) label=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
command -v rg >/dev/null || { echo "rg not found" >&2; exit 2; }
[ -n "$level" ] && export ZG_CPU_LEVEL=$level

# The instruction set extensions of this CPU that matter to zg, as the system names them.
features=""
case "$(uname -s)" in
  Linux)
    flags=$(grep -m1 -E '^(flags|Features)' /proc/cpuinfo || true)
    for f in sse2 ssse3 sse4_1 sse4_2 popcnt avx avx2 bmi1 bmi2 fma avx512f avx512bw avx512vl avx512vbmi \
             asimd asimddp sve sve2 sme; do
      case " $flags " in *" $f "*) features="$features $f" ;; esac
    done ;;
  Darwin)
    for f in FEAT_AdvSIMD FEAT_DotProd FEAT_FP16 FEAT_I8MM FEAT_BF16 FEAT_SME; do
      [ "$(sysctl -n "hw.optional.arm.$f" 2>/dev/null || true)" = 1 ] && features="$features ${f#FEAT_}"
    done ;;
esac

echo "# zg performance"
echo
echo '```'
[ -n "$label" ] && echo "label:    $label"
case "$(uname -s)" in
  Linux)
    echo "cpu:      $(lscpu | sed -n 's/^Model name: *//p' | head -1) ($(nproc) CPUs)"
    echo "memory:   $(awk '/^MemTotal:/ {printf "%d", $2 / 1048576 + 0.5}' /proc/meminfo) GB" ;;
  Darwin)
    echo "cpu:      $(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.ncpu) CPUs)"
    echo "memory:   $(( $(sysctl -n hw.memsize) / 1073741824 )) GB" ;;
esac
echo "features:${features:- none found}"
echo "system:   $(uname -sr) $(uname -m)"
echo "rg:       $(rg --version | head -1)"
echo "zg:       $($bin/zg --version | tr '\n' ' ')"
[ -n "$level" ] && echo "level:    ZG_CPU_LEVEL=$level"
[ -n "$base" ] && echo "base:     $($base --version | tr '\n' ' ')"
echo "sections: $sections, $runs runs per case"
echo '```'
echo

if [ ! -f "$dir/words.txt" ] || [ ! -f "$dir/w64m.txt" ]; then
  "$bin/gen" "$dir" >/dev/null 2>&1
fi

# compare prints its tables on stderr and stdout; one stream for the report.
status=0
if [ -n "$base" ]; then
  # The 39 standard cases: A is the base, B the build under test.
  "$bin/compare" --dir "$dir" --runs "$runs" --sections ab --zg "$base" --zg-b "$bin/zg" \
    --fail-regression "$fail" 2>&1 || status=$?
  echo
fi
"$bin/compare" --dir "$dir" --runs "$runs" --sections "$sections" --zg "$bin/zg" 2>&1
exit "$status"
