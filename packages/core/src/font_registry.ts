/** Permanent font registration and refresh decisions over copied metadata.
 * Native retains font bytes, parsing, allocation, host handles and callbacks.
 */
function nscvFontRegistry(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 83 || request[1] !== 1 || request[2]! > 5 || request[3] !== 0)
    throw new Error("invalid font registry header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, count = w.getUint32(4, true), capacity = w.getUint32(8, true), facts = w.getUint32(12, true);
  if (count > capacity || capacity !== 8 || request.length !== 64 + count * 8 || facts > 3)
    throw new Error("invalid font registry bounds");
  for (let i = 52; i < 64; i++) if (request[i] !== 0) throw new Error("invalid font registry padding");
  const same = (a: number, b: number): boolean => w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
  const less = (a: number, b: number): boolean => w.getUint32(a + 4, true) < w.getUint32(b + 4, true) || w.getUint32(a + 4, true) === w.getUint32(b + 4, true) && w.getUint32(a, true) < w.getUint32(b, true);
  let status = 0, selected = 4294967295, action = 0;
  if (mode <= 1) for (let i = 0; i < count; i++) if (same(16, 64 + i * 8)) { selected = i; break; }
  if (mode === 0) {
    if (w.getUint32(16, true) === 0 && w.getUint32(20, true) === 0) status = 1;
    else if (less(16, 24)) status = 2;
    else if (less(40, 32)) status = 3;
    else if (selected !== 4294967295) status = 4;
    else if (count === capacity) status = 5;
    else { selected = count; action = count === 0 ? 3 : 1; }
  } else if (mode === 2) {
    // This phase is reached only after the host reports UnsupportedService.
    if ((facts & 1) !== 0) status = 6;
  } else if (mode === 3) {
    action = (facts & 1) !== 0 ? 1 : count > 0 ? 2 : 0;
  } else if (mode === 4) {
    action = facts === 3 ? 1 : 0;
  } else if (mode === 5) {
    action = count !== w.getUint32(48, true) ? 1 : 0;
  }
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, status, true);
  out.setUint32(8, selected, true); out.setUint32(12, action, true);
  return result;
}
