// Words
// =====
//! use ../../bend2/effs/sys.js

function words_tree(buf, lo, hi) {
  if (hi - lo === 1) {
    const i = lo * 4;
    const w = (buf[i] | 0) | ((buf[i + 1] | 0) << 8) | ((buf[i + 2] | 0) << 16) | ((buf[i + 3] | 0) << 24);
    return { $: "ALeaf", value: w >>> 0 };
  }
  const mid = (lo + hi) / 2;
  return { $: "ANode", xs: words_tree(buf, lo, mid), ys: words_tree(buf, mid, hi) };
}

function words_read(path) {
  const sys = sys_get();
  const fs = require("fs");
  let buf;
  try {
    buf = fs.readFileSync(path);
  } catch (e) {
    return sys.fail(Math.abs(e.errno ?? 2));
  }
  const words = (buf.length >> 2) + 3;
  let n = 1;
  while (n < words) {
    n *= 2;
  }
  return sys.done(sys.tup(words_tree(buf, 0, n), buf.length));
}
