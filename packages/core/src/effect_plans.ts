/** Portable container washes, backdrop blur, modal scrims and child clip radii.
 * Appearance and surface owners resolve colors and radii; drawing stays native. */
function nscvEffectPlans(request: Uint8Array): Uint8Array {
  if (request.length !== 128 || request[0] !== 52 || request[1]! > 3 || request[2] !== 1 || request[3]! > 15) throw new Error("invalid effect plan header");
  if (request[4]! > 31) throw new Error("invalid effect plan header");
  for (let i = 5; i < 8; i++) if (request[i] !== 0) throw new Error("invalid effect plan header");
  for (let i = 120; i < 128; i++) if (request[i] !== 0) throw new Error("invalid effect plan tail");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), facts = w.getUint32(8, true), kind = w.getUint32(100, true);
  if (facts > 0xfffe || (facts & 1) !== 0 || kind > 62) throw new Error("invalid effect plan facts");
  const numeric = request[3]!, has = (bit: number): boolean => (facts & (1 << bit)) !== 0;
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  // Raw signaling NaN operands follow the target's native max(0, x) behavior.
  const positive = (at: number): number => {
    const word = w.getUint32(at, true), signaling = (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0;
    return signaling && (request[4]! & 16) !== 0 ? NaN : max(0, w.getFloat32(at, true));
  };
  const result = new Uint8Array(112), out = new DataView(result.buffer), id = nscvPrimitiveWord(w, 12), frame = nscvRenderRect(w, 20);
  out.setUint32(0, 1, true);
  let commands = 0;
  // Operations: 0 rounded fill, 1 region blur, 2 rectangle fill.
  const emit = (slot: number, op: number, rect: NscSurfaceRect, radius: number, colorAt: number): void => {
    const at = 16 + commands * 48;
    nscvPrimitiveWrite(out, at, nscvPrimitivePart(id, { primitiveLo: slot, primitiveHi: 0 }));
    out.setUint32(at + 8, op, true); nscvRenderPutRect(out, at + 12, rect); out.setFloat32(at + 28, radius, true);
    if (colorAt !== 0) result.set(request.subarray(colorAt, colorAt + 16), at + 32);
    commands += 1; out.setUint32(8, commands, true);
  };
  const mode = request[1]!;
  if (mode === 0) {
    // Containers: authored rest fill, or the list-row feedback ladder when actionable.
    const actionable = (id.primitiveLo !== 0 || id.primitiveHi !== 0) && !has(1) && (has(2) || has(3) || has(4));
    if (!actionable) {
      if (!has(5) || w.getFloat32(48, true) <= 0) return result;
      emit(1, 0, frame, has(10) ? positive(52) : 0, 36);
      return result;
    }
    if (!has(5) && !has(6) && !has(7) && !(has(8) && !has(9))) return result;
    if (!has(15)) { out.setUint32(4, 1, true); return result; }
    if (w.getFloat32(116, true) <= 0) return result;
    emit(1, 0, frame, has(10) ? positive(52) : 0, 104);
    return result;
  }
  if (mode === 1) {
    const explicit = positive(56), radius = explicit > 0 ? explicit : has(12) ? positive(60) : 0;
    out.setFloat32(12, radius, true);
    if (radius <= 0 || nscvRenderEmpty(nscvSurfaceNormalize(frame))) return result;
    emit(12, 1, frame, radius, 0);
    return result;
  }
  if (mode === 2) {
    const blur = positive(80);
    const emits = has(11) && (kind === 19 || kind === 20 || kind === 21) && (w.getFloat32(76, true) > 0 || blur > 0);
    out.setUint32(12, emits ? 1 : 0, true);
    if (!emits) return result;
    const viewport = has(14) ? nscvRenderRect(w, 84) : nscvSurfaceNormalize(frame);
    if (nscvRenderEmpty(viewport)) return result;
    if (blur > 0) emit(13, 1, viewport, blur, 0);
    if (w.getFloat32(76, true) > 0) emit(14, 2, viewport, 0, 64);
    return result;
  }
  // Child clips follow their surface chrome: 1 bubble capsule, 2-4 the lg/xl/md control radius.
  let source = 0;
  if (has(13)) {
    if (kind === 15) source = 1;
    else if (kind === 17 || kind === 18 || kind === 16 || kind === 22 || kind === 24 || kind === 25 || kind === 21) source = 2;
    else if (kind === 19 || kind === 20 || kind === 23) source = 3;
    else if (kind === 40) source = 4;
  }
  out.setUint32(12, source, true);
  return result;
}
