# zg vs ripgrep

Measured 2026-10-08 on an 8-core Apple Silicon Mac (macOS, 8 GB), warm page cache. Every cell is the median of 15 runs, zg and rg alternating, after one warm-up; rg runs as `rg -a -F --no-config`. The corpora come from `zig build gen` and the tables from `zig build compare` (`--sections single,warm`, plus `--case` for the worst cases).

Output verified identical to rg for all 39 standard and 54 worst cases.

## Warm cache, all cores

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | 1 | lines | 22.6 | 5.5x | 54.3 | 1.0x | 2.40x |
| words.txt | `needle_zz` | 1 | -n | 23.9 | 5.4x | 65.4 | 1.0x | 2.74x |
| words.txt | `needle_zz` | 1 | -c | 21.8 | 5.2x | 54.2 | 1.0x | 2.48x |
| words.txt | `qzxjv` | 0 | lines | 22.2 | 5.0x | 54.7 | 1.0x | 2.46x |
| words.txt | `qzxjv` | 0 | -n | 23.3 | 5.3x | 66.0 | 1.0x | 2.83x |
| words.txt | `qzxjv` | 0 | -c | 22.0 | 5.1x | 54.7 | 1.0x | 2.48x |
| words.txt | `zebra` | 33512 | lines | 22.6 | 5.3x | 58.3 | 1.0x | 2.58x |
| words.txt | `zebra` | 33512 | -n | 23.9 | 5.3x | 72.5 | 1.0x | 3.04x |
| words.txt | `zebra` | 33512 | -c | 21.9 | 5.2x | 57.1 | 1.0x | 2.61x |
| words.txt | `xq` | 37320 | lines | 22.3 | 5.2x | 57.0 | 1.0x | 2.56x |
| words.txt | `xq` | 37320 | -n | 24.9 | 5.0x | 72.0 | 1.0x | 2.90x |
| words.txt | `xq` | 37320 | -c | 22.6 | 5.1x | 56.3 | 1.0x | 2.49x |
| words.txt | `ing ` | 2100750 | lines | 32.1 | 5.7x | 255.8 | 1.0x | 7.96x |
| words.txt | `ing ` | 2100750 | -n | 37.5 | 6.1x | 393.1 | 1.0x | 10.49x |
| words.txt | `ing ` | 2100750 | -c | 27.5 | 5.6x | 194.1 | 1.0x | 7.07x |
| words.txt | `the` | 4675899 | lines | 46.2 | 6.4x | 376.8 | 1.0x | 8.16x |
| words.txt | `the` | 4675899 | -n | 56.6 | 6.4x | 671.7 | 1.0x | 11.88x |
| words.txt | `the` | 4675899 | -c | 37.9 | 6.2x | 244.1 | 1.0x | 6.45x |
| words.txt | `a` | 9303679 | lines | 53.3 | 6.7x | 612.3 | 1.0x | 11.48x |
| words.txt | `a` | 9303679 | -n | 64.8 | 6.6x | 1132.0 | 1.0x | 17.47x |
| words.txt | `a` | 9303679 | -c | 43.5 | 6.5x | 384.6 | 1.0x | 8.84x |
| log.txt | `unique_token_7731` | 1 | lines | 23.2 | 5.0x | 58.3 | 1.0x | 2.51x |
| log.txt | `unique_token_7731` | 1 | -n | 24.3 | 5.0x | 69.4 | 1.0x | 2.85x |
| log.txt | `unique_token_7731` | 1 | -c | 22.8 | 5.1x | 58.3 | 1.0x | 2.56x |
| log.txt | `ERROR` | 1250125 | lines | 27.1 | 5.4x | 129.7 | 1.0x | 4.78x |
| log.txt | `ERROR` | 1250125 | -n | 32.8 | 5.5x | 206.2 | 1.0x | 6.29x |
| log.txt | `ERROR` | 1250125 | -c | 24.8 | 5.2x | 93.9 | 1.0x | 3.79x |
| log.txt | `latency=1999ms` | 2471 | lines | 23.5 | 4.6x | 71.2 | 1.0x | 3.03x |
| log.txt | `latency=1999ms` | 2471 | -n | 24.7 | 4.9x | 82.3 | 1.0x | 3.33x |
| log.txt | `latency=1999ms` | 2471 | -c | 23.0 | 5.0x | 70.9 | 1.0x | 3.08x |
| log.txt | `[auth]` | 1001621 | lines | 25.5 | 5.2x | 133.8 | 1.0x | 5.24x |
| log.txt | `[auth]` | 1001621 | -n | 30.5 | 4.8x | 196.0 | 1.0x | 6.43x |
| log.txt | `[auth]` | 1001621 | -c | 23.7 | 5.1x | 105.2 | 1.0x | 4.44x |
| log.txt | `req=0000` | 78 | lines | 23.3 | 4.5x | 67.5 | 1.0x | 2.90x |
| log.txt | `req=0000` | 78 | -n | 24.4 | 4.8x | 78.9 | 1.0x | 3.24x |
| log.txt | `req=0000` | 78 | -c | 22.6 | 5.0x | 67.4 | 1.0x | 2.98x |
| log.txt | `/api/v2/items/` | 1668884 | lines | 28.5 | 5.1x | 151.3 | 1.0x | 5.30x |
| log.txt | `/api/v2/items/` | 1668884 | -n | 33.1 | 5.6x | 245.3 | 1.0x | 7.42x |
| log.txt | `/api/v2/items/` | 1668884 | -c | 25.2 | 5.0x | 104.5 | 1.0x | 4.15x |

speedup over 39 cells: min 2.40x, median 3.24x, geometric mean 4.25x, max 17.47x

## Warm cache, one thread (-j 1 for both)

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | 1 | lines | 54.2 | 1.0x | 56.3 | 1.0x | 1.04x |
| words.txt | `needle_zz` | 1 | -n | 58.9 | 1.0x | 67.2 | 1.0x | 1.14x |
| words.txt | `needle_zz` | 1 | -c | 50.8 | 1.0x | 56.5 | 1.0x | 1.11x |
| words.txt | `qzxjv` | 0 | lines | 54.4 | 1.0x | 56.6 | 1.0x | 1.04x |
| words.txt | `qzxjv` | 0 | -n | 59.1 | 1.0x | 67.9 | 1.0x | 1.15x |
| words.txt | `qzxjv` | 0 | -c | 51.6 | 1.0x | 56.9 | 1.0x | 1.10x |
| words.txt | `zebra` | 33512 | lines | 56.3 | 1.0x | 60.3 | 1.0x | 1.07x |
| words.txt | `zebra` | 33512 | -n | 61.5 | 1.0x | 74.0 | 1.0x | 1.20x |
| words.txt | `zebra` | 33512 | -c | 53.6 | 1.0x | 59.2 | 1.0x | 1.10x |
| words.txt | `xq` | 37320 | lines | 55.1 | 1.0x | 58.8 | 1.0x | 1.07x |
| words.txt | `xq` | 37320 | -n | 60.8 | 1.0x | 72.8 | 1.0x | 1.20x |
| words.txt | `xq` | 37320 | -c | 51.7 | 1.0x | 57.9 | 1.0x | 1.12x |
| words.txt | `ing ` | 2100750 | lines | 132.0 | 1.0x | 261.4 | 1.0x | 1.98x |
| words.txt | `ing ` | 2100750 | -n | 158.0 | 1.0x | 400.4 | 1.0x | 2.53x |
| words.txt | `ing ` | 2100750 | -c | 111.1 | 1.0x | 196.7 | 1.0x | 1.77x |
| words.txt | `the` | 4675899 | lines | 228.2 | 1.0x | 380.1 | 1.0x | 1.67x |
| words.txt | `the` | 4675899 | -n | 268.8 | 1.0x | 676.6 | 1.0x | 2.52x |
| words.txt | `the` | 4675899 | -c | 189.9 | 1.0x | 245.9 | 1.0x | 1.29x |
| words.txt | `a` | 9303679 | lines | 269.9 | 1.0x | 615.1 | 1.0x | 2.28x |
| words.txt | `a` | 9303679 | -n | 320.8 | 1.0x | 1137.4 | 1.0x | 3.55x |
| words.txt | `a` | 9303679 | -c | 214.9 | 1.0x | 387.5 | 1.0x | 1.80x |
| log.txt | `unique_token_7731` | 1 | lines | 57.3 | 1.0x | 58.7 | 1.0x | 1.02x |
| log.txt | `unique_token_7731` | 1 | -n | 61.6 | 1.0x | 69.5 | 1.0x | 1.13x |
| log.txt | `unique_token_7731` | 1 | -c | 56.6 | 1.0x | 58.4 | 1.0x | 1.03x |
| log.txt | `ERROR` | 1250125 | lines | 80.8 | 1.0x | 129.6 | 1.0x | 1.60x |
| log.txt | `ERROR` | 1250125 | -n | 93.6 | 1.0x | 205.6 | 1.0x | 2.20x |
| log.txt | `ERROR` | 1250125 | -c | 76.6 | 1.0x | 93.9 | 1.0x | 1.23x |
| log.txt | `latency=1999ms` | 2471 | lines | 61.6 | 1.0x | 71.1 | 1.0x | 1.15x |
| log.txt | `latency=1999ms` | 2471 | -n | 66.0 | 1.0x | 82.2 | 1.0x | 1.24x |
| log.txt | `latency=1999ms` | 2471 | -c | 61.3 | 1.0x | 71.0 | 1.0x | 1.16x |
| log.txt | `[auth]` | 1001621 | lines | 75.2 | 1.0x | 133.7 | 1.0x | 1.78x |
| log.txt | `[auth]` | 1001621 | -n | 86.6 | 1.0x | 196.0 | 1.0x | 2.26x |
| log.txt | `[auth]` | 1001621 | -c | 71.9 | 1.0x | 105.0 | 1.0x | 1.46x |
| log.txt | `req=0000` | 78 | lines | 56.9 | 1.0x | 67.4 | 1.0x | 1.18x |
| log.txt | `req=0000` | 78 | -n | 62.0 | 1.0x | 78.9 | 1.0x | 1.27x |
| log.txt | `req=0000` | 78 | -c | 57.0 | 1.0x | 67.5 | 1.0x | 1.19x |
| log.txt | `/api/v2/items/` | 1668884 | lines | 90.5 | 1.0x | 151.3 | 1.0x | 1.67x |
| log.txt | `/api/v2/items/` | 1668884 | -n | 108.6 | 1.0x | 244.4 | 1.0x | 2.25x |
| log.txt | `/api/v2/items/` | 1668884 | -c | 87.2 | 1.0x | 105.0 | 1.0x | 1.20x |

speedup over 39 cells: min 1.02x, median 1.20x, geometric mean 1.43x, max 3.55x

## Worst cases (stress corpora, patterns of only common bytes, long patterns)

Single spaces and common letters, 40- and 200-byte patterns, a file of 20 KB to 600 KB lines (long.txt), a file of 0 to 3 character lines (short.txt) and random binary data (random.bin). rg runs with -a. Output verified identical for all cases.

### All cores

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | ` ` | 9570168 | lines | 55.6 | 6.4x | 596.1 | 1.0x | 10.72x |
| words.txt | ` ` | 9570168 | -n | 67.1 | 6.5x | 1126.5 | 1.0x | 16.78x |
| words.txt | ` ` | 9570168 | -c | 43.7 | 6.3x | 368.3 | 1.0x | 8.43x |
| words.txt | `e ` | 6270085 | lines | 57.5 | 6.5x | 482.3 | 1.0x | 8.39x |
| words.txt | `e ` | 6270085 | -n | 66.9 | 6.6x | 902.4 | 1.0x | 13.49x |
| words.txt | `e ` | 6270085 | -c | 47.1 | 6.4x | 312.9 | 1.0x | 6.64x |
| words.txt | `e t` | 840018 | lines | 28.6 | 5.6x | 144.5 | 1.0x | 5.06x |
| words.txt | `e t` | 840018 | -n | 32.9 | 5.6x | 206.8 | 1.0x | 6.28x |
| words.txt | `e t` | 840018 | -c | 26.3 | 4.9x | 120.2 | 1.0x | 4.57x |
| words.txt | `the ` | 2065023 | lines | 35.1 | 5.9x | 253.9 | 1.0x | 7.23x |
| words.txt | `the ` | 2065023 | -n | 41.7 | 6.0x | 393.4 | 1.0x | 9.44x |
| words.txt | `the ` | 2065023 | -c | 31.1 | 5.7x | 194.5 | 1.0x | 6.25x |
| words.txt | `ing the` | 76335 | lines | 24.7 | 5.0x | 64.7 | 1.0x | 2.62x |
| words.txt | `ing the` | 76335 | -n | 26.1 | 5.0x | 82.0 | 1.0x | 3.15x |
| words.txt | `ing the` | 76335 | -c | 24.6 | 5.0x | 62.5 | 1.0x | 2.54x |
| words.txt | ` a ` | 0 | lines | 24.0 | 4.9x | 115.3 | 1.0x | 4.81x |
| words.txt | ` a ` | 0 | -n | 25.6 | 4.9x | 127.0 | 1.0x | 4.97x |
| words.txt | ` a ` | 0 | -c | 24.1 | 5.0x | 115.3 | 1.0x | 4.78x |
| words.txt | `tion` | 2875489 | lines | 41.8 | 6.1x | 340.2 | 1.0x | 8.14x |
| words.txt | `tion` | 2875489 | -n | 48.4 | 6.1x | 520.5 | 1.0x | 10.75x |
| words.txt | `tion` | 2875489 | -c | 35.9 | 6.0x | 251.7 | 1.0x | 7.02x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | lines | 24.4 | 5.0x | 59.3 | 1.0x | 2.43x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -n | 25.9 | 5.0x | 70.9 | 1.0x | 2.74x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -c | 24.4 | 4.7x | 59.4 | 1.0x | 2.43x |
| long.txt | ` ` | 1655 | lines | 23.5 | 4.8x | 45.6 | 1.0x | 1.94x |
| long.txt | ` ` | 1655 | -n | 23.7 | 5.0x | 57.7 | 1.0x | 2.43x |
| long.txt | ` ` | 1655 | -c | 23.1 | 5.0x | 44.0 | 1.0x | 1.91x |
| long.txt | `th` | 1655 | lines | 23.5 | 4.8x | 45.6 | 1.0x | 1.94x |
| long.txt | `th` | 1655 | -n | 23.8 | 5.0x | 57.9 | 1.0x | 2.43x |
| long.txt | `th` | 1655 | -c | 22.8 | 4.7x | 44.2 | 1.0x | 1.94x |
| long.txt | `needle_zz` | 1 | lines | 23.6 | 4.9x | 52.0 | 1.0x | 2.20x |
| long.txt | `needle_zz` | 1 | -n | 25.0 | 5.0x | 62.6 | 1.0x | 2.51x |
| long.txt | `needle_zz` | 1 | -c | 23.4 | 5.0x | 52.0 | 1.0x | 2.22x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | lines | 23.9 | 5.0x | 55.8 | 1.0x | 2.33x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -n | 25.3 | 4.9x | 66.7 | 1.0x | 2.64x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -c | 23.6 | 4.7x | 55.3 | 1.0x | 2.34x |
| short.txt | `a` | 37967876 | lines | 124.9 | 7.4x | 1546.5 | 1.0x | 12.38x |
| short.txt | `a` | 37967876 | -n | 177.0 | 7.3x | 2764.3 | 1.0x | 15.62x |
| short.txt | `a` | 37967876 | -c | 83.6 | 7.2x | 865.1 | 1.0x | 10.34x |
| short.txt | `ab c` | 0 | lines | 15.3 | 4.4x | 91.3 | 1.0x | 5.98x |
| short.txt | `ab c` | 0 | -n | 16.3 | 4.5x | 97.8 | 1.0x | 6.01x |
| short.txt | `ab c` | 0 | -c | 15.0 | 4.5x | 91.5 | 1.0x | 6.11x |
| short.txt | `needle_zz` | 1 | lines | 14.9 | 4.5x | 33.4 | 1.0x | 2.24x |
| short.txt | `needle_zz` | 1 | -n | 15.9 | 4.7x | 39.5 | 1.0x | 2.48x |
| short.txt | `needle_zz` | 1 | -c | 14.6 | 4.5x | 33.3 | 1.0x | 2.28x |
| random.bin | `ab` | 8209 | lines | 25.1 | 5.0x | 58.5 | 1.0x | 2.33x |
| random.bin | `ab` | 8209 | -n | 26.1 | 4.9x | 70.8 | 1.0x | 2.72x |
| random.bin | `ab` | 8209 | -c | 24.4 | 4.7x | 57.5 | 1.0x | 2.35x |
| random.bin | `abc` | 38 | lines | 24.5 | 4.9x | 58.6 | 1.0x | 2.39x |
| random.bin | `abc` | 38 | -n | 25.9 | 5.0x | 69.9 | 1.0x | 2.69x |
| random.bin | `abc` | 38 | -c | 24.4 | 5.1x | 58.5 | 1.0x | 2.40x |
| random.bin | `needle_zz` | 1 | lines | 24.7 | 4.9x | 57.3 | 1.0x | 2.31x |
| random.bin | `needle_zz` | 1 | -n | 25.7 | 5.0x | 68.7 | 1.0x | 2.67x |
| random.bin | `needle_zz` | 1 | -c | 24.3 | 5.0x | 57.0 | 1.0x | 2.35x |

speedup over 54 cells: min 1.91x, median 2.72x, geometric mean 4.03x, max 16.78x

### One thread (-j 1 for both)

| file | pattern | matching lines | output | zg ms | zg CPU/wall | rg ms | rg CPU/wall | zg speedup |
|---|---|---|---|---|---|---|---|---|
| words.txt | ` ` | 9570168 | lines | 261.9 | 1.0x | 597.0 | 1.0x | 2.28x |
| words.txt | ` ` | 9570168 | -n | 309.8 | 1.0x | 1122.7 | 1.0x | 3.62x |
| words.txt | ` ` | 9570168 | -c | 207.8 | 1.0x | 367.2 | 1.0x | 1.77x |
| words.txt | `e ` | 6270085 | lines | 278.7 | 1.0x | 483.4 | 1.0x | 1.73x |
| words.txt | `e ` | 6270085 | -n | 322.4 | 1.0x | 904.1 | 1.0x | 2.80x |
| words.txt | `e ` | 6270085 | -c | 230.4 | 1.0x | 313.7 | 1.0x | 1.36x |
| words.txt | `e t` | 840018 | lines | 91.0 | 1.0x | 144.7 | 1.0x | 1.59x |
| words.txt | `e t` | 840018 | -n | 102.8 | 1.0x | 206.1 | 1.0x | 2.00x |
| words.txt | `e t` | 840018 | -c | 82.0 | 1.0x | 120.2 | 1.0x | 1.47x |
| words.txt | `the ` | 2065023 | lines | 136.1 | 1.0x | 254.2 | 1.0x | 1.87x |
| words.txt | `the ` | 2065023 | -n | 159.5 | 1.0x | 393.0 | 1.0x | 2.46x |
| words.txt | `the ` | 2065023 | -c | 116.3 | 1.0x | 194.7 | 1.0x | 1.67x |
| words.txt | `ing the` | 76335 | lines | 60.7 | 1.0x | 64.8 | 1.0x | 1.07x |
| words.txt | `ing the` | 76335 | -n | 66.7 | 1.0x | 81.6 | 1.0x | 1.22x |
| words.txt | `ing the` | 76335 | -c | 59.7 | 1.0x | 62.3 | 1.0x | 1.04x |
| words.txt | ` a ` | 0 | lines | 55.5 | 1.0x | 115.4 | 1.0x | 2.08x |
| words.txt | ` a ` | 0 | -n | 60.8 | 1.0x | 126.7 | 1.0x | 2.09x |
| words.txt | ` a ` | 0 | -c | 52.7 | 1.0x | 116.5 | 1.0x | 2.21x |
| words.txt | `tion` | 2875489 | lines | 171.3 | 1.0x | 340.0 | 1.0x | 1.98x |
| words.txt | `tion` | 2875489 | -n | 198.9 | 1.0x | 519.7 | 1.0x | 2.61x |
| words.txt | `tion` | 2875489 | -c | 145.1 | 1.0x | 251.9 | 1.0x | 1.74x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | lines | 56.0 | 1.0x | 59.1 | 1.0x | 1.05x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -n | 60.7 | 1.0x | 70.5 | 1.0x | 1.16x |
| words.txt | `gumian leinger exfo thespl ri thecon it ` | 1 | -c | 54.4 | 1.0x | 59.7 | 1.0x | 1.10x |
| long.txt | ` ` | 1655 | lines | 47.8 | 1.0x | 46.0 | 1.0x | 0.96x |
| long.txt | ` ` | 1655 | -n | 49.3 | 1.0x | 58.5 | 1.0x | 1.19x |
| long.txt | ` ` | 1655 | -c | 45.7 | 1.0x | 45.2 | 1.0x | 0.99x |
| long.txt | `th` | 1655 | lines | 47.6 | 1.0x | 45.5 | 1.0x | 0.96x |
| long.txt | `th` | 1655 | -n | 49.9 | 1.0x | 58.1 | 1.0x | 1.17x |
| long.txt | `th` | 1655 | -c | 45.3 | 1.0x | 44.7 | 1.0x | 0.99x |
| long.txt | `needle_zz` | 1 | lines | 56.4 | 1.0x | 52.1 | 1.0x | 0.93x |
| long.txt | `needle_zz` | 1 | -n | 60.3 | 1.0x | 62.6 | 1.0x | 1.04x |
| long.txt | `needle_zz` | 1 | -c | 53.7 | 1.0x | 52.5 | 1.0x | 0.98x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | lines | 57.9 | 1.0x | 55.7 | 1.0x | 0.96x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -n | 61.6 | 1.0x | 66.4 | 1.0x | 1.08x |
| long.txt | ` t glmelczooi bdoadseo zre tetaa roimom mseenmsssptbvtvbeos p jrrz qdkovcsdc   sfspdtef seaapasct phmtaaga s iibzocmvatt atc bi  ipvtc afsctvjvstmuebneogi aeansp btipes e eooa o idws t aeimwpsn gow pn` | 146 | -c | 55.3 | 1.0x | 56.0 | 1.0x | 1.01x |
| short.txt | `a` | 37967876 | lines | 746.5 | 1.0x | 1549.9 | 1.0x | 2.08x |
| short.txt | `a` | 37967876 | -n | 1020.6 | 1.0x | 2763.9 | 1.0x | 2.71x |
| short.txt | `a` | 37967876 | -c | 502.4 | 1.0x | 858.4 | 1.0x | 1.71x |
| short.txt | `ab c` | 0 | lines | 28.1 | 1.0x | 91.1 | 1.0x | 3.24x |
| short.txt | `ab c` | 0 | -n | 30.8 | 1.0x | 97.2 | 1.0x | 3.16x |
| short.txt | `ab c` | 0 | -c | 28.2 | 1.0x | 91.3 | 1.0x | 3.24x |
| short.txt | `needle_zz` | 1 | lines | 21.4 | 1.0x | 33.2 | 1.0x | 1.55x |
| short.txt | `needle_zz` | 1 | -n | 25.0 | 1.0x | 39.3 | 1.0x | 1.57x |
| short.txt | `needle_zz` | 1 | -c | 21.4 | 1.0x | 33.1 | 1.0x | 1.55x |
| random.bin | `ab` | 8209 | lines | 56.0 | 1.0x | 58.9 | 1.0x | 1.05x |
| random.bin | `ab` | 8209 | -n | 60.9 | 1.0x | 70.9 | 1.0x | 1.16x |
| random.bin | `ab` | 8209 | -c | 53.0 | 1.0x | 57.9 | 1.0x | 1.09x |
| random.bin | `abc` | 38 | lines | 55.3 | 1.0x | 58.8 | 1.0x | 1.06x |
| random.bin | `abc` | 38 | -n | 59.9 | 1.0x | 70.2 | 1.0x | 1.17x |
| random.bin | `abc` | 38 | -c | 52.9 | 1.0x | 59.4 | 1.0x | 1.12x |
| random.bin | `needle_zz` | 1 | lines | 55.1 | 1.0x | 57.4 | 1.0x | 1.04x |
| random.bin | `needle_zz` | 1 | -n | 59.9 | 1.0x | 68.5 | 1.0x | 1.14x |
| random.bin | `needle_zz` | 1 | -c | 52.8 | 1.0x | 57.6 | 1.0x | 1.09x |

speedup over 54 cells: min 0.93x, median 1.36x, geometric mean 1.49x, max 3.62x

## Shared engine under concurrency

`zig build stress -- words.txt small8m.txt` (the first 8 MB of words.txt), in process, one
`Engine(.shared)` with the default settings.

Scaling: 10 searches per caller of `-c needle_zz` on words.txt

| callers | wall ms | ms per search (wall / searches) | vs 1 caller | latency p50 | p99 | max |
|---|---|---|---|---|---|---|
| 1 | 181 | 18.13 | 1.00x | 17.7 | 22.5 | 22.5 |
| 2 | 305 | 15.25 | 1.19x | 30.2 | 33.8 | 33.8 |
| 4 | 584 | 14.61 | 1.24x | 56.3 | 77.5 | 77.5 |
| 8 | 1147 | 14.34 | 1.26x | 111.5 | 146.3 | 146.3 |
| 16 | 2466 | 15.41 | 1.18x | 245.4 | 362.4 | 368.3 |

Mixed load: 4 callers x 50 searches of `-c needle_zz` on small8m.txt, alone and next to `the` (all lines) on words.txt (1 heavy searches meanwhile)

| small searches | p50 ms | p99 ms | max ms |
|---|---|---|---|
| alone | 0.77 | 10.24 | 10.28 |
| next to the heavy search | 0.65 | 1.95 | 1.98 |

The p99 of the small searches alone comes from one slow search out of 200 in this run; the
runs before it gave 1.2 to 1.4 ms.

Peak of the memory zg allocated (anonymous, without mapped file pages): 107 MB

## Measurement and system state

Single-thread numbers on this Mac depend on the state of the system, not only on the code. Two runs of the same matrix with the same build gave a single-thread minimum of 0.88x and 1.43x. Three effects were isolated with a probe build (per-phase timing and `getrusage`):

- **Mapped access to a cached file can get slow ("state C").** For some cached files, at some times, access through a mapping takes an extra kernel trap per page that is not counted as a fault: a second pass over an already faulted mapping still spends about 15 ms in the kernel for 512 MB, and user time doubles. `MADV_WILLNEED` stops paying off. `read`/`pread` copy from the page cache in the kernel and are not affected, which is the path rg takes on macOS (its peak RSS is about 7 MB on a 512 MB file). The state is per file and comes and goes on its own; memory pressure, efficiency cores and `MAP_PRIVATE` vs `MAP_SHARED` were ruled out. zg measures the access methods on the file itself and moves to `pread` in that state.
- **CPU frequency after idle.** After about 20 s of idle, a run of about 20 ms is about 1.9x slower (user and system time alike, `pread` too). The matrix runs back to back and is not affected; single timings should follow some CPU load.
- **First run of a new binary.** macOS scans a freshly built or copied binary on its first run (XprotectService, syspolicyd): 50 to 360 ms more, and a slower run while the scan goes on. Binaries are run once before measuring.

The `long.txt` cells of the one-thread worst-case table were measured in state C: there zg reads with `pread` and pays the same kernel copy as rg (about 30 ms for 512 MB on one core), so it ends at 0.93x to 1.19x of rg (behind only with plain output or `-c`). In the normal state, `th` on `long.txt` (plain output and `-c`) took about 29 to 30 ms for zg against 42 to 44 ms for rg (about 1.45x) in separate runs.

Changes behind these tables, from A/B runs against the previous build (same matrices, runs alternating):

- Filter bytes re-picked on a 64 KB sample when the static pair hits more than once per 2048 bytes (`Searcher.repick`): one thread `[auth]` -21 to -23 %, `latency=1999ms` -15 to -17 %, `req=0000` -13 to -15 %, ` a ` -7 to -17 %, `ing ` -7 to -10 %; all cores neutral (geometric mean 0.984 and 0.996).
- Access methods tried on runs of 6 chunks by one thread, the first 2 not counted, and waits for earlier chunks (`-n`) left out of the timing: one thread `long.txt` -11 % in state C, `log.txt` `-c` cells +3 % in the normal state (the cost of trying the slower methods); all cores unchanged (several threads keep trying single chunks).

The sections below were measured with an earlier build (before the two changes above) and not repeated.

## Adversarial inputs (256 MB, needle of 1000 `a`, best of 3)

`adv1`: lines of 999 `a` (every line shorter than the needle). `adv2`: one 256 MB line of
(`a` x 999 + `b`) repeated, so that every position is a candidate that fails late.
Before: the zg build without the Two-Way fallback and with line-based chunks.

| input | zg before | zg now | rg |
|---|---|---|---|
| adv1, `-c` | 813 ms | 27 ms | 467 ms |
| adv2, `-c` | 4401 ms | 27 ms | 489 ms |
| adv2, `-n ab` (prints the 256 MB line) | 340 ms | 13 ms | 78 ms |

## Peak memory footprint (MB, from /usr/bin/time -l)

| file | pattern | output | zg default | zg --mem=256M | zg -j 1 | rg |
|---|---|---|---|---|---|---|
| words.txt | `needle_zz` | lines | 35 | 4 | 2 | 2 |
| words.txt | `needle_zz` | -n | 2 | 2 | 2 | 2 |
| words.txt | `the` | lines | 75 | 50 | 6 | 2 |
| words.txt | `the` | -n | 173 | 82 | 63 | 2 |
| words.txt | `a` | lines | 114 | 62 | 9 | 2 |
| words.txt | `a` | -n | 269 | 130 | 119 | 2 |
| log.txt | `ERROR` | lines | 60 | 41 | 4 | 2 |
| log.txt | `ERROR` | -n | 53 | 29 | 20 | 2 |
| log.txt | `/api/v2/items/` | lines | 61 | 46 | 4 | 2 |
| log.txt | `/api/v2/items/` | -n | 125 | 36 | 25 | 2 |

## Cold page cache (first read from disk)

| pattern | output | zg ms | rg ms | zg speedup |
|---|---|---|---|---|
| `needle_zz` | -c | 310 | 319 | 1.03x |
| `the` | -c | 312 | 321 | 1.03x |
