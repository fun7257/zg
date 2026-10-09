#!/usr/bin/env bash
# Every CPU level of one platform, one after the other on this machine, so that the levels can be
# compared with each other (a hosted runner is a different CPU model from one job to the next).
# One report per level, from .github/bench.sh, in OUT.
#
#   .github/bench-variants.sh x86|arm|mac [--out DIR] [--runs N] [--base-ref REF]
#                             [--threshold PERCENT] [--corpus DIR] [--sections LIST]
#
#   x86: v1, v2, v3 (the cores of one portable build, `-Dcpu=baseline`, run in turn with
#        ZG_CPU_LEVEL), v4 (a build for x86-64-v4, where the CPU has AVX-512) and native (the
#        build for this CPU)
#   arm: baseline (ARMv8-A with NEON) and native
#   mac: native (Zig's baseline for macOS arm64 is the M1: the same build)
#
# --base-ref: also compare each level with that commit, built the same way.
# --sections: for every level, instead of warm,single,worst,small (native: also mem, and cold on
# Linux).
set -uo pipefail

platform=${1:?platform: x86, arm or mac}
shift
out=bench-out
runs=9
base_ref=""
threshold=15
corpus=bench-corpus
sections_override=""
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --base-ref) base_ref=$2; shift 2 ;;
    --threshold) threshold=$2; shift 2 ;;
    --corpus) corpus=$2; shift 2 ;;
    --sections) sections_override=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

case $platform in
  x86) name="Linux x86-64"; variants="v1 v2 v3 v4 native" ;;
  arm) name="Linux arm64"; variants="baseline native" ;;
  mac) name="macOS arm64"; variants="native" ;;
  *) echo "unknown platform $platform" >&2; exit 2 ;;
esac

work=$(mktemp -d)
trap 'git worktree remove --force "$work/base-src" 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$out"
out=$(cd "$out" && pwd)

# Builds with FLAGS (the head, and the base if there is one) into $work/KEY and $work/KEY-base.
build() {
  local key=$1 flags=$2
  [ -d "$work/$key" ] && return 0
  # shellcheck disable=SC2086
  zig build $flags --prefix "$work/$key" || return 1
  if [ -n "$base_ref" ]; then
    if [ ! -d "$work/base-src" ]; then
      git worktree add -q "$work/base-src" "$base_ref" || return 1
    fi
    # shellcheck disable=SC2086
    (cd "$work/base-src" && zig build $flags --prefix "$work/$key-base") || return 1
  fi
}

status=0
for v in $variants; do
  flags=""
  level=""
  label="$name, native"
  sections="warm,single,worst,small,mem"
  [ "$(uname -s)" = Linux ] && sections="$sections,cold"
  case $v in
    v1) flags=-Dcpu=baseline; level=v1; label="$name, v1 (SSE2)"; sections=warm,single,worst,small ;;
    v2) flags=-Dcpu=baseline; level=v2; label="$name, v2 (SSE4.2, POPCNT)"; sections=warm,single,worst,small ;;
    v3) flags=-Dcpu=baseline; level=v3; label="$name, v3 (AVX2, BMI2, FMA)"; sections=warm,single,worst,small ;;
    v4) flags=-Dcpu=x86_64_v4; label="$name, v4 (AVX-512)"; sections=warm,single,worst,small ;;
    baseline) flags=-Dcpu=baseline; label="$name, baseline (ARMv8-A, NEON)"; sections=warm,single,worst,small ;;
  esac
  [ -n "$sections_override" ] && sections=$sections_override
  report="$out/bench-$platform-$v.md"

  # The AVX-512 build only runs where the CPU has it.
  if [ "$v" = v4 ]; then
    ok=1
    for f in avx512f avx512bw avx512cd avx512dq avx512vl; do
      grep -qw "$f" /proc/cpuinfo 2>/dev/null || ok=0
    done
    if [ $ok = 0 ]; then
      printf '# zg performance\n\n```\nlabel:    %s\nskipped:  this CPU has no AVX-512\n```\n' "$label" > "$report"
      echo "== $label: skipped (no AVX-512)"
      continue
    fi
  fi

  # Levels that share a build (v1, v2, v3) share its key.
  key=${flags//[^a-zA-Z0-9_]/}
  key=${key:-native}
  echo "== $label: build"
  if ! build "$key" "$flags"; then
    printf '# zg performance\n\n```\nlabel:    %s\nskipped:  the build failed\n```\n' "$label" > "$report"
    status=1
    continue
  fi
  args=(--bin "$work/$key/bin" --runs "$runs" --sections "$sections" --label "$label" --dir "$corpus")
  [ -n "$level" ] && args+=(--level "$level")
  if [ -n "$base_ref" ]; then
    args+=(--base "$work/$key-base/bin/zg" --fail-regression "$threshold")
  fi
  echo "== $label: benchmark ($sections)"
  .github/bench.sh "${args[@]}" > "$report"
  rc=$?
  [ $rc -ne 0 ] && { echo "== $label: failed ($rc)"; status=1; }
  cat "$report"
done
exit $status
