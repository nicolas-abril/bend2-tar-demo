// Read exactly n bytes into a word-aligned range of an existing packed Array.
function words_fill(path, a, start, n) {
  const fs = require("fs");
  let fd;
  try {
    fd = fs.openSync(path, "r");
    const buf = Buffer.allocUnsafe(1 << 20);
    let done = 0;
    while (done < n) {
      const want = Math.min(n - done, buf.length);
      const got = fs.readSync(fd, buf, 0, want, done);
      if (got !== want) throw Object.assign(new Error("short read"), { errno: 5 });
      for (let i = 0; i < got; i += 4) {
        a[(start + done + i) >> 2] = ((buf[i] | 0) | ((buf[i + 1] | 0) << 8) | ((buf[i + 2] | 0) << 16) | ((buf[i + 3] | 0) << 24)) >>> 0;
      }
      done += got;
    }
    fs.closeSync(fd);
    return io_tup(a, io_done({ $: "Unit" }));
  } catch (e) {
    if (fd !== undefined) try { fs.closeSync(fd); } catch (_) {}
    return io_tup(a, io_fail(Math.abs(e.errno ?? 5)));
  }
}
