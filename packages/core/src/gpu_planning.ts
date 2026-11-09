/** GPU command admission and ordered encoder programs over copied facts.
 * Payloads, measurement contexts, resources, and output storage stay native.
 * Modes: packet, packet summary, encoder, encoder summary. */
function nscvGpuPlanning(request: Uint8Array): Uint8Array {
  if (request.length < 96 || request[0] !== 65 || request[1] !== 1 || request[2]! > 3 || request[3]! > 15)
    throw new Error("invalid GPU planning header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, count = w.getUint32(4, true), capacity = w.getUint32(8, true), flags = w.getUint32(12, true);
  const glyphs = w.getUint32(16, true), batches = w.getUint32(20, true);
  if (flags > 3 || count > Math.floor((request.length - 96) / 64) ||
      request.length !== 96 + count * 64 + glyphs * 4 + batches * 4 ||
      mode < 2 && batches !== 0 || mode >= 2 && (count !== 0 || glyphs !== 0))
    throw new Error("invalid GPU planning shape");
  for (let at = 72; at < 96; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid GPU planning tail");
  if ((flags & 2) === 0) for (let at = 56; at < 72; at += 4)
    if (w.getUint32(at, true) !== 0) throw new Error("invalid absent GPU scissor");
  const load = flags === 0 ? 0 : (flags & 1) !== 0 ? 2 : 1;
  let caches = 0;
  for (let family = 0; family < 8; family++) caches += w.getUint32(24 + family * 4, true);
  if (caches > 4294967295) throw new Error("GPU cache counts exceed wire range");
  if (mode >= 2) return nscvGpuEncoder(request, w, mode, capacity, load, caches, batches);
  const glyphStart = 96 + count * 64;
  let nextGlyph = 0;
  for (let i = 0; i < count; i++) {
    const at = 96 + i * 64, tag = w.getUint32(at, true), fill = w.getUint32(at + 4, true);
    const usesFill = tag >= 5 && tag <= 10;
    if (tag > 14 || (usesFill ? fill > 1 : fill !== 4294967295) || w.getUint32(at + 8, true) > 1 ||
        w.getUint32(at + 12, true) !== nextGlyph || w.getUint32(at + 28, true) !== 0 || w.getUint32(at + 24, true) > 2)
      throw new Error("invalid GPU command facts");
    const size = w.getUint32(at + 16, true);
    if (tag !== 12 && (size !== 0 || w.getUint32(at + 8, true) !== 0) || size > glyphs - nextGlyph)
      throw new Error("invalid GPU glyph facts");
    nextGlyph += size;
  }
  if (nextGlyph !== glyphs) throw new Error("incomplete GPU glyph facts");
  const summary = mode === 1;
  const output = new Uint8Array(32 + (summary ? 0 : Math.min(count, capacity) * 32)), out = new DataView(output.buffer);
  out.setUint32(0, 1, true); out.setUint32(12, load, true);
  if (load === 0) return output.slice(0, 32);
  out.setUint32(24, caches, true);
  const scissor = nscvResourceNormalize(nscvResourceRect(w, 56));
  let written = 0, unsupported = 0, cached = 0;
  for (let i = 0; i < count; i++) {
    const at = 96 + i * 64;
    if ((flags & 2) !== 0) {
      const bounds = nscvResourceNormalize(nscvResourceRect(w, at + 48));
      if (!nscvGpuIntersects(bounds, scissor, request[3]!)) continue;
    }
    if (!summary && written >= capacity) { out.setUint32(8, 1, true); break; }
    const tag = w.getUint32(at, true), fill = w.getUint32(at + 4, true);
    let kind = 14, pipeline = 4294967295, uses = 0;
    if (tag >= 5 && tag <= 8) {
      kind = (tag === 5 ? 0 : tag === 7 ? 2 : tag === 6 ? 4 : 6) + fill;
      pipeline = fill; uses = fill === 1 ? 4 : 0;
    } else if (tag === 9 || tag === 10) { kind = tag - 1; pipeline = 4; uses = 1 | (fill === 1 ? 4 : 0); }
    else if (tag === 11) { kind = 10; pipeline = 2; uses = 6; }
    else if (tag === 12) {
      let supported = true;
      const start = w.getUint32(at + 12, true), size = w.getUint32(at + 16, true);
      for (let j = 0; j < size; j++) if (w.getUint32(glyphStart + (start + j) * 4, true) > 65535) supported = false;
      if (supported) { kind = 11; pipeline = 3; uses = 20 | (w.getUint32(at + 8, true) === 1 ? 32 : 0); }
    } else if (tag >= 13) { kind = tag - 1; pipeline = tag - 8; uses = 12; }
    if (kind === 14) unsupported++;
    if (uses !== 0) cached++;
    if (!summary) {
      const dest = 32 + written * 32;
      out.setUint32(dest, i, true); out.setUint32(dest + 4, kind, true);
      out.setUint32(dest + 8, pipeline, true); out.setUint32(dest + 12, uses, true);
      nscvResourcePutRect(out, dest + 16, nscvResourceNormalize(nscvResourceRect(w, at + 32)));
    }
    written++;
  }
  out.setUint32(4, written, true); out.setUint32(16, unsupported, true); out.setUint32(20, cached, true);
  return summary ? output : output.slice(0, 32 + written * 32);
}

function nscvGpuEncoder(request: Uint8Array, w: DataView, mode: number, capacity: number, load: number, caches: number, batches: number): Uint8Array {
  let binds = 0, previous = 4294967295;
  for (let i = 0; i < batches; i++) {
    const pipeline = w.getUint32(96 + i * 4, true);
    if (pipeline > 6) throw new Error("invalid GPU encoder pipeline");
    if (pipeline !== previous) binds++;
    previous = pipeline;
  }
  const count = load === 0 ? 0 : 2 + ((w.getUint32(12, true) & 2) !== 0 ? 1 : 0) + caches + binds + batches;
  if (count > 4294967295) throw new Error("GPU encoder count exceeds wire range");
  const summary = mode === 3, output = new Uint8Array(32 + (summary ? 0 : Math.min(capacity, count) * 8));
  const out = new DataView(output.buffer); out.setUint32(0, 1, true); out.setUint32(12, load, true);
  if (load === 0) return output;
  out.setUint32(16, caches, true); out.setUint32(20, binds, true); out.setUint32(24, batches, true);
  if (summary) { out.setUint32(4, count, true); return output; }
  let written = 0;
  const emit = (opcode: number, argument: number): boolean => {
    if (written >= capacity) { out.setUint32(8, 1, true); return false; }
    out.setUint32(32 + written * 8, opcode, true); out.setUint32(36 + written * 8, argument, true); written++; return true;
  };
  let complete = emit(0, 0);
  if (complete && (w.getUint32(12, true) & 2) !== 0) complete = emit(1, 0);
  for (let family = 0; family < 8 && complete; family++) {
    const size = w.getUint32(24 + family * 4, true);
    for (let i = 0; i < size; i++) if (!emit(2 + family, i)) { complete = false; break; }
  }
  previous = 4294967295;
  for (let i = 0; i < batches && complete; i++) {
    const pipeline = w.getUint32(96 + i * 4, true);
    if (pipeline !== previous) complete = emit(10, pipeline);
    if (complete) complete = emit(11, i);
    previous = pipeline;
  }
  if (complete) emit(12, 0);
  out.setUint32(4, written, true);
  return output.slice(0, 32 + written * 8);
}

function nscvGpuIntersects(a: NscResourceRect, b: NscResourceRect, rules: number): boolean {
  if (a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0) return false;
  const f = Math.fround;
  const x = nscvResourceExtremum(a.x, b.x, true, rules), y = nscvResourceExtremum(a.y, b.y, true, rules);
  const right = nscvResourceExtremum(f(a.x + a.width), f(b.x + b.width), false, rules);
  const bottom = nscvResourceExtremum(f(a.y + a.height), f(b.y + b.height), false, rules);
  if (right <= x || bottom <= y) return false;
  return !(f(right - x) <= 0 || f(bottom - y) <= 0);
}
