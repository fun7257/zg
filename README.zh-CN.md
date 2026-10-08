# zg

[English](README.md)

用 Zig 0.16 写的单文件、按行、字面量快速搜索工具：块内用 SIMD，块之间用满所有核。提供命令行工具，也可以作为库嵌入服务。

```
$ zg -n ERROR app.log
2:2026-10-05T12:00:01.217 ERROR [http] req=04203afdc6de user=71909 latency=56ms path=/api/v3/items/31
13:2026-10-05T12:00:12.215 ERROR [sched] req=b5c34aff583d user=72210 latency=423ms path=/api/v1/items/422
...
```

zg 搜索一个精确、区分大小写的字节串，输出包含它的行，相当于对单个文件执行 `grep -F` 或 `rg -F`。在 8 核 Apple Silicon Mac 上、文件已在页缓存中时，全核比 ripgrep 快 1.9–17 倍，单线程最多快 3.6 倍（详见[性能](#性能)）。

范围：一个文件（或内存中的一段数据），字面量模式。不支持正则表达式、不区分大小写搜索和目录遍历。

## 命令行

```
zg [-n] [-c] [-m N] [-j N] [--io=auto|mmap|pread] [--mem=SIZE] [--] PATTERN FILE
```

| 选项 | |
|---|---|
| `-n` | 行首加行号 |
| `-c` | 只输出匹配行数 |
| `-m N` | 匹配 N 行后停止 |
| `-j N` | 线程数（默认每个 CPU 一个；内存上限不够时自动减少） |
| `--io=` | 读文件方式：`auto`（默认，搜索过程中实测选择）、`mmap` 或 `pread` |
| `--mem=SIZE` | zg 自己分配内存的上限，例如 `512M`、`4G`（默认：系统当前不换页就能给出的内存，最多物理内存的一半） |

退出码：有匹配为 0，没有匹配为 1，出错为 2。输出端提前关闭时（`| head`）安静退出。与 ripgrep 的一处差异：`-c` 没有匹配时输出 `0`（与 grep 相同），ripgrep 什么都不输出。

## 构建

需要 [Zig 0.16.0](https://ziglang.org/download/)。

```
zig build                  # 生成 zig-out/bin/zg，ReleaseFast
zig build test             # 运行测试，ReleaseSafe（加 -Dtest-optimize=Debug 用 Debug）
```

在 macOS（Apple Silicon）上开发和测试。Linux aarch64 和 x86_64 可以编译，测试也能编译，但还没有在 Linux 上实际运行过。x86 路径还没有专门调优。不支持 Windows（zg 依赖 `mmap`）。

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
  - 中止：`cancel`、`timeout_ns`，见下一条。
- 中止搜索：
  - 取消：设置 `cancel = &c`，其中 `c` 是一个 `zg.Cancel`，其它线程可以调用 `c.request()`，搜索随即以 `error.Canceled` 结束；
  - 超时：设置 `timeout_ns`，超时返回 `error.Timeout`；
  - 写出失败：写出端出错时（客户端断开，或者写出端自己限制了输出大小），搜索立即以 `error.WriteFailed` 结束。
- 错误：
  - zg 自己的：`error.EmptyPattern`、`error.PatternHasNewline`、`error.FileChanged`（搜索过程中文件变短了）、`error.TooManySearches`（共享引擎上同时超过 1024 个搜索）；
  - 另外还有写出端、文件和分配器返回的错误；
  - 库内不会退出进程，也不打印任何信息。

共享引擎的线程通过传给 `init` 的 `Io` 等待 futex。它是按 `std.Io.Threaded`（也就是 `std.process.Init` 提供的那个）设计的，还没有在事件驱动的 `Io` 下试过。

与"并排运行多个一次性搜索"相比，共享引擎多做了这些：

- **不超订**：同时工作的线程数不超过核数。调用 `search` 的线程也算在内，因为它要写出自己的输出，也会帮着处理块。
- **公平**：线程池按轮转从正在运行的搜索里领取块。被内存预算挡住的搜索（读得慢的客户端）会被跳过，不会占住线程。
- **共用内存**：所有搜索共用一个内存预算；输出缓冲区和读缓冲区跨搜索复用。
- **记住之前的测量**：
  - 256MB 以下：按之前同样大小的文件哪种读法最快（映射或 `pread`）来读，偶尔用另一种试一次；
  - 256MB 以上：块级选择从之前的测量值开始，不用重新预热。
- **文件被截断**：映射期间文件变短会触发 SIGBUS（Linux 上会；macOS 上 zg 用的私有映射仍显示旧内容）。信号处理器会把它转成对应搜索的 `error.FileChanged`，进程不会崩溃。不是 zg 映射引起的 SIGBUS，交还给原来的处理器。

## 工作原理

- **过滤**：
  - 取模式中两个稀有的字节，按它们的偏移一次比较一整个向量（memchr 的 packed-pair 方法，使用它的字节频率表）；这一对太常见时，再加最多两个字节。
  - 这个选择会在文件的 64KB 样本上检验：如果这一对在样本里其实很常见（比如日志里每一行都有 `latency=`），就通过实际计数换一个更稀有的组合。
  - 用几个过滤字节，由在样本上测得的代价模型决定。
- **最坏情况**：验证候选的开销超过扫描本身时，切换到 Two-Way 算法（Crochemore–Perrin），对抗输入下也保持线性时间。
- **切块**：
  - 文件切成若干字节范围，由各线程独立搜索。每块负责在它范围内开头的行。
  - 延伸到后面块的长行，由写出端根据后面各块的结果来判定。所以行再长也不额外占内存，处理它的工作也能分摊到多个线程。
  - `-n` 的行号来自扫描时顺带统计的换行数，按块的顺序依次公布。
- **读取**：
  - 每一块可以用三种方式读：带 `MADV_WILLNEED` 的映射、普通映射或 `pread`。哪种最快取决于系统状态，不只取决于文件是否在缓存里。
  - 所以各线程在文件本身上为这几种方式计时，持续使用最快的一种，并定期复查。
  - 小文件改用 `mincore` 抽样来判断。
- **输出**：
  - 每块把自己的行渲染进一个缓冲区，写出端按顺序写出已完成的块，等待期间自己也处理块。
  - 16KB 及以上的行直接从映射（或该块的 `pread` 缓冲区）写出，不拷贝。
- **内存**：
  - 有一个上限（见 `--mem`），其中三分之二作为待写出输出的预算。
  - 超出预算后，线程暂停领取新块，等写出端跟上（紧跟在写出端后面的块总能继续）；写完的缓冲区直接释放，不再保留。

## 性能

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

### 复现

```
zig build gen -- corpus                     # 生成上面的语料（约 2.4GB）
zig build compare -- --dir corpus           # 与 rg 对比：缓存热、单线程、内存、冷缓存
zig build bench -- corpus/words.txt the -n  # 进程内计时一次搜索
zig build stress -- corpus/words.txt small.txt   # 共享引擎上的并发搜索
```

`compare --sections ab --zg A --zg-b B` 会改为交替运行两个 zg 版本，用于 A/B 对比。

在 macOS 上测量的注意事项：
- 新编译的二进制要先运行一次再计时，因为它第一次运行时会被系统扫描；
- 页缓存的状态可能让单线程的结果相差很多，见 bench/results.md。

## 限制与计划

- `-m` 的 N 很小时，全核比 ripgrep 慢约 3ms，因为每个线程都会先搜完一整个 2MB 的块；单线程时两者持平。
- `searchLines` 提供行号，但还不提供字节偏移。
- 共享引擎上，一个输出大量行的大搜索在跑时，小搜索最多要等一个大块的处理时间（约 1.4ms）才能分到线程。
- 还没验证的：Linux 上的 SIGBUS 处理（只做了编译），共享引擎在事件驱动 `Io` 下的表现，x86 上的调优。
- 可能会做的：共享引擎按模式缓存调好参的过滤器（调参本身只要 0.02–0.5ms）。

## 许可证

[Apache License 2.0](LICENSE)
