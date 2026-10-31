/** Shared frame-clock sampling compiled by scriptc. The host answers only
 * scalar float32 math requests; phase, easing and channel decisions live here.
 * Each continuation requests all currently available primitives in one batch.
 */
function nscvSamplePhase(w: DataView, at: number, now: number): number {
  const duration = w.getUint32(at + 16, true);
  if (duration === 0) return 1;
  const sl = w.getUint32(at + 8, true), sh = w.getUint32(at + 12, true);
  const nl = w.getUint32(now, true), nh = w.getUint32(now + 4, true);
  if (nh < sh || nh === sh && nl <= sl) return 0;
  const low = nl >= sl ? nl - sl : nl + 4294967296 - sl;
  const high = nh - sh - (nl < sl ? 1 : 0), span = duration * 1000000;
  const loop = w.getUint32(at + 24, true), f = Math.fround;
  if (loop === 0) {
    if (high > Math.floor(span / 4294967296) || high === Math.floor(span / 4294967296) && low >= span % 4294967296) return 1;
    return f(f(high * 4294967296 + low) / f(span));
  }
  const divisor = loop === 1 ? span * 2 : span;
  let remainder = 0;
  // Doubling a remainder directly can exceed the exact-number range even
  // though the divisor fits. Subtract first, keeping each intermediate exact.
  for (let bit = 63; bit >= 0; bit--) {
    remainder = remainder >= divisor / 2 ? remainder - (divisor - remainder) : remainder * 2;
    remainder += ((bit >= 32 ? high >>> (bit - 32) : low >>> bit) & 1);
    if (remainder >= divisor) remainder -= divisor;
  }
  const backward = loop === 1 && remainder >= span;
  const sweep = f(f(backward ? remainder - span : remainder) / f(span));
  return backward ? f(1 - sweep) : sweep;
}
function nscvSampleLerp(a: number, b: number, t: number): number {
  return Math.fround(a + Math.fround(Math.fround(b - a) * t));
}
function nscvMotionSampling(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 73 || request[1] !== 1 || request[2]! > 1 || request[3]! > 15) throw new Error("invalid motion sampling header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = w.getUint32(4, true), capacity = w.getUint32(8, true), mode = request[2]!, flags = request[3]!;
  if (request.length !== 32 + count * 144 || w.getUint32(12, true) !== 0 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0 || mode === 1 && (count !== 1 || capacity !== 1)) throw new Error("invalid motion sampling shape");
  for (let i = 0; i < count; i++) {
    const at = 32 + i * 144;
    if (w.getUint32(at + 20, true) > 3 || w.getUint32(at + 24, true) > 2 || w.getUint32(at + 28, true) > 63 || w.getUint32(at + 116, true) > 31 || w.getUint32(at + 140, true) !== 0) throw new Error("invalid motion sampling record");
  }
  const samples = new Uint8Array(Math.min(count, capacity) * 48), s = new DataView(samples.buffer);
  const primitives = new Uint8Array(count * 32), p = new DataView(primitives.buffer);
  const f = Math.fround, clamp = (v: number): number => nscvRenderExtreme(0, nscvRenderExtreme(v, 1, flags, false), flags, true);
  let used = 0, needed = 0, full = false;
  for (let i = 0; i < count; i++) {
    const at = 32 + i * 144, mask = w.getUint32(at + 28, true);
    if (mode === 0 && (w.getUint32(at, true) === 0 && w.getUint32(at + 4, true) === 0 || (mask & 3) !== 3 && (mask & 12) !== 12 && (mask & 48) !== 48)) continue;
    const cache = w.getUint32(at + 116, true);
    const need = (slot: number, op: number, argument: number): void => {
      const to = needed * 16;
      p.setUint32(to, i, true); p.setUint32(to + 4, slot, true); p.setUint32(to + 8, op, true); p.setFloat32(to + 12, argument, true); needed++;
    };
    let t = clamp(nscvSamplePhase(w, at, 16)), ready = true;
    const easing = w.getUint32(at + 20, true);
    if (easing === 1) t = f(f(t * t) * f(3 - f(2 * t)));
    else if (easing === 2) { const x = f(1 - t); t = f(1 - f(f(x * x) * x)); }
    else if (easing === 3 && t > 0 && t < 1) {
      const mass = nscvRenderExtreme(f(0.001), w.getFloat32(at + 32, true), flags, true);
      const stiffness = nscvRenderExtreme(1, w.getFloat32(at + 36, true), flags, true);
      const damping = nscvRenderExtreme(f(0.001), w.getFloat32(at + 40, true), flags, true);
      if ((cache & 1) === 0) { need(0, 3, f(stiffness / mass)); ready = false; }
      if ((cache & 2) === 0) { need(1, 0, f(f(-damping * t) / f(mass * 24))); ready = false; }
      if ((cache & 1) !== 0 && (cache & 4) === 0) { need(2, 1, f(w.getFloat32(at + 120, true) * t)); ready = false; }
      if (ready) t = clamp(f(1 - f(w.getFloat32(at + 124, true) * w.getFloat32(at + 128, true))));
    }
    let rotation: NscRenderAffine | null = null;
    if (ready && mode === 0 && (mask & 48) === 48) {
      const radians = f(nscvSampleLerp(w.getFloat32(at + 100, true), w.getFloat32(at + 104, true), t) * f(0.017453292519943295));
      if ((cache & 8) === 0) { need(3, 1, radians); ready = false; }
      if ((cache & 16) === 0) { need(4, 2, radians); ready = false; }
      if (ready) {
        const c = w.getFloat32(at + 132, true), sin = w.getFloat32(at + 136, true), x = w.getFloat32(at + 108, true), y = w.getFloat32(at + 112, true);
        rotation = nscvRenderMultiply(nscvRenderMultiply({ a: 1, b: 0, c: 0, d: 1, tx: x, ty: y }, { a: c, b: sin, c: -sin, d: c, tx: 0, ty: 0 }), { a: 1, b: 0, c: 0, d: 1, tx: -x, ty: -y });
      }
    }
    if (used === capacity) { full = true; break; }
    if (ready) {
      const to = used * 48;
      s.setUint32(to, i, true);
      s.setUint32(to + 8, w.getUint32(at, true), true); s.setUint32(to + 12, w.getUint32(at + 4, true), true);
      let outputMask = mode === 1 || (mask & 3) === 3 ? 1 : 0;
      if (outputMask !== 0) s.setFloat32(to + 20, mode === 1 ? t : nscvSampleLerp(w.getFloat32(at + 44, true), w.getFloat32(at + 48, true), t), true);
      let transform: NscRenderAffine | null = null;
      if (mode === 0 && (mask & 12) === 12) {
        transform = { a: nscvSampleLerp(w.getFloat32(at + 52, true), w.getFloat32(at + 76, true), t), b: nscvSampleLerp(w.getFloat32(at + 56, true), w.getFloat32(at + 80, true), t), c: nscvSampleLerp(w.getFloat32(at + 60, true), w.getFloat32(at + 84, true), t), d: nscvSampleLerp(w.getFloat32(at + 64, true), w.getFloat32(at + 88, true), t), tx: nscvSampleLerp(w.getFloat32(at + 68, true), w.getFloat32(at + 92, true), t), ty: nscvSampleLerp(w.getFloat32(at + 72, true), w.getFloat32(at + 96, true), t) };
      }
      transform = transform === null ? rotation : rotation === null ? transform : nscvRenderMultiply(transform, rotation);
      if (transform !== null) { outputMask |= 2; nscvRenderPutAffine(s, to + 24, transform); }
      s.setUint32(to + 16, outputMask, true);
    }
    used++;
  }
  const out = new Uint8Array(32 + (needed > 0 ? needed * 16 : used * 48)), v = new DataView(out.buffer);
  v.setUint32(0, 1, true); v.setUint32(4, needed > 0 ? 1 : full ? 2 : 0, true);
  v.setUint32(8, needed > 0 ? needed : used, true);
  out.set(needed > 0 ? primitives.subarray(0, needed * 16) : samples.subarray(0, used * 48), 32);
  return out;
}
