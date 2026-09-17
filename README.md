# tar

Standalone repository: [nicolas-abril/bend2-tar-demo](https://github.com/nicolas-abril/bend2-tar-demo).
Extracted from `bend3-demos/tar` with its Git history.

Requires the `bend` CLI on `PATH` and a C compiler. With a neighboring
`bend2-core` checkout, use `make BEND="bun ../bend2-core/bend2/main.ts"`.

A bsdtar-style archiver in Bend: create, list and extract ustar archives,
gzip'd or not, with a DEFLATE encoder (dynamic Huffman over LZ77) and
decoder written in Bend. `tar.c` is the C twin: the same layout, container,
inflate and deflate, so the two produce byte-identical archives.

A Bend binary takes no arguments, so the command line rides `TAR_ARGS` in
bsdtar's spelling:

    TAR_ARGS="-czvf out.tgz a.txt b.txt" ./tar
    TAR_ARGS="-tzf out.tgz"              ./tar
    TAR_ARGS="-xvf in.tar"               ./tar

Flags: `c` create, `x` extract, `t` list, `f FILE` (`-` for stdin/stdout),
`z` gzip, `v` verbose, `0`-`9` the gzip level (6 by default). Bytes ride
packed word arrays through the two foreign effects under `effs/`. There is
no mkdir or readdir, so an archive holds the files named on the command
line and directory entries are skipped.

`make` builds `tar`; `make smoke` builds both, archives two files with each,
compares the archives byte for byte, lists, extracts and compares the files.
