/** Portable leaf command admission, payload geometry, and table row selection.
 * Appearance/metric owners remain authoritative; drawing and storage stay native. */
function nscvLeafPlans(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 49 || request[1]! > 2 || request[2] !== 1) throw new Error("invalid leaf plan header");
  if (request[1] === 1) return nscvLeafGeometry(request);
  if (request[1] === 2) return nscvLeafRows(request);
  if (request.length !== 40 || request[3]! > 9 || request[4]! > 2 || request[5]! > 127 || request[6] !== 0 || request[7] !== 0) throw new Error("invalid leaf command facts");
  for (let i = 36; i < 40; i++) if (request[i] !== 0) throw new Error("invalid leaf command tail");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), result = new Uint8Array(104), out = new DataView(result.buffer);
  const family = request[3]!, phase = request[4]!, flags = request[5]!, frame = nscvSurfaceNormalize(nscvRenderRect(w, 8));
  const text = (flags & 1) !== 0, image = (flags & 2) !== 0, cover = (flags & 4) !== 0, icon = (flags & 8) !== 0;
  const ops: number[] = [], slots: number[] = [];
  const add = (op: number, slot: number): void => { ops.push(op); slots.push(slot); };
  if (family !== 2 && phase !== 0) throw new Error("invalid leaf phase");
  if (family === 0) {
    if (image && !nscvRenderEmpty(frame)) { if (cover) add(2, 2); add(3, 1); if (cover) add(4, 0); }
  } else if (family === 1) {
    add(0, 1); if (image) { add(2, 2); add(3, 3); add(4, 0); } else if (text) add(5, 3); add(1, 4);
  } else if (family === 2) {
    if (phase === 0) { add(0, 1); add(6, 0); add(7, 0); }
    else if (phase === 1) { if (w.getFloat32(24, true) > 0) add(1, 2); }
    else { if (icon) add(8, 4); if (text) add(5, 3); }
  } else if (family === 3 || family === 4) {
    if (!nscvRenderEmpty(frame)) { add(family === 4 && (flags & 96) !== 0 ? 14 : 0, 1); if (family === 4 && (flags & 16) !== 0) add(9, 2); }
  } else if (family === 5) {
    if (!nscvRenderEmpty(frame)) { add(0, 1); add(10, 2); if (text) add(11, 3); }
  } else if (family === 6) add(0, 1);
  else if (family === 7) { if (!(w.getFloat32(24, true) <= 0)) add(0, 1); }
  else if (family === 8) { if (!nscvRenderEmpty(frame)) add(12, 2); }
  else { if (cover) add(2, 9); add(13, 0); if (cover) add(4, 0); }
  out.setUint32(0, 1, true); out.setUint32(4, ops.length, true);
  for (let i = 0; i < ops.length; i++) { out.setUint32(8 + i * 16, ops[i]!, true); out.setUint32(12 + i * 16, slots[i]!, true); nscvPrimitiveWrite(out, 16 + i * 16, nscvPrimitivePart(nscvPrimitiveWord(w, 28), { primitiveLo: slots[i]!, primitiveHi: 0 })); }
  return result;
}
function nscvLeafGeometry(request: Uint8Array): Uint8Array {
  if (request.length !== 112 || request[3]! > 8 || request[4]! > 15 || request[5]! > 31 || request[6]! > 7 || request[7]! > 3) throw new Error("invalid leaf geometry facts");
  if (wSampling(request) > 1) throw new Error("invalid leaf sampling");
  for (let i = 60; i < 76; i++) if (request[i] !== 0) throw new Error("invalid leaf geometry reserved words");
  for (let i = 80; i < 112; i++) if (request[i] !== 0) throw new Error("invalid leaf geometry tail");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), result = new Uint8Array(80), out = new DataView(result.buffer);
  const f = Math.fround, frame = nscvRenderRect(w, 8), normalized = nscvSurfaceNormalize(frame), op = request[3]!, flags = request[6]!;
  const v = (i: number): number => w.getFloat32(24 + i * 4, true);
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, request[4]!, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, request[4]!, false);
  const writeRect = (at: number, r: NscSurfaceRect): void => { out.setFloat32(at, r.x, true); out.setFloat32(at + 4, r.y, true); out.setFloat32(at + 8, r.width, true); out.setFloat32(at + 12, r.height, true); };
  out.setUint32(0, 1, true); out.setUint32(4, 1, true);
  if (op === 0) { result.set(request.subarray(8, 24), 8); result.set(request.subarray(24, 40), 24); out.setUint32(68, (flags & 4) !== 0 ? 0 : w.getUint32(76, true), true); }
  else if (op === 1) {
    const line = f(v(0) * 1.25), origin = f(frame.y + max(v(0), f(f(f(frame.height - line) * 0.5) + v(0))));
    out.setFloat32(40, f(frame.x + v(1)), true); out.setFloat32(44, origin, true);
    out.setFloat32(56, max(1, f(frame.width - f(v(1) * 2))), true); out.setFloat32(60, line, true);
  } else if (op === 2) {
    const y = f(frame.y + f(f(frame.height - v(0)) * 0.5));
    writeRect(8, { x: (flags & 1) !== 0 ? f(frame.x + v(1)) : f(frame.x + f(f(frame.width - v(0)) * 0.5)), y, width: v(0), height: v(0) });
    const shift = f(v(0) + v(2)); writeRect(24, { x: f(frame.x + shift), y: frame.y, width: max(1, f(frame.width - shift)), height: frame.height });
  } else if (op === 3 || op === 4) {
    const word = w.getUint32(24, true), signaling = (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0;
    const thickness = op === 4 && (flags & 2) !== 0 ? signaling && (request[5]! & 16) !== 0 ? v(0) : max(2, v(0)) : v(0);
    writeRect(8, op === 3 && normalized.width >= normalized.height ? { x: normalized.x, y: f(normalized.y + f(f(normalized.height - thickness) * 0.5)), width: normalized.width, height: thickness } : { x: f(normalized.x + f(f(normalized.width - thickness) * 0.5)), y: normalized.y, width: thickness, height: normalized.height });
    writeRect(24, normalized); out.setFloat32(64, thickness, true);
  } else if (op === 5) {
    writeRect(8, { x: normalized.x, y: normalized.y, width: normalized.width, height: max(v(0), v(1)) });
  } else if (op === 6) {
    let top = v(1), right = v(2), bottom = v(3), left = v(4);
    if (top === 0 && right === 0 && bottom === 0 && left === 0) { top = 7; right = 14; bottom = 7; left = 14; }
    const content = nscvSurfaceNormalize({ x: f(normalized.x + min(left, normalized.width)), y: f(normalized.y + min(top, normalized.height)), width: max(0, f(f(normalized.width - left) - right)), height: max(0, f(f(normalized.height - top) - bottom)) });
    if (nscvRenderEmpty(content)) { out.setUint32(4, 0, true); return result; }
    const line = f(v(0) * 1.25), textFrame = { x: content.x, y: f(normalized.y + max(0, f(f(normalized.height - line) * 0.5))), width: content.width, height: min(content.height, line) };
    writeRect(8, textFrame); out.setFloat32(40, textFrame.x, true); out.setFloat32(44, f(textFrame.y + max(v(0), f(f(f(textFrame.height - line) * 0.5) + v(0)))), true); out.setFloat32(56, textFrame.width, true); out.setFloat32(60, line, true);
  } else if (op === 7) {
    out.setFloat32(40, normalized.x, true); out.setFloat32(44, f(normalized.y + normalized.height), true);
    out.setFloat32(48, f(normalized.x + normalized.width), true); out.setFloat32(52, f(normalized.y + normalized.height), true);
  } else {
    out.setFloat32(64, f(frame.height * 0.5), true);
  }
  const scale = w.getFloat32(56, true), snapping = request[7]!;
  if (Number.isFinite(scale) && scale > 0) {
    const round = (x: number): number => x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5);
    const snap = (x: number): number => f(round(f(x * scale)) / scale);
    const snapRect = (at: number): void => {
      const r = nscvSurfaceNormalize(nscvRenderRect(out, at)), x = snap(r.x), y = snap(r.y);
      writeRect(at, { x, y, width: max(0, f(snap(f(r.x + r.width)) - x)), height: max(0, f(snap(f(r.y + r.height)) - y)) });
    };
    if ((snapping & 1) !== 0 && (op === 3 || op === 4 || op === 5)) { snapRect(8); if (op === 4) snapRect(24); }
    if ((snapping & 1) !== 0 && op === 7) for (let at = 40; at < 56; at += 4) out.setFloat32(at, snap(out.getFloat32(at, true)), true);
    if ((snapping & 2) !== 0 && (op === 1 || op === 6)) { out.setFloat32(40, snap(out.getFloat32(40, true)), true); out.setFloat32(44, snap(out.getFloat32(44, true)), true); }
  }
  const snappedGeometry = (snapping & 1) !== 0 && Number.isFinite(scale) && scale > 0;
  // Fields assigned without arithmetic retain the original f32 storage word.
  if (op === 2) {
    result.set(request.subarray(24, 28), 16); result.set(request.subarray(24, 28), 20);
    result.set(request.subarray(12, 16), 28); result.set(request.subarray(20, 24), 36);
  }
  if (!snappedGeometry) {
    if (op === 4) {
      if (!(frame.width < 0)) { result.set(request.subarray(8, 12), 24); result.set(request.subarray(16, 20), 32); }
      if (!(frame.height < 0)) { result.set(request.subarray(12, 16), 28); result.set(request.subarray(20, 24), 36); }
    }
    if (op === 3 || op === 4 || op === 5) {
      if (op === 3 && normalized.width >= normalized.height || op === 5) {
        if (!(frame.width < 0)) { result.set(request.subarray(8, 12), 8); result.set(request.subarray(16, 20), 16); }
      } else if (!(frame.height < 0)) { result.set(request.subarray(12, 16), 12); result.set(request.subarray(20, 24), 20); }
    }
    if (op === 7 && !(frame.width < 0)) result.set(request.subarray(8, 12), 40);
  }
  if (!snappedGeometry && (op === 3 || op === 4)) {
    const horizontal = op === 3 && normalized.width >= normalized.height;
    const word = w.getUint32(24, true), signaling = (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0;
    if (op === 3 || (flags & 2) === 0) result.set(request.subarray(24, 28), horizontal ? 20 : 16);
    // The active divider computes an extremum rather than copying thickness.
    // Targets that propagate a signaling operand quiet its payload on that operation.
    else if (signaling && (request[5]! & 16) !== 0) out.setUint32(16, word | 0x00400000, true);
  }
  if (op === 4 && (flags & 2) !== 0 && (request[5]! & 16) !== 0) {
    const word = w.getUint32(24, true);
    if ((word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0) out.setUint32(64, word | 0x00400000, true);
  }
  return result;
}
function wSampling(request: Uint8Array): number { return new DataView(request.buffer, request.byteOffset, request.byteLength).getUint32(76, true); }
function nscvLeafRows(request: Uint8Array): Uint8Array {
  if (request.length < 24 || request[3]! > 1 || request[4] !== 0 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0) throw new Error("invalid leaf row header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(8, true);
  if (request.length !== 24 + count * 16 || w.getUint32(12, true) !== 0) throw new Error("invalid leaf row shape");
  const indices: number[] = [], parent = nscvPrimitiveWord(w, 16);
  for (let i = 0; i < count; i++) {
    const at = 24 + i * 16, kind = w.getUint32(at, true), hidden = w.getUint32(at + 4, true), p = nscvPrimitiveWord(w, at + 8);
    if (kind > 62 || hidden > 1) throw new Error("invalid leaf row facts");
    if (kind === 43 && hidden === 0 && (request[3] === 0 || p.primitiveLo === parent.primitiveLo && p.primitiveHi === parent.primitiveHi)) indices.push(i);
  }
  if (indices.length > 0) indices.pop();
  const result = new Uint8Array(8 + count * 4), out = new DataView(result.buffer); out.setUint32(0, 1, true); out.setUint32(4, indices.length, true);
  for (let i = 0; i < indices.length; i++) out.setUint32(8 + i * 4, indices[i]!, true); return result;
}
