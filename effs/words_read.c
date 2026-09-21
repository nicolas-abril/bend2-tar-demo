// Words
// =====
// the whole file packed four bytes to a word, little-endian, in a
// buf block of 2^d u32 lanes with at least three spare words of zeros,
// and its byte count
Term words_read_run(Env e, Term* f, IoWork* w) {
  uint64_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  FILE* fp = io_nul(path, n) ? NULL : fopen(path, "rb");
  if (fp == NULL) {
    free(path);
    return io_fail(e, errno != 0 ? (u32)errno : ENOENT, NULL);
  }
  free(path);
  uint64_t cap = 1 << 20;
  uint64_t len = 0;
  uint8_t* buf = io_mem(malloc(cap));
  for (;;) {
    if (len + 65536 > cap) {
      cap *= 2;
      buf = io_mem(realloc(buf, cap));
    }
    size_t got = fread(buf + len, 1, cap - len, fp);
    if (got == 0) {
      break;
    }
    len += got;
  }
  fclose(fp);
  uint64_t words = (len >> 2) + 3;
  Nat d = 0;
  while ((1ull << d) < words) {
    d += 1;
  }
  Term arr = blk_new(e, 0, d, 0, 0, NULL);
  Loc loc = term_loc(arr);
  for (uint64_t i = 0; i < len; i += 4) {
    uint32_t w = 0;
    for (uint64_t k = 0; k < 4 && i + k < len; k += 1) {
      w |= (uint32_t)buf[i + k] << (8 * k);
    }
    blk_write(e.mem, 0, loc, (u32)(i >> 2), w);
  }
  free(buf);
  return io_done(e, io_tup(e, arr, (Term)len));
}

static void __attribute__((constructor)) words_read_use(void) {
  io_eff(CID_WORDS_READ, words_read_run, 0);
}
