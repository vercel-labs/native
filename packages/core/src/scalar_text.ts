// Scalar text decisions over copied font facts. Font table lookup and OS
// measurement are explicit capabilities; no host pointer crosses this seam.
function nscvScalarTextSequence(byte: number): number { return (byte & 128) === 0 ? 1 : (byte & 224) === 192 ? 2 : (byte & 240) === 224 ? 3 : (byte & 248) === 240 ? 4 : 1; }
// The reserved mono estimator has no font capability. Keep every f32 add,
// including the distinction between a cluster's -0 and a run's initial +0.
function nscvScalarTextMonoWidth(text: Uint8Array, first: number, last: number, size: number, cluster: boolean): number {
  if (first === last) return 0;
  const advance = Math.fround(size * Math.fround(0.6));
  if (cluster) return advance;
  let width = 0;
  while (first < last) { width = Math.fround(width + advance); first = Math.min(last, first + nscvScalarTextSequence(text[first]!)); }
  return width;
}
function nscvScalarTextCodepoint(text: Uint8Array, first: number, last: number): number {
  const length = last - first, lead = text[first]!;
  if (length === 1) return lead >= 32 && lead < 127 ? lead : -1;
  if (length !== nscvScalarTextSequence(lead)) return -1;
  let cp = lead & (length === 2 ? 31 : length === 3 ? 15 : 7);
  for (let i = first + 1; i < last; i++) { const byte = text[i]!; if ((byte & 192) !== 128) return -1; cp = cp * 64 + (byte & 63); }
  if (cp < (length === 2 ? 128 : length === 3 ? 2048 : 65536) || cp > 1114111 || cp >= 55296 && cp <= 57343) return -1;
  return cp;
}
function nscvScalarTextWide(cp: number): boolean {
  return cp >= 0x1100 && cp <= 0x115f || cp >= 0x2e80 && cp <= 0x303e || cp >= 0x3041 && cp <= 0x33ff ||
    cp >= 0x3400 && cp <= 0x4dbf || cp >= 0x4e00 && cp <= 0x9fff || cp >= 0xa000 && cp <= 0xa4cf ||
    cp >= 0xa960 && cp <= 0xa97f || cp >= 0xac00 && cp <= 0xd7a3 || cp >= 0xf900 && cp <= 0xfaff ||
    cp >= 0xfe10 && cp <= 0xfe19 || cp >= 0xfe30 && cp <= 0xfe6f || cp >= 0xff00 && cp <= 0xff60 ||
    cp >= 0xffe0 && cp <= 0xffe6 || cp >= 0x1f300 && cp <= 0x1faff || cp >= 0x20000 && cp <= 0x3fffd;
}
function nscvScalarText(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 60 || request[1] !== 1 || request[2]! > 3 || request[3]! > 1)
    throw new Error("invalid scalar text header");
  const mode = request[2]!, phase = request[3]!, facts = mode === 1 || mode === 2;
  const out = request.slice(), w = new DataView(out.buffer), length = w.getUint32(8, true), slots = w.getUint32(12, true);
  if (w.getUint32(4, true) > 1 || slots !== (facts ? length : 0) || request.length !== 64 + slots * 8 + (facts ? length : 0) || w.getUint32(60, true) !== 0)
    throw new Error("invalid scalar text storage");
  const size = w.getFloat32(24, true), notdef = w.getFloat32(28, true);
  if (phase === 0) {
    for (let at = 32; at < 60; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid initial scalar text state");
    if (facts) for (let at = 64; at < 64 + slots * 8; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid initial scalar text facts");
  } else if (w.getUint32(56, true) !== (facts ? 3 : 2) || w.getUint32(36, true) > slots || !facts && w.getUint32(36, true) !== 0) {
    throw new Error("invalid scalar text continuation");
  }
  if (!facts) {
    if (length === 0 || w.getUint32(4, true) === 0 && mode === 3) { out[3] = 2; w.setUint32(56, 0, true); return out; }
    if (phase === 0 && w.getUint32(4, true) === 1) { out[3] = 1; w.setUint32(56, 2, true); return out; }
    out[3] = 2;
    if (mode === 0) { const value = w.getFloat32(32, true); w.setUint32(56, phase === 1 && value >= 0 && Number.isFinite(value) ? 0 : 1, true); }
    else {
      const a = w.getFloat32(40, true), b = w.getFloat32(44, true), c = w.getFloat32(48, true), d = w.getFloat32(52, true);
      w.setUint32(56, w.getUint32(32, true) === 1 && Number.isFinite(a) && Number.isFinite(b) && Number.isFinite(c) && Number.isFinite(d) && b >= a && d >= c ? 1 : 0, true);
    }
    return out;
  }
  const text = out.subarray(64 + slots * 8), mono = w.getUint32(16, true) === 2 && w.getUint32(20, true) === 0;
  if (mono) {
    // No glyph facts are requested or populated for the reserved mono face.
    // Scan the source directly instead of writing one unused fact per byte.
    out[3] = 2; w.setUint32(56, 0, true);
    w.setFloat32(32, nscvScalarTextMonoWidth(text, 0, length, size, mode === 2), true);
    return out;
  }
  const font = w.getUint32(20, true) === 0 ? w.getUint32(16, true) : 0;
  const factor = Math.fround(font === 3 ? 1.02 : font === 4 || font === 6 ? 1.04 : 1);
  let count = w.getUint32(36, true);
  if (phase === 0) {
    count = 0; let first = 0;
    while (first < length) {
      const last = mode === 2 ? length : Math.min(length, first + nscvScalarTextSequence(text[first]!));
      const cp = nscvScalarTextCodepoint(text, first, last), at = 64 + count * 8;
      w.setUint32(at, cp < 0 ? 0xffffffff : cp, true);
      w.setFloat32(at + 4, cp >= 0 && nscvScalarTextWide(cp) ? 1 : cp >= 0x2190 && cp <= 0x2bff ? Math.fround(0.8) : notdef, true);
      count++; first = last;
    }
    w.setUint32(36, count, true);
    if (count > 0) { out[3] = 1; w.setUint32(56, 3, true); return out; }
  }
  let width = 0;
  for (let i = 0; i < count; i++) {
    const advance = Math.fround(Math.fround(size * w.getFloat32(64 + i * 8 + 4, true)) * factor);
    width = mode === 2 ? advance : Math.fround(width + advance);
  }
  out[3] = 2; w.setUint32(56, 0, true); w.setFloat32(32, width, true); return out;
}
