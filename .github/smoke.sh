#!/usr/bin/env bash
# Compares zg's output with grep -F's on a file of a few tens of MB (enough chunks for
# several threads): plain, -n, -c and -m, for patterns from frequent to absent.
#   .github/smoke.sh ZG [LEVEL...]   with levels, runs each under ZG_CPU_LEVEL=LEVEL
set -euo pipefail
zg=$1
shift
levels=("$@")
[ ${#levels[@]} -eq 0 ] && levels=("")
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
for _ in $(seq 3000); do cat README.md README.zh-CN.md; done > "$dir/big.txt"
fail=0
for level in "${levels[@]}"; do
  for pattern in the zg SIMD 'ripgrep' 'needle_not_there' 'x'; do
    for flags in "" "-n" "-c" "-m 5" "-n -m 1000"; do
      grep -F $flags -- "$pattern" "$dir/big.txt" > "$dir/want" || true
      ZG_CPU_LEVEL=$level "$zg" $flags -- "$pattern" "$dir/big.txt" > "$dir/got" || true
      if ! cmp -s "$dir/want" "$dir/got"; then
        echo "MISMATCH level=${level:-default} flags='$flags' pattern='$pattern'"
        fail=1
      fi
    done
  done
  echo "level ${level:-default}: done"
done
"$zg" --version
exit $fail
