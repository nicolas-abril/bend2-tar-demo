# Benchmarks

Corpus: the [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)
(12 files, 211,938,580 bytes), the usual corpus for comparing general-purpose
compressors (lzbench, zstd and libdeflate publish against it). Every command
archives the same 12 files: `tar` with its own gzip, the others as
`bsdtar -cf - FILES | COMPRESSOR`. Each output is decoded by the reference tool and
compared byte for byte with the inputs.

Machine: Apple M4 (4 performance + 6 efficiency cores), 16 GB, macOS 26, files in
the page cache. The machine was shared with other jobs (load average 4-7), so
each figure is the fastest of three runs (one for the "stronger formats" table).
CPU is user+sys of the whole process tree; peak RSS is the largest process.

Bend builds, 2026-11-24:

- **main**: bendlang/bend `main` at 3d5bf43d (Bend 2.0.40).
- **integration**: nicolas-abril/bend `opt/integration` at 1bae0165 (main plus the
  open performance drafts, 13 commits behind the main above).

`tar` imports gralha-byte-words, gralha-crc32, gralha-deflate, gralha-gzip-frame
and gralha-ustar 0.1.0.0. The C twin is `tar.c` (`cc -O2`).

## Summary

- **Ratio is gzip's.** At -1/-6/-9, Bend writes 2.754/3.096/3.134 against
  gzip's 2.743/3.106/3.133: the 248 KiB parallel tasks cost 0.3% at -6, and -1 and -9
  are as good as or better than zlib.
- **Compression, 10 threads:** 1.25 s at -6 (169 MB/s), 3.4x faster than
  gzip/bsdtar and on a par with the C twin and single-threaded libdeflate.
  pigz is 1.7x faster (0.74 s) and uses 40% less CPU.
- **Compression, one thread:** 7.1 s at -6 (30 MB/s), 1.65x slower than zlib
  (4.3 s) and 4.7x slower than libdeflate (1.5 s). Splitting over 10 threads costs
  about 40% more CPU in total (9.85 s against 7.1 s).
- **Memory:** creation peaks at 33 MB (5 MB on one thread), but extracting and listing
  inflate the whole archive in memory (532 MB / 453 MB for Silesia). gzip and bsdtar
  stream in 3 MB.
- **Extraction:** 0.96 s, 4x slower than bsdtar/gzip (0.24 s). Listing a .tgz costs
  as much as extracting it, because it inflates everything first.
- **main vs integration:** the same at default threads. Integration is 1% slower on
  one-thread creation (7.14 s ± 0.05 against 7.05 s ± 0.03, hyperfine, 10 runs) and 4% slower
  on extraction (982 ± 12 ms against 947 ± 10 ms, 15 runs). Output is byte-identical.
- For scale: zstd -3 gets a better ratio (3.20) in 0.26 s on one thread, and
  xz -6 reaches 4.28.

## Results

### Create a gzip'd archive, default level (tar + compress)

| command | wall (s) | MB/s | CPU (s) | peak RSS (MB) | bytes | ratio |
|---|--:|--:|--:|--:|--:|--:|
| bend main -6 | 1.25 | 169 | 9.85 | 33 | 68,447,016 | 3.096 |
| bend integration -6 | 1.26 | 168 | 10.00 | 33 | 68,447,016 | 3.096 |
| bend main -6 (1 thread) | 7.11 | 30 | 7.11 | 5 | 68,447,016 | 3.096 |
| bend integration -6 (1 thread) | 7.27 | 29 | 7.31 | 5 | 68,447,016 | 3.096 |
| C twin (tar.c) -6 | 1.31 | 162 | 8.54 | 1037 | 68,450,285 | 3.096 |
| bsdtar -czf (zlib -6) | 4.26 | 50 | 4.26 | 4 | 68,228,712 | 3.106 |
| gzip -6 | 4.30 | 49 | 4.41 | 3 | 68,228,782 | 3.106 |
| pigz -6 (10 threads) | 0.74 | 287 | 6.00 | 8 | 68,247,329 | 3.105 |
| pigz -6 -p1 | 4.26 | 50 | 4.30 | 3 | 68,247,329 | 3.105 |
| libdeflate-gzip -6 | 1.50 | 141 | 1.54 | 271 | 67,511,121 | 3.139 |
| zstd -3 | 0.26 | 826 | 0.61 | 60 | 66,218,742 | 3.201 |
| zstd -3 -T0 | 0.13 | 1599 | 0.83 | 155 | 66,218,742 | 3.201 |
| lz4 -1 | 0.15 | 1427 | 0.43 | 40 | 100,936,722 | 2.100 |
| brotli -5 | 2.43 | 87 | 2.45 | 836 | 60,918,421 | 3.479 |

### Levels 1 and 9

| command | wall (s) | MB/s | CPU (s) | peak RSS (MB) | bytes | ratio |
|---|--:|--:|--:|--:|--:|--:|
| bend main -1 | 0.62 | 344 | 4.73 | 33 | 76,947,871 | 2.754 |
| bend main -9 | 3.30 | 64 | 25.18 | 33 | 67,619,519 | 3.134 |
| bend integration -1 | 0.62 | 341 | 4.77 | 33 | 76,947,871 | 2.754 |
| bend integration -9 | 3.28 | 65 | 25.38 | 33 | 67,619,519 | 3.134 |
| gzip -1 | 1.30 | 163 | 1.33 | 3 | 77,260,213 | 2.743 |
| gzip -9 | 10.40 | 20 | 10.45 | 3 | 67,644,311 | 3.133 |
| pigz -1 (10 threads) | 0.24 | 882 | 1.97 | 8 | 77,188,667 | 2.746 |
| pigz -9 (10 threads) | 1.91 | 111 | 14.57 | 8 | 67,666,537 | 3.132 |
| libdeflate-gzip -1 | 0.69 | 307 | 0.70 | 276 | 73,505,871 | 2.883 |
| libdeflate-gzip -9 | 4.25 | 50 | 4.26 | 270 | 66,716,547 | 3.177 |

### Stronger formats, for scale (one run)

| command | wall (s) | MB/s | CPU (s) | peak RSS (MB) | bytes | ratio |
|---|--:|--:|--:|--:|--:|--:|
| bzip2 -9 | 9.82 | 22 | 9.86 | 8 | 54,593,415 | 3.882 |
| xz -6 -T0 | 11.25 | 19 | 69.81 | 1087 | 49,500,656 | 4.282 |
| zstd -19 -T0 | 16.34 | 13 | 80.50 | 825 | 52,849,570 | 4.010 |

### Extract and list (all gzip readers read the same `gzip -6` archive)

| command | wall (s) | MB/s (uncompressed) | CPU (s) | peak RSS (MB) |
|---|--:|--:|--:|--:|
| bend main -xzf | 0.96 | 222 | 0.93 | 532 |
| bend integration -xzf | 1.01 | 211 | 0.97 | 532 |
| C twin -xzf | 0.84 | 252 | 0.83 | 271 |
| bsdtar -xzf | 0.24 | 874 | 0.23 | 3 |
| gzip -dc \| bsdtar -x | 0.24 | 890 | 0.31 | 3 |
| pigz -dc \| bsdtar -x | 0.25 | 857 | 0.41 | 3 |
| libdeflate-gzip -dc \| bsdtar -x | 0.29 | 730 | 0.30 | 269 |
| zstd -dc \| bsdtar -x | 0.17 | 1229 | 0.29 | 7 |
| xz -dc -T0 \| bsdtar -x | 0.41 | 515 | 2.28 | 324 |
| bend main -tzf (list) | 0.85 | 250 | 0.84 | 453 |
| bend integration -tzf (list) | 0.88 | 242 | 0.88 | 453 |
| bsdtar -tzf (list) | 0.20 | 1078 | 0.19 | 3 |

## Reproducing

    make tar tar-c
    ./bench/run.sh                     # Silesia, 3 runs; results/ gets the JSON
    BENDS="main=/path/tar-main integration=/path/tar-int" ./bench/run.sh silesia 3

`run.sh` downloads the corpus into `bench/corpus/`. Set `WRAP` to a command prefix
such as a timeout or memory-cap wrapper; each group runs under it. It needs bsdtar, gzip,
pigz, libdeflate-gzip, zstd, xz, bzip2, brotli and lz4 on `PATH`.
