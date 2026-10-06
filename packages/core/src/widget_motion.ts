/** Widget motion coordination compiled by scriptc. Native supplies retained
 * facts and render samples; plans own admission, reflow, phase and retirement.
 * Identity and timestamp words are never converted to floating point.
 */
function nscvMotionSame(w: DataView, a: number, b: number): boolean {
  return w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
}
function nscvMotionBefore(w: DataView, a: number, b: number): boolean {
  const ah = w.getUint32(a + 4, true), bh = w.getUint32(b + 4, true);
  return ah < bh || ah === bh && w.getUint32(a, true) < w.getUint32(b, true);
}
function nscvMotionCopy(r: Uint8Array, at: number, out: Uint8Array, to: number, count: number): void {
  for (let i = 0; i < count; i++) out[to + i] = r[at + i]!;
}
function nscvWidgetMotion(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 18) throw new Error("invalid widget motion packet");
  const op = request[1]!, flags = request[2]!, mode = request[3]!;
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (op === 0) {
    if (request.length !== 24 || flags > 127 || mode !== 0 || w.getUint32(20, true) !== 0) throw new Error("invalid tween admission");
    const out = new Uint8Array(4), snap = (flags & 16) !== 0 || w.getUint32(4, true) === 0;
    if ((flags & 7) !== 7) { out[0] = 255; return out; }
    if ((flags & 8) !== 0) {
      if (snap) out[1] = 1;
      else {
        if (w.getFloat32(12, true) === w.getFloat32(16, true)) return out;
        out[0] = 3; out[2] = (flags & 64) !== 0 ? 1 : 0; out[3] = 1; return out;
      }
    }
    if (w.getFloat32(8, true) === w.getFloat32(12, true)) return out;
    out[0] = !snap && (flags & 32) !== 0 ? 2 : 1;
    if (out[0] === 2) { out[2] = (flags & 64) !== 0 ? 1 : 0; out[3] = 1; }
    return out;
  }
  if (op === 1) {
    if (request.length !== 16 || flags > 7 || mode !== 0 || w.getUint32(12, true) !== 0) throw new Error("invalid declared tween");
    const out = new Uint8Array(4);
    out[0] = flags === 3 && w.getUint32(4, true) !== 0 && w.getFloat32(8, true) !== 0 ? 1 : 0;
    return out;
  }
  if (op === 2) {
    if (request.length < 24 || flags > 1 || mode > 1) throw new Error("invalid disclosure header");
    const before = w.getUint32(8, true), after = w.getUint32(12, true), flips = w.getUint32(16, true), moves = w.getUint32(20, true);
    if (before > 1024 || after > 1024 || flips > 8 || moves > 256 || request.length !== 24 + (before + after) * 32) throw new Error("invalid disclosure capacity");
    for (let at = 24; at < request.length; at += 32) {
      if (request[at + 8]! > 62 || request[at + 9]! > 1 || request[at + 10]! > 1) throw new Error("invalid disclosure node");
      for (let i = 11; i < 16; i++) if (request[at + i] !== 0) throw new Error("invalid disclosure reserved byte");
    }
    const out = new Uint8Array(16 + flips * 8 + moves * 24), v = new DataView(out.buffer);
    const retire = flags === 1 ? 3 : 0, refresh = flags === 1 ? 2 : 0;
    if (before !== after) { out[0] = retire; return out; }
    for (let i = 0; i < after; i++) {
      const a = 24 + i * 32, b = 24 + before * 32 + i * 32;
      if (!nscvMotionSame(w, a, b) || request[a + 8] !== request[b + 8]) { out[0] = retire; return out; }
    }
    let flipCount = 0, moveCount = 0;
    for (let i = 0; i < after; i++) {
      const a = 24 + i * 32, b = 24 + before * 32 + i * 32, kind = request[b + 8]!;
      if (kind !== 14 || w.getUint32(b, true) === 0 && w.getUint32(b + 4, true) === 0) continue;
      if (request[a + 9] === request[b + 9] && request[b + 10] === 0) continue;
      if (flipCount === flips) { out[0] = retire; return out; }
      nscvMotionCopy(request, b, out, 16 + flipCount * 8, 8); flipCount++; v.setUint32(4, flipCount, true);
    }
    if (flipCount === 0) { out[0] = refresh; return out; }
    const duration = w.getUint32(4, true); v.setUint32(12, duration, true);
    if (mode === 1 || duration === 0) { out[0] = retire; return out; }
    for (let i = 0; i < after; i++) {
      const a = 24 + i * 32, b = 24 + before * 32 + i * 32;
      if (w.getFloat32(a + 16, true) !== w.getFloat32(b + 16, true) || w.getFloat32(a + 24, true) !== w.getFloat32(b + 24, true)) { out[0] = retire; return out; }
      if (w.getFloat32(a + 20, true) === w.getFloat32(b + 20, true) && w.getFloat32(a + 28, true) === w.getFloat32(b + 28, true)) continue;
      if (moveCount === moves) { out[0] = retire; return out; }
      const at = 16 + flips * 8 + moveCount * 24;
      v.setUint32(at, i, true);
      nscvMotionCopy(request, a + 20, out, at + 8, 4); nscvMotionCopy(request, a + 28, out, at + 12, 4);
      nscvMotionCopy(request, b + 20, out, at + 16, 4); nscvMotionCopy(request, b + 28, out, at + 20, 4);
      moveCount++; v.setUint32(8, moveCount, true);
    }
    out[0] = moveCount === 0 ? refresh : 1; return out;
  }
  if (op === 3) {
    if (request.length < 24 || flags > 1 || mode > 1 || w.getUint32(16, true) !== 0 || w.getUint32(20, true) !== 0) throw new Error("invalid drag motion header");
    const count = w.getUint32(8, true), capacity = w.getUint32(12, true);
    if (count > 1024 || capacity > 64 || request.length !== 24 + count * 48) throw new Error("invalid drag motion capacity");
    for (let at = 24; at < request.length; at += 48) if (w.getUint32(at + 8, true) > 15 || w.getUint32(at + 44, true) !== 0) throw new Error("invalid drag motion node");
    const out = new Uint8Array(8 + capacity * 16), v = new DataView(out.buffer); out[0] = flags;
    if (flags === 0 || mode === 1 || w.getUint32(4, true) === 0) return out;
    let used = 0;
    for (let i = 0; i < count; i++) {
      const at = 24 + i * 48, f = w.getUint32(at + 8, true);
      if ((f & 3) !== 3 || w.getUint32(at, true) === 0 && w.getUint32(at + 4, true) === 0) continue;
      const same = (f & 8) === 0 && w.getFloat32(at + 12, true) === w.getFloat32(at + 20, true) && w.getFloat32(at + 16, true) === w.getFloat32(at + 24, true);
      if (same && (f & 4) === 0) continue;
      const x = (f & 8) !== 0 ? w.getFloat32(at + 36, true) : Math.fround(w.getFloat32(at + 12, true) + ((f & 4) !== 0 ? w.getFloat32(at + 28, true) : 0));
      const y = (f & 8) !== 0 ? w.getFloat32(at + 40, true) : Math.fround(w.getFloat32(at + 16, true) + ((f & 4) !== 0 ? w.getFloat32(at + 32, true) : 0));
      const dx = Math.fround(x - w.getFloat32(at + 20, true)), dy = Math.fround(y - w.getFloat32(at + 24, true));
      if (!same && dx === 0 && dy === 0) continue;
      if (used === capacity) break;
      const to = 8 + used * 16; v.setUint32(to, i, true); v.setUint32(to + 4, same ? 1 : 0, true);
      v.setFloat32(to + 8, dx, true); v.setFloat32(to + 12, dy, true); used++; v.setUint32(4, used, true);
    }
    return out;
  }
  if (op === 4) {
    if (request.length !== 32 || flags !== 0 || mode > 3 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) !== 0) throw new Error("invalid motion pose");
    const out = new Uint8Array(12), v = new DataView(out.buffer), progress = w.getFloat32(4, true), done = progress >= 1;
    out[0] = done ? 1 : 0;
    for (let i = 0; i < 2; i++) {
      const from = w.getFloat32(8 + i * 8, true), to = w.getFloat32(12 + i * 8, true);
      const value = mode === 3 ? Math.fround(from * Math.fround(1 - progress)) : done && mode !== 2 ? to : Math.fround(from + Math.fround(Math.fround(to - from) * progress));
      v.setFloat32(4 + i * 4, value, true);
    }
    return out;
  }
  if (op === 5) {
    if (request.length !== 24 || flags !== 0 || mode !== 0 || w.getUint32(4, true) !== 0) throw new Error("invalid motion clock");
    const out = new Uint8Array(8), fresh = w.getUint32(8, true) === 0 && w.getUint32(12, true) === 0 || nscvMotionBefore(w, 16, 8);
    nscvMotionCopy(request, fresh ? 16 : 8, out, 0, 8); return out;
  }
  if (op === 6) {
    if (request.length !== 40 || flags > 63 || mode !== 0 || w.getUint32(4, true) !== 0 || w.getUint32(32, true) !== 0 || w.getUint32(36, true) !== 0) throw new Error("invalid caret motion");
    const out = new Uint8Array(24), v = new DataView(out.buffer);
    const desired = flags === 63;
    out[0] = (w.getUint32(8, true) !== 0 || w.getUint32(12, true) !== 0) && (!desired || !nscvMotionSame(w, 8, 16)) ? 1 : 0;
    out[1] = desired ? 1 : 0;
    if (!desired) return out;
    nscvMotionCopy(request, 16, out, 8, 8);
    const low = w.getUint32(24, true) + 500000000, high = w.getUint32(28, true) + Math.floor(low / 4294967296);
    if (high > 4294967295) throw new Error("caret clock overflow");
    v.setUint32(16, low % 4294967296, true); v.setUint32(20, high, true); return out;
  }
  if (op === 7) {
    if (request.length !== 48 || flags > 63 || mode > 2 || w.getUint32(44, true) !== 0) throw new Error("invalid loop motion");
    const count = w.getUint32(8, true), segment = w.getUint32(12, true), capacity = w.getUint32(16, true), easing = request[40]!;
    if (count > 64 || capacity > 64 || easing > 3 || request[41] !== 0 || request[42] !== 0 || request[43] !== 0 || mode === 1 && (count === 0 || segment >= count)) throw new Error("invalid loop motion segment");
    const out = new Uint8Array(32), v = new DataView(out.buffer);
    if ((flags & 31) !== 31 || (mode === 1 ? count : 1) > capacity) return out;
    out[0] = 1; out[1] = mode === 2 ? easing : 0; out[2] = mode === 2 ? 1 : 2;
    const period = mode === 2 ? 1000 : Math.max(1, w.getUint32(4, true)); v.setUint32(4, period, true);
    let lo = w.getUint32((flags & 32) !== 0 ? 24 : 32, true), hi = w.getUint32((flags & 32) !== 0 ? 28 : 36, true);
    if (mode === 1) {
      const ns = period * 1000000, nh = Math.floor(ns / 4294967296), nl = ns % 4294967296;
      if ((flags & 32) === 0) {
        if (hi < nh || hi === nh && lo < nl) { lo = 0; hi = 0; }
        else { const borrow = lo < nl ? 1 : 0; lo = (lo - nl + 4294967296) % 4294967296; hi = hi - nh - borrow; }
      }
      const delta = Math.floor(ns / count) * segment, dl = delta % 4294967296, dh = Math.floor(delta / 4294967296), sum = lo + dl;
      hi += dh + Math.floor(sum / 4294967296); lo = sum % 4294967296;
      if (hi > 4294967295) throw new Error("loop clock overflow");
    }
    v.setUint32(8, lo, true); v.setUint32(12, hi, true);
    v.setFloat32(16, mode === 0 ? 0 : 1, true);
    v.setFloat32(20, mode === 0 ? 360 : mode === 2 ? 0.5 : Math.min(1, Math.max(0, w.getFloat32(20, true))), true);
    return out;
  }
  if (op === 8) {
    if (request.length < 16 || flags !== 0 || mode !== 0 || w.getUint32(12, true) !== 0) throw new Error("invalid loop retirement header");
    const before = w.getUint32(4, true), after = w.getUint32(8, true);
    if (before > 64 || after > 64 || request.length !== 16 + (before + after) * 8) throw new Error("invalid loop retirement capacity");
    const out = new Uint8Array(4 + before * 4), v = new DataView(out.buffer);
    let count = 0;
    for (let i = 0; i < before; i++) {
      let keep = false;
      for (let j = 0; j < after; j++) if (nscvMotionSame(w, 16 + i * 8, 16 + before * 8 + j * 8)) { keep = true; break; }
      if (!keep) { v.setUint32(4 + count * 4, i, true); count++; }
    }
    v.setUint32(0, count, true); return out;
  }
  throw new Error("invalid widget motion operation");
}
