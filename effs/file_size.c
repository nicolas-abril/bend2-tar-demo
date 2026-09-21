#include <sys/stat.h>

// The byte size of a regular input file, without reading its contents.
Term file_size_run(Env e, Term* f, IoWork* w) {
  uint64_t n = 0;
  char* path = io_cstr(e, f[0], &n);
  struct stat st;
  if (io_nul(path, n) || stat(path, &st) != 0) {
    int err = errno != 0 ? errno : ENOENT;
    free(path);
    return io_fail(e, (u32)err, NULL);
  }
  free(path);
  if (st.st_size < 0 || (uint64_t)st.st_size > UINT32_MAX) {
    return io_fail(e, EFBIG, NULL);
  }
  return io_done(e, (Term)(u32)st.st_size);
}

static void __attribute__((constructor)) file_size_use(void) {
  io_eff(CID_FILE_SIZE, file_size_run, 0);
}
