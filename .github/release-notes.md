zg searches one file (or standard input) for an exact, case-sensitive byte string and prints the
lines that contain it, like `grep -F` or `rg -F`, with SIMD inside chunks of the file and every
core across them. Measured on the CI runners (Linux x86-64, Linux arm64, macOS), with the file in
the page cache, it is 3.2 to 4.4 times faster than ripgrep on all cores and 1.35 to 1.7 times on one
thread (geometric mean over the 39 standard cases); on a cold read from a slow disk both wait for
the disk. No regular expressions, no
`-i`, no directories. See the [README](https://github.com/fun7257/zg#readme).

## Install

Download the archive for your system, check it, unpack it, and put `zg` on your `PATH`:

```
sha256sum -c --ignore-missing SHA256SUMS      # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
tar xzf zg-VERSION-x86_64-linux.tar.gz
install zg-VERSION-x86_64-linux/zg ~/.local/bin/
zg --version
```

| file | for |
|---|---|
| `zg-VERSION-x86_64-linux.tar.gz` | Linux on x86-64, static. One binary with three cores (SSE2, SSE4.2, AVX2): the one the CPU supports is chosen at start-up. |
| `zg-VERSION-aarch64-linux.tar.gz` | Linux on arm64 (ARMv8-A with NEON), static. |
| `zg-VERSION-aarch64-macos.tar.gz` | macOS on Apple Silicon (M1 and later). Not notarized: if it was downloaded with a browser and macOS refuses to open it, run `xattr -d com.apple.quarantine zg` once (a download with `curl` is not affected). |

Not built: Windows, and macOS on Intel. To build for another system: `zig build -Doptimize=ReleaseFast`
with Zig 0.16 (see the README).
