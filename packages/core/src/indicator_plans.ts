/** Portable spinner geometry, pose, trail and command identities. Appearance
 * owners resolve ink and stroke width. Native evaluates the requested sine and
 * cosine pairs with the platform math the reference uses, and draws. */

// Float32 degrees-to-radians factor, exactly as the native reference rounds it.
const nscIndicatorRadiansPerDegree = 0x8efa35 * 2 ** -29;

function nscvIndicatorPlans(request: Uint8Array): Uint8Array {
  if (request.length !== 256 || request[0] !== 51 || request[1]! > 1 || request[2] !== 1 || request[3]! > 15 || request[4]! > 1 || request[5]! > 3 || request[6]! > 31 || request[7] !== 0) throw new Error("invalid indicator plan header");
  for (let i = 84; i < 96; i++) if (request[i] !== 0) throw new Error("invalid indicator plan tail");
  for (let i = 224; i < 256; i++) if (request[i] !== 0) throw new Error("invalid indicator plan tail");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), f = Math.fround, numeric = request[3]!, flags = request[5]!;
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, false);
  const clamp = (v: number, lo: number, hi: number): number => max(lo, min(v, hi));
  // Raw signaling NaN operands follow the target's native min/max behavior.
  const signaling = (at: number): boolean => { const word = w.getUint32(at, true); return (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0; };
  const unit = (at: number): number => signaling(at) && (request[6]! & 1) !== 0 ? 0 : clamp(w.getFloat32(at, true), 0, 1);
  const positive = (at: number): number => signaling(at) && (request[6]! & 16) !== 0 ? NaN : max(0, w.getFloat32(at, true));
  const id = nscvPrimitiveWord(w, 28), count = Math.trunc(clamp(w.getUint32(52, true), 3, 15)), segmented = request[4] === 1;
  const frame = nscvRenderRect(w, 8);
  if (request[1] === 1) {
    // Motion anchors: the runtime arms loops on exactly these commands and
    // spins the arc about the pixel-snapped painted center.
    const result = new Uint8Array(160), out = new DataView(result.buffer), scale = w.getFloat32(80, true);
    let painted = frame;
    if ((flags & 2) !== 0 && Number.isFinite(scale) && scale > 0) {
      const round = (x: number): number => x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5);
      const snap = (x: number): number => f(round(f(x * scale)) / scale), r = nscvSurfaceNormalize(frame);
      const x0 = snap(r.x), y0 = snap(r.y), x1 = snap(f(r.x + r.width)), y1 = snap(f(r.y + r.height));
      painted = { x: x0, y: y0, width: max(0, f(x1 - x0)), height: max(0, f(y1 - y0)) };
    }
    painted = nscvSurfaceNormalize(painted);
    out.setUint32(0, 1, true); out.setUint32(16, count, true);
    out.setFloat32(20, f(painted.x + f(painted.width * 0.5)), true); out.setFloat32(24, f(painted.y + f(painted.height * 0.5)), true);
    nscvPrimitiveWrite(out, 28, nscvPrimitivePart(id, { primitiveLo: 2, primitiveHi: 0 }));
    for (let i = 0; i < count; i++) nscvPrimitiveWrite(out, 40 + i * 8, nscvPrimitivePart(id, { primitiveLo: 1 + i, primitiveHi: 0 }));
    return result;
  }
  const result = new Uint8Array(40 + 15 * 256), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  const normalized = nscvSurfaceNormalize(frame);
  if (nscvRenderEmpty(normalized)) return result;
  const size = signaling(16) && (request[6]! & 2) !== 0 || signaling(20) && (request[6]! & 4) !== 0 ? NaN : min(normalized.width, normalized.height);
  if (size <= 0) return result;
  const value = unit(24), radians = (degrees: number): number => f(degrees * nscIndicatorRadiansPerDegree);
  const start = f(-90 + f(value * 360)), total = 4, delta = f(288 / total);
  const angles: number[] = [];
  if (segmented) for (let segment = 0; segment < count; segment++) angles.push(radians(f(-90 + f(f(360 * segment) / count))));
  else { angles.push(radians(start)); for (let segment = 0; segment < total; segment++) angles.push(radians(f(start + f(delta * segment))), radians(f(start + f(delta * (segment + 1))))); }
  if ((flags & 1) === 0) {
    // Ask for ink, the arc stroke with its box-relative fallback, and the
    // platform sine/cosine of every angle the geometry uses.
    out.setUint32(4, 1, true); out.setFloat32(12, segmented ? 0 : f(size * f(2 / 24)), true); out.setUint32(16, angles.length, true);
    angles.forEach((angle, i) => out.setFloat32(40 + i * 4, angle, true));
    return result;
  }
  let next = 0;
  const pair = (angle: number): { sin: number; cos: number } => {
    if (next >= angles.length || angles[next] !== angle && !(Number.isNaN(angle) && Number.isNaN(angles[next]!))) throw new Error("indicator angle order changed");
    const at = 96 + next++ * 8;
    return { sin: w.getFloat32(at, true), cos: w.getFloat32(at + 4, true) };
  };
  const center = { x: f(normalized.x + f(normalized.width * 0.5)), y: f(normalized.y + f(normalized.height * 0.5)) };
  const ink = [w.getFloat32(36, true), w.getFloat32(40, true), w.getFloat32(44, true), w.getFloat32(48, true)];
  let commands = 0, cursor = 0;
  const begin = (slot: number, stroke: boolean, alpha: number): void => {
    const at = 40 + commands * 256;
    nscvPrimitiveWrite(out, at, nscvPrimitivePart(id, { primitiveLo: slot, primitiveHi: 0 }));
    out.setUint32(at + 8, stroke ? 1 : 0, true);
    for (let i = 0; i < 3; i++) out.setFloat32(at + 16 + i * 4, ink[i]!, true);
    out.setFloat32(at + 28, alpha, true);
    cursor = at + 32; commands += 1;
  };
  const element = (verb: number, ...points: number[]): void => {
    const at = 40 + (commands - 1) * 256;
    out.setUint32(at + 12, out.getUint32(at + 12, true) + 1, true);
    out.setUint32(cursor, verb, true);
    for (let i = 0; i < points.length; i++) out.setFloat32(cursor + 4 + i * 4, points[i]!, true);
    cursor += 28;
  };
  if (!segmented) {
    const radius = f(size * f(9 / 24));
    if (radius <= 0) return result;
    // The reference evaluates tan(72/4 degrees) at compile time: 0x3ea65be0.
    const kappa = f(f(f(4 / 3) * (0xa65be0 * 2 ** -25)) * radius), first = pair(radians(start));
    out.setFloat32(12, w.getFloat32(76, true), true);
    begin(2, true, ink[3]!);
    element(0, f(center.x + f(radius * first.cos)), f(center.y + f(radius * first.sin)));
    for (let segment = 0; segment < total; segment++) {
      const a0 = pair(radians(f(start + f(delta * segment)))), a1 = pair(radians(f(start + f(delta * (segment + 1)))));
      const from = { x: f(center.x + f(radius * a0.cos)), y: f(center.y + f(radius * a0.sin)) };
      const to = { x: f(center.x + f(radius * a1.cos)), y: f(center.y + f(radius * a1.sin)) };
      element(2, f(from.x - f(kappa * a0.sin)), f(from.y + f(kappa * a0.cos)), f(to.x + f(kappa * a1.sin)), f(to.y - f(kappa * a1.cos)), to.x, to.y);
    }
    out.setUint32(8, commands, true);
    return result;
  }
  const length = f(size * positive(56)), thickness = f(size * positive(60)), orbit = f(size * positive(64));
  if (length <= 0 || thickness <= 0) return result;
  const tail = unit(68), reduceMotion = w.getUint32(72, true) === 0;
  const cap = f(thickness * 0.5), half = max(f(f(length * 0.5) - cap), 0), k = f(f(0.5522847498) * cap);
  for (let segment = 0; segment < count; segment++) {
    const trig = pair(radians(f(-90 + f(f(360 * segment) / count))));
    const u = { x: trig.cos, y: trig.sin }, v = { x: -trig.sin, y: trig.cos };
    const pill = { x: f(center.x + f(orbit * u.x)), y: f(center.y + f(orbit * u.y)) };
    const inner = { x: f(pill.x - f(half * u.x)), y: f(pill.y - f(half * u.y)) }, outer = { x: f(pill.x + f(half * u.x)), y: f(pill.y + f(half * u.y)) };
    let opacity = 1;
    if (reduceMotion) {
      // The frozen pose: each step clockwise ahead of the head is one cycle fraction older.
      let distance = f(f(segment / count) - value);
      distance = f(distance - Math.floor(distance));
      let age = f(1 - distance);
      if (age >= 1) age = 0;
      opacity = f(1 - f(f(1 - tail) * age));
    }
    const a = { x: f(inner.x + f(cap * v.x)), y: f(inner.y + f(cap * v.y)) }, b = { x: f(outer.x + f(cap * v.x)), y: f(outer.y + f(cap * v.y)) };
    const outerMid = { x: f(outer.x + f(cap * u.x)), y: f(outer.y + f(cap * u.y)) }, e = { x: f(outer.x - f(cap * v.x)), y: f(outer.y - f(cap * v.y)) };
    const g = { x: f(inner.x - f(cap * v.x)), y: f(inner.y - f(cap * v.y)) }, innerMid = { x: f(inner.x - f(cap * u.x)), y: f(inner.y - f(cap * u.y)) };
    begin(1 + segment, false, clamp(f(ink[3]! * opacity), 0, 1));
    element(0, a.x, a.y);
    element(1, b.x, b.y);
    element(2, f(b.x + f(k * u.x)), f(b.y + f(k * u.y)), f(outerMid.x + f(k * v.x)), f(outerMid.y + f(k * v.y)), outerMid.x, outerMid.y);
    element(2, f(outerMid.x - f(k * v.x)), f(outerMid.y - f(k * v.y)), f(e.x + f(k * u.x)), f(e.y + f(k * u.y)), e.x, e.y);
    element(1, g.x, g.y);
    element(2, f(g.x - f(k * u.x)), f(g.y - f(k * u.y)), f(innerMid.x - f(k * v.x)), f(innerMid.y - f(k * v.y)), innerMid.x, innerMid.y);
    element(2, f(innerMid.x + f(k * v.x)), f(innerMid.y + f(k * v.y)), f(a.x - f(k * u.x)), f(a.y - f(k * u.y)), a.x, a.y);
    element(3);
  }
  out.setUint32(8, commands, true);
  return result;
}
