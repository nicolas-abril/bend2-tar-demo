// The byte size of a regular input file, without reading its contents.
function file_size(path) {
  const fs = require("fs");
  try {
    const n = fs.statSync(path).size;
    if (!Number.isSafeInteger(n) || n < 0 || n > 0xffffffff) {
      return io_fail(27);
    }
    return io_done(n >>> 0);
  } catch (e) {
    return io_fail(Math.abs(e.errno ?? 2));
  }
}
