#!/bin/sh
# prep.sh CORPUS_DIR: the reference tar stream and archives the harness compares against
set -eu
W=${WORK:?}; mkdir -p "$W"; cd "$1"
bsdtar -cf - $(ls | sort) > "$W/ref.tar"
gzip -6 -c "$W/ref.tar" > "$W/ref.tgz"
zstd -3 -q -f -c "$W/ref.tar" > "$W/ref.zst"
xz -6 -T0 -c "$W/ref.tar" > "$W/ref.xz"
