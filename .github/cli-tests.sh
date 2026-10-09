#!/usr/bin/env bash
# The command line beyond its output on a file (that is smoke.sh's): standard input in its
# forms, error messages and exit statuses, options, and a file truncated during a search.
#   .github/cli-tests.sh ZG      (from the repository root: it searches README.md)
set -uo pipefail
zg=$1
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
fail=0

check() { # what, got, want
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1"
    echo "  got:  $2"
    echo "  want: $3"
    fail=1
  fi
}

# Runs ZG with arguments; sets $out, $err and $rc.
run() {
  out=$("$zg" "$@" 2>"$dir/err" </dev/null)
  rc=$?
  err=$(cat "$dir/err")
}

printf 'hello world\nfoo\nHello\nhello again\n' > "$dir/a.txt"
for _ in $(seq 3000); do cat README.md README.zh-CN.md; done > "$dir/big.txt"

# --- standard input, in each form, gives what a file gives (and grep -F)
for pattern in the zg needle_not_there; do
  for flags in "" "-n" "-c" "-m 5"; do
    # shellcheck disable=SC2086
    grep -F $flags -- "$pattern" "$dir/big.txt" > "$dir/want" || true
    # shellcheck disable=SC2086
    cat "$dir/big.txt" | "$zg" $flags -- "$pattern" - > "$dir/got1" || true
    # shellcheck disable=SC2086
    cat "$dir/big.txt" | "$zg" $flags -- "$pattern" > "$dir/got2" || true
    # shellcheck disable=SC2086
    "$zg" $flags -- "$pattern" < "$dir/big.txt" > "$dir/got3" || true
    # shellcheck disable=SC2086
    cat "$dir/big.txt" | "$zg" $flags -- "$pattern" /dev/stdin > "$dir/got4" || true
    for k in 1 2 3 4; do
      cmp -s "$dir/want" "$dir/got$k" || { echo "FAIL: stdin form $k, flags '$flags', pattern '$pattern'"; fail=1; }
    done
  done
done
check "a pipe" "$(echo hello | "$zg" hello)" "hello"
check "a pipe, -" "$(echo hello | "$zg" hello -)" "hello"
check "a process substitution" "$("$zg" -c hello <(cat "$dir/a.txt"))" "2"
check "an empty pipe, -c" "$(: | "$zg" -c hello)" "0"
: | "$zg" hello; check "an empty pipe, status" "$?" "1"
echo hello | "$zg" hello > /dev/null; check "a pipe, status of a match" "$?" "0"
echo hello | "$zg" nope > /dev/null; check "a pipe, status of no match" "$?" "1"

# --- error messages and statuses
expect_error() { # what, status, text in the message, zg arguments...
  local what=$1 want_rc=$2 text=$3
  shift 3
  run "$@"
  check "$what: status" "$rc" "$want_rc"
  case "$err" in *"$text"*) ;; *) echo "FAIL: $what: message '$err' lacks '$text'"; fail=1 ;; esac
  check "$what: nothing on standard output" "$out" ""
}
expect_error "a missing file" 2 "No such file or directory" hello "$dir/missing.txt"
expect_error "a directory" 2 "Is a directory" hello "$dir"
expect_error "two files" 2 "too many arguments" hello "$dir/a.txt" "$dir/a.txt"
expect_error "an empty pattern" 2 "the pattern is empty" "" "$dir/a.txt"
expect_error "a pattern with a newline" 2 "contains a newline" $'a\nb' "$dir/a.txt"
expect_error "no pattern" 2 "usage:"
expect_error "-i" 2 "option '-i' is not supported" -i hello "$dir/a.txt"
expect_error "-A1" 2 "option '-A' is not supported" -A1 hello "$dir/a.txt"
expect_error "-ni" 2 "option '-i' is not supported" -ni hello "$dir/a.txt"
expect_error "--color" 2 "option '--color' is not supported" --color hello "$dir/a.txt"
expect_error "an unknown option" 2 "unknown option '--bogus'" --bogus hello "$dir/a.txt"
expect_error "a bad --io" 2 "bad --io value 'zzz'" --io=zzz hello "$dir/a.txt"
expect_error "a bad -m" 2 "bad match count 'x'" -m x hello "$dir/a.txt"
expect_error "-m without a value" 2 "-m needs a value" hello "$dir/a.txt" -m
if [ "$(id -u)" != 0 ]; then
  : > "$dir/noperm.txt"
  chmod 000 "$dir/noperm.txt"
  expect_error "an unreadable file" 2 "Permission denied" hello "$dir/noperm.txt"
fi

# --- options
check "-m1" "$("$zg" -m1 hello "$dir/a.txt")" "hello world"
check "-nm 1" "$("$zg" -nm 1 hello "$dir/a.txt")" "1:hello world"
check "-nc" "$("$zg" -nc hello "$dir/a.txt")" "2"
check "-F and -a are accepted" "$("$zg" -Fa -c hello "$dir/a.txt")" "2"
check "-j2" "$("$zg" -j2 -c hello "$dir/a.txt")" "2"
check "an empty file" "$("$zg" -c hello /dev/null)" "0"
run --help
check "--help: status" "$rc" "0"
case "$out" in usage:*) ;; *) echo "FAIL: --help prints the usage on standard output"; fail=1 ;; esac
run --version
case "$out" in "zg "*) ;; *) echo "FAIL: --version: '$out'"; fail=1 ;; esac

# --- a file truncated during a search: an error, not a signal (status 128 + signal)
# A small --mem and a consumer that waits keep the search from finishing before the file is
# cut. On macOS the private mapping keeps showing the old contents: the search may finish.
for io in mmap auto; do
  cp "$dir/big.txt" "$dir/t.txt"
  ( "$zg" --mem=8M --io=$io -n e "$dir/t.txt" 2> "$dir/trunc.err" | (sleep 2; cat > /dev/null); echo "${PIPESTATUS[0]}" > "$dir/trunc.rc" ) &
  sleep 0.6
  : > "$dir/t.txt"
  wait
  rc=$(cat "$dir/trunc.rc")
  if [ "$rc" -ge 128 ]; then
    echo "FAIL: truncation, --io=$io: killed by signal $((rc - 128))"
    fail=1
  elif [ "$(uname -s)" = Linux ] && [ "$io" = mmap ]; then
    check "truncation, --io=mmap: status" "$rc" "2"
    case "$(cat "$dir/trunc.err")" in *"the file changed"*) ;; *) echo "FAIL: truncation message: $(cat "$dir/trunc.err")"; fail=1 ;; esac
  fi
done

[ $fail = 0 ] && echo "command line: all checks passed"
exit $fail
