// tar.c: the C twin of tar.bend. Same ustar layout, same gzip
// container, the same inflate, and a deflate with the same level table,
// hash, chain walk, lazy and greedy paths, length-limited Huffman
// builder and run-length coded header, so the archives come out
// byte-identical. Bytes live in plain arrays instead of Strings; the
// command line comes from argv, or from TAR_ARGS when there is none.
//
//   tar -czvf out.tgz a.txt b.txt      tar -tzf out.tgz      tar -xvf in.tar
//
// Flags: c create, x extract, t list, f FILE (- for stdin/stdout), z gzip,
// v verbose, 0-9 the gzip level (6 by default).

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t  u8;
typedef uint32_t u32;

// Byte buffers
// ------------

typedef struct { u8 *p; size_t n, cap; } Buf;

static void oom(void) { fprintf(stderr, "tar: out of memory\n"); exit(1); }

static void buf_reserve(Buf *b, size_t need) {
  if (b->cap >= need) return;
  size_t c = b->cap ? b->cap : 65536;
  while (c < need) c *= 2;
  b->p = realloc(b->p, c);
  if (!b->p) oom();
  b->cap = c;
}

static void buf_push(Buf *b, u8 x) { buf_reserve(b, b->n + 1); b->p[b->n++] = x; }

static void buf_append(Buf *b, const void *p, size_t n) {
  buf_reserve(b, b->n + n);
  memcpy(b->p + b->n, p, n);
  b->n += n;
}

static void buf_fill(Buf *b, u8 x, size_t n) {
  buf_reserve(b, b->n + n);
  memset(b->p + b->n, x, n);
  b->n += n;
}

// Files
// -----

static void die(const char *what, const char *msg) {
  fprintf(stderr, "tar: %s: %s\n", what, msg);
  exit(1);
}

static const char *path_in(const char *f)  { return strcmp(f, "-") == 0 ? "/dev/stdin"  : f; }
static const char *path_out(const char *f) { return strcmp(f, "-") == 0 ? "/dev/stdout" : f; }

static void read_file(const char *path, Buf *out) {
  FILE *f = fopen(path, "rb");
  if (!f) die(path, strerror(errno));
  for (;;) {
    buf_reserve(out, out->n + 1048576);
    size_t got = fread(out->p + out->n, 1, 1048576, f);
    out->n += got;
    if (got == 0) break;
  }
  fclose(f);
}

static void write_file(const char *path, const Buf *b) {
  FILE *f = fopen(path, "wb");
  if (!f) die(path, strerror(errno));
  if (b->n && fwrite(b->p, 1, b->n, f) != b->n) die(path, strerror(errno));
  fclose(f);
}

// Tar
// ---
// ustar: a 512-byte header, the data, NUL padding to 512, and two zero
// blocks at the end. Regular files only: mode 0644, uid and gid 0, mtime 0.

static u32 pad512(u32 n) { return (512 - n % 512) % 512; }

static void octal(u8 *dst, int digits, u32 v) {
  for (int k = digits - 1; k >= 0; k--) { dst[k] = '0' + v % 8; v /= 8; }
}

static u32 unoctal(const u8 *p, size_t n) {
  u32 acc = 0;
  for (size_t i = 0; i < n && p[i] >= '0' && p[i] <= '7'; i++) acc = acc * 8 + (p[i] - '0');
  return acc;
}

static void tar_header(Buf *out, const char *name, u32 size) {
  u8 h[512];
  memset(h, 0, 512);
  strncpy((char *)h, name, 100);
  memcpy(h + 100, "0000644", 7);
  memcpy(h + 108, "0000000", 7);
  memcpy(h + 116, "0000000", 7);
  octal(h + 124, 11, size);
  octal(h + 136, 11, 0);
  memset(h + 148, ' ', 8);
  h[156] = '0';
  memcpy(h + 257, "ustar", 5);
  h[263] = '0'; h[264] = '0';
  memcpy(h + 329, "0000000", 7);
  memcpy(h + 337, "0000000", 7);
  u32 sum = 0;
  for (int i = 0; i < 512; i++) sum += h[i];
  octal(h + 148, 6, sum);
  h[154] = 0; h[155] = ' ';
  buf_append(out, h, 512);
}

static void tar_entry(Buf *out, const char *name, const Buf *data) {
  tar_header(out, name, (u32)data->n);
  buf_append(out, data->p, data->n);
  buf_fill(out, 0, pad512((u32)data->n));
}

static void say(int verbose, const char *pre, const char *name) {
  if (verbose) fprintf(stderr, "%s%s\n", pre, name);
}

static void tar_add(Buf *out, char **names, int count, int verbose) {
  for (int k = 0; k < count; k++) {
    Buf data = {0};
    read_file(names[k], &data);
    say(verbose, "a ", names[k]);
    tar_entry(out, names[k], &data);
    free(data.p);
  }
  buf_fill(out, 0, 1024);
}

static int all_zero(const u8 *p, size_t n) {
  for (size_t i = 0; i < n; i++) if (p[i]) return 0;
  return 1;
}

// walks the entries; the loop is bounded by the block count as in the
// Bend version
static void tar_walk(const Buf *a, int extract, int verbose) {
  size_t off = 0;
  for (u32 fuel = (u32)(a->n / 512 + 1); fuel > 0; fuel--) {
    size_t left = off < a->n ? a->n - off : 0;
    size_t hn = left < 512 ? left : 512;
    if (all_zero(a->p + off, hn)) return;
    const u8 *h = a->p + off;
    char name[101];
    memset(name, 0, sizeof name);
    memcpy(name, h, hn < 100 ? hn : 100);
    u32 size = hn > 124 ? unoctal(h + 124, hn - 124 < 12 ? hn - 124 : 12) : 0;
    u8 kind = hn > 156 ? h[156] : 0;
    off += 512;
    size_t avail = off < a->n ? a->n - off : 0;
    size_t dn = size < avail ? size : avail;
    if (!extract) {
      printf("%s\n", name);
    } else if (kind == '5') {
      fprintf(stderr, "tar: skipping directory %s (no mkdir)\n", name);
    } else {
      say(verbose, "x ", name);
      Buf d = { (u8 *)a->p + off, dn, dn };
      write_file(name, &d);
    }
    off += size + pad512(size);
  }
}

// CRC-32
// ------

static u32 crc_tab[256];

static void crc_init(void) {
  for (u32 i = 0; i < 256; i++) {
    u32 c = i;
    for (int k = 0; k < 8; k++) c = (c >> 1) ^ ((c & 1) * 0xEDB88320u);
    crc_tab[i] = c;
  }
}

static u32 crc32(const u8 *p, size_t n) {
  u32 c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; i++) c = crc_tab[(c ^ p[i]) & 255] ^ (c >> 8);
  return c ^ 0xFFFFFFFFu;
}

// Bit reader
// ----------
// bits come least significant first out of each byte; past the end the
// stream reads as zeros

typedef struct { const u8 *p; size_t n, pos; u32 buf, cnt; } Br;

static u32 br_bits(Br *b, int k) {
  while (b->cnt < (u32)k) {
    u32 byte = b->pos < b->n ? b->p[b->pos] : 0;
    b->pos++;
    b->buf |= byte << b->cnt;
    b->cnt += 8;
  }
  u32 v = b->buf & ((1u << k) - 1);
  b->buf >>= k;
  b->cnt -= k;
  return v;
}

static void br_align(Br *b) { b->buf >>= b->cnt % 8; b->cnt -= b->cnt % 8; }

// Huffman decoding
// ----------------
// canonical codes as in zlib's puff: cnt[len] codes of each length,
// sym[] the symbols ordered by (length, value)

typedef struct { u32 cnt[16]; u32 sym[320]; } Huf;

static void huf_build(Huf *h, const u32 *lens, int n) {
  u32 offs[16];
  memset(h, 0, sizeof *h);
  for (int i = 0; i < n; i++) h->cnt[lens[i]]++;
  h->cnt[0] = 0;
  offs[1] = 0;
  for (int l = 1; l < 15; l++) offs[l + 1] = offs[l] + h->cnt[l];
  for (int i = 0; i < n; i++) if (lens[i]) h->sym[offs[lens[i]]++] = i;
}

static u32 huf_decode(Br *b, const Huf *h) {
  u32 code = 0, first = 0, index = 0;
  for (int len = 1; len <= 15; len++) {
    code |= br_bits(b, 1);
    u32 count = h->cnt[len];
    if (code - first < count) return h->sym[index + (code - first)];
    index += count;
    first = (first + count) << 1;
    code <<= 1;
  }
  return 0;
}

// Inflate
// -------

static const u32 len_base[29]   = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
static const u32 len_extra[29]  = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
static const u32 dist_base[30]  = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
static const u32 dist_extra[30] = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
static const u32 cl_order[19]   = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

static void huff_block(Br *b, Buf *out, const Huf *lit, const Huf *dst) {
  for (;;) {
    u32 sym = huf_decode(b, lit);
    if (sym < 256) { buf_push(out, (u8)sym); continue; }
    if (sym == 256) return;
    u32 c = sym - 257;
    u32 len = len_base[c] + br_bits(b, (int)len_extra[c]);
    u32 d = huf_decode(b, dst);
    u32 dist = dist_base[d] + br_bits(b, (int)dist_extra[d]);
    buf_reserve(out, out->n + len);
    for (u32 k = 0; k < len; k++) { out->p[out->n] = out->p[out->n - dist]; out->n++; }
  }
}

static void stored_block(Br *b, Buf *out) {
  br_align(b);
  u32 len = br_bits(b, 16);
  br_bits(b, 16);
  for (u32 k = 0; k < len; k++) buf_push(out, (u8)br_bits(b, 8));
}

static void dyn_block(Br *b, Buf *out) {
  u32 lens[320], cl[19];
  Huf lit, dst, clh;
  u32 hlit = br_bits(b, 5) + 257, hdist = br_bits(b, 5) + 1, hclen = br_bits(b, 4) + 4;
  memset(cl, 0, sizeof cl);
  for (u32 i = 0; i < hclen; i++) cl[cl_order[i]] = br_bits(b, 3);
  huf_build(&clh, cl, 19);
  u32 i = 0, prev = 0;
  while (i < hlit + hdist) {
    u32 s = huf_decode(b, &clh);
    if (s < 16) { lens[i++] = s; prev = s; continue; }
    u32 rep = s == 16 ? 3 + br_bits(b, 2) : s == 17 ? 3 + br_bits(b, 3) : 11 + br_bits(b, 7);
    u32 v = s == 16 ? prev : 0;
    while (rep-- && i < 320) lens[i++] = v;
    prev = v;
  }
  huf_build(&lit, lens, (int)hlit);
  huf_build(&dst, lens + hlit, (int)hdist);
  huff_block(b, out, &lit, &dst);
}

static void inflate(const u8 *p, size_t n, Buf *out) {
  Br b = { p, n, 0, 0, 0 };
  Huf lit, dst;
  u32 lens[288];
  for (u32 i = 0; i < 288; i++) lens[i] = i <= 143 ? 8 : i <= 255 ? 9 : i <= 279 ? 7 : 8;
  huf_build(&lit, lens, 288);
  for (u32 i = 0; i < 30; i++) lens[i] = 5;
  huf_build(&dst, lens, 30);
  for (u32 last = 0; !last;) {
    u32 hd = br_bits(&b, 3);
    last = hd & 1;
    if ((hd >> 1) == 0) stored_block(&b, out);
    else if ((hd >> 1) == 1) huff_block(&b, out, &lit, &dst);
    else dyn_block(&b, out);
  }
}

// Gzip
// ----
// header: 1f 8b 08 FLG mtime(4) xfl os, then extra, name, comment and a
// header crc as FLG says; the trailer (crc32, isize) is written, not read

static int is_gzip(const Buf *a) { return a->n >= 2 && a->p[0] == 0x1f && a->p[1] == 0x8b; }

static void gunzip(const Buf *a, Buf *out) {
  size_t i = 10;
  u32 flg = a->n > 3 ? a->p[3] : 0;
  if (flg & 4) { u32 xlen = i + 1 < a->n ? a->p[i] | (a->p[i + 1] << 8) : 0; i += 2 + xlen; }
  if (flg & 8)  { while (i < a->n && a->p[i]) i++; i++; }
  if (flg & 16) { while (i < a->n && a->p[i]) i++; i++; }
  if (flg & 2)  i += 2;
  inflate(a->p + (i < a->n ? i : a->n), i < a->n ? a->n - i : 0, out);
}

// Deflate
// -------
// one dynamic-Huffman block over an LZ77 pass, as in the Bend version

typedef struct { u32 good, lazy, nice, chain; int slow; } Cf;

static Cf cf_of(int level) {
  static const Cf tab[10] = {
    { 0, 0, 0, 0, 0 }, { 4, 4, 8, 4, 0 }, { 4, 5, 16, 8, 0 }, { 4, 6, 32, 32, 0 },
    { 4, 4, 16, 16, 1 }, { 8, 16, 32, 32, 1 }, { 8, 16, 128, 128, 1 },
    { 8, 32, 128, 256, 1 }, { 32, 128, 258, 1024, 1 }, { 32, 258, 258, 4096, 1 } };
  return tab[level < 1 ? 1 : level > 9 ? 9 : level];
}

// bit writer
typedef struct { Buf out; u32 buf, cnt; } Bw;

static void bw_put(Bw *w, u32 v, u32 k) {
  w->buf |= v << w->cnt;
  w->cnt += k;
  while (w->cnt >= 8) { buf_push(&w->out, (u8)(w->buf & 255)); w->buf >>= 8; w->cnt -= 8; }
}

static u32 rev_bits(u32 c, u32 k) {
  u32 acc = 0;
  for (u32 i = 0; i < k; i++) { acc = (acc << 1) | (c & 1); c >>= 1; }
  return acc;
}

static void bw_code(Bw *w, u32 code, u32 k) { bw_put(w, rev_bits(code, k), k); }

static void bw_fin(Bw *w) { if (w->cnt > 0) buf_push(&w->out, (u8)(w->buf & 255)); }

// the code index for a length or a distance: the last base <= v
static u32 code_of(u32 v, const u32 *base, u32 count) {
  u32 c = 0;
  while (c + 1 < count && v >= base[c + 1]) c++;
  return c;
}

typedef struct { u32 sym, ex, eb, ds, dx, db; } Tok;

// the pass: input, tables, a block's tokens (16384 at most) with their
// counts and the bytes they cover, the position, the held match of the
// lazy levels, and the flags: done for the input, stop for the block
typedef struct {
  const u8 *inp; u32 n;
  u32 hd[32768], prev[32768];
  Tok toks[16384]; u32 ntok, cov;
  u32 fl[512], fd[32];
  u32 i, pl, pd; int pend, done, stop;
} Lz;

static void push_tok(Lz *z, Tok t) {
  z->toks[z->ntok++] = t;
  z->stop = z->done || z->ntok >= 16384;
}

static void tok_lit(Lz *z, u32 b) {
  Tok t = { b, 0, 0, 0, 0, 0 };
  z->fl[b]++;
  z->cov += 1;
  push_tok(z, t);
}

static void tok_len(Lz *z, u32 len, u32 dist) {
  u32 c = code_of(len, len_base, 29), d = code_of(dist, dist_base, 30);
  Tok t = { 257 + c, len - len_base[c], len_extra[c], d, dist - dist_base[d], dist_extra[d] };
  z->fl[257 + c]++;
  z->fd[d]++;
  z->cov += len;
  push_tok(z, t);
}

// position j into the tables; answers the previous head (a position + 1,
// 0 for none), and 0 when fewer than 3 bytes remain
static u32 ins_at(Lz *z, u32 j) {
  if (j + 2 >= z->n) return 0;
  u32 h = (((u32)z->inp[j] << 10) ^ ((u32)z->inp[j + 1] << 5) ^ z->inp[j + 2]) & 32767;
  u32 cand = z->hd[h];
  z->hd[h] = j + 1;
  z->prev[j & 32767] = cand;
  return cand;
}

// eight bytes a step; the first differing byte is the xor's low zero
// bytes (the input is padded, and the length is clamped after)
static u32 match_at(const Lz *z, u32 i, u32 dist) {
  u32 maxlen = z->n - i < 258 ? z->n - i : 258, len = 0;
  const u8 *a = z->inp + i, *b = z->inp + i - dist;
  while (len < maxlen) {
    uint64_t wa, wb;
    memcpy(&wa, a + len, 8);
    memcpy(&wb, b + len, 8);
    uint64_t x = wa ^ wb;
    if (x != 0) { len += (u32)(__builtin_ctzll(x) >> 3); break; }
    len += 8;
  }
  return len < maxlen ? len : maxlen;
}

// the chain walk with zlib's one-byte reject at the best length
static void chain(const Lz *z, u32 i, u32 cand, u32 cap, u32 nice, int search, u32 *bl, u32 *bd) {
  *bl = 0; *bd = 0;
  u32 x = z->inp[i];
  int more = search && cand != 0 && i - (cand - 1) <= 32768 && i + 2 < z->n && cap > 0;
  for (u32 left = cap; more; left--) {
    u32 c = cand, d = i - (c - 1);
    if (x == z->inp[i + *bl - d]) {
      u32 len = match_at(z, i, d);
      if (len > *bl) { *bl = len; *bd = d; x = z->inp[i + *bl]; }
    }
    u32 nx = z->prev[(c - 1) & 32767];
    cand = nx;
    more = nx != 0 && i - (nx - 1) <= 32768 && *bl < nice && left > 1;
  }
}

static u32 too_far(u32 l, u32 d) { return l == 3 && d > 4096 ? 0 : l; }

// a block's worth of the pass: until the block is full or the input done
static void lz_block(Lz *z, Cf cf) {
  u32 n = z->n;
  while (!z->stop) {
    u32 i = z->i, cand = ins_at(z, i), bl, bd;
    if (!cf.slow) {
      chain(z, i, cand, cf.chain, cf.nice, 1, &bl, &bd);
      u32 cl = too_far(bl, bd);
      if (cl >= 3) {
        if (cl <= cf.lazy) for (u32 j = i + 1; j < i + cl; j++) ins_at(z, j);
        z->i = i + cl;
        z->done = z->i >= n;
        tok_len(z, cl, bd);
      } else {
        z->i = i + 1;
        z->done = z->i >= n;
        tok_lit(z, z->inp[i]);
      }
    } else {
      chain(z, i, cand, z->pl >= cf.good ? cf.chain >> 2 : cf.chain, cf.nice, z->pl < cf.lazy, &bl, &bd);
      u32 cl = too_far(bl, bd), cd = bd;
      if (z->pl >= 3 && cl <= z->pl) {
        u32 pl = z->pl, pd = z->pd;
        for (u32 j = i + 1; j + 1 < i + pl; j++) ins_at(z, j);
        z->i = i + pl - 1;
        z->pl = 0; z->pd = 0; z->pend = 0;
        z->done = z->i >= n;
        tok_len(z, pl, pd);
      } else if (z->pend) {
        z->pl = cl; z->pd = cd; z->pend = i < n;
        z->i = i + (i < n);
        z->done = z->i >= n && !z->pend;
        tok_lit(z, z->inp[i - 1]);
      } else {
        z->pl = cl; z->pd = cd; z->pend = i < n;
        z->done = i >= n;
        z->i = i + 1;
        z->stop = z->done;
      }
    }
  }
}

// Huffman code lengths
// --------------------
// counts to code lengths of at most limit bits: a tree grows by merging
// the two lightest live nodes (a scan each time), a leaf's length is its
// depth, and while a length passes the limit the counts are halved,
// rounding up, and the tree rebuilt

static void two_live(u32 *f, u32 n) {
  u32 c = 0;
  for (u32 i = 0; i < n; i++) c += f[i] != 0;
  if (c < 2) { f[0]++; f[1]++; }
}

static u32 build_once(const u32 *f0, u32 n, u32 *lens) {
  u32 fq[1024], par[1024], cnt = n, mx = 0;
  memset(fq, 0, sizeof fq);
  memset(par, 0, sizeof par);
  memcpy(fq, f0, n * sizeof(u32));
  for (u32 step = 0; step < n; step++) {
    u32 b1 = 0xFFFFFFFFu, f1 = 0xFFFFFFFFu, b2 = 0xFFFFFFFFu, f2 = 0xFFFFFFFFu;
    for (u32 j = 0; j < cnt; j++) {
      u32 f = fq[j];
      if (f != 0 && f < f1) { b2 = b1; f2 = f1; b1 = j; f1 = f; }
      else if (f != 0 && f < f2) { b2 = j; f2 = f; }
    }
    if (b2 == 0xFFFFFFFFu) break;
    fq[b1] = 0; fq[b2] = 0; fq[cnt] = f1 + f2;
    par[b1] = cnt; par[b2] = cnt;
    cnt++;
  }
  u32 root = cnt - 1;
  for (u32 i = 0; i < n; i++) {
    lens[i] = 0;
    if (f0[i] == 0) continue;
    u32 node = i, depth = 0;
    while (node != root) { node = par[node]; depth++; }
    lens[i] = depth;
    if (depth > mx) mx = depth;
  }
  return mx;
}

static void huff_lens(u32 *f0, u32 n, u32 limit, u32 *lens) {
  for (int round = 0; round < 31; round++) {
    if (build_once(f0, n, lens) <= limit) return;
    for (u32 i = 0; i < n; i++) f0[i] = (f0[i] >> 1) + (f0[i] & 1);
  }
}

// canonical codes: next[l] is the first code of length l
static void codes_of(const u32 *lens, u32 n, u32 *codes) {
  u32 cnt[16], next[16], code = 0;
  memset(cnt, 0, sizeof cnt);
  for (u32 i = 0; i < n; i++) cnt[lens[i]]++;
  cnt[0] = 0;
  for (u32 l = 0; l < 15; l++) { code = (code + cnt[l]) << 1; next[l + 1] = code; }
  for (u32 i = 0; i < n; i++) codes[i] = lens[i] ? next[lens[i]]++ : 0;
}

static u32 used(const u32 *lens, u32 n, u32 lo) {
  u32 last = 0;
  for (u32 i = 0; i < n; i++) if (lens[i]) last = i + 1;
  return last < lo ? lo : last;
}

// the run-length coding of the lengths: 16 repeats the previous 3-6
// times, 17 gives 3-10 zeros, 18 11-138 zeros
typedef struct { Tok *t; size_t n; u32 fc[19]; } Rle;

static void rpush(Rle *r, u32 sym, u32 ex, u32 eb) {
  Tok t = { sym, ex, eb, 0, 0, 0 };
  r->t[r->n++] = t;
  r->fc[sym]++;
}

static void rle(Rle *r, const u32 *all, u32 total) {
  for (u32 i = 0; i < total;) {
    u32 l = all[i], run = 1;
    while (i + run < total && all[i + run] == l) run++;
    i += run;
    if (l == 0) {
      for (;;) {
        if (run >= 11) { u32 m = run > 138 ? 138 : run; rpush(r, 18, m - 11, 7); run -= m; }
        else if (run >= 3) { rpush(r, 17, run - 3, 3); run = 0; }
        else if (run >= 1) { rpush(r, 0, 0, 0); run -= 1; }
        else break;
      }
    } else {
      rpush(r, l, 0, 0);
      run -= 1;
      for (;;) {
        if (run >= 3) { u32 m = run > 6 ? 6 : run; rpush(r, 16, m - 3, 2); run -= m; }
        else if (run >= 1) { rpush(r, l, 0, 0); run -= 1; }
        else break;
      }
    }
  }
}

static void bw_align(Bw *w) { bw_put(w, 0, (8 - w->cnt % 8) % 8); }

// the bytes [start, start+cov) as stored blocks of up to 65535 bytes,
// the final flag on the last when final; a size that is a multiple of
// 65535 gets an empty last block
static void stored_out(Bw *w, const u8 *p, u32 start, u32 cov, int final) {
  u32 count = cov / 65535 + 1;
  for (u32 k = 0; k < count; k++) {
    u32 at = k * 65535, len = cov - at > 65535 ? 65535 : cov - at;
    bw_put(w, final && k + 1 == count, 1);
    bw_put(w, 0, 2);
    bw_align(w);
    buf_push(&w->out, len & 255); buf_push(&w->out, len >> 8);
    buf_push(&w->out, (len ^ 65535) & 255); buf_push(&w->out, (len ^ 65535) >> 8);
    buf_append(&w->out, p + start + at, len);
  }
}

static void emit_tok(Bw *w, const Tok *t, const u32 *lc, const u32 *ll, const u32 *dc, const u32 *dl) {
  bw_code(w, lc[t->sym], ll[t->sym]);
  bw_put(w, t->ex, t->eb);
  if (t->sym >= 257) { bw_code(w, dc[t->ds], dl[t->ds]); bw_put(w, t->dx, t->db); }
}

// a block: the tables from the counts, the run-length coded lengths,
// and the choice: stored when its bytes cost less than the coded block
static void block_out(Lz *z, Bw *w, int final) {
  u32 ll[512], dl[32], all[512], lc[512], dc[32], cl[19], clc[19];
  u32 start = z->i - (u32)z->pend - z->cov, cov = z->cov;
  z->fl[256]++;
  two_live(z->fl, 286);
  huff_lens(z->fl, 286, 15, ll);
  two_live(z->fd, 30);
  huff_lens(z->fd, 30, 15, dl);
  u32 hl = used(ll, 286, 257), hd = used(dl, 30, 1);
  memcpy(all, ll, hl * sizeof(u32));
  memcpy(all + hl, dl, hd * sizeof(u32));
  Rle r;
  memset(&r, 0, sizeof r);
  r.t = malloc((hl + hd) * sizeof(Tok));
  if (!r.t) oom();
  rle(&r, all, hl + hd);
  two_live(r.fc, 19);
  huff_lens(r.fc, 19, 7, cl);
  u32 hc = 0;
  for (u32 k = 0; k < 19; k++) if (cl[cl_order[k]]) hc = k + 1;
  if (hc < 4) hc = 4;
  u32 dyn = 17 + 3 * hc + ll[256];
  for (size_t k = 0; k < r.n; k++) dyn += cl[r.t[k].sym] + r.t[k].eb;
  for (size_t k = 0; k < z->ntok; k++) {
    const Tok *t = &z->toks[k];
    dyn += ll[t->sym] + t->eb + (t->sym >= 257 ? dl[t->ds] + t->db : 0);
  }
  if (8 * cov + 40 * (cov / 65535 + 1) + 8 < dyn) {
    stored_out(w, z->inp, start, cov, final);
  } else {
    codes_of(ll, 286, lc);
    codes_of(dl, 30, dc);
    codes_of(cl, 19, clc);
    bw_put(w, final, 1);
    bw_put(w, 2, 2);
    bw_put(w, hl - 257, 5);
    bw_put(w, hd - 1, 5);
    bw_put(w, hc - 4, 4);
    for (u32 k = 0; k < hc; k++) bw_put(w, cl[cl_order[k]], 3);
    for (size_t k = 0; k < r.n; k++) { bw_code(w, clc[r.t[k].sym], cl[r.t[k].sym]); bw_put(w, r.t[k].ex, r.t[k].eb); }
    for (size_t k = 0; k < z->ntok; k++) emit_tok(w, &z->toks[k], lc, ll, dc, dl);
    bw_code(w, lc[256], ll[256]);
  }
  free(r.t);
  z->ntok = 0; z->cov = 0;
  memset(z->fl, 0, sizeof z->fl);
  memset(z->fd, 0, sizeof z->fd);
  z->stop = z->done;
}

// Chunks
// ------
// the input in chunks of 262144 bytes, each with a copy of the 32768
// bytes before it as a dictionary the tables see first; a chunk's
// stream ends byte aligned with an empty stored block unless it is the
// last, so the streams concatenate. One thread per chunk.

typedef struct { const u8 *p; u32 n, d; int last, level; Buf out; } Chunk;

static void *chunk_run(void *arg) {
  Chunk *c = arg;
  Lz *z = calloc(1, sizeof *z);
  if (!z) oom();
  u8 *padded = calloc(c->n + 16, 1);
  if (!padded) oom();
  memcpy(padded, c->p, c->n);
  z->inp = padded; z->n = c->n;
  for (u32 j = 0; j < c->d; j++) ins_at(z, j);
  z->i = c->d; z->done = c->d >= c->n; z->stop = z->done;
  Bw w = { c->out, 0, 0 };
  Cf cf = cf_of(c->level);
  for (int fin = 0; !fin;) {
    lz_block(z, cf);
    block_out(z, &w, z->done && c->last);
    fin = z->done;
  }
  if (!c->last) {
    bw_put(&w, 0, 1); bw_put(&w, 0, 2); bw_align(&w);
    buf_push(&w.out, 0); buf_push(&w.out, 0); buf_push(&w.out, 255); buf_push(&w.out, 255);
  }
  bw_fin(&w);
  c->out = w.out;
  free(z); free(padded);
  return NULL;
}

static void deflate(const u8 *p, u32 n, int level, Buf *out) {
  if (level == 0) {
    Bw w = { *out, 0, 0 };
    stored_out(&w, p, 0, n, 1);
    bw_fin(&w);
    *out = w.out;
    return;
  }
  u32 count = n == 0 ? 1 : (n + 262143) / 262144;
  Chunk *cs = calloc(count, sizeof *cs);
  pthread_t *ts = calloc(count, sizeof *ts);
  if (!cs || !ts) oom();
  for (u32 k = 0; k < count; k++) {
    u32 s = k * 262144, e = n - s < 262144 ? n : s + 262144, d = s < 32768 ? s : 32768;
    cs[k].p = p + s - d; cs[k].n = e - (s - d); cs[k].d = d; cs[k].last = k + 1 == count; cs[k].level = level;
    if (pthread_create(&ts[k], NULL, chunk_run, &cs[k]) != 0) die("thread", "cannot start");
  }
  for (u32 k = 0; k < count; k++) {
    pthread_join(ts[k], NULL);
    buf_append(out, cs[k].out.p, cs[k].out.n);
    free(cs[k].out.p);
  }
  free(cs); free(ts);
}

static void gzip(const Buf *a, int level, Buf *out) {
  u8 head[10] = { 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, (u8)(level == 9 ? 2 : level == 1 ? 4 : 0), 3 };
  buf_append(out, head, 10);
  deflate(a->p, (u32)a->n, level, out);
  u32 c = crc32(a->p, a->n), n = (u32)a->n;
  u8 tail[8] = { c & 255, (c >> 8) & 255, (c >> 16) & 255, c >> 24, n & 255, (n >> 8) & 255, (n >> 16) & 255, n >> 24 };
  buf_append(out, tail, 8);
}

// Command line
// ------------
// mode 0 none, 1 create, 2 extract, 3 list, 4 bad

typedef struct { int mode, gz, verbose, level; const char *file; } Opts;

static void usage(void) {
  fprintf(stderr, "usage: tar -{c|x|t}[zv0-9]f FILE [files..]   (or TAR_ARGS=\"...\" tar)\n");
  exit(1);
}

static int parse(int argc, char **argv, Opts *o, int *first_member) {
  memset(o, 0, sizeof *o);
  o->level = 6;
  if (argc < 1) { o->mode = 4; return 0; }
  const char *s = argv[0];
  if (*s == '-') s++;
  int wants = 0;
  for (; *s; s++) {
    switch (*s) {
      case 'c': o->mode = 1; break;
      case 'x': o->mode = 2; break;
      case 't': o->mode = 3; break;
      case 'z': o->gz = 1; break;
      case 'v': o->verbose = 1; break;
      case 'f': wants = 1; break;
      default:
        if (*s >= '0' && *s <= '9') o->level = *s - '0'; else o->mode = 4;
    }
  }
  int k = 1;
  if (wants) {
    if (k >= argc) { o->mode = 4; return 0; }
    o->file = argv[k++];
  }
  *first_member = k;
  return o->file != NULL;
}

int main(int argc, char **argv) {
  static char *words[64];
  int wc = 0;
  char **args = argv + 1;
  int argn = argc - 1;
  if (argn == 0) {
    char *line = getenv("TAR_ARGS");
    if (!line) usage();
    line = strdup(line);
    for (char *w = strtok(line, " "); w && wc < 64; w = strtok(NULL, " ")) words[wc++] = w;
    args = words; argn = wc;
  }
  Opts o;
  int first;
  crc_init();
  if (!parse(argn, args, &o, &first) || o.mode == 0 || o.mode == 4) usage();
  if (o.mode == 1) {
    Buf a = {0}, g = {0};
    tar_add(&a, args + first, argn - first, o.verbose);
    if (o.gz) { gzip(&a, o.level, &g); write_file(path_out(o.file), &g); }
    else write_file(path_out(o.file), &a);
  } else {
    Buf a = {0}, u = {0};
    read_file(path_in(o.file), &a);
    if (o.gz || is_gzip(&a)) { gunzip(&a, &u); tar_walk(&u, o.mode == 2, o.verbose); }
    else tar_walk(&a, o.mode == 2, o.verbose);
  }
  return 0;
}
