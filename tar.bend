# tar: a bsdtar-style archiver in Bend — create, list and extract ustar
# archives, gzip'd or not, with a DEFLATE encoder (dynamic Huffman over
# LZ77) and decoder written here. Bend binaries take no arguments (the runtime owns argv), so the
# command line rides the TAR_ARGS environment variable, bsdtar's spelling:
#
#   TAR_ARGS="-czvf out.tgz a.txt b.txt" bend tar.bend
#   TAR_ARGS="-tzf out.tgz"              bend tar.bend
#   TAR_ARGS="-xvf in.tar"               bend tar.bend
#
# Flags: c create, x extract, t list, f FILE (- for stdin/stdout), z gzip,
# v verbose, 0-9 the gzip level (6 by default); bundled with or without
# the leading dash. Bytes ride packed word arrays, read and written by
# two foreign effects under effs/; there is no mkdir or readdir, so
# an archive holds the files named on the command line and directory
# entries are skipped.
#
# Spelling notes: a def recurses only on itself, so a loop's decision
# rides in as a parameter its caller computes (a peek at the next head),
# and a stage that opens a result is a helper the loop calls, never one
# that calls the loop back.
import Base

# Bytes and strings
# -----------------

def b2u(b: Bool) -> U32:
  match b:
    case False{}:
      0
    case True{}:
      1

def pick(c: Bool, a: U32, b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

def slen(s: String, +acc: U32) -> U32:
  match s:
    case SNil{}:
      acc
    case SCon{h, t}:
      slen(t, (acc + 1 : U32))

# reverse onto acc
def srev(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{h, t}:
      srev(t, SCon{h, acc})

def sdrop(n: Nat, s: String) -> String:
  match n, s:
    case 0n, rest:
      rest
    case 1n+p, SNil{}:
      SNil{}
    case 1n+p, SCon{h, t}:
      sdrop(p, t)

# the first n bytes, reversed onto acc
def stake_rev(n: Nat, s: String, acc: String) -> String:
  match n, s:
    case 0n, rest:
      acc
    case 1n+p, SNil{}:
      acc
    case 1n+p, SCon{h, t}:
      stake_rev(p, t, SCon{h, acc})

def stake(n: Nat, s: String) -> String:
  srev(stake_rev(n, s, ""), "")

# the first n bytes and the rest
def split_at(n: Nat, s: String, acc: String) -> String & String:
  match n, s:
    case 0n, rest:
      (srev(acc, ""), rest)
    case 1n+p, SNil{}:
      (srev(acc, ""), "")
    case 1n+p, SCon{h, t}:
      split_at(p, t, SCon{h, acc})

# reverse onto acc, counting
def srev_len(s: String, acc: String, +n: U32) -> String & U32:
  match s:
    case SNil{}:
      (acc, n)
    case SCon{h, t}:
      srev_len(t, SCon{h, acc}, (n + 1 : U32))

# n copies of byte c in front of s
def sfill(n: Nat, +c: U32, s: String) -> String:
  match n:
    case 0n:
      s
    case 1n+p:
      sfill(p, c, SCon{Chr{c}, s})

# s cut or NUL-padded to exactly n bytes
def field(+n: U32, +s: String) -> String:
  +len = slen(s, 0)
  stake(U32.to_nat(n), s) ++ sfill(U32.to_nat((n - pick(U32.is_lt(len, n), len, n) : U32)), 0, "")

# the head byte, 0 on empty
def head(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{Chr{c}, t}:
      c

def head_is(s: String, +c: U32) -> Bool:
  U32.is_eq(head(s), c)

def head_digit(s: String) -> Bool:
  +c = head(s)
  (c >= 48 : U32) && (c <= 55 : U32)

# the bytes of s up to the first NUL; nul says whether s starts with one
def cstr(s: String, acc: String, nul: Bool) -> String:
  match s, nul:
    case rest, True{}:
      srev(acc, "")
    case SNil{}, False{}:
      srev(acc, "")
    case SCon{h, t}, False{}:
      +t2 = t
      cstr(t2, SCon{h, acc}, head_is(t2, 0))

# the byte at position i, 0 past the end
def sat(s: String, i: Nat) -> U32:
  match s, i:
    case SNil{}, k:
      0
    case SCon{Chr{c}, t}, 0n:
      c
    case SCon{h, t}, 1n+p:
      sat(t, p)

# n digits of v in octal, least significant first, in front of tail
def octal(n: Nat, +v: U32, tail: String) -> String:
  match n:
    case 0n:
      tail
    case 1n+p:
      octal(p, (v / 8 : U32), SCon{Chr{(48 + v % 8 : U32)}, tail})

# an octal field read while digits last; digit says whether s starts with one
def unoctal(s: String, +acc: U32, digit: Bool) -> U32:
  match s, digit:
    case rest, False{}:
      acc
    case SNil{}, True{}:
      acc
    case SCon{Chr{c}, t}, True{}:
      +t2 = t
      unoctal(t2, (acc * 8 + (c - 48) : U32), head_digit(t2))

def ssum(s: String, +acc: U32) -> U32:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{c}, t}:
      ssum(t, (acc + c : U32))

def all_zero(s: String, ok: Bool) -> Bool:
  match s:
    case SNil{}:
      ok
    case SCon{Chr{c}, t}:
      all_zero(t, ok && U32.is_eq(c, 0))

def le32(+v: U32) -> String:
  SCon{Chr{(v .&. 255 : U32)}, SCon{Chr{((v >> 8n) .&. 255 : U32)}, SCon{Chr{((v >> 16n) .&. 255 : U32)}, SCon{Chr{(v >> 24n : U32)}, ""}}}}

# Words
# -----

# split at the first space: (word, rest); space says whether s starts with one
def word(s: String, acc: String, space: Bool) -> String & String:
  match s, space:
    case rest, True{}:
      (srev(acc, ""), sdrop(1n, rest))
    case SNil{}, False{}:
      (srev(acc, ""), "")
    case SCon{h, t}, False{}:
      +t2 = t
      word(t2, SCon{h, acc}, head_is(t2, 32))

# n words at most, empties included
def split(n: Nat, w: String & String) -> List<&2, String>:
  match n, w:
    case 0n, rest:
      []
    case 1n+p, (h, rest):
      +r = rest
      h <> split(p, word(r, "", head_is(r, 32)))

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
  +l = split(64n, word(s, "", head_is(s, 32)))
  nonempty(l, head_empty(l))

# Arrays
# ------

# the smallest depth d with 2^d >= need
def fit(n: Nat, +d: U32, +need: U32, ok: Bool) -> U32:
  match n, ok:
    case k, True{}:
      d
    case 0n, False{}:
      d
    case 1n+p, False{}:
      fit(p, (d + 1 : U32), need, U32.is_ge(U32.shln(1, U32.to_nat((d + 1 : U32))), need))

def arr_depth(+need: U32) -> Nat:
  U32.to_nat(fit(31n, 0, need, U32.is_le(need, 1)))

# Output growth
# -------------
# the output doubles when a write would pass its capacity, so the size
# need not be known up front (bsdtar pads a piped archive past its trailer)

type Gr is Type:
  Gr{src: Array<U32>, dst: Array<U32>}

def gr_put(r: Array<U32> & U32, dst: Array<U32>, +i: U32) -> Gr:
  (src, v) = r
  Gr{src, Array.set(U32, dst, i, v)}

def gr_loop(n: Nat, st: Gr, +i: U32) -> Gr:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Gr{src, dst}:
      gr_loop(p, gr_put(Array.get(U32, src, i), dst, i), (i + 1 : U32))

def gr_dst(st: Gr) -> Array<U32>:
  match st:
    case Gr{src, dst}:
      dst

def grow(out: Array<U32>, +cap: U32) -> Array<U32>:
  gr_dst(gr_loop(U32.to_nat(cap), Gr{out, Array.new(U32, arr_depth((cap * 2 : U32)), 0)}, 0))

# (out, cap) with cap >= need; ok says it already is
def ensure(n: Nat, out: Array<U32>, +cap: U32, +need: U32, ok: Bool) -> Array<U32> & U32:
  match n, ok:
    case k, True{}:
      (out, cap)
    case 0n, False{}:
      (out, cap)
    case 1n+p, False{}:
      ensure(p, grow(out, cap), (cap * 2 : U32), need, U32.is_ge((cap * 2 : U32), need))

def room(out: Array<U32>, +cap: U32, +need: U32) -> Array<U32> & U32:
  ensure(32n, out, cap, need, U32.is_ge(cap, need))

# Packed input
# ------------
# the input packed four bytes to a word, little-endian: a byte is one
# read and a shift, the window at any byte offset two reads combined.
# The memory is a byte per byte.

def w4_hi(r: Array<U32> & U32, +lo: U32, +sh: U32) -> Array<U32> & U32:
  (a, v) = r
  (a, (lo .|. (U32.shln(v, U32.to_nat((24 - sh : U32))) << 8n) : U32))

def w4_lo(r: Array<U32> & U32, +q: U32, +sh: U32) -> Array<U32> & U32:
  (a, v) = r
  w4_hi(Array.get(U32, a, (q + 1 : U32)), U32.shrn(v, U32.to_nat(sh)), sh)

# the four bytes from j, j lowest
def w4(a: Array<U32>, +j: U32) -> Array<U32> & U32:
  w4_lo(Array.get(U32, a, (j >> 2n : U32)), (j >> 2n : U32), ((j .&. 3) << 3n : U32))

def wb_of(r: Array<U32> & U32, +sh: U32) -> Array<U32> & U32:
  (a, v) = r
  (a, (U32.shrn(v, U32.to_nat(sh)) .&. 255 : U32))

# the byte at j
def wb(a: Array<U32>, +j: U32) -> Array<U32> & U32:
  wb_of(Array.get(U32, a, (j >> 2n : U32)), ((j .&. 3) << 3n : U32))

# Files
# -----
# a file's bytes come and go as words: four bytes to a word,
# little-endian, zero padded past the end with three spare words, so
# the codec's windows never fall off. The two effects are foreign C and
# JS under effs/; the command line still rides a String.

def words_read(path: String) -> IO(Result<&1, &1, U32 & String, Array<U32> & U32>):
  import "./effs/words_read.c"
  import "./effs/words_read.js"

def words_write(path: String, a: Array<U32>, +start: U32, +n: U32) -> IO(Array<U32> & Result<&1, &1, U32 & String, Unit>):
  import "./effs/words_write.c"
  import "./effs/words_write.js"

def words_fill(path: String, a: Array<U32>, +start: U32, +n: U32) -> IO(Array<U32> & Result<&1, &1, U32 & String, Unit>):
  import "./effs/words_fill.c"
  import "./effs/words_fill.js"

def file_size(path: String) -> IO(Result<&1, &1, U32 & String, U32>):
  import "./effs/file_size.c"
  import "./effs/file_size.js"

def stream_append(path: String, a: Array<U32>, +header_n: U32, input: String, +pad_n: U32, +first: U32) -> IO(Array<U32> & Result<&1, &1, U32 & String, Unit>):
  import "./effs/stream_append.c"
  import "./effs/stream_append.js"

def words_crc32(a: Array<U32>, +start: U32, +n: U32) -> IO(Array<U32> & Result<&1, &1, U32 & String, U32>):
  import "./effs/words_crc32.c"
  import "./effs/words_crc32.js"

def File.write_words(file: File, a: Array<U32>, +start: U32, +n: U32) -> IO(File & Array<U32> & Result<&1, &1, U32 & String, Unit>):
  import "./effs/file_words_write.c"
  import "./effs/file_words_write.js"

def File.read_words_at(file: File, +offset: U32, +max: U32) -> IO(File & Result<&1, &1, U32 & String, Array<U32> & U32>):
  import "./effs/file_words_read_at.c"
  import "./effs/file_words_read_at.js"

def output_open(path: String) -> IO(Result<&1, &1, U32 & String, File>):
  import "./effs/output_open.c"
  import "./effs/output_open.js"

def io_fail(what: String, e: U32 & String) -> IO(Unit):
  (code, msg) = e
  IO.die(Unit, 1, "tar: " ++ what ++ ": " ++ msg)

def read_got(what: String, r: Result<&1, &1, U32 & String, Array<U32> & U32>) -> IO(Array<U32> & U32):
  match r:
    case Done{v}:
      IO.pure(Array<U32> & U32, v)
    case Fail{e}:
      do IO<Array<U32> & U32>:
        Unit <- io_fail(what, e)
        IO.die(Array<U32> & U32, 1, "unreachable")

def read_words(+path: String) -> IO(Array<U32> & U32):
  do IO<Array<U32> & U32>:
    r : Result<&1, &1, U32 & String, Array<U32> & U32> <- words_read(path)
    read_got(path, r)

def size_got(what: String, r: Result<&1, &1, U32 & String, U32>) -> IO(U32):
  match r:
    case Done{n}:
      IO.pure(U32, n)
    case Fail{e}:
      do IO<U32>:
        Unit <- io_fail(what, e)
        IO.die(U32, 1, "unreachable")

def size_of(+path: String) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32> <- file_size(path)
    size_got(path, r)

def wr_done(what: String, r: Array<U32> & Result<&1, &1, U32 & String, Unit>) -> IO(Array<U32>):
  (a, w) = r
  match w:
    case Done{u}:
      IO.pure(Array<U32>, a)
    case Fail{e}:
      do IO<Array<U32>>:
        Unit <- io_fail(what, e)
        return a

# n bytes of a from byte start; the words come back
def write_words(+path: String, a: Array<U32>, +start: U32, +n: U32) -> IO(Array<U32>):
  do IO<Array<U32>>:
    r : Array<U32> & Result<&1, &1, U32 & String, Unit> <- words_write(path, a, start, n)
    wr_done(path, r)

def fill_words(+path: String, a: Array<U32>, +start: U32, +n: U32) -> IO(Array<U32>):
  do IO<Array<U32>>:
    r : Array<U32> & Result<&1, &1, U32 & String, Unit> <- words_fill(path, a, start, n)
    wr_done(path, r)

def drop_words(a: Array<U32>) -> IO(Unit):
  IO.pure(Unit, Unit{})

def crc_got(what: String, r: Array<U32> & Result<&1, &1, U32 & String, U32>) -> IO(Array<U32> & U32):
  (a, v) = r
  match v:
    case Done{v}:
      IO.pure(Array<U32> & U32, (a, v))
    case Fail{e}:
      do IO<Array<U32> & U32>:
        Unit <- drop_words(a)
        Unit <- io_fail(what, e)
        IO.die(Array<U32> & U32, 1, "unreachable")

def crc_words(+what: String, a: Array<U32>, +n: U32) -> IO(Array<U32> & U32):
  do IO<Array<U32> & U32>:
    r : Array<U32> & Result<&1, &1, U32 & String, U32> <- words_crc32(a, 0, n)
    crc_got(what, r)

def open_got(what: String, r: Result<&1, &1, U32 & String, File>) -> IO(File):
  match r:
    case Done{file}:
      IO.pure(File, file)
    case Fail{e}:
      do IO<File>:
        Unit <- io_fail(what, e)
        IO.die(File, 1, "unreachable")

def open_out(+path: String) -> IO(File):
  do IO<File>:
    r : Result<&1, &1, U32 & String, File> <- output_open(path)
    open_got(path, r)

type Fr is Type:
  Fr{file: File, a: Array<U32>, n: U32}

def file_read_words_got(what: String, r: File & Result<&1, &1, U32 & String, Array<U32> & U32>) -> IO(Fr):
  (file, v) = r
  match v:
    case Done{(a, n)}:
      IO.pure(Fr, Fr{file, a, n})
    case Fail{e}:
      do IO<Fr>:
        Unit <- File.close(file)
        Unit <- io_fail(what, e)
        IO.die(Fr, 1, "unreachable")

def file_words_got(what: String, r: File & Array<U32> & Result<&1, &1, U32 & String, Unit>) -> IO(File):
  (file, a, v) = r
  match v:
    case Done{u}:
      do IO<File>:
        Unit <- drop_words(a)
        return file
    case Fail{e}:
      do IO<File>:
        Unit <- drop_words(a)
        Unit <- File.close(file)
        Unit <- io_fail(what, e)
        IO.die(File, 1, "unreachable")

def append_words(+path: String, a: Array<U32>, +header_n: U32, +input: String, +pad_n: U32, first: Bool) -> IO(Unit):
  do IO<Unit>:
    r : Array<U32> & Result<&1, &1, U32 & String, Unit> <- stream_append(path, a, header_n, input, pad_n, b2u(first))
    a2 : Array<U32> <- wr_done(path, r)
    drop_words(a2)

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

def say(verbose: Bool, line: String) -> IO(Unit):
  match verbose:
    case True{}:
      IO.print_err(line)
    case False{}:
      IO.pure(Unit, Unit{})

# Output
# ------
# a growing byte sink over packed words: cap counts words, pos bytes.
# A byte lands by read-modify-write of its word; a run of zeros and a
# word-aligned block of words go in whole.

type Ob is Type:
  Ob{a: Array<U32>, cap: U32, pos: U32}

def file_write_ob(+path: String, file: File, st: Ob) -> IO(File):
  match st:
    case Ob{a, cap, pos}:
      do IO<File>:
        r : File & Array<U32> & Result<&1, &1, U32 & String, Unit> <- File.write_words(file, a, 0, pos)
        file_words_got(path, r)

def ob_new() -> Ob:
  Ob{Array.new(U32, 16n, 0), 65536, 0}

def ob_fit(r: Array<U32> & U32, +pos: U32) -> Ob:
  (a, cap) = r
  Ob{a, cap, pos}

# room for bytes up to need
def ob_room(a: Array<U32>, +cap: U32, +pos: U32, +need: U32) -> Ob:
  ob_fit(room(a, cap, ((need >> 2n) + 4 : U32)), pos)

def ob_or(r: Array<U32> & U32, +cap: U32, +pos: U32, +b: U32) -> Ob:
  (a, w) = r
  Ob{Array.set(U32, a, (pos >> 2n : U32), (w .|. U32.shln(b, U32.to_nat(((pos .&. 3) << 3n : U32))) : U32)), cap, (pos + 1 : U32)}

def ob_byte_at(st: Ob, +b: U32) -> Ob:
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      ob_or(Array.get(U32, a, (p >> 2n : U32)), cap, p, b)

def ob_byte(st: Ob, +b: U32) -> Ob:
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      ob_byte_at(ob_room(a, cap, p, (p + 1 : U32)), b)

def ow_split(a: Array<U32>, +q: U32, +v: U32, +sh: U32, split: Bool) -> Array<U32>:
  match split:
    case True{}:
      Array.set(U32, a, (q + 1 : U32), U32.shrn(v, U32.to_nat((32 - sh : U32))))
    case False{}:
      a

def ob_word_got(r: Array<U32> & U32, +cap: U32, +pos: U32, +q: U32, +sh: U32, +v: U32) -> Ob:
  (a, old) = r
  Ob{ow_split(Array.set(U32, a, q, (old .|. U32.shln(v, U32.to_nat(sh)) : U32)), q, v, sh, U32.is_ne(sh, 0)), cap, (pos + 4 : U32)}

# Four bytes into a previously reserved output range. The destination may be
# unaligned; its already-written low bytes are preserved and the high spill
# becomes the prefix of the next word.
def ob_word_at(st: Ob, +v: U32) -> Ob:
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      +q = (p >> 2n : U32)
      +sh = ((p .&. 3) << 3n : U32)
      ob_word_got(Array.get(U32, a, q), cap, p, q, sh, v)

def ob_reserve(st: Ob, +n: U32) -> Ob:
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      ob_room(a, cap, p, (p + n : U32))

# n bytes of a string
def ob_str(s: String, st: Ob) -> Ob:
  match s:
    case SNil{}:
      st
    case SCon{Chr{c}, t}:
      ob_str(t, ob_byte(st, c))

# n zero bytes: the room is zero already
def ob_skip(st: Ob, +n: U32) -> Ob:
  match st:
    case Ob{a, cap, pos}:
      Ob{a, cap, (pos + n : U32)}

def ob_zero(st: Ob, +n: U32) -> Ob:
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      ob_skip(ob_room(a, cap, p, (p + n : U32)), n)

# words of src copied to a word-aligned pos
type Cw is Type:
  Cw{src: Array<U32>, dst: Array<U32>}

# Tar
# ---
# ustar: a 512-byte header, the data, NUL padding to 512, and two zero
# blocks at the end. Regular files only: mode 0644, uid and gid 0, mtime 0.
# Every entry starts at a multiple of 512, so a member's words go into
# the archive aligned.

def pad512(+n: U32) -> U32:
  ((512 - n % 512) % 512 : U32)

def tar_header(name: String, +size: U32) -> String:
  +h = field(100, name) ++ "0000644" ++ "\0" ++ "0000000" ++ "\0" ++ "0000000" ++ "\0"
    ++ octal(11n, size, "\0") ++ octal(11n, 0, "\0") ++ "        " ++ "0" ++ field(100, "")
    ++ "ustar" ++ "\0" ++ "00" ++ field(32, "") ++ field(32, "") ++ "0000000" ++ "\0" ++ "0000000" ++ "\0"
    ++ field(155, "") ++ field(12, "")
  stake(148n, h) ++ octal(6n, ssum(h, 0), "\0 ") ++ sdrop(156n, h)

# Create
# ------

def ob_fill_at(+path: String, +n: U32, +pad: U32, st: Ob) -> IO(Ob):
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      do IO<Ob>:
        a2 : Array<U32> <- fill_words(path, a, p, n)
        return Ob{a2, cap, (p + n + pad : U32)}

def ob_fill(+path: String, +n: U32, +pad: U32, st: Ob) -> IO(Ob):
  match st:
    case Ob{a, cap, pos}:
      +p = pos
      ob_fill_at(path, n, pad, ob_room(a, cap, p, (p + n + pad : U32)))

# Gzip still needs a contiguous archive today, but members are read directly
# into their final ranges, without a temporary file Array or copy loop.
def tar_pack_sized(st: Ob, +name: String, +size: U32) -> IO(Ob):
  ob_fill(name, size, pad512(size), ob_str(tar_header(name, size), st))

def tar_pack(names: List<&2, String>, +verbose: Bool, st: Ob) -> IO(Ob):
  match names:
    case Nil{}:
      IO.pure(Ob, ob_zero(st, 1024))
    case Con{h, t}:
      +name = h
      do IO<Ob>:
        size : U32 <- size_of(name)
        Unit <- say(verbose, "a " ++ name)
        next : Ob <- tar_pack_sized(st, name, size)
        tar_pack(t, verbose, next)

# The plain create path writes one member at a time. Headers stay in Bend;
# the effect only transfers their packed words and copies the file into the
# ordered sink, so member contents never enter the growing archive Array.
def stream_ob(+out: String, +input: String, +pad: U32, first: Bool, st: Ob) -> IO(Unit):
  match st:
    case Ob{a, cap, pos}:
      append_words(out, a, pos, input, pad, first)

def stream_member(+out: String, +name: String, +size: U32, first: Bool) -> IO(Unit):
  stream_ob(out, name, pad512(size), first, ob_str(tar_header(name, size), ob_new()))

def stream_end(+out: String, first: Bool) -> IO(Unit):
  stream_ob(out, "", 0, first, ob_zero(ob_new(), 1024))

def tar_stream(names: List<&2, String>, +verbose: Bool, +out: String, first: Bool) -> IO(Unit):
  match names:
    case Nil{}:
      stream_end(out, first)
    case Con{h, t}:
      +name = h
      do IO<Unit>:
        size : U32 <- size_of(name)
        Unit <- say(verbose, "a " ++ name)
        Unit <- stream_member(out, name, size, first)
        tar_stream(t, verbose, out, False{})

# List and extract
# ----------------
# the header at off: name, size, type, and whether the archive has
# ended (a zero block, or nothing left)

type Hdr is Type:
  Hdr{a: Array<U32>, name: String, size: U32, kind: U32, off: U32, end: Bool}

# the bytes [off, off+n) as a string, reversed onto acc
type Hs2 is Type:
  Hs2{a: Array<U32>, s: String}

def hs_cons(r: Array<U32> & U32, acc: String) -> Hs2:
  (a, b) = r
  Hs2{a, SCon{Chr{b}, acc}}

def hs_loop(n: Nat, st: Hs2, +j: U32) -> Hs2:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Hs2{a, acc}:
      hs_loop(p, hs_cons(wb(a, j), acc), (j + 1 : U32))

def hs_of(st: Hs2) -> Array<U32> & String:
  match st:
    case Hs2{a, s}:
      (a, srev(s, ""))

def bytes_str(a: Array<U32>, +off: U32, +n: U32) -> Array<U32> & String:
  hs_of(hs_loop(U32.to_nat(n), Hs2{a, ""}, off))

# whether the 128 words at off are zero
type Hz is Type:
  Hz{a: Array<U32>, zero: Bool}

def hz_at(r: Array<U32> & U32, zero: Bool) -> Hz:
  (a, w) = r
  Hz{a, zero && U32.is_eq(w, 0)}

def hz_loop(n: Nat, st: Hz, +q: U32) -> Hz:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Hz{a, zero}:
      hz_loop(p, hz_at(Array.get(U32, a, q), zero), (q + 1 : U32))

def hz_of(st: Hz) -> Array<U32> & Bool:
  match st:
    case Hz{a, zero}:
      (a, zero)

def hdr_kind(r: Array<U32> & U32, name: String, +size: U32, +off: U32) -> Hdr:
  (a, kind) = r
  Hdr{a, name, size, kind, off, False{}}

def hdr_size(r: Array<U32> & String, name: String, +off: U32) -> Hdr:
  (a, digits) = r
  +d = digits
  hdr_kind(wb(a, (off + 156 : U32)), name, unoctal(d, 0, head_digit(d)), off)

def hdr_name(r: Array<U32> & String, +off: U32) -> Hdr:
  (a, raw) = r
  +s = raw
  hdr_size(bytes_str(a, (off + 124 : U32), 12), cstr(s, "", head_is(s, 0)), off)

def hdr_live(r: Array<U32> & Bool, +off: U32) -> Hdr:
  (a, zero) = r
  match zero:
    case True{}:
      Hdr{a, "", 0, 0, off, True{}}
    case False{}:
      hdr_name(bytes_str(a, off, 100), off)

def hdr_go(a: Array<U32>, +off: U32, past: Bool) -> Hdr:
  match past:
    case True{}:
      Hdr{a, "", 0, 0, off, True{}}
    case False{}:
      hdr_live(hz_of(hz_loop(128n, Hz{a, True{}}, (off >> 2n : U32))), off)

def hdr_of(a: Array<U32>, +off: U32, +n: U32) -> Hdr:
  hdr_go(a, off, U32.is_ge((off + 512 : U32), (n + 1 : U32)))

def tar_write(a: Array<U32>, +name: String, +off: U32, +size: U32, verbose: Bool, dir: Bool) -> IO(Array<U32>):
  match dir:
    case True{}:
      do IO<Array<U32>>:
        Unit <- IO.print_err("tar: skipping directory " ++ name ++ " (no mkdir)")
        return a
    case False{}:
      do IO<Array<U32>>:
        Unit <- say(verbose, "x " ++ name)
        write_words(name, a, (off + 512 : U32), size)

def tar_emit(a: Array<U32>, +name: String, +off: U32, +size: U32, kind: U32, extract: Bool, verbose: Bool) -> IO(Array<U32>):
  match extract:
    case False{}:
      do IO<Array<U32>>:
        Unit <- IO.print(name)
        return a
    case True{}:
      tar_write(a, name, off, size, verbose, U32.is_eq(kind, 53))

# walks the entries; fuel bounds the loop by the archive's block count
def tar_walk(fuel: Nat, h: Hdr, +n: U32, +extract: Bool, +verbose: Bool) -> IO(Unit):
  match fuel, h:
    case 0n, k:
      IO.pure(Unit, Unit{})
    case 1n+p, Hdr{a, name, size, kind, off, end}:
      match end:
        case True{}:
          drop_words(a)
        case False{}:
          +sz = size
          +o = off
          do IO<Unit>:
            a2 : Array<U32> <- tar_emit(a, name, o, sz, kind, extract, verbose)
            tar_walk(p, hdr_of(a2, (o + 512 + sz + pad512(sz) : U32), n), n, extract, verbose)

def walk(r: Array<U32> & U32, extract: Bool, verbose: Bool) -> IO(Unit):
  (a, n) = r
  +nn = n
  tar_walk(U32.to_nat((nn / 512 + 1 : U32)), hdr_of(a, 0, nn), nn, extract, verbose)

# Bit reader
# ----------
# bits come least significant first out of each byte of the words from
# pos; past n the stream reads as zeros

type Br is Type:
  Br{a: Array<U32>, pos: U32, n: U32, buf: U32, cnt: U32}

# the refill: need says the buffer is still short of kk bits
type Bf is Type:
  Bf{a: Array<U32>, pos: U32, n: U32, buf: U32, cnt: U32, need: Bool}

def bf_byte(r: Array<U32> & U32, +pos: U32, +n: U32, +buf: U32, +cnt: U32, +kk: U32) -> Bf:
  (a, b) = r
  +c2 = (cnt + 8 : U32)
  Bf{a, (pos + 1 : U32), n, (buf .|. U32.shln(b, U32.to_nat(cnt)) : U32), c2, U32.is_lt(c2, kk)}

def bf_step(a: Array<U32>, +pos: U32, +n: U32, +buf: U32, +cnt: U32, +kk: U32, live: Bool) -> Bf:
  match live:
    case True{}:
      bf_byte(wb(a, pos), pos, n, buf, cnt, kk)
    case False{}:
      +c2 = (cnt + 8 : U32)
      Bf{a, (pos + 1 : U32), n, buf, c2, U32.is_lt(c2, kk)}

def bf_loop(fuel: Nat, st: Bf, +kk: U32) -> Bf:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Bf{a, pos, n, buf, cnt, need}:
      match need:
        case False{}:
          Bf{a, pos, n, buf, cnt, False{}}
        case True{}:
          +pp = pos
          +nn = n
          bf_loop(p, bf_step(a, pp, nn, buf, cnt, kk, U32.is_lt(pp, nn)), kk)

def bf_br(st: Bf) -> Br:
  match st:
    case Bf{a, pos, n, buf, cnt, need}:
      Br{a, pos, n, buf, cnt}

def br_ready(br: Br, +kk: U32) -> Br:
  match br:
    case Br{a, pos, n, buf, cnt}:
      +c = cnt
      bf_br(bf_loop(4n, Bf{a, pos, n, buf, c, U32.is_lt(c, kk)}, kk))

def br_take(+k: Nat, +kk: U32, br: Br) -> Br & U32:
  match br:
    case Br{a, pos, n, buf, cnt}:
      +b = buf
      (Br{a, pos, n, U32.shrn(b, k), (cnt - kk : U32)}, (b .&. (U32.shln(1, k) - 1) : U32))

# k bits, k <= 16
def br_bits(+k: Nat, br: Br) -> Br & U32:
  +kk = U32.from_nat(k)
  br_take(k, kk, br_ready(br, kk))

# drop the bits of a partial byte
def br_align(br: Br) -> Br:
  match br:
    case Br{a, pos, n, buf, cnt}:
      +c = cnt
      Br{a, pos, n, U32.shrn(buf, U32.to_nat((c % 8 : U32))), (c - c % 8 : U32)}

# Huffman
# -------
# canonical codes as in zlib's puff: cnt[len] codes of each length,
# sym[] the symbols ordered by (length, value); a code is decoded from a
# peeked 15-bit window, walking the lengths

type Huf is Type:
  Huf{cnt: Array<U32>, sym: Array<U32>, fast: Array<U32>}

# count the lengths: cnt[len[i]] += 1
type Cs is Type:
  Cs{lens: Array<U32>, cnt: Array<U32>}

def cnt_set(lens: Array<U32>, +l: U32, rc: Array<U32> & U32) -> Cs:
  (cnt, c) = rc
  Cs{lens, Array.set(U32, cnt, l, (c + 1 : U32))}

def cnt_at(rl: Array<U32> & U32, cnt: Array<U32>) -> Cs:
  (lens, l) = rl
  +ll = l
  cnt_set(lens, ll, Array.get(U32, cnt, ll))

def cnt_loop(n: Nat, st: Cs, +i: U32) -> Cs:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Cs{lens, cnt}:
      cnt_loop(p, cnt_at(Array.get(U32, lens, i), cnt), (i + 1 : U32))

# offsets: offs[l+1] = offs[l] + cnt[l], for l in 1..15
type Of is Type:
  Of{cnt: Array<U32>, offs: Array<U32>}

def offs_at(rc: Array<U32> & U32, offs: Array<U32>, +l: U32, +o: U32) -> Of & U32:
  (cnt, c) = rc
  +oc = (o + c : U32)
  (Of{cnt, Array.set(U32, offs, (l + 1 : U32), oc)}, oc)

def offs_loop(n: Nat, st: Of & U32, +l: U32) -> Of:
  match n, st:
    case 0n, (r, o):
      r
    case 1n+p, (Of{cnt, offs}, o):
      offs_loop(p, offs_at(Array.get(U32, cnt, l), offs, l, o), (l + 1 : U32))

# place: sym[offs[len[i]]] = i and offs[len[i]] += 1, for lengths > 0
type Pl is Type:
  Pl{lens: Array<U32>, offs: Array<U32>, sym: Array<U32>}

def place_skip(lens: Array<U32>, sym: Array<U32>, ro: Array<U32> & U32) -> Pl:
  (offs, o) = ro
  Pl{lens, offs, sym}

def place_do(lens: Array<U32>, +l: U32, +i: U32, sym: Array<U32>, ro: Array<U32> & U32) -> Pl:
  (offs, o) = ro
  +oo = o
  Pl{lens, Array.set(U32, offs, l, (oo + 1 : U32)), Array.set(U32, sym, oo, i)}

def place_put(lens: Array<U32>, +l: U32, +i: U32, sym: Array<U32>, ro: Array<U32> & U32, live: Bool) -> Pl:
  match live:
    case False{}:
      place_skip(lens, sym, ro)
    case True{}:
      place_do(lens, l, i, sym, ro)

def place_at(rl: Array<U32> & U32, offs: Array<U32>, sym: Array<U32>, +i: U32) -> Pl:
  (lens, l) = rl
  +ll = l
  place_put(lens, ll, i, sym, Array.get(U32, offs, ll), U32.is_ne(ll, 0))

def place_loop(n: Nat, st: Pl, +i: U32) -> Pl:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Pl{lens, offs, sym}:
      place_loop(p, place_at(Array.get(U32, lens, i), offs, sym, i), (i + 1 : U32))

# A nine-bit primary decode table. Entries pack code length in the high half
# and symbol in the low half; zero means that a longer code needs the canonical
# fallback walk.
def hrev(n: Nat, +c: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      hrev(p, (c >> 1n : U32), ((acc << 1n) .|. (c .&. 1) : U32))

def hfast_fill(n: Nat, fast: Array<U32>, +at: U32, +step: U32, +v: U32) -> Array<U32>:
  match n:
    case 0n:
      fast
    case 1n+p:
      hfast_fill(p, Array.set(U32, fast, at, v), (at + step : U32), step, v)

type Hn is Type:
  Hn{cnt: Array<U32>, next: Array<U32>}

def hn_at(r: Array<U32> & U32, next: Array<U32>, +l: U32, +code: U32) -> Hn & U32:
  (cnt, c) = r
  +cd = ((code + c) << 1n : U32)
  (Hn{cnt, Array.set(U32, next, (l + 1 : U32), cd)}, cd)

def hn_loop(n: Nat, st: Hn & U32, +l: U32) -> Hn:
  match n, st:
    case 0n, (r, code):
      r
    case 1n+p, (Hn{cnt, next}, code):
      hn_loop(p, hn_at(Array.get(U32, cnt, l), next, l, code), (l + 1 : U32))

def hn_next(st: Hn) -> Array<U32>:
  match st:
    case Hn{cnt, next}:
      next

type Hf is Type:
  Hf{lens: Array<U32>, next: Array<U32>, fast: Array<U32>}

def hf_code(r: Array<U32> & U32, lens: Array<U32>, fast: Array<U32>, +i: U32, +l: U32) -> Hf:
  (next, code) = r
  +cc = code
  +rev = hrev(U32.to_nat(l), cc, 0)
  +count = U32.shln(1, U32.to_nat((9 - l : U32)))
  Hf{lens, Array.set(U32, next, l, (cc + 1 : U32)), hfast_fill(U32.to_nat(count), fast, rev, U32.shln(1, U32.to_nat(l)), ((l << 16n) .|. i : U32))}

def hf_live(lens: Array<U32>, next: Array<U32>, fast: Array<U32>, +i: U32, +l: U32, live: Bool) -> Hf:
  match live:
    case True{}:
      hf_code(Array.get(U32, next, l), lens, fast, i, l)
    case False{}:
      Hf{lens, next, fast}

def hf_at(r: Array<U32> & U32, next: Array<U32>, fast: Array<U32>, +i: U32) -> Hf:
  (lens, l) = r
  +ll = l
  hf_live(lens, next, fast, i, ll, U32.is_ne(ll, 0) && U32.is_le(ll, 9))

def hf_loop(n: Nat, st: Hf, +i: U32) -> Hf:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Hf{lens, next, fast}:
      hf_loop(p, hf_at(Array.get(U32, lens, i), next, fast, i), (i + 1 : U32))

def hf_fast(st: Hf) -> Array<U32>:
  match st:
    case Hf{lens, next, fast}:
      fast

def hfast_of(lens: Array<U32>, cnt: Array<U32>, +n: U32) -> Array<U32>:
  hf_fast(hf_loop(U32.to_nat(n), Hf{lens, hn_next(hn_loop(15n, (Hn{Array.set(U32, cnt, 0, 0), Array.new(U32, 4n, 0)}, 0), 0)), Array.new(U32, 9n, 0)}, 0))

def huf_with_fast(r: Array<U32> & Array<U32>, lens: Array<U32>, sym: Array<U32>, +n: U32) -> Huf:
  (cnt, code_cnt) = r
  Huf{cnt, sym, hfast_of(lens, code_cnt, n)}

def huf_of_pl(st: Pl, cnt: Array<U32>, +n: U32) -> Huf:
  match st:
    case Pl{lens, offs, sym}:
      huf_with_fast(Array.fork(U32, cnt), lens, sym, n)

def huf_of_of(st: Of, lens: Array<U32>, +n: U32) -> Huf:
  match st:
    case Of{cnt, offs}:
      huf_of_pl(place_loop(U32.to_nat(n), Pl{lens, offs, Array.new(U32, 9n, 0)}, 0), cnt, n)

def huf_of_cs(st: Cs, +n: U32) -> Huf:
  match st:
    case Cs{lens, cnt}:
      huf_of_of(offs_loop(15n, (Of{Array.set(U32, cnt, 0, 0), Array.new(U32, 4n, 0)}, 0), 1), lens, n)

# the table for n code lengths
def huf_build(lens: Array<U32>, +n: U32) -> Huf:
  huf_of_cs(cnt_loop(U32.to_nat(n), Cs{lens, Array.new(U32, 4n, 0)}, 0), n)

# decoding walks the lengths over a peeked window; hit says the code is
# complete and at is its symbol's index
type Hl is Type:
  Hl{cnt: Array<U32>, buf: U32, len: U32, code: U32, first: U32, index: U32, at: U32, hit: Bool}

def hl_step(rc: Array<U32> & U32, +buf: U32, +len: U32, +code: U32, +first: U32, +index: U32) -> Hl:
  (cnt, count) = rc
  +code2 = (code .|. (U32.shrn(buf, U32.to_nat(len)) .&. 1) : U32)
  +cc = count
  Hl{cnt, buf, (len + 1 : U32), (code2 << 1n : U32), ((first + cc) << 1n : U32), (index + cc : U32), (index + (code2 - first) : U32), U32.is_lt((code2 - first : U32), cc)}

def hl_loop(n: Nat, st: Hl) -> Hl:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Hl{cnt, buf, len, code, first, index, at, hit}:
      match hit:
        case True{}:
          Hl{cnt, buf, len, code, first, index, at, True{}}
        case False{}:
          +l = len
          hl_loop(p, hl_step(Array.get(U32, cnt, (l + 1 : U32)), buf, l, code, first, index))

# a decoded symbol with the reader and the table handed back
type Hd is Type:
  Hd{br: Br, h: Huf, sym: U32}

def hd_of(rs: Array<U32> & U32, cnt: Array<U32>, fast: Array<U32>, a: Array<U32>, +pos: U32, +n: U32, +buf: U32, +bits: U32, +len: U32) -> Hd:
  (sym, v) = rs
  Hd{Br{a, pos, n, U32.shrn(buf, U32.to_nat(len)), (bits - len : U32)}, Huf{cnt, sym, fast}, v}

def hd_at(st: Hl, sym: Array<U32>, fast: Array<U32>, a: Array<U32>, +pos: U32, +n: U32, +bits: U32) -> Hd:
  match st:
    case Hl{cnt, buf, len, code, first, index, at, hit}:
      hd_of(Array.get(U32, sym, at), cnt, fast, a, pos, n, buf, bits, len)

def huf_walk(br: Br, h: Huf) -> Hd:
  match br, h:
    case Br{a, pos, n, buf, cnt}, Huf{hc, sym, fast}:
      +b = buf
      hd_at(hl_loop(15n, Hl{hc, b, 0, 0, 0, 0, 0, False{}}), sym, fast, a, pos, n, cnt)

def hd_fast(br: Br, cnt: Array<U32>, sym: Array<U32>, fast: Array<U32>, +v: U32) -> Hd:
  match br:
    case Br{a, pos, n, buf, bits}:
      +len = (v >> 16n : U32)
      Hd{Br{a, pos, n, U32.shrn(buf, U32.to_nat(len)), (bits - len : U32)}, Huf{cnt, sym, fast}, (v .&. 65535 : U32)}

def huf_fast_run(fast: Array<U32>, br: Br, cnt: Array<U32>, sym: Array<U32>, +v: U32, hit: Bool) -> Hd:
  match hit:
    case True{}:
      hd_fast(br, cnt, sym, fast, v)
    case False{}:
      huf_walk(br, Huf{cnt, sym, fast})

def huf_fast_pick(r: Array<U32> & U32, br: Br, cnt: Array<U32>, sym: Array<U32>) -> Hd:
  (fast, v) = r
  +vv = v
  huf_fast_run(fast, br, cnt, sym, vv, U32.is_ne(vv, 0))

def huf_fast_at(br: Br, h: Huf) -> Hd:
  match br, h:
    case Br{a, pos, n, buf, bits}, Huf{cnt, sym, fast}:
      +b = buf
      huf_fast_pick(Array.get(U32, fast, (b .&. 511 : U32)), Br{a, pos, n, b, bits}, cnt, sym)

def huf_decode(br: Br, h: Huf) -> Hd:
  huf_fast_at(br_ready(br, 15), h)

# Inflate
# -------
# the length and distance bases and extra bits of RFC 1951, by formula:
# lengths run 3..10 one per code, then fours of codes sharing an extra
# bit count, with 258 last; distances 1..4, then pairs

def len_base(+c: U32) -> U32:
  +e = ((c - 4) >> 2n : U32)
  pick(U32.is_lt(c, 8), (c + 3 : U32), pick(U32.is_eq(c, 28), 258, (3 + U32.shln(1, U32.to_nat((e + 2 : U32))) + U32.shln((c - (4 * e + 4) : U32), U32.to_nat(e)) : U32)))

def len_extra(+c: U32) -> U32:
  pick(U32.is_lt(c, 8) || U32.is_eq(c, 28), 0, ((c - 4) >> 2n : U32))

def dist_base(+c: U32) -> U32:
  +e = ((c - 2) >> 1n : U32)
  pick(U32.is_lt(c, 4), (c + 1 : U32), (1 + U32.shln(1, U32.to_nat((e + 1 : U32))) + U32.shln((c .&. 1 : U32), U32.to_nat(e)) : U32))

def dist_extra(+c: U32) -> U32:
  pick(U32.is_lt(c, 4), 0, ((c - 2) >> 1n : U32))

# the order the code-length code lengths are sent in, five bits an
# entry, six entries a word
def cl_order(+i: U32) -> U32:
  (U32.shrn(pick(U32.is_lt(i, 6), 243288624, pick(U32.is_lt(i, 12), 145926345, pick(U32.is_lt(i, 18), 48313452, 15))), U32.to_nat((5 * (i % 6) : U32))) .&. 31 : U32)

# the fixed literal/length lengths: 8 up to 143, 9 to 255, 7 to 279, 8 on
def fix_len(+i: U32) -> U32:
  pick(U32.is_le(i, 143), 8, pick(U32.is_le(i, 255), 9, pick(U32.is_le(i, 279), 7, 8)))

def fix_lens(n: Nat, a: Array<U32>, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+p:
      fix_lens(p, Array.set(U32, a, i, fix_len(i)), (i + 1 : U32))

# The inflate output is packed four bytes per word. Its exact byte capacity
# comes from the gzip ISIZE trailer, so decoding neither grows a byte-per-word
# array nor makes a second pass to pack it afterwards.
type Inf is Type:
  Inf{br: Br, out: Array<U32>, cap: U32, pos: U32, last: Bool}

# a block's tables
type Hs is Type:
  Hs{lit: Huf, dst: Huf}

def fixed_tables() -> Hs:
  Hs{huf_build(fix_lens(288n, Array.new(U32, 9n, 0), 0), 288), huf_build(Array.new(U32, 5n, 5), 30)}

# Stored block
# ------------
# after LEN and NLEN the reader is byte aligned and empty, so the bytes
# come straight from the words

def inf_put_got(r: Array<U32> & U32, +pos: U32, +b: U32) -> Array<U32>:
  (out, old) = r
  Array.set(U32, out, (pos >> 2n : U32), (old .|. U32.shln(b, U32.to_nat(((pos .&. 3) << 3n : U32))) : U32))

def inf_put(out: Array<U32>, +pos: U32, +b: U32) -> Array<U32>:
  inf_put_got(Array.get(U32, out, (pos >> 2n : U32)), pos, b)

def inf_word_split(out: Array<U32>, +q: U32, +v: U32, +sh: U32, split: Bool) -> Array<U32>:
  match split:
    case True{}:
      Array.set(U32, out, (q + 1 : U32), U32.shrn(v, U32.to_nat((32 - sh : U32))))
    case False{}:
      out

def inf_word_got(r: Array<U32> & U32, +pos: U32, +q: U32, +sh: U32, +v: U32) -> Array<U32>:
  (out, old) = r
  inf_word_split(Array.set(U32, out, q, (old .|. U32.shln(v, U32.to_nat(sh)) : U32)), q, v, sh, U32.is_ne(sh, 0))

def inf_word(out: Array<U32>, +pos: U32, +v: U32) -> Array<U32>:
  +q = (pos >> 2n : U32)
  +sh = ((pos .&. 3) << 3n : U32)
  inf_word_got(Array.get(U32, out, q), pos, q, sh, v)

def stored_put(r: Array<U32> & U32, +pos: U32, +n: U32, out: Array<U32>, +cap: U32, +at: U32, last: Bool) -> Inf:
  (a, b) = r
  Inf{Br{a, (pos + 1 : U32), n, 0, 0}, inf_put(out, at, b), cap, (at + 1 : U32), last}

def stored_byte(br: Br, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  match br:
    case Br{a, p, n, buf, cnt}:
      +pp = p
      stored_put(wb(a, pp), pp, n, out, cap, pos, last)

def stored_copy(n: Nat, st: Inf) -> Inf:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Inf{br, out, cap, pos, last}:
      stored_copy(p, stored_byte(br, out, cap, pos, last))

def stored_word(r: Array<U32> & U32, +pos: U32, +n: U32, out: Array<U32>, +cap: U32, +at: U32, last: Bool) -> Inf:
  (a, v) = r
  Inf{Br{a, (pos + 4 : U32), n, 0, 0}, inf_word(out, at, v), cap, (at + 4 : U32), last}

def stored_word_at(br: Br, out: Array<U32>, +cap: U32, +at: U32, last: Bool) -> Inf:
  match br:
    case Br{a, pos, n, buf, cnt}:
      +p = pos
      stored_word(w4(a, p), p, n, out, cap, at, last)

def stored_words(n: Nat, st: Inf) -> Inf:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Inf{br, out, cap, pos, last}:
      stored_words(p, stored_word_at(br, out, cap, pos, last))

def stored_tail(st: Inf, +len: U32) -> Inf:
  stored_copy(U32.to_nat((len .&. 3 : U32)), st)

def stored_room(oc: Array<U32> & U32, br: Br, +pos: U32, +len: U32, last: Bool) -> Inf:
  (out, cap) = oc
  stored_tail(stored_words(U32.to_nat((len >> 2n : U32)), Inf{br, out, cap, pos, last}), len)

def stored_nlen(r: Br & U32, out: Array<U32>, +cap: U32, +pos: U32, +len: U32, last: Bool) -> Inf:
  (br, nlen) = r
  stored_room((out, cap), br, pos, len, last)

def stored_len(r: Br & U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  (br, len) = r
  +l = len
  stored_nlen(br_bits(16n, br), out, cap, pos, l, last)

def stored_block(st: Inf) -> Inf:
  match st:
    case Inf{br, out, cap, pos, last}:
      stored_len(br_bits(16n, br_align(br)), out, cap, pos, last)

# Huffman block
# -------------
# one symbol at a time until 256; the record carries the tables and the
# done flag

type Cd is Type:
  Cd{st: Inf, hs: Hs, done: Bool}

type Cp is Type:
  Cp{out: Array<U32>}

def copy_put(r: Array<U32> & U32, +pos: U32) -> Cp:
  (out, b) = r
  Cp{inf_put(out, pos, b)}

def copy_word(r: Array<U32> & U32, +pos: U32) -> Cp:
  (out, v) = r
  Cp{inf_word(out, pos, v)}

# n bytes from dist back, one at a time (an overlap repeats the run)
def copy_loop(n: Nat, st: Cp, +pos: U32, +dist: U32) -> Cp:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Cp{out}:
      copy_loop(p, copy_put(wb(out, (pos - dist : U32)), pos), (pos + 1 : U32), dist)

def copy_words(n: Nat, st: Cp, +pos: U32, +dist: U32) -> Cp:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Cp{out}:
      copy_words(p, copy_word(w4(out, (pos - dist : U32)), pos), (pos + 4 : U32), dist)

def copy_wide(+len: U32, out: Array<U32>, +pos: U32, +dist: U32) -> Cp:
  copy_loop(U32.to_nat((len .&. 3 : U32)), copy_words(U32.to_nat((len >> 2n : U32)), Cp{out}, pos, dist), (pos + (len .&. 4294967292 : U32) : U32), dist)

def copy_pick(+len: U32, out: Array<U32>, +pos: U32, +dist: U32, wide: Bool) -> Cp:
  match wide:
    case True{}:
      copy_wide(len, out, pos, dist)
    case False{}:
      copy_loop(U32.to_nat(len), Cp{out}, pos, dist)

def cp_out(st: Cp) -> Array<U32>:
  match st:
    case Cp{out}:
      out

def copy_room(oc: Array<U32> & U32, br: Br, lit: Huf, dst: Huf, +pos: U32, +len: U32, +dist: U32, last: Bool) -> Cd:
  (out, cap) = oc
  Cd{Inf{br, cp_out(copy_pick(len, out, pos, dist, U32.is_ge(dist, 4) && U32.is_ge(len, 4))), cap, (pos + len : U32), last}, Hs{lit, dst}, False{}}

def emit_copy(br: Br, lit: Huf, dst: Huf, out: Array<U32>, +cap: U32, +pos: U32, +len: U32, +dist: U32, last: Bool) -> Cd:
  copy_room((out, cap), br, lit, dst, pos, len, dist, last)

def dist_fin(r: Br & U32, lit: Huf, dst: Huf, out: Array<U32>, +cap: U32, +pos: U32, +len: U32, +dbase: U32, last: Bool) -> Cd:
  (br, extra) = r
  emit_copy(br, lit, dst, out, cap, pos, len, (dbase + extra : U32), last)

def dist_sym(d: Hd, lit: Huf, out: Array<U32>, +cap: U32, +pos: U32, +len: U32, last: Bool) -> Cd:
  match d:
    case Hd{br, dst, sym}:
      +c = sym
      dist_fin(br_bits(U32.to_nat(dist_extra(c)), br), lit, dst, out, cap, pos, len, dist_base(c), last)

def len_fin(r: Br & U32, lit: Huf, dst: Huf, out: Array<U32>, +cap: U32, +pos: U32, +lbase: U32, last: Bool) -> Cd:
  (br, extra) = r
  dist_sym(huf_decode(br, dst), lit, out, cap, pos, (lbase + extra : U32), last)

def len_sym(br: Br, lit: Huf, dst: Huf, out: Array<U32>, +cap: U32, +pos: U32, +sym: U32, last: Bool) -> Cd:
  +c = (sym - 257 : U32)
  len_fin(br_bits(U32.to_nat(len_extra(c)), br), lit, dst, out, cap, pos, len_base(c), last)


def lit_put(oc: Array<U32> & U32, br: Br, lit: Huf, dst: Huf, +pos: U32, +sym: U32, last: Bool) -> Cd:
  (out, cap) = oc
  Cd{Inf{br, inf_put(out, pos, sym), cap, (pos + 1 : U32), last}, Hs{lit, dst}, False{}}

# a literal below 256, the end of block at 256, a length above
def sym_run(lit_: Bool, eob: Bool, br: Br, lit: Huf, dst: Huf, out: Array<U32>, +cap: U32, +pos: U32, +sym: U32, last: Bool) -> Cd:
  match lit_, eob:
    case True{}, k:
      lit_put((out, cap), br, lit, dst, pos, sym, last)
    case False{}, True{}:
      Cd{Inf{br, out, cap, pos, last}, Hs{lit, dst}, True{}}
    case False{}, False{}:
      len_sym(br, lit, dst, out, cap, pos, sym, last)

def sym_step(d: Hd, dst: Huf, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Cd:
  match d:
    case Hd{br, lit, sym}:
      +v = sym
      sym_run(U32.is_lt(v, 256), U32.is_eq(v, 256), br, lit, dst, out, cap, pos, v, last)

def code_step(st: Inf, hs: Hs) -> Cd:
  match st, hs:
    case Inf{br, out, cap, pos, last}, Hs{lit, dst}:
      sym_step(huf_decode(br, lit), dst, out, cap, pos, last)

def codes(n: Nat, st: Cd) -> Cd:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Cd{st, hs, done}:
      match done:
        case True{}:
          Cd{st, hs, True{}}
        case False{}:
          codes(p, code_step(st, hs))

def cd_inf(st: Cd) -> Inf:
  match st:
    case Cd{st, hs, done}:
      st

# cap bounds the symbols: the output size plus room for a block's worth
def huff_block(st: Inf, hs: Hs, +cap: U32) -> Inf:
  cd_inf(codes(U32.to_nat((cap + 1024 : U32)), Cd{st, hs, False{}}))

# Dynamic block
# -------------
# HLIT+257 literal lengths and HDIST+1 distance lengths, themselves coded
# by a table of HCLEN+4 code-length lengths

type Dy is Type:
  Dy{br: Br, lens: Array<U32>, i: U32, n: U32, prev: U32}

# the code-length lengths, in cl_order
def cl_put(r: Br & U32, lens: Array<U32>, +i: U32) -> Dy:
  (br, l) = r
  Dy{br, Array.set(U32, lens, cl_order(i), l), (i + 1 : U32), 0, 0}

def cl_lens(n: Nat, st: Dy) -> Dy:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Dy{br, lens, i, k, prev}:
      cl_lens(p, cl_put(br_bits(3n, br), lens, i))

# fill v into lens[i..i+n)
def rep_fill(n: Nat, lens: Array<U32>, +i: U32, +v: U32) -> Array<U32>:
  match n:
    case 0n:
      lens
    case 1n+p:
      rep_fill(p, Array.set(U32, lens, i, v), (i + 1 : U32), v)

# a code-length symbol: 0-15 a length, 16 repeats prev 3-6 times, 17
# gives 3-10 zeros, 18 11-138 zeros
def rl_put(r: Br & U32, lens: Array<U32>, +i: U32, +n: U32, +v: U32, +base: U32) -> Dy:
  (br, extra) = r
  +count = (base + extra : U32)
  Dy{br, rep_fill(U32.to_nat(count), lens, i, v), (i + count : U32), n, v}

def rl_run(len_: Bool, rep: Bool, z3: Bool, br: Br, lens: Array<U32>, +i: U32, +n: U32, +prev: U32, +sym: U32) -> Dy:
  match len_, rep, z3:
    case True{}, k1, k2:
      Dy{br, Array.set(U32, lens, i, sym), (i + 1 : U32), n, sym}
    case False{}, True{}, k2:
      rl_put(br_bits(2n, br), lens, i, n, prev, 3)
    case False{}, False{}, True{}:
      rl_put(br_bits(3n, br), lens, i, n, 0, 3)
    case False{}, False{}, False{}:
      rl_put(br_bits(7n, br), lens, i, n, 0, 11)

# the lengths being read with their table
type Dl is Type:
  Dl{dy: Dy, h: Huf, more: Bool}

def dl_of(st: Dy, h: Huf) -> Dl:
  match st:
    case Dy{br, lens, i, n, prev}:
      +ii = i
      +nn = n
      Dl{Dy{br, lens, ii, nn, prev}, h, U32.is_lt(ii, nn)}

def rl_sym(d: Hd, lens: Array<U32>, +i: U32, +n: U32, +prev: U32) -> Dl:
  match d:
    case Hd{br, h, sym}:
      +v = sym
      dl_of(rl_run(U32.is_lt(v, 16), U32.is_eq(v, 16), U32.is_eq(v, 17), br, lens, i, n, prev, v), h)

def rl_step(st: Dy, h: Huf) -> Dl:
  match st:
    case Dy{br, lens, i, n, prev}:
      rl_sym(huf_decode(br, h), lens, i, n, prev)

def rl_loop(fuel: Nat, st: Dl) -> Dl:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Dl{dy, h, more}:
      match more:
        case False{}:
          Dl{dy, h, False{}}
        case True{}:
          rl_loop(p, rl_step(dy, h))

def dy_pair(dy: Dy) -> Br & Array<U32>:
  match dy:
    case Dy{br, lens, i, n, prev}:
      (br, lens)

def dy_lens(st: Dl) -> Br & Array<U32>:
  match st:
    case Dl{dy, h, more}:
      dy_pair(dy)

# lens[off..off+n) copied into dst[0..n)
type Sp is Type:
  Sp{src: Array<U32>, dst: Array<U32>}

def sp_put(r: Array<U32> & U32, dst: Array<U32>, +i: U32) -> Sp:
  (src, v) = r
  Sp{src, Array.set(U32, dst, i, v)}

def sp_loop(n: Nat, st: Sp, +i: U32, +off: U32) -> Sp:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Sp{src, dst}:
      sp_loop(p, sp_put(Array.get(U32, src, (off + i : U32)), dst, i), (i + 1 : U32), off)

def sp_pair(st: Sp) -> Array<U32> & Array<U32>:
  match st:
    case Sp{src, dst}:
      (src, dst)

def split_lens(+n: U32, src: Array<U32>, dst: Array<U32>, +off: U32) -> Array<U32> & Array<U32>:
  sp_pair(sp_loop(U32.to_nat(n), Sp{src, dst}, 0, off))

def dyn_dist(r: Array<U32> & Array<U32>, br: Br, +nlit: U32, +ndist: U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  (lit_lens, dist_lens) = r
  huff_block(Inf{br, out, cap, pos, last}, Hs{huf_build(lit_lens, nlit), huf_build(dist_lens, ndist)}, (pos + 1000000 : U32))

def dyn_tables(r: Br & Array<U32>, +nlit: U32, +ndist: U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  (br, lens) = r
  dyn_dist(split_lens(ndist, lens, Array.new(U32, 5n, 0), nlit), br, nlit, ndist, out, cap, pos, last)

def dyn_body(cl: Dy, +nlit: U32, +ndist: U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  match cl:
    case Dy{br, cl_lens, i, k, prev}:
      +total = (nlit + ndist : U32)
      dyn_tables(dy_lens(rl_loop(U32.to_nat((total + 1 : U32)), Dl{Dy{br, Array.new(U32, 9n, 0), 0, total, 0}, huf_build(cl_lens, 19), True{}})), nlit, ndist, out, cap, pos, last)

def dyn_hclen(r: Br & U32, +nlit: U32, +ndist: U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  (br, hclen) = r
  dyn_body(cl_lens(U32.to_nat((hclen + 4 : U32)), Dy{br, Array.new(U32, 5n, 0), 0, 0, 0}), nlit, ndist, out, cap, pos, last)

def dyn_hdist(r: Br & U32, +nlit: U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  (br, hdist) = r
  dyn_hclen(br_bits(4n, br), nlit, (hdist + 1 : U32), out, cap, pos, last)

def dyn_hlit(r: Br & U32, out: Array<U32>, +cap: U32, +pos: U32, last: Bool) -> Inf:
  (br, hlit) = r
  dyn_hdist(br_bits(5n, br), (hlit + 257 : U32), out, cap, pos, last)

def dyn_block(st: Inf) -> Inf:
  match st:
    case Inf{br, out, cap, pos, last}:
      dyn_hlit(br_bits(5n, br), out, cap, pos, last)

# Blocks
# ------

def block_run(stored: Bool, fixed: Bool, st: Inf) -> Inf:
  match stored, fixed:
    case True{}, k:
      stored_block(st)
    case False{}, True{}:
      huff_block(st, fixed_tables(), 1000000)
    case False{}, False{}:
      dyn_block(st)

def block_head(r: Br & U32, out: Array<U32>, +cap: U32, +pos: U32) -> Inf:
  (br, hd) = r
  +h = hd
  block_run(U32.is_eq((h >> 1n : U32), 0), U32.is_eq((h >> 1n : U32), 1), Inf{br, out, cap, pos, U32.is_eq((h .&. 1 : U32), 1)})

def block(st: Inf) -> Inf:
  match st:
    case Inf{br, out, cap, pos, last}:
      block_head(br_bits(3n, br), out, cap, pos)

def blocks(n: Nat, st: Inf) -> Inf:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Inf{br, out, cap, pos, last}:
      match last:
        case True{}:
          Inf{br, out, cap, pos, True{}}
        case False{}:
          blocks(p, block(Inf{br, out, cap, pos, False{}}))


# Gzip
# ----
# header: 1f 8b 08 FLG mtime(4) xfl os, then extra, name, comment and a
# header crc as FLG says; the final four trailer bytes are ISIZE.

def inf_pack(st: Inf) -> Array<U32> & U32:
  match st:
    case Inf{br, out, cap, pos, last}:
      (out, pos)

# the deflate stream from pos; out_n is the gzip trailer's ISIZE
def inflate(a: Array<U32>, +pos: U32, +n: U32, +out_n: U32) -> Array<U32> & U32:
  inf_pack(blocks(U32.to_nat(65536), Inf{Br{a, pos, n, 0, 0}, Array.new(U32, arr_depth(((out_n >> 2n) + 3 : U32)), 0), out_n, 0, False{}}))

# past a NUL-terminated field from pos
type Sk is Type:
  Sk{a: Array<U32>, pos: U32, more: Bool}

def sk_at(r: Array<U32> & U32, +pos: U32, +n: U32) -> Sk:
  (a, b) = r
  Sk{a, (pos + 1 : U32), U32.is_ne(b, 0) && U32.is_lt((pos + 1 : U32), n)}

def sk_loop(fuel: Nat, st: Sk, +n: U32) -> Sk:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Sk{a, pos, more}:
      match more:
        case False{}:
          Sk{a, pos, False{}}
        case True{}:
          +pp = pos
          sk_loop(p, sk_at(wb(a, pp), pp, n), n)

def sk_of(st: Sk) -> Array<U32> & U32:
  match st:
    case Sk{a, pos, more}:
      (a, pos)

def skip_nul_go(a: Array<U32>, +pos: U32, +n: U32, on: Bool) -> Array<U32> & U32:
  match on:
    case True{}:
      sk_of(sk_loop(U32.to_nat(n), Sk{a, pos, U32.is_lt(pos, n)}, n))
    case False{}:
      (a, pos)

def skip_nul(r: Array<U32> & U32, +n: U32, on: Bool) -> Array<U32> & U32:
  (a, pos) = r
  +p = pos
  skip_nul_go(a, p, n, on)

def skip_n(r: Array<U32> & U32, +k: U32, on: Bool) -> Array<U32> & U32:
  (a, pos) = r
  (a, (pos + pick(on, k, 0) : U32))

def skip_xlen(r: Array<U32> & U32, +pos: U32) -> Array<U32> & U32:
  (a, w) = r
  (a, (pos + 2 + (w .&. 65535) : U32))

def skip_extra_go(a: Array<U32>, +pos: U32, on: Bool) -> Array<U32> & U32:
  match on:
    case True{}:
      skip_xlen(w4(a, pos), pos)
    case False{}:
      (a, pos)

def skip_extra(r: Array<U32> & U32, on: Bool) -> Array<U32> & U32:
  (a, pos) = r
  +p = pos
  skip_extra_go(a, p, on)

# the deflate stream's offset from the flags byte
def gz_body(r: Array<U32> & U32, +n: U32) -> Array<U32> & U32:
  (a, flg) = r
  +f = flg
  skip_n(skip_nul(skip_nul(skip_extra((a, 10), U32.is_ne((f .&. 4 : U32), 0)), n, U32.is_ne((f .&. 8 : U32), 0)), n, U32.is_ne((f .&. 16 : U32), 0)), 2, U32.is_ne((f .&. 2 : U32), 0))

def gz_start(r: Array<U32> & U32, +n: U32, +out_n: U32) -> Array<U32> & U32:
  (a, pos) = r
  inflate(a, pos, n, out_n)

def gz_sized(r: Array<U32> & U32, +n: U32) -> Array<U32> & U32:
  (a, out_n) = r
  gz_start(gz_body(wb(a, 3), n), n, out_n)

def gunzip(a: Array<U32>, +n: U32) -> Array<U32> & U32:
  gz_sized(w4(a, (n - 4 : U32)), n)

# the magic 1f 8b
def gz_magic(r: Array<U32> & U32) -> Array<U32> & Bool:
  (a, w) = r
  (a, U32.is_eq((w .&. 65535 : U32), 35615))

def gz_peek(a: Array<U32>) -> Array<U32> & Bool:
  gz_magic(w4(a, 0))

def maybe_gunzip(a: Array<U32>, +n: U32, gz: Bool) -> Array<U32> & U32:
  match gz:
    case True{}:
      gunzip(a, n)
    case False{}:
      (a, n)

# Plain archives are listed one header at a time. Payload ranges are skipped by
# advancing the pread offset, so a one-file 64 MiB archive reads 512 bytes rather
# than materializing all 64 MiB. Gzip still uses the decoder above.
type Ls is Type:
  LRead{file: File, a: Array<U32>, n: U32, off: U32}
  LHdr{file: File, h: Hdr, off: U32}

def ls_read(r: Fr, +off: U32) -> Ls:
  match r:
    case Fr{file, a, n}:
      LRead{file, a, n, off}

def list_stream_close(st: Ls) -> IO(Unit):
  match st:
    case LRead{file, a, n, off}:
      do IO<Unit>:
        Unit <- drop_words(a)
        File.close(file)
    case LHdr{file, Hdr{a, name, size, kind, hoff, end}, off}:
      do IO<Unit>:
        Unit <- drop_words(a)
        File.close(file)

def list_stream_loop(fuel: Nat, st: Ls, +path: String, +n: U32) -> IO(Unit):
  match fuel, st:
    case 0n, r:
      list_stream_close(r)
    case 1n+p, LRead{file, a, got, off}:
      +nn = got
      list_stream_loop(p, LHdr{file, hdr_of(a, 0, nn), off}, path, n)
    case 1n+p, LHdr{file, Hdr{a, name, size, kind, hoff, end}, off}:
      match end:
        case True{}:
          do IO<Unit>:
            Unit <- drop_words(a)
            File.close(file)
        case False{}:
          +sz = size
          +next = (off + 512 + sz + pad512(sz) : U32)
          do IO<Unit>:
            Unit <- IO.print(name)
            Unit <- drop_words(a)
            raw : File & Result<&1, &1, U32 & String, Array<U32> & U32> <- File.read_words_at(file, next, 512)
            chunk : Fr <- file_read_words_got(path, raw)
            list_stream_loop(p, ls_read(chunk, next), path, n)

def walk_in_gzip(r: Array<U32> & U32) -> IO(Unit):
  (a, n) = r
  walk(gunzip(a, n), False{}, False{})

def list_stream_peek(r: Array<U32> & Bool, file: File, +path: String, +n: U32, +got: U32) -> IO(Unit):
  (a, magic) = r
  match magic:
    case False{}:
      list_stream_loop(U32.to_nat((n / 256 + 4 : U32)), LHdr{file, hdr_of(a, 0, got), 0}, path, n)
    case True{}:
      do IO<Unit>:
        Unit <- drop_words(a)
        Unit <- File.close(file)
        packed : Array<U32> & U32 <- read_words(path)
        walk_in_gzip(packed)

def list_stream_first(r: Fr, +path: String, +total: U32) -> IO(Unit):
  match r:
    case Fr{file, a, n}:
      +nn = n
      list_stream_peek(gz_peek(a), file, path, total, nn)

def list_stream_open(file: File, +path: String, +n: U32) -> IO(Unit):
  do IO<Unit>:
    raw : File & Result<&1, &1, U32 & String, Array<U32> & U32> <- File.read_words_at(file, 0, 512)
    chunk : Fr <- file_read_words_got(path, raw)
    list_stream_first(chunk, path, n)

def list_stream(+path: String) -> IO(Unit):
  do IO<Unit>:
    n : U32 <- size_of(path)
    opened : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    file : File <- open_got(path, opened)
    list_stream_open(file, path, n)

# Deflate
# -------
# one dynamic-Huffman block over an LZ77 pass: a hash of three bytes
# remembers the last position seen, and a match of 3 to 258 bytes at
# most 32768 back becomes a length/distance pair. The pass keeps its
# tokens and symbol counts; the counts give Huffman codes of at most 15
# bits, whose lengths go out run-length coded under a 7-bit code

# bit writer over the output sink; more says a byte is ready
type Bw is Type:
  Bw{ob: Ob, buf: U32, cnt: U32, more: Bool}

def bw_flush(n: Nat, st: Bw) -> Bw:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Bw{ob, buf, cnt, more}:
      match more:
        case False{}:
          Bw{ob, buf, cnt, False{}}
        case True{}:
          +b = buf
          +c = (cnt - 8 : U32)
          bw_flush(p, Bw{ob_byte(ob, (b .&. 255 : U32)), (b >> 8n : U32), c, U32.is_ge(c, 8)})

# v's low k bits, least significant first
def bw_put(st: Bw, +v: U32, +k: U32) -> Bw:
  match st:
    case Bw{ob, buf, cnt, more}:
      +c = cnt
      +c2 = (c + k : U32)
      bw_flush(4n, Bw{ob, (buf .|. U32.shln(v, U32.to_nat(c)) : U32), c2, U32.is_ge(c2, 8)})

def rev_bits(n: Nat, +c: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      rev_bits(p, (c >> 1n : U32), ((acc << 1n) .|. (c .&. 1) : U32))

# a Huffman code goes most significant bit first
def bw_code(st: Bw, +code: U32, +k: U32) -> Bw:
  bw_put(st, rev_bits(U32.to_nat(k), code, 0), k)

def bw_last(ob: Ob, +buf: U32, some: Bool) -> Ob:
  match some:
    case True{}:
      ob_byte(ob, (buf .&. 255 : U32))
    case False{}:
      ob

def bw_fin(st: Bw) -> Ob:
  match st:
    case Bw{ob, buf, cnt, more}:
      +c = cnt
      bw_last(ob, buf, U32.is_gt(c, 0))

def base_of(dist: Bool, +c: U32) -> U32:
  match dist:
    case True{}:
      dist_base(c)
    case False{}:
      len_base(c)

def extra_of(dist: Bool, +c: U32) -> U32:
  match dist:
    case True{}:
      dist_extra(c)
    case False{}:
      len_extra(c)

# the code index for a length or a distance: the last base <= v; stop
# says the next base is already past v
def code_of(n: Nat, +v: U32, +c: U32, stop: Bool, +dist: Bool) -> U32:
  match n, stop:
    case k, True{}:
      c
    case 0n, False{}:
      c
    case 1n+p, False{}:
      code_of(p, v, (c + 1 : U32), U32.is_lt(v, base_of(dist, (c + 2 : U32))), dist)

# Tokens
# ------
# a block's tokens, two words each: sym | ex << 9 | eb << 14 | ds << 17
# | db << 22, then the distance's extra bits; a block holds 16384 and
# the run-length coded lengths ride a short list of Tok

type Tok is Data:
  Tok{sym: U32, ex: U32, eb: U32, ds: U32, dx: U32, db: U32}

def bump_put(r: Array<U32> & U32, +i: U32) -> Array<U32>:
  (a, v) = r
  Array.set(U32, a, i, (v + 1 : U32))

def bump(a: Array<U32>, +i: U32) -> Array<U32>:
  bump_put(Array.get(U32, a, i), i)

def tk_w0(+sym: U32, +ex: U32, +eb: U32, +ds: U32, +db: U32) -> U32:
  (sym .|. (ex << 9n) .|. (eb << 14n) .|. (ds << 17n) .|. (db << 22n) : U32)

# the token state of a block: the words, the count, the literal/length
# and distance counts, and the bytes covered
type Ts is Type:
  Ts{tk: Array<U32>, nt: U32, fl: Array<U32>, fd: Array<U32>, cov: U32}

def ts_new() -> Ts:
  Ts{Array.new(U32, 15n, 0), 0, Array.new(U32, 9n, 0), Array.new(U32, 5n, 0), 0}

def ts_put(tk: Array<U32>, +nt: U32, +w0: U32, +w1: U32) -> Array<U32>:
  Array.set(U32, Array.set(U32, tk, (nt << 1n : U32), w0), ((nt << 1n) + 1 : U32), w1)

# a literal; the flag says the block is full
def ts_lit(st: Ts, +b: U32) -> Ts & Bool:
  match st:
    case Ts{tk, nt, fl, fd, cov}:
      +k = nt
      (Ts{ts_put(tk, k, b, 0), (k + 1 : U32), bump(fl, b), fd, (cov + 1 : U32)}, U32.is_ge((k + 1 : U32), 16384))

def ts_len(st: Ts, +len: U32, +dist: U32) -> Ts & Bool:
  match st:
    case Ts{tk, nt, fl, fd, cov}:
      +k = nt
      +c = code_of(29n, len, 0, U32.is_lt(len, 4), False{})
      +d = code_of(30n, dist, 0, U32.is_lt(dist, 2), True{})
      (Ts{ts_put(tk, k, tk_w0((257 + c : U32), (len - len_base(c) : U32), extra_of(False{}, c), d, extra_of(True{}, d)), (dist - dist_base(d) : U32)), (k + 1 : U32), bump(fl, (257 + c : U32)), bump(fd, d), (cov + len : U32)}, U32.is_ge((k + 1 : U32), 16384))

def trev(l: List<&2, Tok>, acc: List<&2, Tok>) -> List<&2, Tok>:
  match l:
    case Nil{}:
      acc
    case Con{h, t}:
      trev(t, h <> acc)

# Matcher
# -------
# zlib's shape: head[hash of 3 bytes] holds the last position + 1 with
# that hash and prev[pos & 32767] the one before it, so a chain walks
# back through the window. A level picks the knobs: chain caps the walk,
# nice ends it early on a long enough match, and on the lazy levels a
# match is held back one byte to see if the next position does better
# (lazy stops that search once the held match is long enough, good
# shortens the chain for it). Levels 1-3 are greedy, and lazy is then
# the longest match whose inner positions still enter the table.

type Cf is Data:
  Cf{good: U32, lazy: U32, nice: U32, chain: U32, slow: Bool}

def cf_of(+l: U32) -> Cf:
  Cf{pick(U32.is_le(l, 4), 4, pick(U32.is_le(l, 7), 8, 32)),
    pick(U32.is_le(l, 3), (l + 3 : U32), pick(U32.is_eq(l, 4), 4, pick(U32.is_le(l, 6), 16, pick(U32.is_eq(l, 7), 32, pick(U32.is_eq(l, 8), 128, 258))))),
    pick(U32.is_le(l, 3), U32.shln(4, U32.to_nat(l)), pick(U32.is_eq(l, 4), 16, pick(U32.is_eq(l, 5), 32, pick(U32.is_le(l, 7), 128, 258)))),
    pick(U32.is_eq(l, 1), 4, pick(U32.is_eq(l, 2), 8, pick(U32.is_eq(l, 3), 32, pick(U32.is_eq(l, 4), 16, pick(U32.is_eq(l, 5), 32, pick(U32.is_eq(l, 6), 128, pick(U32.is_eq(l, 7), 256, pick(U32.is_eq(l, 8), 1024, 4096)))))))),
    U32.is_ge(l, 4)}

def cf_slow(cf: Cf) -> Bool:
  match cf:
    case Cf{good, lazy, nice, chain, slow}:
      slow

# Match extension keeps one linear input handle. The old implementation forked
# that handle for every candidate and joined it afterwards. On repetitive data,
# all workers then contended on the input array's atomic ownership metadata.
# Serially reading the two four-byte windows costs two more word reads per step,
# but leaves the shared input read-only and ownership-local to each chunk.
type Mw is Type:
  Mw{w: Array<U32>, a: U32, b: U32, len: U32, more: Bool}

def mw_cmp(r: Array<U32> & U32, +a: U32, +b: U32, +wa: U32, +len: U32, +maxlen: U32) -> Mw:
  (w, wb2) = r
  +x = U32.xor(wa, wb2)
  +eq4 = U32.is_eq(x, 0)
  +len2 = (len + pick(eq4, 4, (b2u(U32.is_eq((x .&. 255 : U32), 0)) + b2u(U32.is_eq((x .&. 65535 : U32), 0)) + b2u(U32.is_eq((x .&. 16777215 : U32), 0)) : U32)) : U32)
  Mw{w, (a + 4 : U32), (b + 4 : U32), pick(U32.is_gt(len2, maxlen), maxlen, len2), eq4 && U32.is_lt(len2, maxlen)}

def mw_b(r: Array<U32> & U32, +a: U32, +b: U32, +len: U32, +maxlen: U32) -> Mw:
  (w, wa) = r
  mw_cmp(w4(w, b), a, b, wa, len, maxlen)

def mw_loop(fuel: Nat, st: Mw, +maxlen: U32) -> Mw:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Mw{w, a, b, len, more}:
      match more:
        case False{}:
          Mw{w, a, b, len, False{}}
        case True{}:
          +aa = a
          +bb = b
          +ll = len
          mw_loop(p, mw_b(w4(w, aa), aa, bb, ll, maxlen), maxlen)

def mw_fin(st: Mw) -> Array<U32> & U32:
  match st:
    case Mw{w, a, b, len, more}:
      (w, len)

def match_pick(w: Array<U32>, +i: U32, +dist: U32, +maxlen: U32, +x: U32, same: Bool) -> Array<U32> & U32:
  match same:
    case True{}:
      +len = pick(U32.is_lt(maxlen, 4), maxlen, 4)
      mw_fin(mw_loop(64n, Mw{w, (i + 4 : U32), (i - dist + 4 : U32), len, U32.is_gt(maxlen, 4)}, maxlen))
    case False{}:
      +len = (b2u(U32.is_eq((x .&. 255 : U32), 0)) + b2u(U32.is_eq((x .&. 65535 : U32), 0)) + b2u(U32.is_eq((x .&. 16777215 : U32), 0)) : U32)
      (w, pick(U32.is_gt(len, maxlen), maxlen, len))

def match_quick_b(r: Array<U32> & U32, +wa: U32, +i: U32, +dist: U32, +maxlen: U32) -> Array<U32> & U32:
  (w, wb2) = r
  +x = U32.xor(wa, wb2)
  match_pick(w, i, dist, maxlen, x, U32.is_eq(x, 0))

def match_quick_a(r: Array<U32> & U32, +i: U32, +dist: U32, +maxlen: U32) -> Array<U32> & U32:
  (w, wa) = r
  match_quick_b(w4(w, (i - dist : U32)), wa, i, dist, maxlen)

# the length of the match at i against i - dist, at most 258 and the
# bytes left
def match_at(w: Array<U32>, +i: U32, +dist: U32, +n: U32) -> Array<U32> & U32:
  +maxlen = pick(U32.is_lt((n - i : U32), 258), (n - i : U32), 258)
  match_quick_a(w4(w, i), i, dist, maxlen)

# the hash tables
type In is Type:
  In{w: Array<U32>, hd: Array<U32>, prev: Array<U32>}

def in_hd(r: Array<U32> & U32, w: Array<U32>, prev: Array<U32>, +j: U32, +h: U32) -> In & U32:
  (hd, cand) = r
  +c = cand
  (In{w, Array.set(U32, hd, h, (j + 1 : U32)), Array.set(U32, prev, (j .&. 32767 : U32), c)}, c)

# the hash of the three bytes at j, from one window
def in_win(r: Array<U32> & U32, hd: Array<U32>, prev: Array<U32>, +j: U32) -> In & U32:
  (w, v) = r
  +vv = v
  +h = (U32.xor(U32.xor(((vv .&. 255) << 10n : U32), (((vv >> 8n) .&. 255) << 5n : U32)), ((vv >> 16n) .&. 255 : U32)) .&. 32767 : U32)
  in_hd(Array.get(U32, hd, h), w, prev, j, h)

def ins_go(w: Array<U32>, hd: Array<U32>, prev: Array<U32>, +j: U32, ok: Bool) -> In & U32:
  match ok:
    case False{}:
      (In{w, hd, prev}, 0)
    case True{}:
      in_win(w4(w, j), hd, prev, j)

# position j into the tables; answers the previous head (a position + 1,
# 0 for none), and 0 when fewer than 3 bytes remain
def ins_at(w: Array<U32>, hd: Array<U32>, prev: Array<U32>, +j: U32, +n: U32) -> In & U32:
  ins_go(w, hd, prev, j, U32.is_lt((j + 2 : U32), n))

def ins_drop(r: In & U32) -> In:
  (ht, c) = r
  ht

# positions j.. into the tables
def ins_loop(fuel: Nat, st: In, +j: U32, +n: U32) -> In:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, In{w, hd, prev}:
      ins_loop(p, ins_drop(ins_at(w, hd, prev, j, n)), (j + 1 : U32), n)

# the chain walk: the best length and distance so far, the input byte
# at the best length (read again only when the best changes), and the
# candidate to try; more says it is live, in the window, and worth trying
type Ch is Type:
  Ch{w: Array<U32>, prev: Array<U32>, bl: U32, bd: U32, x: U32, cand: U32, more: Bool}

def ch_nx(rp: Array<U32> & U32, w: Array<U32>, +bl: U32, +bd: U32, +x: U32, +i: U32, +nice: U32, +left: U32) -> Ch:
  (prev, nxt) = rp
  +nx = nxt
  Ch{w, prev, bl, bd, x, nx, U32.is_ne(nx, 0) && U32.is_le((i - (nx - 1) : U32), 32768) && U32.is_lt(bl, nice) && U32.is_gt(left, 1)}

def ch_x(r: Array<U32> & U32, prev: Array<U32>, +bl: U32, +bd: U32, +c: U32, +i: U32, +nice: U32, +left: U32) -> Ch:
  (w, x) = r
  ch_nx(Array.get(U32, prev, ((c - 1) .&. 32767 : U32)), w, bl, bd, x, i, nice, left)

def ch_upd(w: Array<U32>, prev: Array<U32>, +l: U32, +bl: U32, +bd: U32, +c: U32, +d: U32, +i: U32, +nice: U32, +left: U32, +x: U32, better: Bool) -> Ch:
  match better:
    case True{}:
      ch_x(wb(w, (i + l : U32)), prev, l, d, c, i, nice, left)
    case False{}:
      ch_nx(Array.get(U32, prev, ((c - 1) .&. 32767 : U32)), w, bl, bd, x, i, nice, left)

def ch_at(r: Array<U32> & U32, prev: Array<U32>, +bl: U32, +bd: U32, +c: U32, +d: U32, +i: U32, +nice: U32, +left: U32, +x: U32) -> Ch:
  (w, len) = r
  +l = len
  ch_upd(w, prev, l, bl, bd, c, d, i, nice, left, x, U32.is_gt(l, bl))

# a candidate whose byte at the best length differs cannot do better:
# one compare there before the full one, as zlib does
def ch_go(w: Array<U32>, prev: Array<U32>, +bl: U32, +bd: U32, +c: U32, +d: U32, +i: U32, +n: U32, +nice: U32, +left: U32, +x: U32, ok: Bool) -> Ch:
  match ok:
    case False{}:
      ch_nx(Array.get(U32, prev, ((c - 1) .&. 32767 : U32)), w, bl, bd, x, i, nice, left)
    case True{}:
      ch_at(match_at(w, i, d, n), prev, bl, bd, c, d, i, nice, left, x)

def ch_q(r: Array<U32> & U32, prev: Array<U32>, +bl: U32, +bd: U32, +c: U32, +d: U32, +i: U32, +n: U32, +nice: U32, +left: U32, +x: U32) -> Ch:
  (w, y) = r
  ch_go(w, prev, bl, bd, c, d, i, n, nice, left, x, U32.is_eq(x, y))

def ch_loop(fuel: Nat, st: Ch, +i: U32, +n: U32, +nice: U32, +left: U32) -> Ch:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Ch{w, prev, bl, bd, x, cand, more}:
      match more:
        case False{}:
          Ch{w, prev, bl, bd, x, cand, False{}}
        case True{}:
          +c = cand
          +l = bl
          ch_loop(p, ch_q(wb(w, (i + l - (i - (c - 1)) : U32)), prev, l, bd, c, (i - (c - 1) : U32), i, n, nice, left, x), i, n, nice, (left - 1 : U32))

def ch_start(r: Array<U32> & U32, prev: Array<U32>, +i: U32, +n: U32, +cand: U32, +chain: U32, +nice: U32, search: Bool) -> Ch:
  (w, x) = r
  ch_loop(U32.to_nat(chain), Ch{w, prev, 0, 0, x, cand, search && U32.is_ne(cand, 0) && U32.is_le((i - (cand - 1) : U32), 32768) && U32.is_lt((i + 2 : U32), n) && U32.is_gt(chain, 0)}, i, n, nice, chain)

# the walk from head cand; search says it is wanted at all
def chain(w: Array<U32>, prev: Array<U32>, +i: U32, +n: U32, +cand: U32, +chain: U32, +nice: U32, search: Bool) -> Ch:
  ch_start(wb(w, i), prev, i, n, cand, chain, nice, search)

# a match of 3 farther than 4096 back costs more than its literals
def too_far(+l: U32, +d: U32) -> U32:
  pick(U32.is_eq(l, 3) && U32.is_gt(d, 4096), 0, l)

# the pass: input, tables, the block's tokens, the position, and on the
# lazy levels the held match (pl, pd) for position i - 1 with pend
# saying that byte is still unsent; stop says the block is full or the
# input done
type Lz is Type:
  Lz{w: Array<U32>, hd: Array<U32>, prev: Array<U32>, ts: Ts, i: U32, n: U32, pl: U32, pd: U32, pend: Bool, done: Bool, stop: Bool}

def lz_of(r: Ts & Bool, w: Array<U32>, hd: Array<U32>, prev: Array<U32>, +i: U32, +n: U32, +pl: U32, +pd: U32, +pend: Bool, +done: Bool) -> Lz:
  (ts, full) = r
  Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, done || full}

# a match token; the pass resumes at i
def lz_match(ht: In, ts: Ts, +i: U32, +n: U32, +len: U32, +dist: U32) -> Lz:
  match ht:
    case In{w, hd, prev}:
      lz_of(ts_len(ts, len, dist), w, hd, prev, i, n, 0, 0, False{}, U32.is_ge(i, n))

# a literal token; the pass resumes at i holding (pl, pd)
def lz_lit(r: Array<U32> & U32, hd: Array<U32>, prev: Array<U32>, ts: Ts, +i: U32, +n: U32, +pl: U32, +pd: U32, +pend: Bool) -> Lz:
  (w, b) = r
  lz_of(ts_lit(ts, b), w, hd, prev, i, n, pl, pd, pend, U32.is_ge(i, n) && U32.is_eq(b2u(pend), 0))

# Greedy levels
# -------------

def fa_ins(ht: In, +i: U32, +n: U32, +cl: U32, ins: Bool) -> In:
  match ins:
    case True{}:
      ins_loop(U32.to_nat((cl - 1 : U32)), ht, (i + 1 : U32), n)
    case False{}:
      ht

def fa_decide(w: Array<U32>, hd: Array<U32>, prev: Array<U32>, ts: Ts, +i: U32, +n: U32, +cl: U32, +cd: U32, +maxins: U32, hit: Bool) -> Lz:
  match hit:
    case True{}:
      lz_match(fa_ins(In{w, hd, prev}, i, n, cl, U32.is_le(cl, maxins)), ts, (i + cl : U32), n, cl, cd)
    case False{}:
      lz_lit(wb(w, i), hd, prev, ts, (i + 1 : U32), n, 0, 0, False{})

def fa_found(ch: Ch, hd: Array<U32>, ts: Ts, +i: U32, +n: U32, +maxins: U32) -> Lz:
  match ch:
    case Ch{w, prev, bl, bd, x, cand, more}:
      +d = bd
      +cl = too_far(bl, d)
      fa_decide(w, hd, prev, ts, i, n, cl, d, maxins, U32.is_ge(cl, 3))

def fa_ht(ht: In, +cand: U32, ts: Ts, +i: U32, +n: U32, +cf: Cf) -> Lz:
  match ht, cf:
    case In{w, hd, prev}, Cf{good, lazy, nice, ch, slow}:
      fa_found(chain(w, prev, i, n, cand, ch, nice, True{}), hd, ts, i, n, lazy)

def fa_ins_at(r: In & U32, ts: Ts, +i: U32, +n: U32, +cf: Cf) -> Lz:
  (ht, cand) = r
  fa_ht(ht, cand, ts, i, n, cf)

def fa_step(st: Lz, +cf: Cf) -> Lz:
  match st:
    case Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, stop}:
      +ii = i
      +nn = n
      fa_ins_at(ins_at(w, hd, prev, ii, nn), ts, ii, nn, cf)

# Lazy levels
# -----------
# at i the held match for i - 1 is sent when the new one is no longer;
# otherwise i - 1 goes out as a literal and the new match is held

def ins_stride(fuel: Nat, st: In, +j: U32, +n: U32) -> In:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, In{w, hd, prev}:
      ins_stride(p, ins_drop(ins_at(w, hd, prev, j, n)), (j + 2 : U32), n)

def sl_insert(ht: In, +i: U32, +n: U32, +pl: U32, +maxins: U32, insert: Bool) -> In:
  match insert:
    case True{}:
      ins_loop(U32.to_nat((pl - 2 : U32)), ht, (i + 1 : U32), n)
    case False{}:
      ins_stride(U32.to_nat(((pl - 1) / 2 : U32)), ht, (i + 1 : U32), n)

def sl_decide(w: Array<U32>, hd: Array<U32>, prev: Array<U32>, ts: Ts, +i: U32, +n: U32, +pl: U32, +pd: U32, +cl: U32, +cd: U32, +maxins: U32, pend: Bool, take: Bool) -> Lz:
  match pend, take:
    case k, True{}:
      lz_match(sl_insert(In{w, hd, prev}, i, n, pl, maxins, U32.is_le(pl, maxins)), ts, (i + pl - 1 : U32), n, pl, pd)
    case True{}, False{}:
      lz_lit(wb(w, (i - 1 : U32)), hd, prev, ts, (i + b2u(U32.is_lt(i, n)) : U32), n, cl, cd, U32.is_lt(i, n))
    case False{}, False{}:
      Lz{w, hd, prev, ts, (i + 1 : U32), n, cl, cd, U32.is_lt(i, n), U32.is_ge(i, n), U32.is_ge(i, n)}

def sl_found(ch: Ch, hd: Array<U32>, ts: Ts, +i: U32, +n: U32, +pl: U32, +pd: U32, +maxins: U32, pend: Bool) -> Lz:
  match ch:
    case Ch{w, prev, bl, bd, x, cand, more}:
      +d = bd
      +cl = too_far(bl, d)
      sl_decide(w, hd, prev, ts, i, n, pl, pd, cl, d, maxins, pend, U32.is_ge(pl, 3) && U32.is_le(cl, pl))

def sl_ht(ht: In, +cand: U32, ts: Ts, +i: U32, +n: U32, +pl: U32, +pd: U32, pend: Bool, +cf: Cf) -> Lz:
  match ht, cf:
    case In{w, hd, prev}, Cf{good, lazy, nice, ch, slow}:
      sl_found(chain(w, prev, i, n, cand, pick(U32.is_ge(pl, good), (ch >> 2n : U32), ch), nice, U32.is_lt(pl, lazy)), hd, ts, i, n, pl, pd, lazy, pend)

def sl_ins_at(r: In & U32, ts: Ts, +i: U32, +n: U32, +pl: U32, +pd: U32, pend: Bool, +cf: Cf) -> Lz:
  (ht, cand) = r
  sl_ht(ht, cand, ts, i, n, pl, pd, pend, cf)

def sl_step(st: Lz, +cf: Cf) -> Lz:
  match st:
    case Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, stop}:
      +ii = i
      +nn = n
      sl_ins_at(ins_at(w, hd, prev, ii, nn), ts, ii, nn, pl, pd, pend, cf)

def lz_mode(st: Lz, +cf: Cf, slow: Bool) -> Lz:
  match slow:
    case True{}:
      sl_step(st, cf)
    case False{}:
      fa_step(st, cf)

def lz_step(st: Lz, +cf: Cf) -> Lz:
  lz_mode(st, cf, cf_slow(cf))

# until the block is full or the input done
def lz_loop(fuel: Nat, st: Lz, +cf: Cf) -> Lz:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, stop}:
      match stop:
        case True{}:
          Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, True{}}
        case False{}:
          lz_loop(p, lz_step(Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, False{}}, cf), cf)

# Huffman code lengths
# --------------------
# counts to code lengths of at most limit bits: a tree grows by merging
# the two lightest live nodes (a scan each time; n is small), a leaf's
# length is its depth, and while a length passes the limit the counts
# are halved, rounding up, and the tree rebuilt

# the two lightest live nodes seen so far, 4294967295 for none
type Sc is Type:
  Sc{fq: Array<U32>, b1: U32, f1: U32, b2: U32, f2: U32}

def sc_take(fq: Array<U32>, +j: U32, +f: U32, +b1: U32, +f1: U32, +b2: U32, +f2: U32, lt1: Bool, lt2: Bool) -> Sc:
  match lt1, lt2:
    case True{}, k:
      Sc{fq, j, f, b1, f1}
    case False{}, True{}:
      Sc{fq, b1, f1, j, f}
    case False{}, False{}:
      Sc{fq, b1, f1, b2, f2}

def sc_at(r: Array<U32> & U32, +j: U32, +b1: U32, +f1: U32, +b2: U32, +f2: U32) -> Sc:
  (fq, f) = r
  +ff = f
  +live = U32.is_ne(ff, 0)
  sc_take(fq, j, ff, b1, f1, b2, f2, live && U32.is_lt(ff, f1), live && U32.is_lt(ff, f2))

def sc_loop(n: Nat, st: Sc, +j: U32) -> Sc:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Sc{fq, b1, f1, b2, f2}:
      sc_loop(p, sc_at(Array.get(U32, fq, j), j, b1, f1, b2, f2), (j + 1 : U32))

# the tree: node counts (0 once merged), parents, the node count; more
# says a merge happened
type Mg is Type:
  Mg{fq: Array<U32>, par: Array<U32>, cnt: U32, more: Bool}

def mg_do(fq: Array<U32>, par: Array<U32>, +cnt: U32, +b1: U32, +f1: U32, +b2: U32, +f2: U32, ok: Bool) -> Mg:
  match ok:
    case False{}:
      Mg{fq, par, cnt, False{}}
    case True{}:
      Mg{Array.set(U32, Array.set(U32, Array.set(U32, fq, b1, 0), b2, 0), cnt, (f1 + f2 : U32)), Array.set(U32, Array.set(U32, par, b1, cnt), b2, cnt), (cnt + 1 : U32), True{}}

def mg_apply(sc: Sc, par: Array<U32>, +cnt: U32) -> Mg:
  match sc:
    case Sc{fq, b1, f1, b2, f2}:
      +bb2 = b2
      mg_do(fq, par, cnt, b1, f1, bb2, f2, U32.is_ne(bb2, 4294967295))

def mg_step(fq: Array<U32>, par: Array<U32>, +cnt: U32) -> Mg:
  mg_apply(sc_loop(U32.to_nat(cnt), Sc{fq, 4294967295, 4294967295, 4294967295, 4294967295}, 0), par, cnt)

def mg_loop(n: Nat, st: Mg) -> Mg:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Mg{fq, par, cnt, more}:
      match more:
        case False{}:
          Mg{fq, par, cnt, False{}}
        case True{}:
          mg_loop(p, mg_step(fq, par, cnt))

# a leaf's depth: parents up to the root
type Dp is Type:
  Dp{par: Array<U32>, node: U32, depth: U32, more: Bool}

def dp_at(r: Array<U32> & U32, +depth: U32, +root: U32) -> Dp:
  (par, p) = r
  +pp = p
  Dp{par, pp, (depth + 1 : U32), U32.is_ne(pp, root)}

def dp_loop(n: Nat, st: Dp, +root: U32) -> Dp:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Dp{par, node, depth, more}:
      match more:
        case False{}:
          Dp{par, node, depth, False{}}
        case True{}:
          dp_loop(p, dp_at(Array.get(U32, par, node), depth, root), root)

def dp_pair(st: Dp) -> Array<U32> & U32:
  match st:
    case Dp{par, node, depth, more}:
      (par, depth)

def depth_of(par: Array<U32>, +i: U32, +root: U32) -> Array<U32> & U32:
  dp_pair(dp_loop(U32.to_nat(1024), Dp{par, i, 0, True{}}, root))

# the lengths of the live leaves and the longest
type Ln is Type:
  Ln{f0: Array<U32>, par: Array<U32>, lens: Array<U32>, mx: U32}

def ln_put(r: Array<U32> & U32, f0: Array<U32>, lens: Array<U32>, +i: U32, +mx: U32) -> Ln:
  (par, d) = r
  +dd = d
  Ln{f0, par, Array.set(U32, lens, i, dd), pick(U32.is_gt(dd, mx), dd, mx)}

def ln_go(f0: Array<U32>, par: Array<U32>, lens: Array<U32>, +i: U32, +root: U32, +mx: U32, live: Bool) -> Ln:
  match live:
    case False{}:
      Ln{f0, par, lens, mx}
    case True{}:
      ln_put(depth_of(par, i, root), f0, lens, i, mx)

def ln_at(rf: Array<U32> & U32, par: Array<U32>, lens: Array<U32>, +i: U32, +root: U32, +mx: U32) -> Ln:
  (f0, f) = rf
  ln_go(f0, par, lens, i, root, mx, U32.is_ne(f, 0))

def ln_loop(n: Nat, st: Ln, +i: U32, +root: U32) -> Ln:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Ln{f0, par, lens, mx}:
      ln_loop(p, ln_at(Array.get(U32, f0, i), par, lens, i, root, mx), (i + 1 : U32), root)

# one build; over says a length passed the limit
type Hc is Type:
  Hc{f0: Array<U32>, lens: Array<U32>, mx: U32, over: Bool}

def hc_of(ln: Ln, +limit: U32) -> Hc:
  match ln:
    case Ln{f0, par, lens, mx}:
      +m = mx
      Hc{f0, lens, m, U32.is_gt(m, limit)}

def hc_ln(mg: Mg, f0: Array<U32>, +n: U32, +limit: U32) -> Hc:
  match mg:
    case Mg{fq, par, cnt, more}:
      hc_of(ln_loop(U32.to_nat(n), Ln{f0, par, Array.new(U32, 9n, 0), 0}, 0, (cnt - 1 : U32)), limit)

def gr_pair(st: Gr) -> Array<U32> & Array<U32>:
  match st:
    case Gr{src, dst}:
      (src, dst)

def hc_mg(r: Array<U32> & Array<U32>, +n: U32, +limit: U32) -> Hc:
  (f0, fq) = r
  hc_ln(mg_loop(U32.to_nat(n), Mg{fq, Array.new(U32, 10n, 0), n, True{}}), f0, n, limit)

def hc_once(f0: Array<U32>, +n: U32, +limit: U32) -> Hc:
  hc_mg(gr_pair(gr_loop(U32.to_nat(n), Gr{f0, Array.new(U32, 10n, 0)}, 0)), n, limit)

def hv_put(r: Array<U32> & U32, +i: U32) -> Array<U32>:
  (a, v) = r
  +vv = v
  Array.set(U32, a, i, ((vv >> 1n) + (vv .&. 1) : U32))

# counts halved, rounding up so live stays live
def hv_loop(n: Nat, a: Array<U32>, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+p:
      hv_loop(p, hv_put(Array.get(U32, a, i), i), (i + 1 : U32))

def hc_limit(n: Nat, st: Hc, +sz: U32, +limit: U32) -> Hc:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Hc{f0, lens, mx, over}:
      match over:
        case False{}:
          Hc{f0, lens, mx, False{}}
        case True{}:
          hc_limit(p, hc_once(hv_loop(U32.to_nat(sz), f0, 0), sz, limit), sz, limit)

def hc_lens(st: Hc) -> Array<U32>:
  match st:
    case Hc{f0, lens, mx, over}:
      lens

def huff_lens(f0: Array<U32>, +n: U32, +limit: U32) -> Array<U32>:
  hc_lens(hc_limit(30n, hc_once(f0, n, limit), n, limit))

# at least two live symbols, as a tree needs: 0 and 1 are bumped otherwise
type Nz is Type:
  Nz{a: Array<U32>, c: U32}

def nz_at(r: Array<U32> & U32, +c: U32) -> Nz:
  (a, v) = r
  Nz{a, (c + b2u(U32.is_ne(v, 0)) : U32)}

def nz_loop(n: Nat, st: Nz, +i: U32) -> Nz:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Nz{a, c}:
      nz_loop(p, nz_at(Array.get(U32, a, i), c), (i + 1 : U32))

def nz_go(a: Array<U32>, few: Bool) -> Array<U32>:
  match few:
    case True{}:
      bump(bump(a, 0), 1)
    case False{}:
      a

def nz_fix(st: Nz) -> Array<U32>:
  match st:
    case Nz{a, c}:
      nz_go(a, U32.is_lt(c, 2))

def two_live(a: Array<U32>, +n: U32) -> Array<U32>:
  nz_fix(nz_loop(U32.to_nat(n), Nz{a, 0}, 0))

# Canonical codes
# ---------------
# next[l] is the first code of length l: (next[l-1] + count[l-1]) << 1

type Nx is Type:
  Nx{cnt: Array<U32>, next: Array<U32>}

def nx_at(rc: Array<U32> & U32, next: Array<U32>, +l: U32, +code: U32) -> Nx & U32:
  (cnt, c) = rc
  +cd = ((code + c) << 1n : U32)
  (Nx{cnt, Array.set(U32, next, (l + 1 : U32), cd)}, cd)

def nx_loop(n: Nat, st: Nx & U32, +l: U32) -> Nx:
  match n, st:
    case 0n, (r, code):
      r
    case 1n+p, (Nx{cnt, next}, code):
      nx_loop(p, nx_at(Array.get(U32, cnt, l), next, l, code), (l + 1 : U32))

# codes[i] = next[len[i]]++ for live symbols
type Cc is Type:
  Cc{lens: Array<U32>, next: Array<U32>, codes: Array<U32>}

def cc_skip(lens: Array<U32>, codes: Array<U32>, ro: Array<U32> & U32) -> Cc:
  (next, o) = ro
  Cc{lens, next, codes}

def cc_do(lens: Array<U32>, +l: U32, +i: U32, codes: Array<U32>, ro: Array<U32> & U32) -> Cc:
  (next, o) = ro
  +oo = o
  Cc{lens, Array.set(U32, next, l, (oo + 1 : U32)), Array.set(U32, codes, i, oo)}

def cc_put(lens: Array<U32>, +l: U32, +i: U32, codes: Array<U32>, ro: Array<U32> & U32, live: Bool) -> Cc:
  match live:
    case False{}:
      cc_skip(lens, codes, ro)
    case True{}:
      cc_do(lens, l, i, codes, ro)

def cc_at(rl: Array<U32> & U32, next: Array<U32>, codes: Array<U32>, +i: U32) -> Cc:
  (lens, l) = rl
  +ll = l
  cc_put(lens, ll, i, codes, Array.get(U32, next, ll), U32.is_ne(ll, 0))

def cc_loop(n: Nat, st: Cc, +i: U32) -> Cc:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Cc{lens, next, codes}:
      cc_loop(p, cc_at(Array.get(U32, lens, i), next, codes, i), (i + 1 : U32))

# a code table: lengths and codes by symbol
type Tb is Type:
  Tb{lens: Array<U32>, codes: Array<U32>}

def cc_tb(st: Cc) -> Tb:
  match st:
    case Cc{lens, next, codes}:
      Tb{lens, codes}

def tb_nx(st: Nx, lens: Array<U32>, +n: U32) -> Tb:
  match st:
    case Nx{cnt, next}:
      cc_tb(cc_loop(U32.to_nat(n), Cc{lens, next, Array.new(U32, 9n, 0)}, 0))

def tb_cs(st: Cs, +n: U32) -> Tb:
  match st:
    case Cs{lens, cnt}:
      tb_nx(nx_loop(15n, (Nx{Array.set(U32, cnt, 0, 0), Array.new(U32, 4n, 0)}, 0), 0), lens, n)

def tb_of(lens: Array<U32>, +n: U32) -> Tb:
  tb_cs(cnt_loop(U32.to_nat(n), Cs{lens, Array.new(U32, 4n, 0)}, 0), n)

# the writer with a table
type Ew is Type:
  Ew{bw: Bw, tb: Tb}

def tb_put(r: Array<U32> & U32, lens: Array<U32>, bw: Bw, +l: U32) -> Ew:
  (codes, c) = r
  Ew{bw_code(bw, c, l), Tb{lens, codes}}

def tb_at(r: Array<U32> & U32, codes: Array<U32>, bw: Bw, +sym: U32) -> Ew:
  (lens, l) = r
  +ll = l
  tb_put(Array.get(U32, codes, sym), lens, bw, ll)

def tb_code(bw: Bw, tb: Tb, +sym: U32) -> Ew:
  match tb:
    case Tb{lens, codes}:
      tb_at(Array.get(U32, lens, sym), codes, bw, sym)

# Header
# ------
# HLIT and HDIST count the codes up to the last live one; the lengths
# then go out run-length coded: 16 repeats the previous 3-6 times, 17
# gives 3-10 zeros, 18 11-138 zeros

# the count of codes up to the last live one, at least lo
type Lx is Type:
  Lx{a: Array<U32>, last: U32}

def lx_at(r: Array<U32> & U32, +i: U32, +last: U32) -> Lx:
  (a, v) = r
  Lx{a, pick(U32.is_ne(v, 0), (i + 1 : U32), last)}

def lx_loop(n: Nat, st: Lx, +i: U32) -> Lx:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Lx{a, last}:
      lx_loop(p, lx_at(Array.get(U32, a, i), i, last), (i + 1 : U32))

# the same over cl_order, for HCLEN
def lo_loop(n: Nat, st: Lx, +i: U32) -> Lx:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Lx{a, last}:
      lo_loop(p, lx_at(Array.get(U32, a, cl_order(i)), i, last), (i + 1 : U32))

def lx_of(st: Lx, +lo: U32) -> Array<U32> & U32:
  match st:
    case Lx{a, last}:
      +l = last
      (a, pick(U32.is_lt(l, lo), lo, l))

def used(a: Array<U32>, +n: U32, +lo: U32) -> Array<U32> & U32:
  lx_of(lx_loop(U32.to_nat(n), Lx{a, 0}, 0), lo)

def used_ord(a: Array<U32>, +lo: U32) -> Array<U32> & U32:
  lx_of(lo_loop(19n, Lx{a, 0}, 0), lo)

# dst[off + i] = src[i]
def ap_put(r: Array<U32> & U32, dst: Array<U32>, +i: U32, +off: U32) -> Sp:
  (src, v) = r
  Sp{src, Array.set(U32, dst, (off + i : U32), v)}

def ap_loop(n: Nat, st: Sp, +i: U32, +off: U32) -> Sp:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Sp{src, dst}:
      ap_loop(p, ap_put(Array.get(U32, src, i), dst, i, off), (i + 1 : U32), off)

# the run-length tokens (reversed) and the code-length symbol counts
type Rt is Type:
  Rt{toks: List<&2, Tok>, fc: Array<U32>}

def rpush(st: Rt, +sym: U32, +ex: U32, +eb: U32) -> Rt:
  match st:
    case Rt{toks, fc}:
      Rt{Tok{sym, ex, eb, 0, 0, 0} <> toks, bump(fc, sym)}


# a run of r zeros: 11-138 go as an 18, 3-10 as a 17, one as a zero;
# the flags say which the run allows
def zrun(n: Nat, st: Rt, +r: U32, b11: Bool, b3: Bool, b1: Bool) -> Rt:
  match n, b11, b3, b1:
    case 0n, k1, k2, k3:
      st
    case 1n+p, True{}, k2, k3:
      +m = pick(U32.is_gt(r, 138), 138, r)
      +r2 = (r - m : U32)
      zrun(p, rpush(st, 18, (m - 11 : U32), 7), r2, U32.is_ge(r2, 11), U32.is_ge(r2, 3), U32.is_ge(r2, 1))
    case 1n+p, False{}, True{}, k3:
      zrun(p, rpush(st, 17, (r - 3 : U32), 3), 0, False{}, False{}, False{})
    case 1n+p, False{}, False{}, True{}:
      +r2 = (r - 1 : U32)
      zrun(p, rpush(st, 0, 0, 0), r2, U32.is_ge(r2, 11), U32.is_ge(r2, 3), U32.is_ge(r2, 1))
    case 1n+p, False{}, False{}, False{}:
      st

# r more copies of a length l already sent: 3-6 go as a 16, one sends
# l again
def lrun(n: Nat, st: Rt, +l: U32, +r: U32, b3: Bool, b1: Bool) -> Rt:
  match n, b3, b1:
    case 0n, k1, k2:
      st
    case 1n+p, True{}, k2:
      +m = pick(U32.is_gt(r, 6), 6, r)
      +r2 = (r - m : U32)
      lrun(p, rpush(st, 16, (m - 3 : U32), 2), l, r2, U32.is_ge(r2, 3), U32.is_ge(r2, 1))
    case 1n+p, False{}, True{}:
      +r2 = (r - 1 : U32)
      lrun(p, rpush(st, l, 0, 0), l, r2, U32.is_ge(r2, 3), U32.is_ge(r2, 1))
    case 1n+p, False{}, False{}:
      st

def run_go(st: Rt, +l: U32, +r: U32, zero: Bool) -> Rt:
  match zero:
    case True{}:
      zrun(U32.to_nat((r + 1 : U32)), st, r, U32.is_ge(r, 11), U32.is_ge(r, 3), U32.is_ge(r, 1))
    case False{}:
      lrun(U32.to_nat((r + 1 : U32)), rpush(st, l, 0, 0), l, (r - 1 : U32), U32.is_ge((r - 1 : U32), 3), U32.is_ge((r - 1 : U32), 1))

def run_emit(st: Rt, +l: U32, +r: U32) -> Rt:
  run_go(st, l, r, U32.is_eq(l, 0))

# the run of a length from i; more says the next entry may extend it
type Rn is Type:
  Rn{a: Array<U32>, r: U32, more: Bool}

def rn_at(rv: Array<U32> & U32, +r: U32, +i: U32, +l: U32, +total: U32) -> Rn:
  (a, v) = rv
  +eq = U32.is_eq(v, l)
  Rn{a, (r + b2u(eq) : U32), eq && U32.is_lt((i + r + 1 : U32), total)}

def rn_loop(n: Nat, st: Rn, +i: U32, +l: U32, +total: U32) -> Rn:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Rn{a, r, more}:
      match more:
        case False{}:
          Rn{a, r, False{}}
        case True{}:
          +rr = r
          rn_loop(p, rn_at(Array.get(U32, a, (i + rr : U32)), rr, i, l, total), i, l, total)

# the lengths being coded: the array, the tokens and counts, the position
type Re is Type:
  Re{a: Array<U32>, toks: List<&2, Tok>, fc: Array<U32>, i: U32, more: Bool}

def re_of(a: Array<U32>, rt: Rt, +i: U32, +total: U32) -> Re:
  match rt:
    case Rt{toks, fc}:
      Re{a, toks, fc, i, U32.is_lt(i, total)}

def re_run(rn: Rn, toks: List<&2, Tok>, fc: Array<U32>, +i: U32, +l: U32, +total: U32) -> Re:
  match rn:
    case Rn{a, r, more}:
      +rr = r
      re_of(a, run_emit(Rt{toks, fc}, l, rr), (i + rr : U32), total)

def re_at(r: Array<U32> & U32, toks: List<&2, Tok>, fc: Array<U32>, +i: U32, +total: U32) -> Re:
  (a, l) = r
  +ll = l
  re_run(rn_loop(U32.to_nat(total), Rn{a, 1, U32.is_lt((i + 1 : U32), total)}, i, ll, total), toks, fc, i, ll, total)

def re_loop(n: Nat, st: Re, +total: U32) -> Re:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Re{a, toks, fc, i, more}:
      match more:
        case False{}:
          Re{a, toks, fc, i, False{}}
        case True{}:
          +ii = i
          re_loop(p, re_at(Array.get(U32, a, ii), toks, fc, ii, total), total)

# Block
# -----

# the code-length lengths, 3 bits each in cl_order
type Hw is Type:
  Hw{bw: Bw, a: Array<U32>}

def hw_put(r: Array<U32> & U32, bw: Bw) -> Hw:
  (a, v) = r
  Hw{bw_put(bw, v, 3), a}

def hw_loop(n: Nat, st: Hw, +k: U32) -> Hw:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Hw{bw, a}:
      hw_loop(p, hw_put(Array.get(U32, a, cl_order(k)), bw), (k + 1 : U32))

def ec_ex(st: Ew, +ex: U32, +eb: U32) -> Ew:
  match st:
    case Ew{bw, tb}:
      Ew{bw_put(bw, ex, eb), tb}

def ec_tok(t: Tok, st: Ew) -> Ew:
  match t, st:
    case Tok{sym, ex, eb, ds, dx, db}, Ew{bw, tb}:
      ec_ex(tb_code(bw, tb, sym), ex, eb)

def ec_loop(toks: List<&2, Tok>, st: Ew) -> Ew:
  match toks:
    case Nil{}:
      st
    case Con{h, t}:
      ec_loop(t, ec_tok(h, st))

# Block out
# ---------
# the writer persists across blocks. A block's tokens go out under the
# tables, then the end-of-block code

def bw_byte(st: Bw, +b: U32) -> Bw:
  match st:
    case Bw{ob, buf, cnt, more}:
      Bw{ob_byte(ob, b), buf, cnt, more}

# zeros to the next byte boundary
def bw_align(st: Bw) -> Bw:
  match st:
    case Bw{ob, buf, cnt, more}:
      +c = cnt
      bw_put(Bw{ob, buf, c, more}, 0, ((8 - c % 8) % 8 : U32))

type Em is Type:
  Em{bw: Bw, lit: Tb, dst: Tb, tk: Array<U32>}

def em_dist(st: Ew, lit: Tb, +dx: U32, +db: U32, tk: Array<U32>) -> Em:
  match st:
    case Ew{bw, dst}:
      Em{bw_put(bw, dx, db), lit, dst, tk}

def em_len(st: Ew, dst: Tb, +ds: U32, +dx: U32, +db: U32, tk: Array<U32>, islen: Bool) -> Em:
  match st, islen:
    case Ew{bw, lit}, False{}:
      Em{bw, lit, dst, tk}
    case Ew{bw, lit}, True{}:
      em_dist(tb_code(bw, dst, ds), lit, dx, db, tk)

def em_tok(+w0: U32, +w1: U32, bw: Bw, lit: Tb, dst: Tb, tk: Array<U32>) -> Em:
  +sym = (w0 .&. 511 : U32)
  em_len(ec_ex(tb_code(bw, lit, sym), ((w0 >> 9n) .&. 31 : U32), ((w0 >> 14n) .&. 7 : U32)), dst, ((w0 >> 17n) .&. 31 : U32), w1, ((w0 >> 22n) .&. 15 : U32), tk, U32.is_ge(sym, 257))

def em_w1(r: Array<U32> & U32, bw: Bw, lit: Tb, dst: Tb, +w0: U32) -> Em:
  (tk, w1) = r
  em_tok(w0, w1, bw, lit, dst, tk)

def em_w0(r: Array<U32> & U32, bw: Bw, lit: Tb, dst: Tb, +j: U32) -> Em:
  (tk, w0) = r
  em_w1(Array.get(U32, tk, ((j << 1n) + 1 : U32)), bw, lit, dst, w0)

def em_loop(k: Nat, st: Em, +j: U32) -> Em:
  match k, st:
    case 0n, r:
      r
    case 1n+p, Em{bw, lit, dst, tk}:
      em_loop(p, em_w0(Array.get(U32, tk, (j << 1n : U32)), bw, lit, dst, j), (j + 1 : U32))

def em_fin(st: Ew) -> Bw:
  match st:
    case Ew{bw, tb}:
      bw

def em_eob(st: Em) -> Bw:
  match st:
    case Em{bw, lit, dst, tk}:
      em_fin(tb_code(bw, lit, 256))

# the block's cost under the tables, in bits, end-of-block included
type Ct is Type:
  Ct{tk: Array<U32>, ll: Array<U32>, dl: Array<U32>, bits: U32}

def ct_dl(r: Array<U32> & U32, tk: Array<U32>, ll: Array<U32>, +bits: U32, +db: U32) -> Ct:
  (dl, l) = r
  Ct{tk, ll, dl, (bits + l + db : U32)}

def ct_len(tk: Array<U32>, ll: Array<U32>, dl: Array<U32>, +bits: U32, +ds: U32, +db: U32, islen: Bool) -> Ct:
  match islen:
    case False{}:
      Ct{tk, ll, dl, bits}
    case True{}:
      ct_dl(Array.get(U32, dl, ds), tk, ll, bits, db)

def ct_ll(r: Array<U32> & U32, tk: Array<U32>, dl: Array<U32>, +bits: U32, +w0: U32) -> Ct:
  (ll, l) = r
  ct_len(tk, ll, dl, (bits + l + ((w0 >> 14n) .&. 7) : U32), ((w0 >> 17n) .&. 31 : U32), ((w0 >> 22n) .&. 15 : U32), U32.is_ge((w0 .&. 511 : U32), 257))

def ct_w0(r: Array<U32> & U32, ll: Array<U32>, dl: Array<U32>, +bits: U32) -> Ct:
  (tk, w0) = r
  +v = w0
  ct_ll(Array.get(U32, ll, (v .&. 511 : U32)), tk, dl, bits, v)

def ct_loop(k: Nat, st: Ct, +j: U32) -> Ct:
  match k, st:
    case 0n, r:
      r
    case 1n+p, Ct{tk, ll, dl, bits}:
      ct_loop(p, ct_w0(Array.get(U32, tk, (j << 1n : U32)), ll, dl, bits), (j + 1 : U32))

def ct_swap(r: Array<U32> & U32, tk: Array<U32>, dl: Array<U32>, +bits: U32, +db: U32) -> Ct:
  (ll, l) = r
  Ct{tk, ll, dl, (bits + l + db : U32)}

def ct_eob(st: Ct) -> Ct:
  match st:
    case Ct{tk, ll, dl, bits}:
      ct_swap(Array.get(U32, ll, 256), tk, dl, bits, 0)

# the run-length tokens' cost under the code-length code
type Cr is Type:
  Cr{cl: Array<U32>, bits: U32}

def cr_at(r: Array<U32> & U32, +bits: U32, +eb: U32) -> Cr:
  (cl, l) = r
  Cr{cl, (bits + l + eb : U32)}

def cr_tok(t: Tok, cl: Array<U32>, +bits: U32) -> Cr:
  match t:
    case Tok{sym, ex, eb, ds, dx, db}:
      cr_at(Array.get(U32, cl, sym), bits, eb)

def cr_loop(l: List<&2, Tok>, st: Cr) -> Cr:
  match l, st:
    case Nil{}, r:
      r
    case Con{h, t}, Cr{cl, bits}:
      cr_loop(t, cr_tok(h, cl, bits))

def cr_of(st: Cr) -> Array<U32> & U32:
  match st:
    case Cr{cl, bits}:
      (cl, bits)

# Stored blocks
# -------------
# the bytes [start, start+cov) as stored blocks of up to 65535 bytes:
# BFINAL, BTYPE 00, zeros to the byte, LEN, its complement, the bytes.
# A final run ends with the final flag on its last block; a size that
# is a multiple of 65535 gets an empty last block

type Sb is Type:
  Sb{w: Array<U32>, bw: Bw}

def sb_put(r: Array<U32> & U32, bw: Bw) -> Sb:
  (w, b) = r
  Sb{w, bw_byte(bw, b)}

def sb_copy(n: Nat, st: Sb, +j: U32) -> Sb:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Sb{w, bw}:
      sb_copy(p, sb_put(wb(w, j), bw), (j + 1 : U32))

def sb_word(r: Array<U32> & U32, bw: Bw) -> Sb:
  (w, v) = r
  match bw:
    case Bw{ob, buf, cnt, more}:
      Sb{w, Bw{ob_word_at(ob, v), buf, cnt, more}}

def sb_words(n: Nat, st: Sb, +j: U32) -> Sb:
  match n, st:
    case 0n, r:
      r
    case 1n+p, Sb{w, bw}:
      sb_words(p, sb_word(w4(w, j), bw), (j + 4 : U32))

def sb_fast(+len: U32, st: Sb, +j: U32) -> Sb:
  sb_copy(U32.to_nat((len .&. 3 : U32)), sb_words(U32.to_nat((len >> 2n : U32)), st, j), (j + (len .&. 4294967292 : U32) : U32))

def bw_reserve(st: Bw, +n: U32) -> Bw:
  match st:
    case Bw{ob, buf, cnt, more}:
      Bw{ob_reserve(ob, n), buf, cnt, more}

def sb_head(st: Sb, +len: U32, final: Bool) -> Sb:
  match st:
    case Sb{w, bw}:
      +l = len
      Sb{w, bw_reserve(bw_byte(bw_byte(bw_byte(bw_byte(bw_align(bw_put(bw_put(bw, b2u(final), 1), 0, 2)), (l .&. 255 : U32)), (l >> 8n : U32)), (U32.xor(l, 65535) .&. 255 : U32)), (U32.xor(l, 65535) >> 8n : U32)), l)}

def sb_loop(m: Nat, st: Sb, +k: U32, +start: U32, +cov: U32, +count: U32, +final: Bool) -> Sb:
  match m, st:
    case 0n, r:
      r
    case 1n+p, Sb{w, bw}:
      +at = (k * 65535 : U32)
      +len = pick(U32.is_gt((cov - at : U32), 65535), 65535, (cov - at : U32))
      sb_loop(p, sb_fast(len, sb_head(Sb{w, bw}, len, final && U32.is_eq((k + 1 : U32), count)), (start + at : U32)), (k + 1 : U32), start, cov, count, final)

def sb_pair(st: Sb) -> Array<U32> & Bw:
  match st:
    case Sb{w, bw}:
      (w, bw)

def stored_out(w: Array<U32>, bw: Bw, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  +count = (cov / 65535 + 1 : U32)
  sb_pair(sb_loop(U32.to_nat(count), Sb{w, bw}, 0, start, cov, count, final))

# Dynamic blocks
# --------------
# the tables from the counts, the run-length coded lengths, and the
# choice: stored when its bytes cost less than the coded block

def df_9(bw: Bw, w: Array<U32>) -> Array<U32> & Bw:
  (w, bw)

def df_8(tk: Array<U32>, +nt: U32, lit: Tb, dst: Tb, ew: Ew, w: Array<U32>) -> Array<U32> & Bw:
  match ew:
    case Ew{bw, clt}:
      df_9(em_eob(em_loop(U32.to_nat(nt), Em{bw, lit, dst, tk}, 0)), w)

def df_7(tk: Array<U32>, +nt: U32, ll: Array<U32>, dl: Array<U32>, ctoks: List<&2, Tok>, hw: Hw, w: Array<U32>) -> Array<U32> & Bw:
  match hw:
    case Hw{bw, cl}:
      df_8(tk, nt, tb_of(ll, 286), tb_of(dl, 30), ec_loop(trev(ctoks, []), Ew{bw, tb_of(cl, 19)}), w)

# BFINAL, BTYPE 10, then HLIT-257, HDIST-1, HCLEN-4 and the code-length lengths
def df_dyn(tk: Array<U32>, +nt: U32, ll: Array<U32>, dl: Array<U32>, ctoks: List<&2, Tok>, cl: Array<U32>, +hl: U32, +hd: U32, +hc: U32, bw: Bw, w: Array<U32>, final: Bool) -> Array<U32> & Bw:
  df_7(tk, nt, ll, dl, ctoks, hw_loop(U32.to_nat(hc), Hw{bw_put(bw_put(bw_put(bw_put(bw_put(bw, b2u(final), 1), 2, 2), (hl - 257 : U32), 5), (hd - 1 : U32), 5), (hc - 4 : U32), 4), cl}, 0), w)

def df_pick(tk: Array<U32>, +nt: U32, ll: Array<U32>, dl: Array<U32>, ctoks: List<&2, Tok>, cl: Array<U32>, +hl: U32, +hd: U32, +hc: U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool, stored: Bool) -> Array<U32> & Bw:
  match stored:
    case True{}:
      stored_out(w, bw, start, cov, final)
    case False{}:
      df_dyn(tk, nt, ll, dl, ctoks, cl, hl, hd, hc, bw, w, final)

def df_cost(ct: Ct, rc: Array<U32> & U32, ctoks: List<&2, Tok>, +nt: U32, +hl: U32, +hd: U32, +hc: U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  match ct:
    case Ct{tk, ll, dl, bits}:
      (cl, rbits) = rc
      +dyn = (17 + 3 * hc + rbits + bits : U32)
      df_pick(tk, nt, ll, dl, ctoks, cl, hl, hd, hc, bw, w, start, cov, final, U32.is_lt((8 * cov + 40 * (cov / 65535 + 1) + 8 : U32), dyn))

def df_6(tk: Array<U32>, +nt: U32, ll: Array<U32>, dl: Array<U32>, +ctoks: List<&2, Tok>, rc: Array<U32> & U32, +hl: U32, +hd: U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  (cl, hclen) = rc
  +hc = hclen
  df_cost(ct_eob(ct_loop(U32.to_nat(nt), Ct{tk, ll, dl, 0}, 0)), cr_of(cr_loop(ctoks, Cr{cl, 0})), ctoks, nt, hl, hd, hc, bw, w, start, cov, final)

def df_5(tk: Array<U32>, +nt: U32, ll: Array<U32>, dl: Array<U32>, re: Re, +hl: U32, +hd: U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  match re:
    case Re{all, ctoks, fc, i, more}:
      +ct = ctoks
      df_6(tk, nt, ll, dl, ct, used_ord(huff_lens(two_live(fc, 19), 19, 7), 4), hl, hd, bw, w, start, cov, final)

def df_4(tk: Array<U32>, +nt: U32, ll: Array<U32>, sp: Sp, +hl: U32, +hd: U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  match sp:
    case Sp{dl, all}:
      df_5(tk, nt, ll, dl, re_loop(U32.to_nat((hl + hd : U32)), Re{all, [], Array.new(U32, 5n, 0), 0, True{}}, (hl + hd : U32)), hl, hd, bw, w, start, cov, final)

def df_3(tk: Array<U32>, +nt: U32, sp: Sp, dl: Array<U32>, +hl: U32, +hd: U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  match sp:
    case Sp{ll, all}:
      df_4(tk, nt, ll, ap_loop(U32.to_nat(hd), Sp{dl, all}, 0, hl), hl, hd, bw, w, start, cov, final)

def df_2(tk: Array<U32>, +nt: U32, rl: Array<U32> & U32, rd: Array<U32> & U32, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool) -> Array<U32> & Bw:
  (ll, hlit) = rl
  (dl, hdist) = rd
  +hl = hlit
  +hd = hdist
  df_3(tk, nt, ap_loop(U32.to_nat(hl), Sp{ll, Array.new(U32, 9n, 0)}, 0, 0), dl, hl, hd, bw, w, start, cov, final)

def df_start(tk: Array<U32>, +nt: U32, fl: Array<U32>, fd: Array<U32>, bw: Bw, w: Array<U32>, +start: U32, +cov: U32, final: Bool, raw: Bool) -> Array<U32> & Bw:
  match raw:
    case True{}:
      stored_out(w, bw, start, cov, final)
    case False{}:
      df_2(tk, nt, used(huff_lens(two_live(bump(fl, 256), 286), 286, 15), 286, 257), used(huff_lens(two_live(fd, 30), 30, 15), 30, 1), bw, w, start, cov, final)

def df_1(ts: Ts, bw: Bw, w: Array<U32>, +iend: U32, final: Bool) -> Array<U32> & Bw:
  match ts:
    case Ts{tk, nt, fl, fd, cov}:
      +c = cov
      +k = nt
      df_start(tk, k, fl, fd, bw, w, (iend - c : U32), c, final, U32.is_gt((k * 100 : U32), (c * 99 : U32)))

# Blocks
# ------
# the pass runs a block's worth, the block goes out, the pass resumes;
# only a last chunk's last block carries the final flag

type Bk is Type:
  Bk{lz: Lz, bw: Bw, fin: Bool}

def bk_next(r: Array<U32> & Bw, hd: Array<U32>, prev: Array<U32>, +i: U32, +n: U32, +pl: U32, +pd: U32, +pend: Bool, +done: Bool) -> Bk:
  (w, bw) = r
  Bk{Lz{w, hd, prev, ts_new(), i, n, pl, pd, pend, done, done}, bw, done}

def bk_emit(st: Lz, bw: Bw, +last: Bool) -> Bk:
  match st:
    case Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, stop}:
      +ii = i
      +pe = pend
      +dn = done
      bk_next(df_1(ts, bw, w, (ii - b2u(pe) : U32), dn && last), hd, prev, ii, n, pl, pd, pe, dn)

def bk_loop(fuel: Nat, st: Bk, +cf: Cf, +last: Bool) -> Bk:
  match fuel, st:
    case 0n, r:
      r
    case 1n+p, Bk{lz, bw, fin}:
      match fin:
        case True{}:
          Bk{lz, bw, True{}}
        case False{}:
          bk_loop(p, bk_emit(lz_loop(U32.to_nat(32772), lz, cf), bw, last), cf, last)

def lz_drop(lz: Lz, bw: Bw) -> Bw:
  match lz:
    case Lz{w, hd, prev, ts, i, n, pl, pd, pend, done, stop}:
      bw

def bk_bw(st: Bk) -> Bw:
  match st:
    case Bk{lz, bw, fin}:
      lz_drop(lz, bw)

# Chunks
# ------
# the input in chunks of 262144 bytes. Array.fork gives every chunk a
# read-only handle to the same block in O(1); the 32768 bytes before its
# start are the dictionary the tables see first. A chunk's
# stream ends byte aligned with an empty stored block unless it is the
# last, so the streams concatenate. The chunks form a balanced tree,
# and a parallel let forks over it.

type Ck is Type:
  Ck{a: Array<U32>, start: U32, n: U32, d: U32, last: Bool}

type Cq is Type:
  CLeaf{ck: Ck}
  CNode{l: Cq, r: Cq}

type Ot is Type:
  OLeaf{ob: Ob}
  ONode{l: Ot, r: Ot}

# an empty stored block: BFINAL 0, BTYPE 00, zeros to the byte, 0, 65535
def stored_empty(bw: Bw) -> Bw:
  bw_byte(bw_byte(bw_byte(bw_byte(bw_align(bw_put(bw_put(bw, 0, 1), 0, 2)), 0), 0), 255), 255)

def ck_fin(bw: Bw, last: Bool) -> Ob:
  match last:
    case True{}:
      bw_fin(bw)
    case False{}:
      bw_fin(stored_empty(bw))

def ck_end(st: Bk, last: Bool) -> Ob:
  ck_fin(bk_bw(st), last)

# the chunk's stream: the dictionary goes into the tables, the pass
# starts past it
def ck_go(ht: In, +i0: U32, +n: U32, +cf: Cf, +last: Bool) -> Ob:
  match ht:
    case In{w, hd, prev}:
      +dn = U32.is_ge(i0, n)
      ck_end(bk_loop(U32.to_nat(((n - i0) / 16384 + 2 : U32)), Bk{Lz{w, hd, prev, ts_new(), i0, n, 0, 0, False{}, dn, dn}, Bw{ob_new(), 0, 0, False{}}, False{}}, cf, last), last)

def ck_run_at(a: Array<U32>, +start: U32, +n: U32, +d: U32, last: Bool, +cf: Cf) -> Ob:
  +ss = start
  +dd = d
  +nn = n
  ck_go(ins_loop(U32.to_nat(dd), In{a, Array.new(U32, 15n, 0), Array.new(U32, 15n, 0)}, (ss - dd : U32), nn), ss, nn, cf, last)

def ck_run(ck: Ck, +cf: Cf) -> Ob:
  match ck:
    case Ck{a, start, n, d, last}:
      ck_run_at(a, start, n, d, last, cf)

# the fork: siblings own their chunks
def par_tree(t: Cq, +cf: Cf) -> Ot:
  match t:
    case CLeaf{ck}:
      OLeaf{ck_run(ck, cf)}
    case CNode{l, r}:
      a b = par_tree(l, cf) par_tree(r, cf)
      ONode{a, b}

# the chunks as leaves, built from the last down so the list runs in order
type Lv is Type:
  Lv{w: Array<U32>, acc: List<&1, Cq>}

def lv_add(r: Array<U32> & Array<U32>, acc: List<&1, Cq>, +start: U32, +n: U32, +d: U32, last: Bool) -> Lv:
  (w, chunk) = r
  Lv{w, CLeaf{Ck{chunk, start, n, d, last}} <> acc}

def lv_loop(m: Nat, st: Lv, +k: U32, +count: U32, +n: U32) -> Lv:
  match m, st:
    case 0n, r:
      r
    case 1n+p, Lv{w, acc}:
      +s = (k * 262144 : U32)
      +e = (s + pick(U32.is_lt((n - s : U32), 262144), (n - s : U32), 262144) : U32)
      +d = pick(U32.is_lt(s, 32768), s, 32768)
      lv_loop(p, lv_add(Array.fork(U32, w), acc, s, e, d, U32.is_eq((k + 1 : U32), count)), (k - 1 : U32), count, n)

def lv_list(st: Lv) -> List<&1, Cq>:
  match st:
    case Lv{w, acc}:
      acc

# neighbours paired up, until one tree is left
def pair_up(l: List<&1, Cq>) -> List<&1, Cq>:
  match l:
    case Nil{}:
      []
    case Con{a, Nil{}}:
      [a]
    case Con{a, Con{b, t}}:
      CNode{a, b} <> pair_up(t)

def pair_loop(fuel: Nat, l: List<&1, Cq>, +count: U32, single: Bool) -> List<&1, Cq>:
  match fuel, single:
    case 0n, k:
      l
    case 1n+p, True{}:
      l
    case 1n+p, False{}:
      pair_loop(p, pair_up(l), ((count + 1) / 2 : U32), U32.is_eq(((count + 1) / 2 : U32), 1))

def tree_only(t: List<&1, Cq>, h: Cq) -> Cq:
  match t:
    case Nil{}:
      h
    case Con{a, b}:
      h

def tree_head(l: List<&1, Cq>) -> Cq:
  match l:
    case Nil{}:
      CLeaf{Ck{Array.new(U32, 4n, 0), 0, 0, 0, True{}}}
    case Con{h, t}:
      tree_only(t, h)

def chunks(w: Array<U32>, +n: U32) -> Cq:
  +count = pick(U32.is_eq(n, 0), 1, ((n + 262143) / 262144 : U32))
  tree_head(pair_loop(32n, lv_list(lv_loop(U32.to_nat(count), Lv{w, []}, (count - 1 : U32), count, n)), count, U32.is_eq(count, 1)))

# A compressed leaf already ends on a byte boundary. Keep the leaves separate
# so IO can write them in order without copying them into another Bend Array.
def stored_bw(r: Array<U32> & Bw) -> Bw:
  (w, bw) = r
  bw

def deflate_parts_go(w: Array<U32>, +n: U32, +level: U32, stored: Bool) -> Ot:
  match stored:
    case True{}:
      OLeaf{bw_fin(stored_bw(stored_out(w, Bw{ob_new(), 0, 0, False{}}, 0, n, True{})))}
    case False{}:
      par_tree(chunks(w, n), cf_of(level))

def deflate_parts(w: Array<U32>, +n: U32, +level: U32) -> Ot:
  deflate_parts_go(w, n, level, U32.is_eq(level, 0))

# XFL says 2 for the slowest level and 4 for the fastest
def gz_head(ob: Ob, +level: U32) -> Ob:
  ob_byte(ob_byte(ob_zero(ob_byte(ob_byte(ob_byte(ob, 31), 139), 8), 5), pick(U32.is_eq(level, 9), 2, pick(U32.is_eq(level, 1), 4, 0))), 3)

def le32_put(ob: Ob, +v: U32) -> Ob:
  ob_byte(ob_byte(ob_byte(ob_byte(ob, (v .&. 255 : U32)), ((v >> 8n) .&. 255 : U32)), ((v >> 16n) .&. 255 : U32)), (v >> 24n : U32))

def parts_list(parts: Ot, rest: List<&1, Ob>) -> List<&1, Ob>:
  match parts:
    case OLeaf{ob}:
      ob <> rest
    case ONode{l, r}:
      parts_list(l, parts_list(r, rest))

def stream_parts(parts: List<&1, Ob>, +path: String, file: File) -> IO(File):
  match parts:
    case Nil{}:
      IO.pure(File, file)
    case Con{h, t}:
      do IO<File>:
        next : File <- file_write_ob(path, file, h)
        stream_parts(t, path, next)

def gzip_stream_got(+path: String, file: File, r: Array<U32> & U32, +n: U32, +level: U32) -> IO(Unit):
  (a, crc) = r
  do IO<Unit>:
    body : File <- file_write_ob(path, file, gz_head(ob_new(), level))
    tail : File <- stream_parts(parts_list(deflate_parts(a, n, level), []), path, body)
    done : File <- file_write_ob(path, tail, le32_put(le32_put(ob_new(), crc), n))
    File.close(done)

# The input remains shared by the parallel DEFLATE leaves. The checksum uses
# the native CRC primitive, and each completed leaf goes straight to the file.
def gzip_stream(+path: String, st: Ob, +level: U32) -> IO(Unit):
  match st:
    case Ob{a, cap, pos}:
      +n = pos
      do IO<Unit>:
        checked : Array<U32> & U32 <- crc_words(path, a, n)
        file : File <- open_out(path)
        gzip_stream_got(path, file, checked, n, level)

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
      take_file_at(wants_file(flags(strip_dash(s, head_is(s, 45)), Opts{0, False{}, False{}, "", 6})), t)

# Main
# ----

def usage() -> IO(Unit):
  IO.die(Unit, 1, "usage: TAR_ARGS=\"-{c|x|t}[zv0-9]f FILE [files..]\" bend tar.bend")

def walk_peek(r: Array<U32> & Bool, +n: U32, gz: Bool, extract: Bool, verbose: Bool) -> IO(Unit):
  (a, magic) = r
  walk(maybe_gunzip(a, n, gz || magic), extract, verbose)

# gzip'd input is detected by its magic, as bsdtar does, with or without z
def walk_in(r: Array<U32> & U32, gz: Bool, extract: Bool, verbose: Bool) -> IO(Unit):
  (a, n) = r
  walk_peek(gz_peek(a), n, gz, extract, verbose)

def create_out(gz: Bool, verbose: Bool, +file: String, +level: U32, members: List<&2, String>) -> IO(Unit):
  match gz:
    case True{}:
      do IO<Unit>:
        st : Ob <- tar_pack(members, verbose, ob_new())
        gzip_stream(path_out(file), st, level)
    case False{}:
      tar_stream(members, verbose, path_out(file), True{})

def list_plain(+file: String, verbose: Bool, stream: Bool) -> IO(Unit):
  match stream:
    case True{}:
      list_stream(path_in(file))
    case False{}:
      do IO<Unit>:
        r : Array<U32> & U32 <- read_words(path_in(file))
        walk_in(r, False{}, False{}, verbose)

def list_in(gz: Bool, +file: String, verbose: Bool) -> IO(Unit):
  match gz:
    case True{}:
      do IO<Unit>:
        r : Array<U32> & U32 <- read_words(path_in(file))
        walk_in(r, True{}, False{}, verbose)
    case False{}:
      list_plain(file, verbose, Bool.not(String.eq(file, "-")))

def run_mode(create: Bool, extract: Bool, list: Bool, gz: Bool, verbose: Bool, +file: String, +level: U32, members: List<&2, String>) -> IO(Unit):
  match create, extract, list:
    case True{}, k1, k2:
      create_out(gz, verbose, file, level, members)
    case False{}, True{}, k2:
      do IO<Unit>:
        r : Array<U32> & U32 <- read_words(path_in(file))
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

def main() -> IO(Unit):
  do IO<Unit>:
    line : String <- IO.try(String, IO.get_env("TAR_ARGS"))
    run_parsed(parse(words(line)))
