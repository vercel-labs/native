// Measured-text retention decisions over copied facts. Hashes, provider and
// policy identities, generations and LRU ticks stay as exact u32 words.
// Native owns font calls, thread-local advances/runs and pointer rebasing.
function nscvTextMeasurementCache(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 58 || request[1] !== 1 || request[2]! > 7 || request[3]! > 7)
    throw new Error("invalid measured text cache header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, count = w.getUint32(4, true), length = w.getUint32(8, true), capacity = w.getUint32(12, true);
  for (let at = 16; at < 32; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid measured text cache padding");
  const result = new Uint8Array(16), out = new DataView(result.buffer);
  out.setUint32(4, 0xffffffff, true);
  const answer = (kind: number, slot: number, flags: number): Uint8Array => {
    out.setUint32(0, kind, true); out.setUint32(4, slot, true); out.setUint32(8, flags, true); return result;
  };
  if (mode === 0 || mode === 3) {
    if (request.length !== 32 || count !== 0 || (mode === 3 && request[3]! > 1)) throw new Error("invalid measured text admission");
    if (mode === 3) return answer((request[3] === 1 && capacity >= 160) ? 6 : 0, 0xffffffff, 0);
    if ((request[3]! & 1) === 0) return result;
    if (length === 0) return answer(1, 0xffffffff, 0);
    if (length > 65536 || (request[3]! & 4) === 0 && (request[3]! & 2) === 0) return result;
    return answer(6, 0xffffffff, 0);
  }
  if (mode === 6) {
    if (request[3]! > 1 || count !== 0 || capacity !== 0 || length > 65536 || request.length !== 32 + length * 4)
      throw new Error("invalid measured text advance batch");
    if (request[3] === 0) return result;
    for (let i = 0; i < length; i++) {
      const value = w.getFloat32(32 + i * 4, true);
      if (!(value >= 0) || !Number.isFinite(value)) return result;
    }
    return answer(5, 0xffffffff, 0);
  }
  if (mode === 7) {
    // Native has proved the actual pointer relationship; these are only
    // copied source lengths and offsets. Reject the entire rebase on any
    // mismatch before native materializes even the first run.
    if (request[3] !== 0 || capacity !== 0 || count > 160 || length > 32 || request.length !== 32 + length * 4 + count * 12)
      throw new Error("invalid measured paragraph rebase");
    for (let i = 0; i < count; i++) {
      const at = 32 + length * 4 + i * 12, span = w.getUint32(at, true), start = w.getUint32(at + 4, true), size = w.getUint32(at + 8, true);
      if (span >= length || start + size > w.getUint32(32 + span * 4, true)) return result;
    }
    return answer(5, 0xffffffff, 0);
  }
  const advance = mode === 1 || mode === 2, oversize = advance && length > 2048;
  if (request[3]! > 1 || capacity !== 0 || count !== (advance && oversize ? 257 : 256) || request.length !== 128 + count * 104 || advance && (length === 0 || length > 65536))
    throw new Error("invalid measured text cache facts");
  for (let i = -1; i < count; i++) {
    const at = i < 0 ? 32 : 128 + i * 104;
    if (w.getUint32(at + 88, true) > 1 || w.getUint32(at + 92, true) !== 0) throw new Error("invalid measured text cache key");
  }
  if (mode === 5 && (length > 160 || request[3] !== 1)) return result;
  let victim = 0, low = 0xffffffff, high = 0xffffffff;
  const begin = oversize ? 256 : 0, end = oversize ? 257 : count;
  for (let i = begin; i < end; i++) {
    const at = 128 + i * 104, used = w.getUint32(at + 88, true) !== 0;
    if (mode !== 5 && used && w.getUint32(120, true) !== 0) {
      let same = true;
      for (let byte = 0; byte < 88; byte += 4) if (w.getUint32(at + byte, true) !== w.getUint32(32 + byte, true)) same = false;
      if (same) return answer(2, i, (mode === 1 || mode === 4 || !oversize ? 1 : 0) | 2);
    }
    const tickLow = used ? w.getUint32(at + 96, true) : 0, tickHigh = used ? w.getUint32(at + 100, true) : 0;
    if (tickHigh < high || tickHigh === high && tickLow < low) { victim = i; low = tickLow; high = tickHigh; }
  }
  if (mode === 2) return result;
  if (mode === 4) return answer(0, 0xffffffff, 8);
  if (mode === 5) return answer(4, victim, 1);
  return answer(3, oversize ? 256 : victim, 1 | 4);
}
