# zg

[English](README.md) · [![CI](https://github.com/fun7257/zg/actions/workflows/ci.yml/badge.svg)](https://github.com/fun7257/zg/actions/workflows/ci.yml)

用 Zig 0.17 写的单文件、按行、字面量快速搜索工具：块内用 SIMD，块之间用满所有核。提供命令行工具，也可以作为库嵌入服务。

```
$ zg -n ERROR app.log
2:2026-10-05T12:00:01.217 ERROR [http] req=04203afdc6de user=71909 latency=56ms path=/api/v3/items/31
13:2026-10-05T12:00:12.215 ERROR [sched] req=b5c34aff583d user=72210 latency=423ms path=/api/v1/items/422
...
```

zg 搜索一个精确、区分大小写的字节串，输出包含它的行，相当于对单个文件执行 `grep -F` 或 `rg -F`。文件已在页缓存中时，全核在 8 核 Apple Silicon Mac 上比 ripgrep 快 1.9–17 倍，在 8 核 x86-64 Linux 笔记本上快 2.6–37 倍；单线程分别最多快 3.6 倍和 4.3 倍（详见[性能](#性能)）。

范围：一个文件（或内存中的一段数据），字面量模式。不支持正则表达式、不区分大小写搜索和目录遍历。

## 命令行

```
zg [-n] [-c] [-m N] [-j N] [--io=auto|mmap|pread] [--mem=SIZE] [--] PATTERN [FILE]
zg --version
```

不给 `FILE`，或给 `-`，就搜索标准输入：`some-command | zg ERROR`。短选项可以合并，值可以紧跟在选项后：`-nc`、`-m5`、`-nm 5`。

| 选项 | |
|---|---|
| `-n` | 行首加行号 |
| `-c` | 只输出匹配行数 |
| `-m N` | 匹配 N 行后停止 |
| `-j N` | 线程数（默认按实际收益决定，最多每个 CPU 一个，见[工作原理](#工作原理)；内存上限不够时也会减少） |
| `--io=` | 读文件方式：`auto`（默认，搜索过程中实测选择）、`mmap` 或 `pread` |
| `--mem=SIZE` | zg 自己分配内存的上限，例如 `64M`、`1G`（默认：线程所需的几倍，16 线程约 150MB，至少 32MB；低于它时，输出很多的搜索会变慢） |
| `-F`、`-a` | 接受但忽略：zg 始终按字节搜索字面量 |
| `--version`、`-V` | 版本、构建目标；可移植的 x86-64 构建还会显示在本机运行的级别（`running v3`） |

退出码：有匹配为 0，没有匹配为 1，出错为 2。输出端提前关闭时（`| head`）安静退出。与 ripgrep 的一处差异：`-c` 没有匹配时输出 `0`（与 grep 相同），ripgrep 什么都不输出。

**标准输入**（以及其他不是普通文件的输入：管道、`<(命令)`、`/dev/stdin`、读的时候由系统生成内容的文件，比如 `/proc` 下的）会先整个读进内存，上限是物理内存的一半（`--mem=SIZE` 可以改），然后再搜索：输入结束之前不会输出任何东西，所以 `tail -f log | zg ERROR` 什么也看不到，几十 GB 的管道输入则需要先存成文件。把普通文件作为标准输入（`zg ERROR < app.log`）则直接在原文件上搜索，从头开始，和文件参数一样。

**错误**是标准错误上的一行，有系统通用说法的用系统的说法（`zg: app.log: No such file or directory`），退出码 2。zg 不支持的功能（正则表达式、`-i`、`-v`、`-o`、上下文行、多个文件或目录）会明确说明：`zg: option '-i' is not supported: zg searches for a case-sensitive literal in one file or standard input`。

**搜索过程中文件被截断**（别的进程把它变短）会以 `zg: app.log: the file changed while it was being searched` 结束，退出码 2，进程不会被 SIGBUS 杀死（macOS 上 zg 用的私有映射仍显示旧内容，搜索会正常结束）。

## 安装

预编译的程序在[发布页](https://github.com/fun7257/zg/releases)：Linux x86-64（一个静态二进制，内含 SSE2、SSE4.2、AVX2 三份核心，启动时选择）、Linux arm64，以及 Apple Silicon 的 macOS。下载后用 `SHA256SUMS` 校验，解压，把 `zg` 放进 `PATH`：

```
tar xzf zg-0.1.0-x86_64-linux.tar.gz
install zg-0.1.0-x86_64-linux/zg ~/.local/bin/
```

macOS 的程序没有经过公证：如果是用浏览器下载的，macOS 拒绝打开时，执行一次 `xattr -d com.apple.quarantine zg`。想自己编译，见下文。

## 构建

需要 [Zig 0.17.0](https://ziglang.org/download/)。

```
zig build                  # 生成 zig-out/bin/zg 和基准工具，ReleaseFast，按本机 CPU 编译
zig build install          # 只安装 zg，到 zig-out/bin（用 --prefix-exe-dir ~/.local/bin 指定别处）
zig build -Dcpu=baseline   # 可移植的 x86-64 二进制（见下）
zig build test             # 运行测试，ReleaseSafe（加 -Dtest-optimize=debug 用 Debug）
zig build test-levels      # 按本机支持的每个 x86-64 级别（v1、v2、v3）各跑一遍测试
```

为不支持 AVX2 的 x86-64 CPU 构建时（`-Dcpu=baseline`，或发布用的 `-Dtarget`），二进制里还会带上按 x86-64-v2 和 x86-64-v3 编译的核心，启动时用 `cpuid` 检测 CPU 支持哪一级，就运行哪一份。Zig 按模块指定目标 CPU，所以这几份是同一份源码放在不同模块里。在下文的 Ryzen 上，单线程在 540MB 缓存文件里计数一个稀有模式：按本机编译 68ms，可移植二进制 69ms，此前普通的基线构建要 155ms。`-Dcpu-dispatch=false` 可以关掉分派；`ZG_CPU_LEVEL=v1` 或 `v2` 可以强制使用较低的级别，用于测试。AVX-512（x86-64-v4）没有加入：这些代码还没有在支持它的 CPU 上运行过。

在 macOS（Apple Silicon）上开发；在 macOS 和 x86-64 Linux 上测试并测量过性能。CI（[.github/workflows/ci.yml](.github/workflows/ci.yml)）在 Linux x86-64、Linux aarch64 和 macOS（Apple Silicon）上构建并运行测试，把输出与 `grep -F` 对比；在 x86-64 上还会对可移植构建的每个级别分别跑测试和这项对比。不支持 Windows（zg 依赖 `mmap`）。

## 作为库使用

包导出模块 `zg`。添加依赖：

```
zig fetch --save git+https://github.com/fun7257/zg
```

在 `build.zig` 中：

```zig
const zg = b.dependency("zg", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zg", zg.module("zg"));
```

有两种引擎，对一次搜索的各个块执行的是同一份代码：

- `zg.Engine(.oneshot)`：每次搜索自己开线程、自己计算内存上限。命令行工具就是它的薄封装；`zg.run` 是它的简便写法。
- `zg.Engine(.shared)`：常驻引擎，适合服务端。所有同时进行的搜索共用一个线程池和一个内存上限；`search` 可以从多个线程同时调用。

```zig
const std = @import("std");
const zg = @import("zg");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var engine: zg.Engine(.shared) = try .init(io, init.gpa, .{});
    defer engine.deinit();

    const file = try std.Io.Dir.cwd().openFile(io, "app.log", .{});
    defer file.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const n = try engine.search(.{ .file = file }, .{ .pattern = "ERROR", .line_numbers = true }, &out.interface);
    std.debug.print("{d} matching lines\n", .{n});
}
```

- 输入（`zg.Source`）：`.{ .file = f }`，或用 `.{ .bytes = data }` 搜索已经在内存里的数据（比如请求体）。
- 输出：
  - 任意 `*std.Io.Writer`：各块完成后按文件顺序写出，例如写进 HTTP 分块响应。长行直接从文件映射写出，不经过拷贝。
  - `searchLines(src, opts, ctx, on_line)`：按顺序对每一个匹配行调用 `on_line(ctx, 行号, 行内容)`，例如用来生成 JSON。
- `zg.Options`：
  - 搜索内容和输出：`pattern`、`line_numbers`、`count_only`、`max_matches`；
  - 资源：`threads`（共享引擎上表示这次搜索最多用几个线程）、`io`、`memory_limit`（只用于一次性引擎）；
  - 中止：`cancel`、`timeout_ns`，见下一条；`truncation_guard`（一次性引擎）让搜索期间被截断的文件以 `error.FileChanged` 结束，而不是被 SIGBUS 杀死进程。
- 中止搜索：
  - 取消：设置 `cancel = &c`，其中 `c` 是一个 `zg.Cancel`，其它线程可以调用 `c.request()`，搜索随即以 `error.Canceled` 结束；
  - 超时：设置 `timeout_ns`，超时返回 `error.Timeout`；
  - 写出失败：写出端出错时（客户端断开，或者写出端自己限制了输出大小），搜索立即以 `error.WriteFailed` 结束。
- 错误：
  - zg 自己的：`error.EmptyPattern`、`error.PatternHasNewline`、`error.FileChanged`（搜索过程中文件变短了）、`error.TooManySearches`（共享引擎上同时超过 1024 个搜索）；
  - 另外还有写出端、文件和分配器返回的错误；
  - 库内不会退出进程，也不打印任何信息。

一次性引擎在搜索过程中按需启动线程。Zig 标准库会给每个线程分配一个 256KB 的信号备用栈，放在线程局部存储里，只用于栈溢出时打印堆栈跟踪；每启动一个线程都要把它清零，使启动慢约 7 倍（x86-64 Linux 上 130µs 对 17µs）。命令行工具在非 Debug 构建中关掉了它；嵌入 zg 的程序也可以在根文件里这样关掉：

```zig
pub const std_options: std.Options = .{ .signal_stack_size = null };
```

共享引擎的线程通过传给 `init` 的 `Io` 等待 futex。它是按 `std.Io.Threaded`（也就是 `std.process.Init` 提供的那个）设计的，还没有在事件驱动的 `Io` 下试过。

与"并排运行多个一次性搜索"相比，共享引擎多做了这些：

- **不超订**：同时工作的线程数不超过核数。调用 `search` 的线程也算在内，因为它要写出自己的输出，也会帮着处理块。
- **公平**：线程池按轮转从正在运行的搜索里领取块。被内存预算挡住的搜索（读得慢的客户端）会被跳过，不会占住线程。
- **共用内存**：所有搜索共用一个内存预算；输出缓冲区和读缓冲区跨搜索复用。
- **记住之前的测量**：
  - 256MB 以下：按之前同样大小的文件哪种读法最快（映射或 `pread`）来读，偶尔用另一种试一次；
  - 256MB 以上：块级选择从之前的测量值开始，不用重新预热（Linux 上 256MB 以上只用 `pread`：解除映射时，被映射方式缺页填充的页表要拆除，期间持有进程地址空间锁，其他搜索都要等）。
- **跨搜索保留**（256MB 以下的文件）：文件的映射（已缺页填好的页面）和每个模式在它上面调好的过滤器。文件变化（大小或修改时间）后会重新映射、重新调参。在 Ryzen 上，8MB 缓存文件的小搜索从 0.6ms 降到 0.1ms；有输出大量行的大搜索同时在跑时，小搜索的 p99 从 11ms 降到 4ms。
- **每个搜索的线程数按收益决定**，与一次性搜索相同（见下文）。
- 大搜索留下的缓冲区由空闲的池线程释放，而不是由恰好最后结束的那个搜索来做。
- **文件被截断**：映射期间文件变短会触发 SIGBUS（Linux 上会，测试中会在搜索进行时截断文件来验证；macOS 上 zg 用的私有映射仍显示旧内容）。信号处理器会把它转成对应搜索的 `error.FileChanged`，进程不会崩溃。不是 zg 映射引起的 SIGBUS，交还给原来的处理器。一次性搜索通过 `Options.truncation_guard` 获得同样的保护（命令行工具已打开）；那里默认关闭，因为信号处理器是进程级的。

## 工作原理

- **过滤**：
  - 取模式中两个稀有的字节，按它们的偏移一次比较一整个向量（memchr 的 packed-pair 方法，使用它的字节频率表）；这一对太常见时，再加最多两个字节。
  - 这个选择会在文件的 64KB 样本上检验：如果这一对在样本里其实很常见（比如日志里每一行都有 `latency=`），就通过实际计数换一个更稀有的组合。
  - 用几个过滤字节，由在样本上测得的代价模型决定。
- **最坏情况**：验证候选的开销超过扫描本身时，切换到 Two-Way 算法（Crochemore–Perrin），对抗输入下也保持线性时间。
- **切块**：
  - 文件切成若干字节范围，由各线程独立搜索。每块负责在它范围内开头的行。
  - 块最大为一个硬件线程分到的 L2 缓存（运行时从系统读取：Apple Silicon 上是 2MB，两个线程共享一个核的 Zen 3 上是 256KB），这样用 `pread` 读进来的数据在扫描时仍在缓存里。
  - 延伸到后面块的长行，由写出端根据后面各块的结果来判定。所以行再长也不额外占内存，处理它的工作也能分摊到多个线程。
  - `-n` 的行号来自扫描时顺带统计的换行数，按块的顺序依次公布。
- **读取**：
  - 每一块可以用三种方式读：带 `MADV_WILLNEED` 的映射、普通映射或 `pread`。哪种最快取决于系统状态，不只取决于文件是否在缓存里。
  - 所以各线程在文件本身上为这几种方式计时，持续使用最快的一种，并定期复查。
  - Linux 上，映射方式还要计入结束时解除映射的成本：这一步是串行的，块计时看不到（540MB 要 14ms）。所以 Linux 上缓存中的文件大多用 `pread` 读，并且从页边界开始读（x86 上源和目标在缓存行内偏移不同时，拷贝要慢好几倍）。
  - 小文件改用 `mincore` 抽样来判断。
- **输出**：
  - 每块把自己的行渲染进一个缓冲区，写出端按顺序写出已完成的块，等待期间自己也处理块。
  - 16KB 及以上的行直接从映射（或该块的 `pread` 缓冲区）写出，不拷贝。
- **线程**（未指定 `-j` 的搜索；共享引擎上指一个搜索放行的池线程）：参考 Suleman 等人的带宽感知线程选择（ASPLOS 2008），按实际收益启动。
  - 一次性搜索从调用线程开始，并由它启动的一个线程实测"此刻此机器上启动线程要多久"（空闲的核要 70 到 320µs 才执行第一条指令，刚用过的核 22 到 73µs，再加上线程第一块缓冲区的 100 到 290µs）。做完第一块后，调用线程知道单线程做完剩余部分要多久 W，按 T(n) = [W + (n-1)(L+s) + s·n(n-1)/2] / n 启动完成最快的 n 个线程（L 是线程的启动延迟，s 是启动并回收一个线程所花的时间），单线程更快就不启动（W > L + 2s 时 2 个线程才划算）。孤立线程测到的只是帮手线程真实代价的下限，两者的比值随机器而变，所以第一步只在这些实测代价本身就说值得时才启动线程、且最多按三倍代价允许的数量启动，再由启动的第一个线程实测自己的第一块，其余线程据此决定。这取代了按文件大小设阈值的做法，那样热状态下对、冷状态下错（2 MB 文件：核空闲之后单线程 3.1ms、8 线程 3.5ms；核刚用过则是 1.55ms 和 1.24ms）。Ryzen 7735U 上 4 到 32MB 的文件比一开始就每核一个线程少用 7% 到 24% 的时间、最多少用一半 CPU 时间；32MB 及以上的文件要为这段等待付出 0% 到 3%（第一块只取一个块的四分之一，为的是更早做决定）。带 `-m` 时只从调用线程开始，每做完一轮块就翻倍，因为这类搜索往往很早结束；共享引擎的池线程本来就在运行，所以搜索不做测量，直接每核放行一个（小文件少放行）。
  - 每个核的第二个硬件线程，只在搜索有计算可以重叠时才启动：用 `pread` 读的块里，至少一半时间花在扫描和渲染输出上，而不是从页缓存拷贝数据。否则多出的线程只会争抢内存带宽。例如在 8 核 Ryzen 上，540MB 缓存文件里找一个稀有模式，8 线程 24.3ms，16 线程 26.4ms；而输出 470 万行时，分别是 41.1ms 和 32.6ms。如果最初几块的占比就已经达到 0.75 以上，立即决定。
- **内存**：
  - 有一个上限（见 `--mem`），其中三分之二作为待写出输出的预算。默认值是线程所需内存的几倍（每个线程渲染输出时预留十几个块）：16 线程、256KB 块时约 150MB，这也是一次搜索最多用的内存，不管输出多少、读输出的一方多慢（读者停住时输出 400MB：用 110MB，而此前上限是内存的一半，用到了 588MB）。更多的内存没有让 zg 更快（输出几百万行的标准用例，128MB 与用全部内存一样快；64MB 最多慢 7%，32MB 最多慢 22%）。
  - 超出预算后，线程暂停领取新块，等写出端跟上（紧跟在写出端后面的块总能继续）；写完的缓冲区直接释放，不再保留。zg 快的关键是页缓存里的文件，那由系统保管，不计入 zg 的内存。

## 性能

### Apple Silicon（macOS）

测试方法：
- **计时**：每格取 15 次的中位数；zg 与 ripgrep 15.2（`rg -a -F --no-config`）交替运行；文件已在页缓存中。
- **机器**：8 核 Apple Silicon，8GB 内存，macOS。
- **语料**（由 `zig build gen` 生成）：540MB 单词（每行 3–14 个）、514MB 日志行、512MB 每行 20–600KB 的长行（`long.txt`）、300MB 每行 0–3 个字符的短行（`short.txt`）、512MB 随机字节。
- **输出**：写到 `/dev/null`，每个用例都与 ripgrep 的输出逐字节一致。

| | 全核：最小 / 几何平均 | 单线程：最小 / 几何平均 |
|---|---|---|
| 标准 39 格（单词、日志；输出整行、`-n`、`-c`） | 2.40x / 4.25x | 1.02x / 1.43x |
| 最坏 54 格（常见字节、长模式、压力语料） | 1.91x / 4.03x | 0.93x / 1.49x |

| 用例 | zg 全核 | ripgrep | zg 单线程 | ripgrep |
|---|---|---|---|---|
| 单词，`needle_zz`（1 行） | 22.6 ms | 54.3 ms | 54.2 ms | 56.3 ms |
| 单词，`the`（470 万行） | 46.2 ms | 376.8 ms | 228.2 ms | 380.1 ms |
| 单词，`a`，`-n`（930 万行） | 64.8 ms | 1132.0 ms | 320.8 ms | 1137.4 ms |
| 日志，`ERROR`（125 万行） | 27.1 ms | 129.7 ms | 80.8 ms | 129.6 ms |
| `short.txt`，`a`（3800 万行） | 124.9 ms | 1546.5 ms | 746.5 ms | 1549.9 ms |
| `long.txt`，`th`（1655 行） | 23.5 ms | 45.6 ms | 47.6 ms | 45.5 ms |

- **单线程落后的格子**：只有 `long.txt` 输出整行或 `-c`。测量时 macOS 正好让这个文件的映射访问变慢，zg 改用 `pread` 读，和 ripgrep 付同样的拷贝成本。
- **冷缓存**（第一次从磁盘读）：两者都受限于磁盘速度。
- **完整数据**：全部表格、对抗输入（zg 27ms，ripgrep 489ms）和内存占用，见 [bench/results.md](bench/results.md)。

共享引擎（进程内测试，`zig build stress`）：
- 单次搜索 540MB 文件用时 17.7ms；
- 2–16 个搜索并发时，每次 14.3–15.4ms，总吞吐保持住了；
- 一个输出数百万行的大搜索在跑的同时，8MB 小文件搜索的 p50 是 0.65ms，p99 是 2.0ms。

以上数据测于下文针对 x86-64 Linux 的改动之前。那些改动也涉及在 Mac 上运行的代码，之后还没有在 Mac 上重新测量。

### x86-64 Linux

同样的矩阵，机器为 AMD Ryzen 7 7735U（8 核 16 线程）、20GB 内存、Debian 13（Linux 6.12），ripgrep 14.1.1；每个用例的输出都与 ripgrep 逐字节一致。

| | 全核：最小 / 几何平均 | 单线程：最小 / 几何平均 |
|---|---|---|
| 标准 39 格 | 3.16x / 5.48x | 1.00x / 1.50x |
| 最坏 54 格 | 2.64x / 5.45x | 1.01x / 1.58x |
| 小文件（1–64MB）与 `-m` 共 10 格 | 1.16x / 2.03x | |

| 用例 | zg 全核 | ripgrep | zg 单线程 | ripgrep |
|---|---|---|---|---|
| 单词，`needle_zz`（1 行） | 25.2 ms | 81.8 ms | 69.4 ms | 82.2 ms |
| 单词，`the`（470 万行） | 30.9 ms | 378.4 ms | 203.1 ms | 383.8 ms |
| 单词，`a`，`-n`（930 万行） | 45.9 ms | 1019.7 ms | 281.1 ms | 983.4 ms |
| 日志，`ERROR`（125 万行） | 21.8 ms | 126.9 ms | 81.3 ms | 126.2 ms |
| `short.txt`，`a`（3800 万行） | 65.8 ms | 1702.3 ms | 394.8 ms | 1693.3 ms |
| `long.txt`，`th`（1655 行） | 24.2 ms | 63.9 ms | 56.2 ms | 63.4 ms |
| 单词，`the`，`-m 1` | 2.1 ms | 2.4 ms | | |

- **可移植构建**（`-Dcpu=baseline`）结果相同：标准用例单线程 1.03x / 1.50x（此前的基线构建是 0.49x / 0.78x，比 ripgrep 还慢）。
- **冷缓存**：190–215ms，ripgrep 是 291–427ms，接近这块 SSD 2.9GB/s 的读取上限。
- **共享引擎**：单次搜索 540MB 用时 21.6ms；8MB 文件的小搜索 0.1ms（p50），有输出大量行的大搜索同时在跑时 0.3ms（p99 3.7ms）。
- **完整数据**：全部表格，以及把第一轮 Linux 测量（全核几何平均 2.92 倍、单线程 1.39 倍）提升到上表的各项修复，见 [bench/results-x86-linux.md](bench/results-x86-linux.md)。

### 复现

```
zig build gen -- corpus                     # 生成上面的语料（约 2.4GB）
zig build compare -- --dir corpus           # 与 rg 对比：缓存热、单线程、小文件与 -m、内存、冷缓存
zig build bench -- corpus/words.txt the -n  # 进程内计时一次搜索
zig build stress -- corpus/words.txt small.txt   # 共享引擎上的并发搜索
```

`compare --sections ab --zg A --zg-b B` 会改为交替运行两个 zg 版本，用于 A/B 对比；`bench --chunk=SIZE` 用指定的块大小计时。

#### 性能 CI

想测一个改动的性能，就把它合并进 `perf` 分支：向 `perf` 推送或合并会触发 [`.github/workflows/bench.yml`](.github/workflows/bench.yml)，每个平台一个任务，任务里依次对该平台的每个 CPU 级别运行 `.github/bench.sh`（`.github/bench-variants.sh`），它们在同一台机器上跑：GitHub 托管机器的 CPU 型号每个任务都可能不同，所以只有在同一个任务里测出的级别才能互相比较。最后合成一份总报告（job summary，以及产物 `bench-summary`：`summary.md` 和 `results.csv`，后者是所有计时表的每一行）。

| 平台 | CPU 级别 |
|---|---|
| Linux x86-64 | native（运行机器自己的 CPU）；v1（SSE2）、v2（SSE4.2、POPCNT）、v3（AVX2、BMI2、FMA），即可移植构建里的三份核心依次运行；v4（AVX-512），按 x86-64-v4 编译的构建，只在运行机器的 CPU 支持时运行 |
| Linux arm64 | native（运行机器自己的 CPU）；baseline（ARMv8-A 加 NEON，zg 在所有 arm64 CPU 上用的就是它） |
| macOS arm64（Apple Silicon） | native（Zig 在 macOS arm64 上的 baseline 就是 M1，是同一个构建） |

每次运行测量 zg 对 ripgrep：39 个标准用例和 54 个最坏用例（常见字节、长模式、极长和极短的行、随机字节），全核和单线程各一遍，以及小文件和 `-m`；每个平台的 native 运行还测峰值内存，Linux 上还测第一次从磁盘读（macOS 不测冷读：运行机器的磁盘太小，放不下需要的拷贝）。还会把 `perf` 的新状态和推送之前的状态对比，两个版本在同一台机器上交替运行，共享机器的噪声对两边影响相同；39 个用例的几何平均慢 15% 以上就会失败（相同的构建在这里相差 1% 到 2%）；单个用例只能作参考。连续的推送会排队，不会互相取代。每周也会在 `main` 上跑一次（只对 ripgrep），也可以手动触发，用 `base_ref`（要对比的分支、标签或提交）、`runs` 和 `threshold` 参数。zg 自己没有 AVX-512 或 SVE 的代码：v4 和 native 两行显示的是让编译器使用这些指令的效果。在自己机器上：

```
zig build
.github/bench.sh                          # 对 ripgrep
.github/bench.sh --base ./zg-old --fail-regression 10   # 再与另一个构建对比
.github/bench.sh --sections warm,single,worst,small,mem,cold   # CI 跑的全部内容，再加上冷读
zig build -Dcpu=baseline --prefix p && .github/bench.sh --bin p/bin --level v1   # 指定一个 CPU 级别
.github/bench-variants.sh x86 --out reports   # 一个平台的所有级别，各出一份报告
python3 .github/summarize.py report1.md report2.md > summary.md   # 合并报告
```

在 macOS 上测量的注意事项：
- 新编译的二进制要先运行一次再计时，因为它第一次运行时会被系统扫描；
- 页缓存的状态可能让单线程的结果相差很多，见 bench/results.md。

## 限制与计划

- `-m` 的 N 很小时，Mac 上全核比 ripgrep 慢约 3ms（测于按需启动线程之前；Linux 笔记本上 zg 现在更快，2.0ms 对 2.6ms）。
- 结果受计算限制的搜索，要先在每核一个线程上测量，才会用满全部线程，比一开始就全部启动最多慢 4%（short.txt 上的 `-c a`）；其余搜索与用满全部线程一样快或更快。
- `searchLines` 提供行号，但还不提供字节偏移。
- 共享引擎上，一个输出大量行的大搜索在跑时，小搜索最多要等一个大块的处理时间（Mac 上约 1.4ms）才能分到线程；Linux 笔记本上 p99 是 3.7ms（空闲时 0.73ms），剩下的来自对进程地址空间锁的等待。
- 还没验证的：共享引擎在事件驱动 `Io` 下的表现，Linux aarch64，除这台 Zen 3+ 笔记本以外的 x86 机器。
- 可能会做的：AVX-512 内核（x86-64-v4），等有条件测量时再做。

## 许可证

[Apache License 2.0](LICENSE)
