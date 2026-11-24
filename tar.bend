# tar: a bsdtar-style archiver in Bend — create, list and extract ustar
# archives, gzip'd or not, with a DEFLATE encoder (dynamic Huffman over
# LZ77) and decoder from the gralha packages. The command line is bsdtar's spelling;
# with no arguments, it is read from the TAR_ARGS environment variable:
#
#   bend tar.bend -czvf out.tgz a.txt b.txt
#   ./tar -tzf out.tgz
#   TAR_ARGS="-xvf in.tar" ./tar
#
# Flags: c create, x extract, t list, f FILE (- for stdin/stdout), z gzip,
# v verbose, 0-9 the gzip level (6 by default); bundled with or without
# the leading dash. Bytes ride packed word arrays, read and written by
# gralha-byte-words' foreign effects; there is no mkdir or readdir, so
# an archive holds the files named on the command line and directory
# entries are skipped.
#
# Spelling notes: a def recurses only on itself, so a loop's decision
# rides in as a parameter its caller computes (a peek at the next head),
# and a stage that opens a result is a helper the loop calls, never one
# that calls the loop back.
#
# The work is in five BendHub packages: gralha-byte-words, gralha-crc32,
# gralha-deflate, gralha-gzip-frame and gralha-ustar. This file is the
# command line and the bounded, parallel gzip batching.
import Base
import gralha-byte-words@0.1.0.0/words.bend as Words
import gralha-crc32@0.1.0.0/crc32.bend as Crc32
import gralha-deflate@0.1.0.1/deflate.bend as Deflate
import gralha-gzip-frame@0.1.0.1/gzip.bend as Gzip
import gralha-ustar@0.1.0.0/ustar.bend as Ustar

def pick(c: Bool, a: U32, b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

# Words
# -----

# split at the first space: (word, rest); space says whether s starts with one
def word(s: String, acc: String, space: Bool) -> String & String:
  match s, space:
    case rest, True{}:
      (Ustar.srev(acc, ""), Ustar.sdrop(1n, rest))
    case SNil{}, False{}:
      (Ustar.srev(acc, ""), "")
    case SCon{h, t}, False{}:
      +t2 = t
      word(t2, SCon{h, acc}, Ustar.head_is(t2, 32))

# Keep the last word and stop once no unparsed input remains. Without the
# SNil branch, a generous safety bound would manufacture empty words up to the
# bound on every invocation.
def split(n: Nat, w: String & String) -> List<&2, String>:
  match n, w:
    case 0n, rest:
      []
    case 1n+p, (h, SNil{}):
      [h]
    case 1n+p, (h, SCon{x, xs}):
      +r : String = SCon{x, xs}
      h <> split(p, word(r, "", Ustar.head_is(r, 32)))

def head_empty(l: List<&2, String>) -> Bool:
  match l:
    case Nil{}:
      False{}
    case Con{h, t}:
      String.eq(h, "")

# drops the empty words; e says whether l starts with one
def nonempty(l: List<&2, String>, e: Bool) -> List<&2, String>:
  match l, e:
    case Nil{}, k:
      []
    case Con{h, t}, True{}:
      +t2 = t
      nonempty(t2, head_empty(t2))
    case Con{h, t}, False{}:
      +t2 = t
      h <> nonempty(t2, head_empty(t2))

def words(+s: String) -> List<&2, String>:
  +l = split(4096n, word(s, "", Ustar.head_is(s, 32)))
  nonempty(l, head_empty(l))

def path_pick(f: String, dash: Bool, dev: String) -> String:
  match dash:
    case True{}:
      dev
    case False{}:
      f

def path_in(+f: String) -> String:
  path_pick(f, String.eq(f, "-"), "/dev/stdin")

def path_out(+f: String) -> String:
  path_pick(f, String.eq(f, "-"), "/dev/stdout")

def walk_in_gzip(r: Array<U32> & U32) -> IO(Unit):
  (a, n) = r
  Ustar.walk(Gzip.decode(a, n), False{}, False{})

def list_stream_peek(r: Array<U32> & Bool, file: File, +path: String, +n: U32, +got: U32) -> IO(Unit):
  (a, magic) = r
  match magic:
    case False{}:
      Ustar.list_file(file, a, got, path, n)
    case True{}:
      do IO<Unit>:
        Unit <- Words.drop(a)
        Unit <- File.close(file)
        packed : Array<U32> & U32 <- Words.read(path)
        walk_in_gzip(packed)

def list_stream_first(r: Words.Chunk, +path: String, +total: U32) -> IO(Unit):
  match r:
    case Words.Chunk{file, a, n}:
      +nn = n
      list_stream_peek(Gzip.is_gzip(a), file, path, total, nn)

def list_stream_open(file: File, +path: String, +n: U32) -> IO(Unit):
  do IO<Unit>:
    raw : File & Result<&1, &1, U32 & String, Array<U32> & U32> <- Words.file_read_at_raw(file, 0, 512)
    chunk : Words.Chunk <- Words.file_read_got(path, raw)
    list_stream_first(chunk, path, n)

def list_stream(+path: String) -> IO(Unit):
  do IO<Unit>:
    n : U32 <- Words.file_size(path)
    opened : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    file : File <- Words.open_got(path, opened)
    list_stream_open(file, path, n)

type Gc is Type:
  Gc{src: Array<U32>, dict: Array<U32>}

def batch_carry_pair(r: Array<U32> & Array<U32>) -> Gc:
  (src, dst) = r
  Gc{src, dst}

def batch_seed_pair(r: Array<U32> & Array<U32>, +cap: U32) -> IO(Words.Sink):
  (dict, dst) = r
  do IO<Words.Sink>:
    Unit <- Words.drop(dict)
    return Words.Sink{dst, cap, 32768}

# Four chunks per worker keep the current wave bounded while leaving enough
# independent work to balance heterogeneous cores and uneven input.
def batch_chunk_budget(+workers: U32) -> U32:
  +w = pick(U32.is_eq(workers, 0), 1, workers)
  +want = (w * 4 : U32)
  pick(U32.is_gt(want, 60), 60, want)

def batch_depth(+chunks: U32) -> U32:
  Words.fit(31n, 0, (((32768 + chunks * 253952 : U32) + 3 : U32) / 4 + 3 : U32), False{})

def batch_cap(+depth: U32) -> U32:
  U32.shln(1, U32.to_nat(depth))

def batch_new(+depth: U32, +cap: U32) -> Words.Sink:
  Words.Sink{Array.new(U32, U32.to_nat(depth), 0), cap, 0}

type Gst is Type:
  GFill{src: Ustar.Gsrc, ob: Words.Sink, dict: U32, file: File, crc: U32, total: U32}
  GHave{built: Ustar.Bt, dict: U32, file: File, crc: U32, total: U32}
  GChecked{src: Ustar.Gsrc, checked: Array<U32> & U32, dict: U32, n: U32, pos: U32, file: File, total: U32, done: Bool}
  GCarry{src: Ustar.Gsrc, carry: Gc, dict: U32, n: U32, file: File, crc: U32, total: U32}

def gzip_batch_stop(st: Gst) -> IO(Unit):
  match st:
    case GFill{src, Words.Sink{a, cap, pos}, dict, file, crc, total}:
      do IO<Unit>:
        Unit <- Words.drop(a)
        Unit <- File.close(file)
        IO.die(Unit, 1, "tar: gzip batch limit")
    case GHave{Ustar.Bt{src, Words.Sink{a, cap, pos}, done}, dict, file, crc, total}:
      do IO<Unit>:
        Unit <- Words.drop(a)
        Unit <- File.close(file)
        IO.die(Unit, 1, "tar: gzip batch limit")
    case GChecked{src, (a, crc), dict, n, pos, file, total, done}:
      do IO<Unit>:
        Unit <- Words.drop(a)
        Unit <- File.close(file)
        IO.die(Unit, 1, "tar: gzip batch limit")
    case GCarry{src, Gc{a, b}, dict, n, file, crc, total}:
      do IO<Unit>:
        Unit <- Words.drop(a)
        Unit <- Words.drop(b)
        Unit <- File.close(file)
        IO.die(Unit, 1, "tar: gzip batch limit")

def gzip_batches(fuel: Nat, st: Gst, +level: U32, +path: String, +depth: U32, +batch_words: U32, +payload: U32) -> IO(Unit):
  match fuel, st:
    case 0n, r:
      gzip_batch_stop(r)
    case 1n+p, GFill{src, ob, dict, file, crc, total}:
      +dd = dict
      do IO<Unit>:
        built : Ustar.Bt <- Ustar.fill(16384n, True{}, src, ob, (dd + payload : U32))
        gzip_batches(p, GHave{built, dd, file, crc, total}, level, path, depth, batch_words, payload)
    case 1n+p, GHave{Ustar.Bt{src, Words.Sink{a, cap, pos}, done}, dict, file, crc, total}:
      +dd = dict
      +pp = pos
      +nn = (pp - dd : U32)
      do IO<Unit>:
        checked : Array<U32> & U32 <- Crc32.update(path, a, dd, nn, crc)
        gzip_batches(p, GChecked{src, checked, dd, nn, pp, file, total, done}, level, path, depth, batch_words, payload)
    case 1n+p, GChecked{src, (a, crc), dict, n, pos, file, total, True{}}:
      +dd = dict
      +nn = n
      +cc = crc
      +tt = (total + nn : U32)
      do IO<Unit>:
        body : File <- Deflate.write(Deflate.compress(a, dd, nn, level, True{}), path, file)
        tail : File <- Words.sink_write(path, body, Gzip.trailer(Words.sink_new(), cc, tt))
        File.close(tail)
    case 1n+p, GChecked{src, (a, crc), dict, n, pos, file, total, False{}}:
      +dd = dict
      +nn = n
      +pp = pos
      +cc = crc
      +tt = (total + nn : U32)
      do IO<Unit>:
        carried : Array<U32> & Array<U32> <- Words.copy_range(a, (pp - 32768 : U32), Array.new(U32, 13n, 0), 0, 32768)
        gzip_batches(p, GCarry{src, batch_carry_pair(carried), dd, nn, file, cc, tt}, level, path, depth, batch_words, payload)
    case 1n+p, GCarry{src, Gc{a, dict_words}, dict, n, file, crc, total}:
      +dd = dict
      +nn = n
      do IO<Unit>:
        tail : File <- Deflate.write(Deflate.compress(a, dd, nn, level, False{}), path, file)
        seeded : Array<U32> & Array<U32> <- Words.copy_range(dict_words, 0, Array.new(U32, U32.to_nat(depth), 0), 0, 32768)
        next : Words.Sink <- batch_seed_pair(seeded, batch_words)
        gzip_batches(p, GFill{src, next, 32768, tail, crc, total}, level, path, depth, batch_words, payload)

def gzip_bounded(+path: String, names: List<&2, String>, +verbose: Bool, +level: U32) -> IO(Unit):
  do IO<Unit>:
    thread_count : U32 <- IO.thread_count()
    +chunks : U32 = batch_chunk_budget(thread_count)
    +depth : U32 = batch_depth(chunks)
    +cap : U32 = batch_cap(depth)
    +payload : U32 = (chunks * 253952 : U32)
    members : List<&1, Ustar.Tm> <- Ustar.manifest(names, verbose)
    file : File <- Words.open_out(path)
    body : File <- Words.sink_write(path, file, Gzip.header(Words.sink_new(), level))
    gzip_batches(U32.to_nat(4096), GFill{Ustar.GFiles{members}, batch_new(depth, cap), 0, body, 0, 0}, level, path, depth, cap, payload)

# Command line
# ------------
# mode 0 none, 1 create, 2 extract, 3 list, 4 bad; "-f" in file until the
# archive name fills it; level is gzip's 0-9, 6 unless a digit flag says

type Opts is Data:
  Opts{mode: U32, gz: Bool, verbose: Bool, file: String, level: U32}

def flag(o: Opts, c: Bool, x: Bool, t: Bool, z: Bool, v: Bool, f: Bool) -> Opts:
  match o, c, x, t, z, v, f:
    case Opts{mode, gz, verbose, file, level}, True{}, k1, k2, k3, k4, k5:
      Opts{1, gz, verbose, file, level}
    case Opts{mode, gz, verbose, file, level}, False{}, True{}, k2, k3, k4, k5:
      Opts{2, gz, verbose, file, level}
    case Opts{mode, gz, verbose, file, level}, False{}, False{}, True{}, k3, k4, k5:
      Opts{3, gz, verbose, file, level}
    case Opts{mode, gz, verbose, file, level}, False{}, False{}, False{}, True{}, k4, k5:
      Opts{mode, True{}, verbose, file, level}
    case Opts{mode, gz, verbose, file, level}, False{}, False{}, False{}, False{}, True{}, k5:
      Opts{mode, gz, True{}, file, level}
    case Opts{mode, gz, verbose, file, level}, False{}, False{}, False{}, False{}, False{}, True{}:
      Opts{mode, gz, verbose, "-f", level}
    case Opts{mode, gz, verbose, file, level}, False{}, False{}, False{}, False{}, False{}, False{}:
      Opts{4, gz, verbose, file, level}

def level_set(o: Opts, +l: U32) -> Opts:
  match o:
    case Opts{mode, gz, verbose, file, level}:
      Opts{mode, gz, verbose, file, l}

def flag_digit(+c: U32, o: Opts, digit: Bool) -> Opts:
  match digit:
    case True{}:
      level_set(o, (c - 48 : U32))
    case False{}:
      flag(o, U32.is_eq(c, 99), U32.is_eq(c, 120), U32.is_eq(c, 116), U32.is_eq(c, 122), U32.is_eq(c, 118), U32.is_eq(c, 102))

def flags(s: String, o: Opts) -> Opts:
  match s:
    case SNil{}:
      o
    case SCon{Chr{c}, t}:
      +cc = c
      flags(t, flag_digit(cc, o, (cc >= 48 : U32) && (cc <= 57 : U32)))

def take_file(o: Opts, args: List<&2, String>, wants: Bool) -> Opts & List<&2, String>:
  match o, args, wants:
    case rest, more, False{}:
      (rest, more)
    case Opts{mode, gz, verbose, file, level}, Nil{}, True{}:
      (Opts{4, gz, verbose, "", level}, [])
    case Opts{mode, gz, verbose, file, level}, Con{h, t}, True{}:
      (Opts{mode, gz, verbose, h, level}, t)

def wants_file(o: Opts) -> Opts & Bool:
  match o:
    case Opts{mode, gz, verbose, file, level}:
      +f = file
      (Opts{mode, gz, verbose, f, level}, String.eq(f, "-f"))

def take_file_at(w: Opts & Bool, args: List<&2, String>) -> Opts & List<&2, String>:
  (o, wants) = w
  take_file(o, args, wants)

def strip_dash(s: String, dash: Bool) -> String:
  match s, dash:
    case SCon{h, t}, True{}:
      t
    case rest, False{}:
      rest
    case SNil{}, True{}:
      SNil{}

def parse(args: List<&2, String>) -> Opts & List<&2, String>:
  match args:
    case Nil{}:
      (Opts{4, False{}, False{}, "", 6}, [])
    case Con{h, t}:
      +s = h
      take_file_at(wants_file(flags(strip_dash(s, Ustar.head_is(s, 45)), Opts{0, False{}, False{}, "", 6})), t)

# Main
# ----

def usage() -> IO(Unit):
  IO.die(Unit, 1, "usage: tar -{c|x|t}[zv0-9]f FILE [files..]")

def walk_peek(r: Array<U32> & Bool, +n: U32, gz: Bool, extract: Bool, verbose: Bool) -> IO(Unit):
  (a, magic) = r
  Ustar.walk(Gzip.decode_if(a, n, gz || magic), extract, verbose)

# gzip'd input is detected by its magic, as bsdtar does, with or without z
def walk_in(r: Array<U32> & U32, gz: Bool, extract: Bool, verbose: Bool) -> IO(Unit):
  (a, n) = r
  walk_peek(Gzip.is_gzip(a), n, gz, extract, verbose)

def create_out(gz: Bool, verbose: Bool, +file: String, +level: U32, members: List<&2, String>) -> IO(Unit):
  match gz:
    case True{}:
      gzip_bounded(path_out(file), members, verbose, level)
    case False{}:
      Ustar.create_stream(members, verbose, path_out(file), True{})

def list_plain(+file: String, verbose: Bool, stream: Bool) -> IO(Unit):
  match stream:
    case True{}:
      list_stream(path_in(file))
    case False{}:
      do IO<Unit>:
        r : Array<U32> & U32 <- Words.read(path_in(file))
        walk_in(r, False{}, False{}, verbose)

def list_in(gz: Bool, +file: String, verbose: Bool) -> IO(Unit):
  match gz:
    case True{}:
      do IO<Unit>:
        r : Array<U32> & U32 <- Words.read(path_in(file))
        walk_in(r, True{}, False{}, verbose)
    case False{}:
      list_plain(file, verbose, Bool.not(String.eq(file, "-")))

def run_mode(create: Bool, extract: Bool, list: Bool, gz: Bool, verbose: Bool, +file: String, +level: U32, members: List<&2, String>) -> IO(Unit):
  match create, extract, list:
    case True{}, k1, k2:
      create_out(gz, verbose, file, level, members)
    case False{}, True{}, k2:
      do IO<Unit>:
        r : Array<U32> & U32 <- Words.read(path_in(file))
        walk_in(r, gz, True{}, verbose)
    case False{}, False{}, True{}:
      list_in(gz, file, verbose)
    case False{}, False{}, False{}:
      usage()

def run(o: Opts, members: List<&2, String>) -> IO(Unit):
  match o:
    case Opts{mode, gz, verbose, file, level}:
      +m = mode
      run_mode(U32.is_eq(m, 1), U32.is_eq(m, 2), U32.is_eq(m, 3), gz, verbose, file, level, members)

def run_parsed(p: Opts & List<&2, String>) -> IO(Unit):
  (o, members) = p
  run(o, members)

def args_list(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Con{h, t}:
      h <> args_list(t)

def env_args(r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{line}:
      run_parsed(parse(words(line)))
    case Fail{e}:
      usage()

# the command line after the program's name, else TAR_ARGS's words
def main_args(args: List<String>) -> IO(Unit):
  match args:
    case Con{prog, Con{h, t}}:
      run_parsed(parse(args_list(h <> t)))
    case _:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, String> <- IO.get_env("TAR_ARGS")
        env_args(r)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main_args(args)
