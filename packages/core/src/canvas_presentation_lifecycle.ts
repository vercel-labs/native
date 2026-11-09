/** Presentation lifecycle decisions over copied host and buffer observations.
 * Native owns rasterization, encoding, uploads, storage and presentation. */
function nscvCanvasPresentationLifecycle(request: Uint8Array): Uint8Array {
  if (request.length !== 128 || request[0] !== 77 || request[1] !== 1 || request[2]! > 12 || request[3]! > 3)
    throw new Error("invalid presentation lifecycle header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, flags = w.getUint32(4, true);
  const safety = (request[3]! & 1) !== 0, word32 = (request[3]! & 2) !== 0;
  if (flags > 1023 || w.getUint32(112, true) > 5 || w.getUint32(116, true) > 5 ||
      w.getUint32(120, true) !== 0 || w.getUint32(124, true) !== 0)
    throw new Error("invalid presentation lifecycle facts");
  if (word32) for (let at = 12; at < 112; at += 8) if (w.getUint32(at, true) !== 0)
    throw new Error("invalid presentation lifecycle word extent");
  const nonzero = (at: number): boolean => w.getUint32(at, true) !== 0 || w.getUint32(at + 4, true) !== 0;
  const compare = (a: number, b: number): number => {
    const ah = w.getUint32(a + 4, true), bh = w.getUint32(b + 4, true);
    return ah === bh ? w.getUint32(a, true) - w.getUint32(b, true) : ah - bh;
  };
  // skipped, packet, upload, encode, pixels, done, gather, adopt, invalidate, observe image.
  let instruction = 0, refusal = 0, mutations = 0;
  let countLower = 0, countUpper = 0, loggedLower = 0, loggedUpper = 0;
  let detailLower = 0, detailUpper = 0;
  const requested = (flags & 2) === 0 || (flags & 4) === 0;
  if (mode === 0) instruction = requested ? 1 : 4;
  else if (mode === 1) {
    if ((flags & 1) !== 0) {
      instruction = 4;
      if (requested && nonzero(8) && nonzero(16)) {
        if ((flags & 8) !== 0) instruction = 1;
        else refusal = 1;
      }
    }
  } else if (mode === 2) {
    instruction = (flags & 16) !== 0 ? 2 : 4;
    refusal = (flags & 16) !== 0 ? 0 : 2;
  } else if (mode === 3) {
    instruction = (flags & 32) !== 0 ? 3 : 4;
    refusal = (flags & 32) !== 0 ? 0 : 1;
  } else if (mode === 4) instruction = (flags & 32) !== 0 ? 5 : 4;
  else if (mode === 5) {
    instruction = (flags & 1) !== 0 ? 4 : 0;
    if (instruction === 4 && compare(24, 32) >= 0) mutations = 1;
  } else if (mode === 6) instruction = (flags & 64) !== 0 ? 6 : 8;
  else if (mode === 7) instruction = (flags & 128) !== 0 ? 7 : 8;
  else if (mode === 8) {
    countLower = w.getUint32(40, true); countUpper = w.getUint32(44, true);
    loggedLower = w.getUint32(48, true); loggedUpper = w.getUint32(52, true);
    if (safety && countLower === 4294967295 && (word32 || countUpper === 4294967295)) mutations = 4;
    else {
      countLower = (countLower + 1) >>> 0;
      if (countLower === 0 && !word32) countUpper = (countUpper + 1) >>> 0;
      const first = countUpper === 0 && countLower === 1;
      const changed = w.getUint32(112, true) !== w.getUint32(116, true);
      // Preserve native short-circuiting: the subtraction is not evaluated
      // on the first fallback or a reason change, even for hostile counters.
      let log = first || changed;
      if (!log) {
        const below = countUpper < loggedUpper || countUpper === loggedUpper && countLower < loggedLower;
        if (below && safety) mutations = 4;
        else {
          const lower = (countLower - loggedLower) >>> 0;
          const upper = word32 ? 0 : (countUpper - loggedUpper - (countLower < loggedLower ? 1 : 0)) >>> 0;
          log = upper !== 0 || lower >= 120;
        }
      }
      if (log) { mutations |= 2; loggedLower = countLower; loggedUpper = countUpper; }
    }
    const detail = compare(56, 64) < 0 ? 56 : 64;
    detailLower = w.getUint32(detail, true); detailUpper = w.getUint32(detail + 4, true);
  } else if (mode === 9) {
    if ((flags & 256) !== 0 && (flags & 512) !== 0 && compare(72, 80) < 0) instruction = 9;
  } else if (mode === 10) {
    if (nonzero(88) && nonzero(96) && nonzero(104)) instruction = 2;
  } else if (mode === 11) {
    instruction = 2; refusal = (flags & 16) !== 0 ? 1 : 2;
  } else instruction = (flags & 1) !== 0 ? 5 : 0;
  const result = new Uint8Array(64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, instruction, true);
  out.setUint32(8, refusal, true); out.setUint32(12, mutations, true);
  out.setUint32(16, countLower, true); out.setUint32(20, countUpper, true);
  out.setUint32(24, loggedLower, true); out.setUint32(28, loggedUpper, true);
  out.setUint32(32, detailLower, true); out.setUint32(36, detailUpper, true);
  return result;
}
