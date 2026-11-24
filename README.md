# tar

Standalone repository: [nicolas-abril/bend2-tar-demo](https://github.com/nicolas-abril/bend2-tar-demo).
Extracted from `bend3-demos/tar` with its Git history.

Requires Bend 2.0.40 or newer (the `bend` CLI on `PATH`; tested on
bendlang/bend main 3d5bf43d) and a C compiler.
With a neighboring `bend2-core` checkout, use
`make BEND="bun ../bend2-core/bend2/main.ts"`.

A bsdtar-style archiver in Bend: create, list and extract ustar archives,
gzip'd or not, with a DEFLATE encoder (dynamic Huffman over LZ77) and
decoder written in Bend. The archive, compression and byte layers are
BendHub packages built in
[bend2-libs](https://github.com/nicolas-abril/bend2-libs) and imported by
name: `gralha-ustar`, `gralha-gzip-frame`, `gralha-deflate`, `gralha-crc32`
and `gralha-byte-words`. `tar.bend` is the command line and the parallel
gzip batching. `tar.c` is the C twin: the same layout, container,
inflate and deflate. Plain archives are byte-identical; gzip archives are
byte-identical while the tar stream fits one 248 KiB compression task, and
past that the twin's 256 KiB chunks split the DEFLATE stream elsewhere.

The command line is bsdtar's spelling. With no arguments, it is read from
the `TAR_ARGS` environment variable instead:

    ./tar -czvf out.tgz a.txt b.txt
    ./tar -tzf out.tgz
    TAR_ARGS="-xvf in.tar" ./tar
    bend tar.bend -- -tzf out.tgz    # `--` ends bend's own options

Flags: `c` create, `x` extract, `t` list, `f FILE` (`-` for stdin/stdout),
`z` gzip, `v` verbose, `0`-`9` the gzip level (6 by default). Bytes ride
packed word arrays through `gralha-byte-words`' foreign effects. There is
no mkdir or readdir, so an archive holds the files named on the command
line and directory entries are skipped. The `TAR_ARGS` parser accepts up to
4096 words and stops as soon as the environment string ends. Bend's runtime
options go between `+RTS` and `-RTS` or in `BENDRTS`:
`./tar +RTS --threads 8 -RTS -czf out.tgz a b` or
`BENDRTS="--threads 8" ./tar -czf out.tgz a b`.

Plain creation is streamed: Bend constructs each ustar header, then the sink
effect writes that header, copies the member, and adds its padding in order.
Member contents are never copied into a whole-archive array. Gzip creation
builds the logical tar stream in bounded batches. Base's `IO.thread_count`
reads the effective native worker count (`+RTS --threads N`, or its detected
default; one in JavaScript). Each compression task owns at most
248 KiB, so incompressible output fits in its initial 256 KiB Array. The task
count is four times the worker count (capped at sixty), keeping an eight-worker
batch near 8 MiB while leaving enough independent work to balance uneven files
and heterogeneous cores. Bend writes a completed batch before allocating and
producing the next one and carries only the preceding 32 KiB dictionary between
batches.
The LZ77 matcher (gralha-deflate 0.1.0.1) chains on 4-byte hashes with a one-entry
3-byte table beside them, and extends a candidate only when its four bytes at the
start and at the best length both agree.
CRC-32 is updated incrementally by `gralha-crc32`'s packed-array primitive, which uses
ARM64 CRC instructions when available and a portable implementation elsewhere.

Plain listing is streamed by reading one 512-byte header at a time from an
open file and advancing past member payloads without reading them. Stdin keeps
the sequential whole-input path because pipes cannot seek. Gzip inflate reads
ISIZE up front, writes directly into packed output, copies stored data and
backreferences four bytes at a time where possible, and uses a nine-bit primary
Huffman table with a canonical fallback for longer codes.

Speed, ratio and memory on the Silesia corpus against gzip, pigz and libdeflate
are in [BENCHMARKS.md](BENCHMARKS.md): gzip's ratio, zlib's speed on one thread,
4.8x gzip on 10 threads and 1.19x behind pigz at -6.

`make` builds `tar`; `make smoke` builds both, archives two files with each,
compares the archives byte for byte (the inputs fit one task), lists, extracts and compares the files.
