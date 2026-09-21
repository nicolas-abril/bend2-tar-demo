// Read exactly n bytes directly into a word-aligned range of an existing
// packed Array. The Array comes back outside the Result.
Term words_fill_run(Env e, Term* f, IoWork* w) {
  uint64_t path_n = 0;
  char* path = io_cstr(e, f[0], &path_n);
  Term arr = f[1];
  uint64_t start = (uint64_t)(u32)f[2];
  uint64_t count = (uint64_t)(u32)f[3];
  FILE* fp = io_nul(path, path_n) ? NULL : fopen(path, "rb");
  if (fp == NULL) {
    int err = errno != 0 ? errno : ENOENT;
    free(path);
    return io_tup(e, arr, io_fail(e, (u32)err, NULL));
  }
  free(path);
  uint8_t* buf = io_mem(malloc(1 << 20));
  Loc loc = term_loc(arr);
  uint64_t done = 0;
  while (done < count) {
    uint64_t want = count - done;
    if (want > (1 << 20)) want = 1 << 20;
    size_t got = fread(buf, 1, want, fp);
    if (got != want) {
      int err = ferror(fp) && errno != 0 ? errno : EIO;
      free(buf);
      fclose(fp);
      return io_tup(e, arr, io_fail(e, (u32)err, NULL));
    }
    for (uint64_t i = 0; i < got; i += 4) {
      u32 word = 0;
      for (uint64_t k = 0; k < 4 && i + k < got; k += 1) {
        word |= (u32)buf[i + k] << (8 * k);
      }
      blk_write(e.mem, 0, loc, (u32)((start + done + i) >> 2), word);
    }
    done += got;
  }
  free(buf);
  if (fclose(fp) != 0) {
    return io_tup(e, arr, io_fail(e, (u32)(errno != 0 ? errno : EIO), NULL));
  }
  return io_tup(e, arr, io_done(e, term_pak(CID_UNIT, 0)));
}

static void __attribute__((constructor)) words_fill_use(void) {
  io_eff(CID_WORDS_FILL, words_fill_run, 0);
}
