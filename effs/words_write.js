// Words
// =====
//! use ../../bend2/effs/sys.js

function words_flat(a, out, at) {
  if (a.$ === "ALeaf") {
    out[at] = a.value;
    return at + 1;
  }
  return words_flat(a.ys, out, words_flat(a.xs, out, at));
}

function words_write(path, a, start, n) {
  const sys = sys_get();
  const fs = require("fs");
  const words = new Uint32Array(array_len(a));
  words_flat(a, words, 0);
  const bytes = new Uint8Array(n);
  for (let j = 0; j < n; j++) {
    const at = start + j;
    bytes[j] = (words[at >> 2] >>> (8 * (at & 3))) & 255;
  }
  try {
    const fd = fs.openSync(path, "w");
    fs.writeSync(fd, bytes, 0, n, null);
    fs.closeSync(fd);
  } catch (e) {
    return sys.tup(a, sys.fail(Math.abs(e.errno ?? 5)));
  }
  return sys.tup(a, sys.done({ $: "Unit" }));
}
