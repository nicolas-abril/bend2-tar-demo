# Benchmarks

Corpus: the [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)
(12 files, 211,938,580 bytes), the usual corpus for comparing general-purpose
compressors (lzbench, zstd and libdeflate publish against it). Every command
archives the same 12 files: `tar` with its own gzip, the others as
`bsdtar -cf - FILES | COMPRESSOR`. Each output is decoded by the reference tool and
compared byte for byte with the inputs. The like-for-like rivals are the other
DEFLATE (gzip) encoders: zlib (`gzip`, `bsdtar -z`), pigz and libdeflate. zstd, xz,
bzip2, brotli and lz4 are other formats, listed only for scale.

Machine: Apple M4 (4 performance + 6 efficiency cores), 16 GB, macOS 26, files in
the page cache, Apple's zlib 1.2.12. The machine was shared with other jobs (load
average 5-7), so each figure is the fastest of three runs (one for the other
formats), and the pigz comparison below is interleaved, ten runs each.
CPU is user+sys of the whole process tree; peak RSS is the largest process.

Builds, 2026-11-24:

- **main**: bendlang/bend `main` at 3d5bf43d (Bend 2.0.40).
- **integration**: nicolas-abril/bend `opt/integration` at 1af5908a.
- `tar` imports gralha-deflate 0.1.0.1 and gralha-gzip-frame 0.1.0.1 (the rest
  0.1.0.0). The C twin is `tar.c` (`cc -O2`), the same algorithm in C.

## Summary

| Silesia, 10 threads | Bend (gralha-deflate 0.1.0.0) | Bend now | pigz | pigz faster by |
|---|--:|--:|--:|--:|
| -1 | 0.62 s | 0.48 s | 0.25 s | 1.91x ± 0.09 |
| -6 | 1.25 s | 0.91 s | 0.76 s | 1.19x ± 0.08 |
| -9 | 3.30 s | 2.33 s | 1.85 s | 1.26x ± 0.05 |

(pigz rows: hyperfine, ten interleaved runs; `results/h2h-bend-vs-pigz-*.json`.)

- **Ratio is gzip's.** -1/-6/-9 write 2.811/3.103/3.134 against gzip's
  2.743/3.106/3.133.
- **One thread is now zlib's speed.** 4.52 s at -6 against zlib's 4.32 s (was
  7.11 s).
- **What is left to pigz is the runtime, not the algorithm.** The C twin runs the same
  algorithm in 3.17 s on one thread and 0.53 s on 10 threads, ahead of pigz. Bend
  costs 1.43x the C twin per core, and at -1, where there is little work per byte,
  the batch's serial reading, CRC and writing (about 0.1 s) are half the gap.
- **main vs integration:** the same output; integration is about 3% slower on
  one thread (4.67 s against 4.52 s) and the same on 10 threads.
- **Extraction is unchanged:** 0.96 s against bsdtar's 0.24 s, and it holds the whole
  inflated archive in memory (532 MB). Listing a .tgz costs the same.

## What changed (gralha-deflate 0.1.0.1)

One thread at -6, Silesia, step by step on the C twin (Bend followed each step,
staying byte-identical to it):

| step | C twin | Bend |
|---|--:|--:|
| 0.1.0.0: zlib's matcher, 3-byte hash chains | 6.37 s | 7.05 s |
| 4-byte hash chains + one-entry 3-byte table; a candidate is extended only when its first four bytes and the four ending at the best length agree | 4.44 s | 5.34 s |
| Huffman trees by two queues (the same tree, n log n), codes stored bit-reversed, length/distance codes by log2 | 3.17 s | 4.58 s |
| match extension by `U32.ctz` | | 4.51 s |

With zlib's 3-byte hash, the chain walk visited about 30 candidates a search,
over 90% of them rejected at the first compared byte; on 4-byte hashes far fewer
are visited, and the output got 0.2% smaller.

Tried and dropped:

- A per-chunk window array (one `Array.get` per four-byte read instead of
  `le32_at`'s two): 4% on one thread, nothing on 10, for 75% more memory.
- A native `U32.ctz` in the compiler: no measurable change, because Base's
  `U32.ctz` already compiles to a native popcount (and `comp.ts` is at its token
  cap).
- Larger batches (8 or 16 chunks a worker instead of 4): no change.
- Overlapping a batch's reads and writes with the next one's compression: a Bend
  program's computations share one event loop and run their pure code one at a
  time, so the effects cannot run beside the compression.

## Results

### Create a gzip'd archive, default level (tar + compress)

| command | wall (s) | MB/s | CPU (s) | peak RSS (MB) | bytes | ratio |
|---|--:|--:|--:|--:|--:|--:|
| bend main -6 | 0.88 | 240 | 6.42 | 34 | 68,303,749 | 3.103 |
| bend integration -6 | 0.89 | 239 | 6.61 | 34 | 68,303,749 | 3.103 |
| bend main -6 (1 thread) | 4.52 | 47 | 4.50 | 5 | 68,303,749 | 3.103 |
| bend integration -6 (1 thread) | 4.67 | 45 | 4.65 | 5 | 68,303,749 | 3.103 |
| C twin (tar.c) -6 | 0.53 | 398 | 4.42 | 867 | 68,306,585 | 3.103 |
| bsdtar -czf (zlib -6) | 4.32 | 49 | 4.32 | 4 | 68,228,712 | 3.106 |
| gzip -6 | 4.41 | 48 | 4.35 | 3 | 68,228,782 | 3.106 |
| pigz -6 (10 threads) | 0.78 | 273 | 6.05 | 8 | 68,247,329 | 3.105 |
| pigz -6 -p1 | 4.35 | 49 | 4.41 | 3 | 68,247,329 | 3.105 |
| libdeflate-gzip -6 | 1.51 | 140 | 1.52 | 271 | 67,511,121 | 3.139 |
| zstd -3 | 0.27 | 799 | 0.66 | 60 | 66,218,742 | 3.201 |
| zstd -3 -T0 | 0.15 | 1456 | 0.88 | 151 | 66,218,742 | 3.201 |
| lz4 -1 | 0.13 | 1652 | 0.40 | 45 | 100,936,722 | 2.100 |
| brotli -5 | 2.46 | 86 | 2.46 | 838 | 60,918,421 | 3.479 |

### Levels 1 and 9

| command | wall (s) | MB/s | CPU (s) | peak RSS (MB) | bytes | ratio |
|---|--:|--:|--:|--:|--:|--:|
| bend main -1 | 0.48 | 439 | 3.48 | 34 | 75,391,136 | 2.811 |
| bend main -9 | 2.22 | 96 | 15.57 | 34 | 67,624,457 | 3.134 |
| bend integration -1 | 0.51 | 414 | 3.63 | 34 | 75,391,136 | 2.811 |
| bend integration -9 | 2.27 | 93 | 16.06 | 34 | 67,624,457 | 3.134 |
| gzip -1 | 1.31 | 161 | 1.34 | 3 | 77,260,213 | 2.743 |
| gzip -9 | 10.53 | 20 | 10.61 | 3 | 67,644,311 | 3.133 |
| pigz -1 (10 threads) | 0.26 | 829 | 2.01 | 8 | 77,188,667 | 2.746 |
| pigz -9 (10 threads) | 1.92 | 111 | 14.89 | 8 | 67,666,537 | 3.132 |
| libdeflate-gzip -1 | 0.69 | 305 | 0.70 | 276 | 73,505,871 | 2.883 |
| libdeflate-gzip -9 | 4.28 | 50 | 4.30 | 270 | 66,716,547 | 3.177 |

### Other formats, for scale only (one run)

| command | wall (s) | MB/s | CPU (s) | peak RSS (MB) | bytes | ratio |
|---|--:|--:|--:|--:|--:|--:|
| bzip2 -9 | 10.21 | 21 | 9.99 | 9 | 54,593,415 | 3.882 |
| xz -6 -T0 | 11.82 | 18 | 70.43 | 1087 | 49,500,656 | 4.282 |
| zstd -19 -T0 | 16.72 | 13 | 81.26 | 825 | 52,849,570 | 4.010 |

### Extract and list (all gzip readers read the same `gzip -6` archive)

| command | wall (s) | MB/s (uncompressed) | CPU (s) | peak RSS (MB) |
|---|--:|--:|--:|--:|
| bend main -xzf | 0.96 | 221 | 0.94 | 532 |
| bend integration -xzf | 0.99 | 215 | 0.97 | 532 |
| C twin -xzf | 0.86 | 248 | 0.84 | 271 |
| bsdtar -xzf | 0.24 | 886 | 0.23 | 3 |
| gzip -dc \| bsdtar -x | 0.24 | 889 | 0.31 | 3 |
| pigz -dc \| bsdtar -x | 0.27 | 794 | 0.43 | 3 |
| libdeflate-gzip -dc \| bsdtar -x | 0.31 | 694 | 0.31 | 269 |
| zstd -dc \| bsdtar -x | 0.19 | 1135 | 0.34 | 7 |
| xz -dc -T0 \| bsdtar -x | 0.45 | 466 | 2.31 | 324 |
| bend main -tzf (list) | 0.85 | 248 | 0.85 | 453 |
| bend integration -tzf (list) | 0.88 | 240 | 0.88 | 453 |
| bsdtar -tzf (list) | 0.20 | 1064 | 0.20 | 3 |

## Reproducing

    make tar tar-c
    ./bench/run.sh                     # Silesia, 3 runs; results/ gets the JSON
    BENDS="main=/path/tar-main integration=/path/tar-int" ./bench/run.sh silesia 3

`run.sh` downloads the corpus into `bench/corpus/`. Set `WRAP` to a command prefix
such as a timeout or memory-cap wrapper; each group runs under it. It needs bsdtar, gzip,
pigz, libdeflate-gzip, zstd, xz, bzip2, brotli and lz4 on `PATH`.
