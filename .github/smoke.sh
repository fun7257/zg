#!/usr/bin/env bash
# Compares zg's output with grep -F's on files of 1 MB (one thread), 12 MB (a few threads) and
# 140 MB (a thread per core): plain, -n, -c and -m, for patterns from frequent to absent. How
# many threads a search gets depends on measured costs (`threadsForWork` in src/zg.zig).
#   .github/smoke.sh ZG [LEVEL...]   with levels, runs each under ZG_CPU_LEVEL=LEVEL
set -euo pipefail
zg=$1
shift
levels=("$@")
[ ${#levels[@]} -eq 0 ] && levels=("")
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
for _ in $(seq 3000); do cat README.md README.zh-CN.md; done > "$dir/big.txt"
# Whole lines, about 1 MB and 12 MB.
head -c 1000000 "$dir/big.txt" | sed '$d' > "$dir/small.txt"
head -c 12000000 "$dir/big.txt" | sed '$d' > "$dir/mid.txt"
fail=0
for level in "${levels[@]}"; do
  for file in small mid big; do
    for pattern in the zg SIMD 'ripgrep' 'needle_not_there' 'x'; do
      for flags in "" "-n" "-c" "-m 5" "-n -m 1000"; do
        grep -F $flags -- "$pattern" "$dir/$file.txt" > "$dir/want" || true
        ZG_CPU_LEVEL=$level "$zg" $flags -- "$pattern" "$dir/$file.txt" > "$dir/got" || true
        if ! cmp -s "$dir/want" "$dir/got"; then
          echo "MISMATCH level=${level:-default} file=$file flags='$flags' pattern='$pattern'"
          fail=1
        fi
      done
    done
  done
  echo "level ${level:-default}: done"
done
"$zg" --version
exit $fail
