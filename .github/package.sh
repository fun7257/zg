#!/usr/bin/env bash
# Builds, checks and packs the binary of a release for one system:
#
#   .github/package.sh NAME [ZIG BUILD FLAGS...]      e.g. x86_64-linux -Dcpu=baseline
#
# Writes dist/zg-VERSION-NAME.tar.gz with zg, LICENSE and the READMEs. VERSION is the one in
# build.zig.zon; it must be the one the binary reports, and the tag's (when run for a tag). The
# binary is built stripped, then tested as it will be shipped: output against grep -F, and the
# command line (.github/smoke.sh, .github/cli-tests.sh). LEVELS="v1 v2 v3" runs the first at
# each CPU level of a portable x86-64 build.
set -euo pipefail

name=${1:?usage: package.sh NAME [ZIG BUILD FLAGS...]}
shift
version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' build.zig.zon)
[ -n "$version" ] || { echo "no version in build.zig.zon" >&2; exit 1; }
if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ "$GITHUB_REF_NAME" != "v$version" ]; then
  echo "the tag $GITHUB_REF_NAME is not v$version (build.zig.zon)" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
zig build install --prefix-exe-dir "$stage" -Dstrip=true "$@"
bin=$stage/zg

reported=$("$bin" --version | head -1)
[ "$reported" = "zg $version" ] || { echo "the binary says '$reported', not 'zg $version'" >&2; exit 1; }

# Static on Linux: it runs on any distribution.
if [ "$(uname -s)" = Linux ] && ldd "$bin" > /dev/null 2>&1; then
  echo "the binary is dynamically linked" >&2
  exit 1
fi

# shellcheck disable=SC2086
.github/smoke.sh "$bin" ${LEVELS:-}
.github/cli-tests.sh "$bin"

pkg=zg-$version-$name
rm -rf "dist/$pkg" "dist/$pkg.tar.gz"
mkdir -p "dist/$pkg"
cp "$bin" LICENSE README.md README.zh-CN.md "dist/$pkg/"
tar -czf "dist/$pkg.tar.gz" -C dist "$pkg"
rm -rf "dist/$pkg"
echo "dist/$pkg.tar.gz: $(wc -c < "dist/$pkg.tar.gz") bytes"
