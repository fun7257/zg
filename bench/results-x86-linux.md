# zg vs ripgrep on x86-64 Linux

Measured 2026-10-08 on an AMD Ryzen 7 7735U (Zen 3+, 8 cores / 16 threads, 512 KB of L2 per
core, 16 MB of L3), 20 GB of LPDDR5, NVMe SSD, Debian 13 (Linux 6.12), warm page cache. Every
cell is the median of 15 runs, zg and rg alternating, after one warm-up; rg 14.1.1 runs as
`rg -a -F --no-config`. The corpora come from `zig build gen` and the tables from
`zig build compare` (`--sections warm,single,small,mem,cold`, plus `--case` for the worst
cases). The machine is a laptop with a desktop session running: expect a few percent of noise.

Output verified identical to rg for all 39 standard, 54 worst and 10 small-file cases, by
the native build and by the portable one (`-Dcpu=baseline`).

For the Apple Silicon numbers see [results.md](results.md).

## Warm cache, all cores

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | 1 | lines | 25.2 | 7.1x | 81.8 | 1.0x | 3.25x |
| words.txt | `needle_zz` | 1 | -n | 26.4 | 6.5x | 108.7 | 1.0x | 4.11x |
| words.txt | `needle_zz` | 1 | -c | 25.2 | 7.0x | 82.0 | 1.0x | 3.25x |
| words.txt | `qzxjv` | 0 | lines | 25.3 | 7.0x | 82.3 | 1.0x | 3.25x |
| words.txt | `qzxjv` | 0 | -n | 25.7 | 6.8x | 81.5 | 1.0x | 3.17x |
| words.txt | `qzxjv` | 0 | -c | 25.4 | 7.0x | 81.7 | 1.0x | 3.22x |
| words.txt | `zebra` | 33512 | lines | 25.8 | 7.0x | 85.3 | 1.0x | 3.30x |
| words.txt | `zebra` | 33512 | -n | 25.9 | 6.8x | 97.7 | 1.0x | 3.78x |
| words.txt | `zebra` | 33512 | -c | 25.3 | 7.1x | 84.7 | 1.0x | 3.34x |
| words.txt | `xq` | 37320 | lines | 25.8 | 7.0x | 82.9 | 1.0x | 3.22x |
| words.txt | `xq` | 37320 | -n | 27.2 | 6.3x | 95.4 | 1.0x | 3.50x |
| words.txt | `xq` | 37320 | -c | 25.4 | 7.1x | 81.6 | 1.0x | 3.22x |
| words.txt | `ing ` | 2100750 | lines | 27.8 | 12.6x | 260.3 | 1.0x | 9.37x |
| words.txt | `ing ` | 2100750 | -n | 30.3 | 7.1x | 379.9 | 1.0x | 12.52x |
| words.txt | `ing ` | 2100750 | -c | 25.4 | 7.0x | 218.6 | 1.0x | 8.60x |
| words.txt | `the` | 4675899 | lines | 30.9 | 12.9x | 378.4 | 1.0x | 12.24x |
| words.txt | `the` | 4675899 | -n | 38.9 | 11.5x | 636.9 | 1.0x | 16.38x |
| words.txt | `the` | 4675899 | -c | 26.5 | 13.2x | 311.1 | 1.0x | 11.76x |
| words.txt | `a` | 9303679 | lines | 37.1 | 12.5x | 555.5 | 1.0x | 14.96x |
| words.txt | `a` | 9303679 | -n | 45.9 | 12.3x | 1019.7 | 1.0x | 22.21x |
| words.txt | `a` | 9303679 | -c | 26.4 | 13.3x | 450.4 | 1.0x | 17.08x |
| log.txt | `unique_token_7731` | 1 | lines | 20.9 | 6.8x | 67.2 | 1.0x | 3.22x |
| log.txt | `unique_token_7731` | 1 | -n | 21.3 | 6.6x | 92.0 | 1.0x | 4.31x |
| log.txt | `unique_token_7731` | 1 | -c | 21.2 | 6.9x | 66.9 | 1.0x | 3.16x |
| log.txt | `ERROR` | 1250125 | lines | 21.8 | 6.8x | 126.9 | 1.0x | 5.82x |
| log.txt | `ERROR` | 1250125 | -n | 23.7 | 11.5x | 190.3 | 1.0x | 8.04x |
| log.txt | `ERROR` | 1250125 | -c | 20.6 | 6.9x | 107.0 | 1.0x | 5.19x |
| log.txt | `latency=1999ms` | 2471 | lines | 21.2 | 6.7x | 72.3 | 1.0x | 3.41x |
| log.txt | `latency=1999ms` | 2471 | -n | 21.6 | 6.6x | 81.7 | 1.0x | 3.78x |
| log.txt | `latency=1999ms` | 2471 | -c | 20.9 | 6.9x | 71.7 | 1.0x | 3.44x |
| log.txt | `[auth]` | 1001621 | lines | 21.7 | 6.8x | 127.4 | 1.0x | 5.88x |
| log.txt | `[auth]` | 1001621 | -n | 23.6 | 11.7x | 182.4 | 1.0x | 7.74x |
| log.txt | `[auth]` | 1001621 | -c | 20.9 | 6.8x | 116.8 | 1.0x | 5.58x |
| log.txt | `req=0000` | 78 | lines | 21.0 | 6.9x | 69.2 | 1.0x | 3.29x |
| log.txt | `req=0000` | 78 | -n | 21.5 | 6.6x | 90.2 | 1.0x | 4.20x |
| log.txt | `req=0000` | 78 | -c | 21.1 | 6.8x | 69.0 | 1.0x | 3.26x |
| log.txt | `/api/v2/items/` | 1668884 | lines | 23.7 | 12.5x | 152.5 | 1.0x | 6.45x |
| log.txt | `/api/v2/items/` | 1668884 | -n | 25.0 | 11.3x | 234.5 | 1.0x | 9.38x |
| log.txt | `/api/v2/items/` | 1668884 | -c | 20.8 | 6.9x | 136.0 | 1.0x | 6.53x |

speedup over 39 cells: min 3.16x, median 4.20x, geometric mean 5.48x, max 22.21x
CPU time, zg over rg: geometric mean 1.48x

## Warm cache, one thread (-j 1 for both)

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | 1 | lines | 69.4 | 1.0x | 82.2 | 1.0x | 1.18x |
| words.txt | `needle_zz` | 1 | -n | 70.1 | 1.0x | 109.0 | 1.0x | 1.56x |
| words.txt | `needle_zz` | 1 | -c | 68.4 | 1.0x | 82.4 | 1.0x | 1.20x |
| words.txt | `qzxjv` | 0 | lines | 70.3 | 1.0x | 82.3 | 1.0x | 1.17x |
| words.txt | `qzxjv` | 0 | -n | 71.7 | 1.0x | 82.4 | 1.0x | 1.15x |
| words.txt | `qzxjv` | 0 | -c | 69.0 | 1.0x | 82.4 | 1.0x | 1.19x |
| words.txt | `zebra` | 33512 | lines | 81.5 | 1.0x | 85.6 | 1.0x | 1.05x |
| words.txt | `zebra` | 33512 | -n | 83.4 | 1.0x | 97.9 | 1.0x | 1.17x |
| words.txt | `zebra` | 33512 | -c | 71.1 | 1.0x | 84.6 | 1.0x | 1.19x |
| words.txt | `xq` | 37320 | lines | 71.3 | 1.0x | 82.9 | 1.0x | 1.16x |
| words.txt | `xq` | 37320 | -n | 82.6 | 1.0x | 95.1 | 1.0x | 1.15x |
| words.txt | `xq` | 37320 | -c | 69.3 | 1.0x | 82.2 | 1.0x | 1.19x |
| words.txt | `ing ` | 2100750 | lines | 133.6 | 1.0x | 251.4 | 1.0x | 1.88x |
| words.txt | `ing ` | 2100750 | -n | 153.6 | 1.0x | 375.2 | 1.0x | 2.44x |
| words.txt | `ing ` | 2100750 | -c | 114.2 | 1.0x | 217.3 | 1.0x | 1.90x |
| words.txt | `the` | 4675899 | lines | 203.1 | 1.0x | 383.8 | 1.0x | 1.89x |
| words.txt | `the` | 4675899 | -n | 241.2 | 1.0x | 634.0 | 1.0x | 2.63x |
| words.txt | `the` | 4675899 | -c | 169.5 | 1.0x | 306.9 | 1.0x | 1.81x |
| words.txt | `a` | 9303679 | lines | 222.5 | 1.0x | 551.4 | 1.0x | 2.48x |
| words.txt | `a` | 9303679 | -n | 281.1 | 1.0x | 983.4 | 1.0x | 3.50x |
| words.txt | `a` | 9303679 | -c | 175.5 | 1.0x | 436.2 | 1.0x | 2.49x |
| log.txt | `unique_token_7731` | 1 | lines | 67.1 | 1.0x | 67.2 | 1.0x | 1.00x |
| log.txt | `unique_token_7731` | 1 | -n | 64.9 | 1.0x | 91.8 | 1.0x | 1.41x |
| log.txt | `unique_token_7731` | 1 | -c | 59.1 | 1.0x | 67.1 | 1.0x | 1.13x |
| log.txt | `ERROR` | 1250125 | lines | 81.3 | 1.0x | 126.2 | 1.0x | 1.55x |
| log.txt | `ERROR` | 1250125 | -n | 94.7 | 1.0x | 186.3 | 1.0x | 1.97x |
| log.txt | `ERROR` | 1250125 | -c | 76.0 | 1.0x | 105.2 | 1.0x | 1.39x |
| log.txt | `latency=1999ms` | 2471 | lines | 67.8 | 1.0x | 72.4 | 1.0x | 1.07x |
| log.txt | `latency=1999ms` | 2471 | -n | 71.1 | 1.0x | 81.5 | 1.0x | 1.15x |
| log.txt | `latency=1999ms` | 2471 | -c | 63.0 | 1.0x | 72.0 | 1.0x | 1.14x |
| log.txt | `[auth]` | 1001621 | lines | 79.1 | 1.0x | 126.9 | 1.0x | 1.60x |
| log.txt | `[auth]` | 1001621 | -n | 90.4 | 1.0x | 181.4 | 1.0x | 2.01x |
| log.txt | `[auth]` | 1001621 | -c | 73.2 | 1.0x | 116.5 | 1.0x | 1.59x |
| log.txt | `req=0000` | 78 | lines | 59.8 | 1.0x | 69.6 | 1.0x | 1.16x |
| log.txt | `req=0000` | 78 | -n | 65.5 | 1.0x | 90.2 | 1.0x | 1.38x |
| log.txt | `req=0000` | 78 | -c | 58.6 | 1.0x | 69.7 | 1.0x | 1.19x |
| log.txt | `/api/v2/items/` | 1668884 | lines | 89.9 | 1.0x | 147.4 | 1.0x | 1.64x |
| log.txt | `/api/v2/items/` | 1668884 | -n | 109.1 | 1.0x | 229.9 | 1.0x | 2.11x |
| log.txt | `/api/v2/items/` | 1668884 | -c | 81.7 | 1.0x | 136.5 | 1.0x | 1.67x |

speedup over 39 cells: min 1.00x, median 1.39x, geometric mean 1.50x, max 3.50x
CPU time, zg over rg: geometric mean 0.67x

## Worst cases (stress corpora, patterns of only common bytes, long patterns)

The cases of the table in [results.md](results.md): single spaces and common letters, 40- and
200-byte patterns, `long.txt` (lines of 20 to 600 KB), `short.txt` (lines of 0 to 3
characters) and `random.bin`. Output verified identical for all cases.

### Warm cache, all cores

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | ` ` | 9570168 | lines | 39.2 | 11.7x | 559.1 | 1.0x | 14.27x |
| words.txt | ` ` | 9570168 | -n | 48.5 | 11.8x | 1029.8 | 1.0x | 21.24x |
| words.txt | ` ` | 9570168 | -c | 26.2 | 13.3x | 452.8 | 1.0x | 17.27x |
| words.txt | `e ` | 6270085 | lines | 33.2 | 12.0x | 480.4 | 1.0x | 14.48x |
| words.txt | `e ` | 6270085 | -n | 39.4 | 12.1x | 799.3 | 1.0x | 20.29x |
| words.txt | `e ` | 6270085 | -c | 26.4 | 13.1x | 379.9 | 1.0x | 14.39x |
| words.txt | `e t` | 840018 | lines | 25.8 | 6.9x | 144.3 | 1.0x | 5.59x |
| words.txt | `e t` | 840018 | -n | 26.8 | 6.8x | 200.6 | 1.0x | 7.48x |
| words.txt | `e t` | 840018 | -c | 25.0 | 7.0x | 129.8 | 1.0x | 5.19x |
| words.txt | `the ` | 2065023 | lines | 28.3 | 12.5x | 254.4 | 1.0x | 8.98x |
| words.txt | `the ` | 2065023 | -n | 29.5 | 11.8x | 378.7 | 1.0x | 12.86x |
| words.txt | `the ` | 2065023 | -c | 25.4 | 7.0x | 220.0 | 1.0x | 8.65x |
| words.txt | `ing the` | 76335 | lines | 25.7 | 7.0x | 87.5 | 1.0x | 3.40x |
| words.txt | `ing the` | 76335 | -n | 26.3 | 6.8x | 101.6 | 1.0x | 3.87x |
| words.txt | `ing the` | 76335 | -c | 25.5 | 7.0x | 85.4 | 1.0x | 3.35x |
| words.txt | ` a ` | 0 | lines | 25.5 | 7.0x | 109.3 | 1.0x | 4.28x |
| words.txt | ` a ` | 0 | -n | 25.7 | 6.8x | 108.9 | 1.0x | 4.24x |
| words.txt | ` a ` | 0 | -c | 25.6 | 7.0x | 109.3 | 1.0x | 4.27x |
| words.txt | `tion` | 2875489 | lines | 28.2 | 12.8x | 329.4 | 1.0x | 11.68x |
| words.txt | `tion` | 2875489 | -n | 32.2 | 12.1x | 494.6 | 1.0x | 15.37x |
| words.txt | `tion` | 2875489 | -c | 26.9 | 12.9x | 277.6 | 1.0x | 10.30x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | lines | 25.5 | 7.1x | 80.1 | 1.0x | 3.14x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -n | 25.6 | 6.8x | 80.6 | 1.0x | 3.15x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -c | 25.5 | 7.0x | 80.2 | 1.0x | 3.15x |
| long.txt | ` ` | 1655 | lines | 23.2 | 6.7x | 63.1 | 1.0x | 2.72x |
| long.txt | ` ` | 1655 | -n | 23.3 | 6.3x | 74.7 | 1.0x | 3.20x |
| long.txt | ` ` | 1655 | -c | 21.1 | 7.0x | 62.1 | 1.0x | 2.95x |
| long.txt | `th` | 1655 | lines | 24.2 | 6.5x | 63.9 | 1.0x | 2.64x |
| long.txt | `th` | 1655 | -n | 23.1 | 6.4x | 75.1 | 1.0x | 3.25x |
| long.txt | `th` | 1655 | -c | 21.1 | 7.0x | 62.2 | 1.0x | 2.95x |
| long.txt | `needle_zz` | 1 | lines | 23.2 | 6.6x | 68.0 | 1.0x | 2.94x |
| long.txt | `needle_zz` | 1 | -n | 23.0 | 6.2x | 94.3 | 1.0x | 4.10x |
| long.txt | `needle_zz` | 1 | -c | 21.4 | 6.9x | 67.7 | 1.0x | 3.17x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | lines | 23.5 | 6.7x | 68.2 | 1.0x | 2.90x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -n | 23.5 | 6.4x | 88.2 | 1.0x | 3.75x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -c | 21.2 | 6.9x | 67.5 | 1.0x | 3.18x |
| short.txt | `a` | 37967876 | lines | 65.8 | 14.6x | 1702.3 | 1.0x | 25.88x |
| short.txt | `a` | 37967876 | -n | 109.2 | 13.7x | 2796.1 | 1.0x | 25.60x |
| short.txt | `a` | 37967876 | -c | 32.7 | 12.6x | 1199.5 | 1.0x | 36.69x |
| short.txt | `ab c` | 0 | lines | 14.2 | 6.5x | 76.7 | 1.0x | 5.40x |
| short.txt | `ab c` | 0 | -n | 14.6 | 6.3x | 77.0 | 1.0x | 5.26x |
| short.txt | `ab c` | 0 | -c | 14.1 | 6.6x | 76.9 | 1.0x | 5.45x |
| short.txt | `needle_zz` | 1 | lines | 14.1 | 6.6x | 42.2 | 1.0x | 2.99x |
| short.txt | `needle_zz` | 1 | -n | 14.7 | 6.2x | 56.5 | 1.0x | 3.84x |
| short.txt | `needle_zz` | 1 | -c | 14.1 | 6.5x | 41.9 | 1.0x | 2.98x |
| random.bin | `ab` | 8209 | lines | 22.9 | 6.9x | 71.7 | 1.0x | 3.13x |
| random.bin | `ab` | 8209 | -n | 23.3 | 6.6x | 83.1 | 1.0x | 3.57x |
| random.bin | `ab` | 8209 | -c | 22.8 | 6.9x | 70.8 | 1.0x | 3.11x |
| random.bin | `abc` | 38 | lines | 22.5 | 6.9x | 70.4 | 1.0x | 3.13x |
| random.bin | `abc` | 38 | -n | 23.6 | 6.6x | 92.9 | 1.0x | 3.93x |
| random.bin | `abc` | 38 | -c | 22.7 | 6.8x | 70.0 | 1.0x | 3.09x |
| random.bin | `needle_zz` | 1 | lines | 22.6 | 7.0x | 71.6 | 1.0x | 3.17x |
| random.bin | `needle_zz` | 1 | -n | 23.0 | 6.7x | 97.6 | 1.0x | 4.25x |
| random.bin | `needle_zz` | 1 | -c | 22.6 | 7.0x | 71.7 | 1.0x | 3.18x |

speedup over 54 cells: min 2.64x, median 3.93x, geometric mean 5.45x, max 36.69x
CPU time, zg over rg: geometric mean 1.46x

### Warm cache, one thread (-j 1 for both)

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | ` ` | 9570168 | lines | 220.7 | 1.0x | 557.8 | 1.0x | 2.53x |
| words.txt | ` ` | 9570168 | -n | 274.6 | 1.0x | 997.9 | 1.0x | 3.63x |
| words.txt | ` ` | 9570168 | -c | 175.9 | 1.0x | 442.2 | 1.0x | 2.51x |
| words.txt | `e ` | 6270085 | lines | 212.3 | 1.0x | 479.3 | 1.0x | 2.26x |
| words.txt | `e ` | 6270085 | -n | 255.6 | 1.0x | 787.0 | 1.0x | 3.08x |
| words.txt | `e ` | 6270085 | -c | 168.0 | 1.0x | 379.1 | 1.0x | 2.26x |
| words.txt | `e t` | 840018 | lines | 102.4 | 1.0x | 143.6 | 1.0x | 1.40x |
| words.txt | `e t` | 840018 | -n | 111.4 | 1.0x | 200.2 | 1.0x | 1.80x |
| words.txt | `e t` | 840018 | -c | 93.6 | 1.0x | 129.6 | 1.0x | 1.38x |
| words.txt | `the ` | 2065023 | lines | 137.9 | 1.0x | 253.3 | 1.0x | 1.84x |
| words.txt | `the ` | 2065023 | -n | 158.4 | 1.0x | 374.7 | 1.0x | 2.37x |
| words.txt | `the ` | 2065023 | -c | 116.6 | 1.0x | 219.1 | 1.0x | 1.88x |
| words.txt | `ing the` | 76335 | lines | 83.4 | 1.0x | 87.7 | 1.0x | 1.05x |
| words.txt | `ing the` | 76335 | -n | 85.6 | 1.0x | 101.5 | 1.0x | 1.19x |
| words.txt | `ing the` | 76335 | -c | 82.0 | 1.0x | 85.4 | 1.0x | 1.04x |
| words.txt | ` a ` | 0 | lines | 70.5 | 1.0x | 109.0 | 1.0x | 1.55x |
| words.txt | ` a ` | 0 | -n | 80.2 | 1.0x | 108.9 | 1.0x | 1.36x |
| words.txt | ` a ` | 0 | -c | 68.6 | 1.0x | 108.6 | 1.0x | 1.58x |
| words.txt | `tion` | 2875489 | lines | 165.5 | 1.0x | 325.5 | 1.0x | 1.97x |
| words.txt | `tion` | 2875489 | -n | 192.3 | 1.0x | 492.2 | 1.0x | 2.56x |
| words.txt | `tion` | 2875489 | -c | 140.5 | 1.0x | 276.2 | 1.0x | 1.97x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | lines | 70.8 | 1.0x | 80.8 | 1.0x | 1.14x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -n | 71.4 | 1.0x | 80.6 | 1.0x | 1.13x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -c | 69.3 | 1.0x | 80.4 | 1.0x | 1.16x |
| long.txt | ` ` | 1655 | lines | 55.6 | 1.0x | 63.5 | 1.0x | 1.14x |
| long.txt | ` ` | 1655 | -n | 55.4 | 1.0x | 74.6 | 1.0x | 1.35x |
| long.txt | ` ` | 1655 | -c | 51.2 | 1.0x | 62.7 | 1.0x | 1.22x |
| long.txt | `th` | 1655 | lines | 56.2 | 1.0x | 63.4 | 1.0x | 1.13x |
| long.txt | `th` | 1655 | -n | 55.9 | 1.0x | 74.7 | 1.0x | 1.34x |
| long.txt | `th` | 1655 | -c | 51.7 | 1.0x | 62.8 | 1.0x | 1.21x |
| long.txt | `needle_zz` | 1 | lines | 62.3 | 1.0x | 68.0 | 1.0x | 1.09x |
| long.txt | `needle_zz` | 1 | -n | 70.6 | 1.0x | 95.0 | 1.0x | 1.35x |
| long.txt | `needle_zz` | 1 | -c | 60.8 | 1.0x | 67.9 | 1.0x | 1.12x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | lines | 64.7 | 1.0x | 67.7 | 1.0x | 1.05x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -n | 64.8 | 1.0x | 88.1 | 1.0x | 1.36x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -c | 62.9 | 1.0x | 67.6 | 1.0x | 1.07x |
| short.txt | `a` | 37967876 | lines | 394.8 | 1.0x | 1693.3 | 1.0x | 4.29x |
| short.txt | `a` | 37967876 | -n | 690.8 | 1.0x | 2788.2 | 1.0x | 4.04x |
| short.txt | `a` | 37967876 | -c | 292.9 | 1.0x | 1182.5 | 1.0x | 4.04x |
| short.txt | `ab c` | 0 | lines | 38.6 | 1.0x | 77.0 | 1.0x | 1.99x |
| short.txt | `ab c` | 0 | -n | 38.5 | 1.0x | 77.3 | 1.0x | 2.01x |
| short.txt | `ab c` | 0 | -c | 39.2 | 1.0x | 77.1 | 1.0x | 1.97x |
| short.txt | `needle_zz` | 1 | lines | 33.3 | 1.0x | 42.4 | 1.0x | 1.27x |
| short.txt | `needle_zz` | 1 | -n | 34.4 | 1.0x | 57.4 | 1.0x | 1.67x |
| short.txt | `needle_zz` | 1 | -c | 33.0 | 1.0x | 42.5 | 1.0x | 1.29x |
| random.bin | `ab` | 8209 | lines | 69.4 | 1.0x | 71.6 | 1.0x | 1.03x |
| random.bin | `ab` | 8209 | -n | 67.1 | 1.0x | 82.8 | 1.0x | 1.23x |
| random.bin | `ab` | 8209 | -c | 58.8 | 1.0x | 70.9 | 1.0x | 1.21x |
| random.bin | `abc` | 38 | lines | 60.3 | 1.0x | 70.2 | 1.0x | 1.17x |
| random.bin | `abc` | 38 | -n | 61.3 | 1.0x | 92.9 | 1.0x | 1.52x |
| random.bin | `abc` | 38 | -c | 58.8 | 1.0x | 70.2 | 1.0x | 1.19x |
| random.bin | `needle_zz` | 1 | lines | 70.8 | 1.0x | 71.7 | 1.0x | 1.01x |
| random.bin | `needle_zz` | 1 | -n | 66.6 | 1.0x | 97.2 | 1.0x | 1.46x |
| random.bin | `needle_zz` | 1 | -c | 58.5 | 1.0x | 71.8 | 1.0x | 1.23x |

speedup over 54 cells: min 1.01x, median 1.36x, geometric mean 1.58x, max 4.29x
CPU time, zg over rg: geometric mean 0.63x

## Small files and -m (all cores)

| file | pattern | flags | zg ms | zg CPU ms | rg ms | rg CPU ms | zg speedup |
|---|---|---|---|---|---|---|---|
| w1m.txt | `the` |  | 2.0 | 2.2 | 3.2 | 3.0 | 1.57x |
| w1m.txt | `needle_zz` | -c | 1.5 | 1.3 | 2.2 | 2.1 | 1.55x |
| w8m.txt | `the` |  | 4.1 | 14.5 | 8.1 | 8.0 | 1.99x |
| w8m.txt | `needle_zz` | -c | 2.4 | 4.3 | 3.0 | 2.9 | 1.24x |
| w64m.txt | `the` |  | 8.5 | 61.5 | 48.4 | 48.1 | 5.67x |
| w64m.txt | `the` | -n | 9.6 | 60.9 | 78.7 | 78.4 | 8.16x |
| w64m.txt | `needle_zz` | -c | 4.8 | 20.8 | 10.1 | 10.0 | 2.12x |
| words.txt | `the` | -m 1 | 2.1 | 2.0 | 2.4 | 2.3 | 1.16x |
| words.txt | `zebra` | -m 10 | 1.9 | 1.7 | 2.5 | 2.3 | 1.33x |
| log.txt | `ERROR` | -m 1000 | 2.1 | 2.0 | 2.6 | 2.5 | 1.28x |

speedup over 10 cells: geometric mean 2.03x; CPU time, zg over rg: geometric mean 1.03x

Small files are the first 1, 8 and 64 MB of words.txt (`w1m.txt`, `w8m.txt`, `w64m.txt`);
`-m` runs on the large files. Here fixed costs weigh: starting threads, setting up the search.
Before threads were started as they pay off (next section), the same cells gave a geometric
mean of 1.17x, with the `-m` cells at 0.34x to 0.36x (7.3 ms against 2.5 ms) and `w8m.txt -c`
at 0.83x; zg used 3.0x the CPU time of rg, now 1.01x.

## Peak RSS (MB, from wait4; includes the mapped file pages touched)

| file | pattern | output | zg default | zg --mem=256M | zg -j 1 | rg |
|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | lines | 26 | 30 | 32 | 521 |
| words.txt | `needle_zz` | -n | 22 | 19 | 504 | 521 |
| words.txt | `the` | lines | 43 | 26 | 505 | 521 |
| words.txt | `the` | -n | 60 | 178 | 506 | 521 |
| words.txt | `a` | lines | 226 | 218 | 505 | 521 |
| words.txt | `a` | -n | 288 | 27 | 506 | 521 |
| log.txt | `ERROR` | lines | 69 | 29 | 481 | 496 |
| log.txt | `ERROR` | -n | 21 | 23 | 480 | 496 |
| log.txt | `/api/v2/items/` | lines | 28 | 52 | 481 | 496 |
| log.txt | `/api/v2/items/` | -n | 26 | 23 | 481 | 497 |

On Linux the peak RSS counts the pages of the file mapping that a process touched, so it
shows how a file was read more than what was allocated: rg maps the file (about 500 MB), and so
does zg where its measurements picked the mapping (`-j 1`, some default runs); with `pread`
zg's RSS is what it allocated. The macOS footprint in [results.md](results.md) leaves mapped
file pages out.

| file | pattern | output | zg default | zg --mem=256M | zg -j 1 | rg |
|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | lines | 26 | 30 | 32 | 521 |
| words.txt | `needle_zz` | -n | 22 | 19 | 504 | 521 |
| words.txt | `the` | lines | 43 | 26 | 505 | 521 |
| words.txt | `the` | -n | 60 | 178 | 506 | 521 |
| words.txt | `a` | lines | 226 | 218 | 505 | 521 |
| words.txt | `a` | -n | 288 | 27 | 506 | 521 |
| log.txt | `ERROR` | lines | 69 | 29 | 481 | 496 |
| log.txt | `ERROR` | -n | 21 | 23 | 480 | 496 |
| log.txt | `/api/v2/items/` | lines | 28 | 52 | 481 | 496 |
| log.txt | `/api/v2/items/` | -n | 26 | 23 | 481 | 497 |

On Linux the peak RSS counts the pages of the file mapping that a process touched, so it
shows how a file was read more than what was allocated: rg maps the file (about 500 MB), and so
does zg where its measurements picked the mapping (`-j 1`, some default runs); with `pread`
zg's RSS is what it allocated. The macOS footprint in [results.md](results.md) leaves mapped
file pages out.

## Cold page cache (first read from disk)

| pattern | output | zg ms | rg ms | zg speedup |
|---|---|---|---|---|
| `needle_zz` | -c | 190 | 291 | 1.53x |
| `the` | -c | 215 | 427 | 1.99x |

Each run reads a fresh copy of words.txt, dropped from the page cache with
`POSIX_FADV_DONTNEED` beforehand. `dd` with `O_DIRECT` and 4 MB blocks reads the same file at
2.9 GB/s (190 ms): zg is close to what the disk delivers.

## Shared engine under concurrency

`zig build stress -- words.txt small8m.txt` (the first 8 MB of words.txt), in process, one
`Engine(.shared)` with the default settings.

1. 10 searches per caller of `-c needle_zz` on words.txt

| callers | wall ms | ms per search (wall / searches) | vs 1 caller | latency p50 | p99 | max |
|---|---|---|---|---|---|---|
| 1 | 216 | 21.58 | 1.00x | 21.6 | 21.9 | 21.9 |
| 2 | 246 | 12.29 | 1.76x | 24.1 | 28.7 | 28.7 |
| 4 | 837 | 20.93 | 1.03x | 86.4 | 95.0 | 95.0 |
| 8 | 1524 | 19.04 | 1.13x | 156.6 | 205.4 | 205.4 |
| 16 | 3109 | 19.43 | 1.11x | 298.3 | 513.4 | 580.1 |

2. 4 callers x 50 searches of `-c needle_zz` on small8m.txt, alone and next to `the` (all lines) on words.txt (1 heavy searches meanwhile)

| small searches | p50 ms | p99 ms | max ms |
|---|---|---|---|
| alone | 0.11 | 0.87 | 1.00 |
| next to the heavy search | 0.31 | 3.33 | 4.58 |

peak resident set (maxrss, with mapped file pages): 44 MB

With 150 rounds (4 callers x 750 small searches, 9 heavy searches meanwhile): alone p50
0.10 ms, p99 0.73 ms; next to the heavy search p50 0.30 ms, p99 3.66 ms, longest 6.17 ms.
Before the second round (below) the same run gave 0.64 / 1.3 ms alone and 1.8 / 11.6 ms
(longest 17.6 to 20.1 ms) next to the heavy search.

## Threads started as they pay off

One-shot searches without `-j` used to start one thread per CPU at once. They now start them
as they pay off (`Ramp` in src/zg.zig): up to one per physical core without measuring (from
the caller alone with `-m`), and the second thread of each core only when the work has
compute to overlap with the copies from the page cache. Two findings shaped it:

- **What decides it.** One thread per core against two, alternating runs (ms):

  | case | 8 threads | 16 threads |
  |---|---|---|
  | words.txt `-c needle_zz` | 24.3 | 26.4 |
  | log.txt `ERROR` | 21.2 | 24.5 |
  | long.txt `th` | 23.2 | 42.3 |
  | w64m.txt `-c needle_zz` | 3.7 | 4.3 |
  | words.txt `zebra` | 25.1 | 27.9 |
  | words.txt `the` | 41.1 | 32.6 |
  | words.txt `-n a` | 67.3 | 47.8 |
  | words.txt `-c the` | 30.4 | 25.4 |
  | short.txt `-c a` | 51.7 | 30.2 |

  The share of the `pread` chunks' time spent on scanning and rendering (rather than on the
  read) separates them: 0.09 to 0.48 where 8 threads won, 0.52 to 0.94 where 16 did; the
  threshold is 0.5. Over six runs per case it chose the faster count every time except once
  for `-c the` (share near 0.5, where the two counts are closest). Comparing the throughput
  on 8 threads with the one on 16 instead was unreliable: the clock rises during the first
  milliseconds and drops under the power limit with all threads busy, so the later
  measurement mostly looked better (16 threads won for `-c needle_zz` in 6 runs of 8).
- **Starting a thread was expensive.** Zig's standard library gives every thread a 256 KB
  alternate signal stack in thread-local storage, cleared at every thread start: 15 starts
  took 1.9 ms (2.9 ms while other threads allocate), 0.26 ms (0.8 ms) without it. The command
  line tool turns it off outside Debug builds (`std_options.signal_stack_size`).

A/B against the build before (same matrices, runs alternating): the 39 standard cells 1.12x
faster (geometric mean; 0.94x to 1.25x), the 54 worst cells 1.15x (0.94x to 1.92x; long.txt
1.4x to 1.9x). The cells that lost are the ones printing the most lines (`a -n`, short.txt
`a`): they reach 16 threads only after the measurement on 8, about 2 ms in. CPU time against
rg (geometric mean): all cores 1.36x on the standard cells and 1.46x on the worst, one
thread 0.67x and 0.63x.

## Thread count from measured costs (2026-10-10)

The ramp above started one thread per core at once (fewer for files under 8 chunks per
thread). A one-shot search now starts on the caller alone and starts threads after its first
chunk, as many as the model below says finish soonest (`threadsForWork`, `Ramp.probe` in
src/zg.zig). It uses no file size: where threads begin to pay depends on the time the search
takes on one thread, W, which depends on the pattern (single-thread rates here: 9.7 GB/s for
`-c needle_zz`, 3.5 for `-c the`, 2.8 for `the` printing lines), and on what starting a
thread costs, which depends on whether the other cores were just busy.

**Model.** n threads are asked for at the same moment; the caller spends s on starting (and
later joining) each, so the i-th starts working at i*s + L, L being the time from asking to the
first chunk's work; the work is shared as chunks. Then T(n) = [W + (n-1)(L+s) + s n (n-1)/2] / n
against W on one thread: n threads win where W > L + s(1 + n/2), two where W > L + 2s, and the
least T is at n = sqrt(2 (W-L-s) / s). The caller measures W from the chunks done. L and s are
measured by a detached thread started with the search (`StartCost`), which times its own
start and the getting of a buffer, and the caller's `spawn` call.

**What starting a thread costs** (median of 40 runs, 16 MB file; thread start measured
by `StartCost`, the buffer being 256 KB):

| state | thread runs its first instruction | buffer of the first chunk | `spawn` call |
|---|---|---|---|
| cores busy just before | 22 to 73 us | 98 to 290 us | 19 to 40 us |
| cores idle for 0.4 s | 69 to 320 us | 157 to 294 us | 39 to 78 us |

The same 2 MB search, `-c the`: 1.55 ms with `-j 1` and 1.24 ms with `-j 8` right after
16-thread runs; 3.13 and 3.46 ms after 0.4 s idle. A file size threshold fitted in back-to-back
benchmark runs is wrong for a command typed now and then.

**Checking the model.** Fixed `-j 1/2/4/8`, medians of 21 rounds in rotating order, the
cores made busy (a 16-thread run) or idle (0.3 s) before every run; W is the time on one thread
less that of a 128 KB file. Gain in ms over `-j 1`, observed / predicted, with L and s
fitted (warm L 0.31, s 0.134; cold L 0.94, s 0.200, rms 0.12 and 0.24 ms; the measured values
are 0.12 and 0.041 warm, 0.36 and 0.105 cold, so the measured costs are lower bounds, 1.9 to
3.3 times too low: the helpers also contend for the kernel's locks, find the file cold in their
caches and are joined; the factor that fits was 2.5 on this Ryzen and 2.8 to 2.9 on the hosted x86-64 runner, 0.6 to 0.9 on the hosted arm64 one, see below):

| state | size, search | W | 2 threads | 4 threads | 8 threads |
|---|---|---|---|---|---|
| warm | 4 MB `-c the` | 1.50 | 0.61 / 0.65 | 0.85 / 0.94 | 0.84 / 1.03 |
| warm | 8 MB `-c the` | 2.54 | 1.09 / 1.17 | 1.41 / 1.72 | 1.60 / 1.94 |
| warm | 16 MB `-c the` | 5.51 | 2.51 / 2.66 | 3.60 / 3.95 | 4.08 / 4.54 |
| warm | 16 MB `-c needle_zz` | 2.63 | 1.01 / 1.21 | 1.39 / 1.79 | 1.21 / 2.01 |
| warm | 2 MB `-c needle_zz` | 0.42 | 0.08 / 0.11 | 0.00 / 0.13 | -0.08 / 0.08 |
| cold | 2 MB `-c needle_zz` | 0.58 | -0.14 / 0.00 | -0.39 / -0.07 | -0.86 / -0.27 |
| cold | 2 MB `the` (lines) | 1.22 | -0.11 / 0.33 | -0.19 / 0.41 | -0.58 / 0.30 |
| cold | 8 MB `-c the` | 3.26 | 1.06 / 1.35 | 1.52 / 1.94 | 1.35 / 2.08 |

The form holds: 2 threads within 5 to 10 % where threads win, and the signs where they lose.
It is too hopeful with more threads, for two reasons it does not contain. Bandwidth: 16 MB
`-c needle_zz` (9.7 GB/s on one thread) gains less with 8 threads than with 4, saturated at
about 4 threads where the memory delivers about 33 GB/s (the roofline: threads <= B / r1,
r1 the rate of one), while `-c the` (3.5 GB/s) is still gaining at 8 (saturation at about 9).
The writer of searches that print lines is serial. Neither is modelled; the second thread of
each core is decided from the share of time in the copy as before, and at most one thread per
core is started by the model.

**Result.** Words.txt prefixes cached, `--io=pread`, wall time in ms, geometric mean over
`-c needle_zz`, `-c the` and `the` (lines), the builds alternating in rotating order. "Per
core" is the build before (one thread per core at once), "ranges" a build with fixed ranges of
file size (one thread under 4 MiB, one per core from 32 MiB, the model between), "model" the
final one:

| size | warm: one thread | per core | ranges | model | cold: one thread | per core | ranges | model |
|---|---|---|---|---|---|---|---|---|
| 1 MB | 1.99 | | 1.89 | 1.94 | 2.81 | | 2.81 | 2.83 |
| 2 MB | 2.15 | | 2.12 | 2.16 | 3.20 | | 3.21 | 3.30 |
| 4 MB | 2.53 | | 2.55 | 2.30 | 4.16 | | 3.87 | 3.93 |
| 8 MB | 3.23 | | 2.74 | 2.29 | 5.07 | | 4.26 | 4.24 |
| 16 MB | 5.49 | | 3.32 | 2.53 | 8.17 | | 5.62 | 5.36 |
| 32 MB | 8.48 | 3.34 | 4.14 | 3.48 | 10.96 | | 6.20 | 6.46 |
| 128 MB | 30.0 | 6.80 | 7.14 | 7.16 | 32.3 | | 10.9 | 11.0 |

("Per core" and "ranges" are the same code from 32 MB; the runs differ by the state of the
machine, 10 to 20 % at 8 to 32 MB, so compare within a row of one run.) Against one thread per
core at once the model takes 7 to 24 % less time on 4 to 32 MB warm and the CPU time of one
thread to a half; files from 32 MB on pay the wait for the first chunk and the measurement
before the threads start, 0.2 to 0.35 ms: 3 to 5 % on 32 to 128 MB, 0.7 % on 515 MB. The 39
standard cells 0.996x; CPU time against ripgrep unchanged.

**Other CPUs** (hosted runners, `.github/thread-sweep.py` through the Performance workflow with
`only_threads`, 15 rounds, 3 or 4 CPUs, runs 38036037681 and 38045790082). Starting a thread,
median of 40, warm / cold, in us (first instruction, 1 chunk-size buffer, `spawn` call):

| platform | chunk | first instruction | buffer | `spawn` call | kappa that fits (warm, cold) |
|---|---|---|---|---|---|
| x86-64, 4 CPUs | 256 KB | 36 / 65 | 195 / 258 | 29 / 41 | 2.8, 2.3 (the Ryzen: 2.5) |
| arm64 Neoverse N2, 4 CPUs | 1 MB | 48 / 131 | 532 / 824 | 36 / 48 | 1.0, 0.6 |
| macOS M1 (virtual), 3 CPUs | 2 MB | 42 / 35 | 259 / 267 | 30 / 23 | too noisy (3.1, 8.0; rms 0.9 to 2.3 ms) |

kappa is the factor on the measured L and s that makes the predicted gain of 2 and 4 threads
closest to the observed (4 to 32 MB, `-c the` and `the` printing lines). The costs measured on a
lone thread are lower bounds of what the helpers pay, and how far below depends on the machine,
hence the two steps (`start_cost_upper`). Default against one thread and against all threads at
once (wall time ratio, warm; below 1 the default is faster), first run:

| size | x86 one / all | arm64 one / all | macOS one / all |
|---|---|---|---|
| 1 MB | 1.05 / 0.92 | 1.05 / 0.99 | 1.08 / 1.07 |
| 4 MB | 0.90 / 0.99 | 0.83 / 1.12 | 0.98 / 1.19 |
| 16 MB | 0.59 / 1.02 | 0.45 / 1.07 | 0.77 / 1.12 |
| 64 MB | 0.43 / 1.05 | 0.35 / 1.07 | 0.56 / 1.08 |

The default is 40 to 65 % faster than one thread from 8 MB on, on all three, but 2 to 12 % slower
than all threads at once from 2 MB on arm64 and 4 to 5 % on x86-64 from 8 MB. The second run,
with the two steps (the first thread started times itself and the others follow from it), did
not change that on arm64 (4 MB 1.10, 8 MB 1.11, 16 MB 1.07, 64 MB 1.07): the loss is not too
few threads but the wait before the first one is started. The decision comes after the first
chunk, which takes about 0.3 to 0.4 ms of a 1 MB chunk on the arm64 runner (a 256 KB chunk of
x86-64: 0.05 to 0.1 ms), and after the measuring thread has reported (60 to 250 us): a fixed
0.3 to 0.5 ms that is 3 to 10 % of a search of 5 to 10 ms and 0.5 % of one of 100 ms.

**A short first chunk.** The decision comes after the first chunk, whose time grows with the
chunk (256 KB on x86-64, 1 MB on the arm64 runner, 2 MB on the Mac), so the wait did. The first
chunk is now a quarter of a chunk, page-aligned, and the others follow from where it ends
(`firstChunkLen`, `chunkLo`); the work left is estimated from the time per byte. Default against
all threads at once, wall time ratio (below 1 the default is faster), on the hosted runners
(warm / cold), whole first chunk, then a quarter:

| size | x86-64 | arm64 | macOS (noisy) |
|---|---|---|---|
| 4 MB | 0.99 / 0.96 then 0.98 / 0.96 | 1.12 / 1.10 then 1.04 / 1.03 | 1.19 / 1.04 then 1.08 / 0.90 |
| 16 MB | 1.02 / 1.01 then 1.04 / 1.00 | 1.07 / 1.07 then 1.04 / 1.02 | 1.12 / 0.97 then 0.96 / 0.88 |
| 64 MB | 1.05 / 0.99 then 1.02 / 1.02 | 1.07 / 1.06 then 1.02 / 1.02 | 1.08 / 1.01 then 1.04 / 0.99 |

On the Ryzen (warm, geometric mean, against the previous commit and against a thread per core
at once): 32 MB 4.42 ms against 4.60 and 4.34, 64 MB 5.75 against 6.00 and 5.67, 128 MB 7.97
against 8.27 and 8.02, 515 MB 20.70 against 21.28 and 20.70. Cold cores the same; the 39 standard
cells 0.994x, 1.004x and 0.997x in three runs. The thread count against one thread is as before
(8 MB: x86-64 0.76 to 0.68, arm64 0.65 to 0.61 of the time of one thread).

What was tried on the way:

- **A first table that was wrong.** Thread count against file size, each setting run in a
  block of its own, showed 2 to 8 MB files twice as fast with 8 to 16 threads as with the
  default. Run alternating it was the other way round: the clock rate of the laptop followed
  the order of the blocks. In process (`bench`) a 2 MB search takes 0.3 ms on one thread and
  0.5 ms on 8: the 1 to 2 ms of the command is the process.
- **Fixed ranges of file size** (one thread under 4 MiB, one per core from 32 MiB, in between
  a thread for each N = s / epsilon of W after heartbeat scheduling, Acar et al., PLDI 2018):
  as good as the model warm, but the 4 MiB was where W is about a millisecond for this pattern
  and this machine in this state; for a search printing lines it is 1 MB, and cold the start of
  a thread costs three times more.
- **Other ways to find the count**, 4 to 64 MB, wall and CPU time against the build before
  (geometric mean): a thread for each 500 us of W, with a shortcut from 64 MB (0.88 to 0.93,
  0.74 to 0.76); the first thread timed until the end of its first chunk, then sqrt(W / tau)
  threads (0.94, 0.72); sqrt(W / tau) with a worst-case tau as the first guess (0.96 to 0.99,
  0.68 to 0.71, too few threads for 4 to 16 MB); the start latency and s as two terms, without
  the stagger of the starts (1.05, 0.94); epsilon 10 % instead of 5 %: 0.98, 0.85.
- **Raising the threads started at once for small files** (the divisor of `nchunks`, one
  thread per chunk, all threads from 2 MB): no gain, 3 to 20 % either way by case.
- **All threads for a file too short to measure the second thread of each core** (what
  `pace` used to do after a probe): 25 to 50 % more CPU time on 2 to 32 MB files without making
  them faster; it stays at one per core.
- **Timing a thread's start with a 256 KB buffer** cost 0.4 to 0.5 ms of CPU time on a 1 MB
  search; with 64 KB (16 pages, the cost per page scaled) about a third of that.
- **Waiting on shared engines** doubled the time of a small search (p50 0.12 to 0.25 ms,
  `-c needle_zz` on 8 MB, 4 callers): the pool threads are already running. Not done there.

## Second round: CPU levels, the writer, the shared engine

**Portable builds.** `zig build -Dcpu=baseline` (x86-64 without AVX2) used to give a binary
slower than rg on one thread: its 32-byte vectors were split in two on SSE2 and the lane
masks put back together. One thread, 39 standard cells, against rg:

| build | min | geometric mean |
|---|---|---|
| baseline, before | 0.49x | 0.78x |
| baseline now (16-byte vectors without AVX2, cores for v2 and v3 chosen with `cpuid`) | 1.03x | 1.50x |
| for this machine (`-Dcpu=native`) | 1.00x | 1.50x |

16-byte vectors alone took one thread `-c needle_zz` from 154 to 74 ms; the v3 core (AVX2,
chosen at run time) to 69 ms, as the native build (68 ms). The v2 and v1 cores, forced with
`ZG_CPU_LEVEL`, give 78 and 79 ms. The fat binary is 6.0 MB against 4.7 MB (debug info in
both); small files and `-m` with it: geometric mean 1.99x against rg (native 2.03x).

**The writer.** The idea was to save a copy of the output on its way out. There is none:
chunk outputs larger than the writer's buffer go to `writev` directly (1145 calls of 108 KB
on average for short.txt `a`, 124 MB of output). That case is bound elsewhere (8 and 16
threads within 7% of each other); nothing was changed.

**Threads: an early decision.** Waiting out the measurement on one thread per core cost the
plainly compute-bound searches up to 14% against starting all threads at once (short.txt
`-c a`, 33.8 against 29.7 ms). A share of 0.75 or more over the settling chunks now decides
at once (the highest share seen where one thread per core was faster: 0.55 over that
shorter window). Against `-j 16` (ms): short.txt `-c a` 32.1 / 30.9, short.txt `a` 66.3 /
70.3, `-n a` 46.2 / 52.8, `the` 29.7 / 35.1, `ERROR` 21.5 / 24.3, long.txt `th` 22.6 / 37.7.
Shorter measurement windows were tried and rejected: with one chunk per thread to settle and
two to measure, `ERROR` chose 16 threads in 3 runs of 8, and windows made only of the first
chunks (the access methods being tried) had no `pread` chunk to measure.

**Shared engine.** In order, measured with `zig build stress` (4 callers of small searches
on an 8 MB file next to one caller printing all lines with `the` on words.txt):

- Threads per search as in one-shot searches (`Ramp` lets the pool threads in): one caller
  of `-c needle_zz` on words.txt 23.6 -> 21.5 ms per search, two callers 21.8 -> 15 ms.
- The small searches' tail. With 200 samples the p99 read 17 to 25 ms, which turned out to
  be close to the longest; with 3000 it is about 11 ms, longest about 26 ms. Per-thread
  `getrusage` showed the slow searches' callers asleep (2 to 6 voluntary context switches,
  0.2 to 4 ms of CPU for 6 to 12 ms), and the phases showed `mmap`, `munmap` and the first
  reads of the mapping taking milliseconds: waits for the process's address space lock.
  Changes, with what each did:
  - Buffers freed by an idle pool thread instead of the search that ends last (that search
    spent 20 ms and more freeing what a large one left): removed those cases.
  - On Linux, files above 256 MB read with `pread` only on shared engines (a large search
    that had chosen the mapping held the lock for its whole unmapping): longest 25.6 to
    27.4 -> 18.6 to 19.9 ms, p99 unchanged. The stress run's peak RSS, which counts the
    mapped file pages touched, went from 1666 to 44 MB.
  - Mappings unmapped 8 MB at a time; the buffer and pool locks spin briefly, then sleep
    instead of spinning: no measurable change on their own.
  - Mappings and tuned filters kept from one search of a file to the next (`MapCache`,
    `TuneCache`): small searches alone 0.6 -> 0.1 ms (p50); next to the heavy one p50 1.8 ->
    0.3 ms, p99 11 -> 4 ms, longest 17 to 20 -> 6 to 9 ms. Unmapping had been a third of a
    small search (170 us of 0.5 ms), and with it went most of the waiting for the lock.

## What changed for x86-64 Linux

The first run of this matrix (the build developed on macOS) gave all cores 1.52x / 2.92x
(minimum / geometric mean, standard cases) and one thread 0.92x / 1.39x; the worst cases
1.04x / 3.11x and 0.92x / 1.43x. Fixes, each measured on its own:

- **`pread` from page boundaries.** Chunks were read from `lo - 1`, so the kernel copied from
  the page cache into a buffer offset by one byte. On x86 that copy is several times slower:
  2 MB from offset 2097151 took 0.6 to 1.2 ms, from offset 0 0.2 ms. One thread, `-c` on
  words.txt with `pread`: 162 ms before, 51 ms after (rg: 68 ms with its mapping, 61 ms with
  `--no-mmap`).
- **Chunks of a thread's share of L2.** The chunk size was at most 2 MB, which suits Apple
  Silicon (3 MB of L2 per core) but not 512 KB shared by two hardware threads: the bytes
  read with `pread` were out of the cache again before they were scanned. The limit is now
  the L2 size over the threads sharing it, read from the system (`/sys/devices/system/cpu`,
  `sysctl` on macOS): 256 KB here. 16 threads, words.txt with `pread`: `-c needle_zz` 62 ms
  with 2 MB chunks, 22 ms with 256 KB; `the` (4.7 M lines) 120 ms and 35 ms.
- **Unmapping counted against the mapping.** On Linux, unmapping 540 MB of faulted-in pages
  takes 13.8 ms on one thread at the end of a search, after 17 ms of searching on 8 threads.
  The per-chunk timings that choose the access method did not see it and picked the mapping.
  The mapped methods are now charged about 100 ns per 4 KB page and thread
  (`unmapCost`): 16 threads, `-c needle_zz` went from 36 to 24 ms, one thread from 70 to
  54 ms.
- **A writer that keeps up with small chunks.** With 8 times more chunks, the writer fell
  behind by hundreds of chunks: almost every `pread` chunk ends inside a line and handed its
  whole buffer to the writer for that piece of line, every text chunk reserved an output
  buffer before it had a match, and every chunk signalled a futex nobody waited on. Short
  pieces are now copied, output buffers are taken at the first match, and wake-ups go only to
  sleepers. Plain output of `needle_zz` (1 line): 33.5 ms before, 24.4 ms after (as `-c`).

Tried and left out: `MADV_POPULATE_READ` for the mapped chunks (no gain: the cost of the
mapping is in unmapping, not in the faults) and `POSIX_FADV_SEQUENTIAL` for files read with
`pread` (cold reads 204 ms before, 256 ms with it).

The tables in [results.md](results.md) were measured on the Mac before these changes, which
also touch the code that runs there (the writer, the read offsets); they have not been
measured on the Mac since.
