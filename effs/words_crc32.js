// IEEE CRC-32 over n bytes of a packed Array, starting at byte start.
function words_crc32(a, start, n) {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) {
      c = (c >>> 1) ^ ((c & 1) ? 0xedb88320 : 0);
    }
    table[i] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (let i = 0; i < n; i++) {
    const at = start + i;
    const b = (a[at >> 2] >>> (8 * (at & 3))) & 255;
    crc = (table[(crc ^ b) & 255] ^ (crc >>> 8)) >>> 0;
  }
  return io_tup(a, io_done((crc ^ 0xffffffff) >>> 0));
}
