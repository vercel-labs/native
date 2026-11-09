/** Embedded WebView pane coordination (99). Native owns text and retained
 * storage, supplies exact byte-equality lookup facts and OS outcomes, and
 * executes copied plans. Reload identities remain two complete integer words.
 */
function nscvWebPanes(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 99 || request[1]! > 3 || request[2]! > 15 || request[3] !== 0)
    throw new Error("invalid web pane header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const word = (at: number): number => w.getUint32(at, true);
  const bounded = (at: number, capacity: number): number => word(at + 4) !== 0 || word(at) > capacity ? capacity : word(at);
  const mode = request[1]!;
  if (mode !== 0 && request[2] !== 0) throw new Error("invalid web pane numeric flags");
  if (mode === 0) {
    if (request.length < 32 || word(4) > 1024 || word(8) > 1 || word(12) !== 0 ||
        request.length !== 32 + word(4) * 20 || word(8) === 0 && word(4) !== 0)
      throw new Error("invalid web pane frame facts");
    const result = new Uint8Array(24), out = new DataView(result.buffer);
    let selected = 4294967295, at = 16;
    for (let i = 0; i < word(4); i++) {
      const row = 32 + i * 20;
      if (word(row) > 1) throw new Error("invalid web pane anchor fact");
      if (selected === 4294967295 && word(row) === 1) { selected = i; at = row + 4; }
    }
    out.setUint32(4, selected, true);
    if (word(8) === 1 && selected === 4294967295) return result;
    if (w.getFloat32(at + 8, true) < 1 || w.getFloat32(at + 12, true) < 1) { out.setUint32(0, 1, true); return result; }
    out.setUint32(0, 2, true);
    result.set(request.subarray(at, at + 16), 8);
    for (let i = 0; i < 2; i++) {
      const value = w.getFloat32(at + i * 4, true);
      // The existing native numeric capability specifies opposite-zero
      // extrema. NaN follows the numeric max operation's non-NaN operand.
      const clamped = value === 0 ? (1 / value < 0 && (request[2]! & 4) !== 0 ? -0 : 0) : Number.isNaN(value) || value < 0 ? 0 : value;
      out.setFloat32(8 + i * 4, clamped, true);
    }
    return result;
  }
  if (mode === 1) {
    if (request.length !== 32 || word(4) > 4 || word(16) > 64 || word(24) !== 0 || word(28) !== 0)
      throw new Error("invalid web pane slot facts");
    const result = new Uint8Array(12), out = new DataView(result.buffer);
    let selected = 4294967295;
    for (let i = 0; i < 4; i++) {
      if (request[20 + i]! > 1 || i >= word(4) && request[20 + i] !== 0) throw new Error("invalid web pane slot match");
      if (i < word(4) && request[20 + i] === 1 && selected === 4294967295) selected = i;
    }
    if (selected !== 4294967295) out.setUint32(0, 1, true);
    else if (word(4) < 4) { selected = word(4); out.setUint32(0, 2, true); out.setUint32(8, bounded(8, word(16)), true); }
    out.setUint32(4, selected, true);
    return result;
  }
  if (mode === 2) {
    if (request.length !== 64 || word(4) > 7 || word(56) !== 0 || word(60) !== 0)
      throw new Error("invalid web pane patch facts");
    let equal = true;
    for (let i = 0; i < 4; i++) if (!(Math.abs(Math.fround(w.getFloat32(24 + i * 4, true) - w.getFloat32(8 + i * 4, true))) < 0.25)) equal = false;
    const tokensEqual = word(40) === word(48) && word(44) === word(52);
    const flags = word(4), result = new Uint8Array(4);
    result[0] = (equal ? 0 : 1) | ((flags & 4) !== 0 && ((flags & 1) !== 0 || (flags & 2) === 0 || !tokensEqual) ? 2 : 0);
    return result;
  }
  if (request.length !== 32 || word(4) > 1 || word(16) > 4096 || word(20) !== 0 || word(24) !== 0 || word(28) !== 0)
    throw new Error("invalid web pane commit facts");
  const result = new Uint8Array(8), out = new DataView(result.buffer);
  if (word(4) === 1) { out.setUint32(0, 1, true); out.setUint32(4, bounded(8, word(16)), true); }
  return result;
}
