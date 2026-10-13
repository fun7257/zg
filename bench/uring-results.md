# pread against io_uring

Measured 2026-10-13 on the same machine as [results-x86-linux.md](results-x86-linux.md): AMD Ryzen 7 7735U (Zen 3+, 8 cores / 16 threads, 512 KB of L2 per core, 16 MB of L3), 20 GB of LPDDR5, Samsung SSD 980 500GB, ext4 on `/dev/nvme0n1p2`, Debian 13 (Linux 6.12). The queue is `mq-deadline`, `read_ahead_kb` is 256, the logical block size is 512. `RLIMIT_MEMLOCK` is 8 MB, so registered buffers stay at 4 × 1 MB. SQPOLL is permitted. A desktop session was running.

The file is 2 GiB of `x` with a newline every 64 bytes, on the NVMe filesystem (`bench-corpus/uring.bin`, not tmpfs). Every read is positional and page-aligned, which is zg's `pread` rule: a copy whose source and destination sit at different offsets in a cache line is several times slower on x86. io_uring uses `IORING_OP_READ` into the same kind of buffer, several in flight per thread. `fixed` is `IORING_OP_READ_FIXED`. `defer` is `SINGLE_ISSUER | COOP_TASKRUN | DEFER_TASKRUN`.

Each cell is the median of 5 rounds. Inside a round the rows are rotated, so a clock that follows the order of the runs does not favour one row. GB/s is decimal (file bytes / seconds). The min and max are the spread of those 5. `ru_inblock` on every cold and direct row was 4194304, which is 2 GiB / 512, so those rows read the whole file from the device. `ru_majflt` stayed 0; the fault counter does not see this path. A pread and an io_uring scan of the file agreed on every byte, and so did `O_DIRECT`.

`scan` is the warm read plus a SIMD pass over every returned byte.

## Warm page cache

The destination buffer is reused, and at 256 KB it fits in a core's L2, so this is a streaming read of the page cache rather than a second trip to DRAM.

| threads | block | pread | io_uring | ratio |
|---|---|---|---|---|
| 1 | 64 KB | 15.34 GB/s | 14.35 (qd 64) | 0.94x |
| 1 | 256 KB | 15.64 | 15.61 (qd 32) | 1.00x |
| 1 | 4 MB | 16.14 | 9.44 (qd 32), 9.35 (qd 128) | 0.58x |
| 8 | 256 KB | 34.30 | 25.49 (qd 8) | 0.74x |
| 8 | 1 MB | 34.36 | 11.49 (qd 16) | 0.33x |
| 8 | 4 MB | 14.23 | 11.15 (qd 8) | 0.78x |
| 16 | 256 KB | 32.15 | 22.96 (qd 4) | 0.71x |
| 16 | 4 MB | 10.96 | 10.73 (qd 4) | 0.98x |

One thread, registered 1 MB buffers, queue depth 4: 17.35 GB/s. That is the best single thread, and it is half of the 8-thread pread. `defer` on the 64 KB row did not move it (14.32 GB/s).

The 8-thread pread of 256 KB or 1 MB, one buffer per thread, is the ceiling on this machine: 34.3 GB/s, spread 61.4–63.5 ms. A deep queue of large buffers misses. Eight threads with 16 buffers of 1 MB is 128 MB of destinations, past L2 and L3, and that row is 11.5 GB/s. The 4 MB pread is the same effect with one buffer: 14 GB/s. Sixteen threads do not beat eight.

## Cold page cache

`POSIX_FADV_DONTNEED` before each run.

| threads | block | pread | io_uring | ratio |
|---|---|---|---|---|
| 1 | 1 MB | 1.96 GB/s | 2.62 (qd 32), 2.59 (qd 128) | 1.34x |
| 4 | 1 MB | 2.65 | 2.64 (qd 32) | 1.00x |
| 8 | 1 MB | 2.64 | 2.68 (qd 16) | 1.02x |
| 8 | 4 MB | 2.64 | 2.67 (qd 8) | 1.01x |

One io_uring thread reaches the plateau that 4 or 8 pread threads already sit on, about 2.65 GB/s. Nothing in the table goes past 2.68. Registered buffers, `defer` and SQPOLL are on that same plateau (2.58–2.62).

## O_DIRECT

| threads | block | pread | io_uring | ratio |
|---|---|---|---|---|
| 1 | 1 MB | 2.15 GB/s | 3.16 (qd 32), 3.16 (qd 128) | 1.47x |
| 4 | 1 MB | 2.66 | 2.72 (qd 32) | 1.02x |
| 8 | 1 MB | 2.66 | 2.72 (qd 16) | 1.02x |
| 8 | 4 MB | 2.72 | 2.73 (qd 8) | 1.00x |

One thread, 1 MB, queue depth 32, is 3.16 GB/s (678.8–680.7 ms). Queue depth 128, SQPOLL, `defer` and registered buffers at depth 4 are the same number. That is the 980's rated 3100 MB/s sequential read. Several threads, pread or io_uring, fall back to about 2.7 GB/s: the drive wants one sequential stream with depth, not several streams. `IORING_SETUP_IOPOLL` completed with `EOPNOTSUPP`.

## Scan

Touching every byte, 8 threads, 256 KB: pread 34.75 GB/s, io_uring 23.29 GB/s. The touch hits the buffer that is already in L2, so the ceiling does not move. One thread drops from 15.6 GB/s to 12.9 GB/s, and pread and io_uring stay tied. The ring never gets ahead by overlapping the scan with the next read, because the scan is not the pipe that is full.

## What this says for zg

zg's chunk is one core's share of L2, and a thread has one `pread` buffer. That is the row that read the page cache at 34 GB/s. Replacing it with an io_uring queue makes the warm path slower as soon as the buffers spill out of L2.

On a cold file the buffered plateau is 2.65 GB/s, and zg already gets there by using several threads. io_uring gets one thread there and does not lift the plateau. `O_DIRECT` with one ring reaches 3.16 GB/s, about 0.5 GB/s more, and then the next search does not find the file in the page cache. That is a different access method, not a faster `pread`.
