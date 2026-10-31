/** Loop-thread image and adopted-texture decisions over copied observations.
 * Pixels, allocation, codec calls, producer locks and GPU calls remain native.
 */
function nscvImageRegistry(request: Uint8Array): Uint8Array {
  if (request.length < 96 || request[0] !== 82 || request[1] !== 1 || request[2]! > 8 || (request[3] !== 32 && request[3] !== 64))
    throw new Error("invalid image registry header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, count = w.getUint32(4, true), capacity = w.getUint32(8, true), cursor = w.getUint32(12, true), facts = w.getUint32(16, true);
  if (count > capacity || capacity > 32 || request.length !== 96 + count * 32 || facts > 3 || (mode === 5 && capacity !== 4) || (mode <= 3 && capacity !== 16))
    throw new Error("invalid image registry bounds");
  for (let at = 72; at < 96; at++) if (request[at] !== 0) throw new Error("invalid image registry reserved bytes");
  for (let i = 0; i < count; i++) {
    const at = 96 + i * 32;
    if (w.getUint32(at + 16, true) > 3) throw new Error("invalid image registry record");
    for (let j = 20; j < 32; j++) if (request[at + j] !== 0) throw new Error("invalid image registry record padding");
  }
  const same = (a: number, b: number): boolean => w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
  const zero = (at: number): boolean => w.getUint32(at, true) === 0 && w.getUint32(at + 4, true) === 0;
  const greater = (a: number, b: number): boolean => w.getUint32(a + 4, true) > w.getUint32(b + 4, true) || w.getUint32(a + 4, true) === w.getUint32(b + 4, true) && w.getUint32(a, true) > w.getUint32(b, true);
  let selected = -1, status = 0, action = 0, next = 4294967295;
  if (mode !== 4) for (let i = 0; i < count; i++) {
    const at = 96 + i * 32;
    if (same(24, at) && (mode !== 7 && mode !== 8 || !zero(at + 8))) { selected = i; break; }
  }
  if (mode === 0 || mode === 1) {
    if (zero(24) || (w.getUint32(28, true) & 2147483648) !== 0) status = 1;
    else if (mode === 1) {
      if (w.getUint32(52, true) !== 0 || w.getUint32(48, true) > w.getUint32(20, true)) status = 3;
      else action = 1;
    } else {
      // Base-65536 multiplication keeps every intermediate exact, including
      // size_t overflow on both 32-bit and 64-bit native hosts.
      const a: number[] = [], b: number[] = [], product: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0];
      for (let i = 0; i < 4; i++) { a.push(w.getUint16(32 + i * 2, true)); b.push(w.getUint16(40 + i * 2, true)); }
      for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) product[i + j] = product[i + j]! + a[i]! * b[j]! * 4;
      for (let i = 0; i < 8; i++) { product[i + 1] = product[i + 1]! + Math.floor(product[i]! / 65536); product[i] = product[i]! % 65536; }
      let overflow = false, matches = true;
      for (let i = request[3] === 32 ? 2 : 4; i < 9; i++) if (product[i] !== 0) overflow = true;
      for (let i = 0; i < 4; i++) if (product[i] !== w.getUint16(48 + i * 2, true)) matches = false;
      if (zero(32) || zero(40) || overflow || !matches) status = 2;
      else if (greater(48, 56)) status = 3;
      else if (selected < 0 && count === capacity) status = 4;
      else { if (selected < 0) selected = count; action = 1; }
    }
  } else if (mode === 3) { if (selected >= 0) action = 2; }
  else if (mode === 4) {
    if (cursor >= count) throw new Error("invalid image registry view cursor");
    if (w.getUint32(96 + cursor * 32 + 16, true) === 3) action = 4;
    selected = cursor;
  } else if (mode === 5) {
    if (selected >= 0) action = 1;
    else if (count < capacity) { selected = count; action = 8; }
    else if ((facts & 1) === 0) { action = 16; next = 0; }
    else {
      if (cursor >= count) throw new Error("invalid image registry reclaim cursor");
      if ((facts & 2) === 0) { selected = cursor; action = 32; }
      else if (cursor + 1 < count) { action = 16; next = cursor + 1; }
    }
  } else if (mode === 6) {
    if (same(64, 56)) action = 64;
  } else if (mode === 8 && selected >= 0) action = 128;
  const result = new Uint8Array(32), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true); out.setUint32(8, status, true);
  out.setUint32(12, selected < 0 ? 4294967295 : selected, true); out.setUint32(16, action, true); out.setUint32(20, next, true);
  return result;
}
