#!/bin/sh
# Silesia (default) or Canterbury benchmark of tar against gzip, pigz, libdeflate,
# zstd, xz, bzip2, brotli and lz4. Needs those tools, bsdtar and hyperfine-free python3.
#   BENDS="main=../tar" ./run.sh [silesia|canterbury] [REPS]
#   BENDS="main=/x/tar-main integration=/x/tar-int" WRAP="heavy.sh 580 3072 --" ./run.sh
# Results land in results/<corpus>-<group>.json; the table prints as it goes.
set -eu
cd "$(dirname "$0")"
CORPUS=${1:-silesia}; REPS=${2:-3}
: "${BENDS:=main=../tar}"; : "${TWIN:=../tar-c}"; : "${WORK:=$PWD/work}"; WRAP=${WRAP:-}
export BENDS TWIN WORK
mkdir -p corpus results "$WORK"
if [ ! -d "corpus/$CORPUS" ]; then
  mkdir -p "corpus/$CORPUS.dl" "corpus/$CORPUS"
  case $CORPUS in
    silesia)    curl -fsSL -o corpus/$CORPUS.dl/a.zip https://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip
                (cd corpus/$CORPUS && unzip -q ../$CORPUS.dl/a.zip) ;;
    canterbury) curl -fsSL -o corpus/$CORPUS.dl/a.tgz https://corpus.canterbury.ac.nz/resources/cantrbry.tar.gz
                (cd corpus/$CORPUS && tar xzf ../$CORPUS.dl/a.tgz) ;;
    *) echo "unknown corpus $CORPUS" >&2; exit 2 ;;
  esac
fi
C=$PWD/corpus/$CORPUS
$WRAP ./prep.sh "$C"
for g in create levels strong extract; do
  r=$REPS; [ $g = strong ] && r=1
  $WRAP python3 -I bench.py $g $r "$C" "results/$CORPUS-$g.json"
done
