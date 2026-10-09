#!/usr/bin/env bash
# Performance run for CI and by hand: zg against ripgrep on this machine and, with --base, the
# build under test against another build of zg (alternating runs, so noise on the machine
# affects both alike). Writes Markdown to stdout.
#
#   .github/bench.sh [--base ZG_BINARY] [--runs N] [--dir CORPUS] [--fail-regression PERCENT]
#                    [--bin DIR]
#
# Needs DIR/{zg,compare,gen} (default zig-out/bin, from `zig build`) and rg on the PATH. The corpus (about 2.4 GB)
# is generated in CORPUS (default: ./bench-corpus) if it is not there yet.
set -euo pipefail

base=""
runs=11
dir=bench-corpus
fail=0
bin=zig-out/bin
while [ $# -gt 0 ]; do
  case $1 in
    --base) base=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --dir) dir=$2; shift 2 ;;
    --fail-regression) fail=$2; shift 2 ;;
    --bin) bin=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
command -v rg >/dev/null || { echo "rg not found" >&2; exit 2; }

echo "# zg performance"
echo
echo '```'
case "$(uname -s)" in
  Linux)
    echo "cpu:    $(lscpu | sed -n 's/^Model name: *//p' | head -1) ($(nproc) CPUs)"
    echo "memory: $(free -g | awk '/^Mem:/ {print $2}') GB" ;;
  Darwin)
    echo "cpu:    $(sysctl -n machdep.cpu.brand_string) ($(sysctl -n hw.ncpu) CPUs)"
    echo "memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB" ;;
esac
echo "system: $(uname -sr) $(uname -m)"
echo "rg:     $(rg --version | head -1)"
echo "zg:     $($bin/zg --version | tr '\n' ' ')"
[ -n "$base" ] && echo "base:   $($base --version | tr '\n' ' ')"
echo '```'
echo

if [ ! -f "$dir/words.txt" ] || [ ! -f "$dir/w64m.txt" ]; then
  "$bin/gen" "$dir" >/dev/null 2>&1
fi

# Both tools print their tables to stderr/stdout; one stream for the report.
if [ -n "$base" ]; then
  # Cases and outputs of the default list: A is the base, B the build under test.
  "$bin/compare" --dir "$dir" --runs "$runs" --sections ab --zg "$base" --zg-b "$bin/zg" \
    --fail-regression "$fail" 2>&1 || status=$?
  echo
fi
"$bin/compare" --dir "$dir" --runs "$runs" --sections warm,small 2>&1
exit "${status:-0}"
