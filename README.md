# tar

Standalone repository: [nicolas-abril/bend2-tar-demo](https://github.com/nicolas-abril/bend2-tar-demo).
Extracted from `bend3-demos/tar` with its Git history.

Requires the `bend` CLI on `PATH` and a C compiler. With a neighboring
`bend2-core` checkout, use `make BEND="bun ../bend2-core/bend2/main.ts"`.

A bsdtar-style archiver in Bend: create, list and extract ustar archives,
gzip'd or not, with a DEFLATE encoder (dynamic Huffman over LZ77) and
decoder written in Bend. `tar.c` is the C twin: the same layout, container,
inflate and deflate. Default-level archives remain byte-identical.

A Bend binary takes no arguments, so the command line rides `TAR_ARGS` in
bsdtar's spelling:

    TAR_ARGS="-czvf out.tgz a.txt b.txt" ./tar
    TAR_ARGS="-tzf out.tgz"              ./tar
    TAR_ARGS="-xvf in.tar"               ./tar

Flags: `c` create, `x` extract, `t` list, `f FILE` (`-` for stdin/stdout),
`z` gzip, `v` verbose, `0`-`9` the gzip level (6 by default). Bytes ride
packed word arrays through the foreign effects under `effs/`. There is
no mkdir or readdir, so an archive holds the files named on the command
line and directory entries are skipped.

Plain creation is streamed: Bend constructs each ustar header, then the sink
effect writes that header, copies the member, and adds its padding in order.
Member contents are never copied into a whole-archive array. Gzip creation
builds the logical tar stream in bounded batches. A temporary user-defined
runtime effect reads the effective native worker count (`--threads`, or its
detected default; one in JavaScript). Each worker task owns at most 992 KiB and
compresses it as eight adjacent 124 KiB DEFLATE streams, retaining its matcher
tables between streams. Incompressible streams therefore fit in their initial
128 KiB output Arrays. The task count follows the worker count (rounded up for
an odd pool and capped at sixty-two), so an eight-worker batch remains near
8 MiB while every worker receives a long-lived task. Bend writes a completed
batch before allocating and producing the next one and carries only the
preceding 32 KiB dictionary between batches. This effect can be removed when Bend
provides the public API requested in
[bendlang/bend#971](https://github.com/bendlang/bend/issues/971).
CRC-32 is updated incrementally by a foreign packed-array primitive that uses
ARM64 CRC instructions when available and a portable implementation elsewhere.

Plain listing is streamed by reading one 512-byte header at a time from an
open file and advancing past member payloads without reading them. Stdin keeps
the sequential whole-input path because pipes cannot seek. Gzip inflate reads
ISIZE up front, writes directly into packed output, copies stored data and
backreferences four bytes at a time where possible, and uses a nine-bit primary
Huffman table with a canonical fallback for longer codes.

`make` builds `tar`; `make smoke` builds both, archives two files with each,
compares the archives byte for byte, lists, extracts and compares the files.
