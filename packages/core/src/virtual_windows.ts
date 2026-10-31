/** Virtual-window coordination over owned copies. Operation 97:
 * mode 0: 16-byte header (list/node counts), 24-byte declarations
 * (u64 identity/count, variable flag, zero), then 24-byte layout facts
 * (u64 identity/parent, parent/anchor/row/empty flags, zero). The result
 * has a 16-byte header, one 16-byte plan per list (first node, coverage
 * kind, measurement start/count), then ordered u32 row ordinals.
 * mode 1: 16-byte header (count, queried u64 identity), then u64 ids.
 * mode 2: 16-byte retry facts (pass, corrected/known/undercovered flags).
 * mode 3: 16-byte header (count), then copied f32 pending corrections.
 * mode 4: 72-byte fixed coverage facts reuse the shipped range policy.
 * Identities and parent slots always compare complete integer words.
 * Native retains tables, callbacks, geometry and measurement storage.
 */
function nscvVirtualWindows(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 97 || request[1]! > 4 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid virtual window header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[1]!, count = w.getUint32(4, true), missing = 4294967295;
  const zero = (at: number): boolean => w.getUint32(at, true) === 0 && w.getUint32(at + 4, true) === 0;
  const equal = (a: number, b: number): boolean => w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
  if (mode === 1) {
    if (count > 8 || request.length !== 16 + count * 8) throw new Error("invalid virtual window identities");
    let found = false;
    if (!zero(8)) for (let i = 0; i < count; i++) if (equal(8, 16 + i * 8)) { found = true; break; }
    const out = new Uint8Array(1); out[0] = found ? 1 : 0; return out;
  }
  if (mode === 2) {
    const flags = w.getUint32(8, true);
    if (request.length !== 16 || count > 2 || flags > 7 || w.getUint32(12, true) !== 0 || (flags & 4) !== 0 && (flags & 2) === 0)
      throw new Error("invalid virtual window retry");
    const out = new Uint8Array(1);
    out[0] = count >= 2 ? 0 : (flags & 1) !== 0 ? 2 : (flags & 2) === 0 ? 1 : (flags & 4) !== 0 ? 2 : 0;
    return out;
  }
  if (mode === 3) {
    if (count > 8 || request.length !== 16 + count * 4 || !zero(8)) throw new Error("invalid virtual window corrections");
    let corrected = false;
    for (let i = 0; i < count; i++) if (Math.abs(w.getFloat32(16 + i * 4, true)) > 0.5) corrected = true;
    const out = new Uint8Array(1); out[0] = corrected ? 1 : 0; return out;
  }
  if (mode === 4) {
    const flags = w.getUint32(4, true);
    if (request.length !== 72 || flags > 3 || w.getUint32(64, true) !== 0 || w.getUint32(68, true) !== 0)
      throw new Error("invalid virtual fixed coverage");
    const authored = w.getFloat32(44, true), fallback = w.getFloat32(48, true);
    const range = nscvFlowRange(nscvFlowInteger(w, 8), w.getFloat32(40, true), authored > 0 ? authored : fallback,
      w.getFloat32(52, true), w.getFloat32(56, true), w.getFloat32(60, true), nscvFlowInteger(w, 16), flags);
    const out = new Uint8Array(1);
    out[0] = nscvFlowCompare(range.start, nscvFlowInteger(w, 24)) < 0 || nscvFlowCompare(range.end, nscvFlowInteger(w, 32)) > 0 ? 1 : 0;
    return out;
  }
  const nodes = w.getUint32(8, true);
  if (count > 8 || nodes > 1024 || request.length !== 16 + (count + nodes) * 24 || w.getUint32(12, true) !== 0)
    throw new Error("invalid virtual window layout");
  for (let i = 0; i < count; i++) if (w.getUint32(32 + i * 24, true) > 1 || w.getUint32(36 + i * 24, true) !== 0)
    throw new Error("invalid virtual window declaration");
  const firstNode = 16 + count * 24;
  for (let i = 0; i < nodes; i++) {
    const at = firstNode + i * 24;
    if (w.getUint32(at + 16, true) > 15 || w.getUint32(at + 20, true) !== 0) throw new Error("invalid virtual window node");
  }
  const plans: number[] = [], rows: number[] = [];
  for (let i = 0; i < count; i++) {
    const record = 16 + i * 24, variable = w.getUint32(record + 16, true) !== 0;
    let selected = missing;
    for (let j = 0; j < nodes; j++) if (equal(record, firstNode + j * 24)) { selected = j; break; }
    const begin = rows.length;
    let coverage = 0, measure = false;
    if (selected !== missing) {
      const flags = w.getUint32(firstNode + selected * 24 + 16, true);
      const active = (flags & 8) === 0;
      if (active && !zero(record)) coverage = variable ? (zero(record + 8) ? 0 : 2) : 1;
      if (active && variable && !zero(record + 8)) {
        measure = true;
        for (let j = 0; j < nodes; j++) {
          const at = firstNode + j * 24, rowFlags = w.getUint32(at + 16, true);
          if ((rowFlags & 7) === 5 && w.getUint32(at + 8, true) === selected && w.getUint32(at + 12, true) === 0) rows.push(j);
        }
      }
    }
    plans.push(selected, coverage | (measure ? 4 : 0), begin, rows.length - begin);
  }
  const out = new Uint8Array(16 + plans.length * 4 + rows.length * 4), v = new DataView(out.buffer);
  out[0] = 97; v.setUint32(4, count, true); v.setUint32(8, rows.length, true);
  for (let i = 0; i < plans.length; i++) v.setUint32(16 + i * 4, plans[i]!, true);
  for (let i = 0; i < rows.length; i++) v.setUint32(16 + plans.length * 4 + i * 4, rows[i]!, true);
  return out;
}
