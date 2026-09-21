// The effective native CPU worker count, after --threads/default selection
// and runtime clamping. Custom effects are emitted into the runtime's C
// translation unit, so they can read its internal pool size.
Term runtime_threads_run(Env e, Term* f, IoWork* w) {
  return (Term)pool_size;
}

static void __attribute__((constructor)) runtime_threads_use(void) {
  io_eff(CID_RUNTIME_THREADS, runtime_threads_run, 0);
}
