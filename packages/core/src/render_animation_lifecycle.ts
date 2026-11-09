/** Render-animation admission, retirement, and replacement damage. Clocks,
 * retained records, command bounds, and buffer lifetime are native capabilities.
 * Bounds are requested in reference order, including repeated targets. */
function nscvAnimationIdentity(w: DataView, at: number): boolean {
  return w.getFloat32(at, true) === 1 && w.getFloat32(at + 4, true) === 0 &&
    w.getFloat32(at + 8, true) === 0 && w.getFloat32(at + 12, true) === 1 &&
    w.getFloat32(at + 16, true) === 0 && w.getFloat32(at + 20, true) === 0;
}
function nscvAnimationId(w: DataView, at: number): boolean {
  return w.getUint32(at, true) !== 0 || w.getUint32(at + 4, true) !== 0;
}
function nscvAnimationSame(w: DataView, a: number, b: number): boolean {
  return w.getUint32(a, true) === w.getUint32(b, true) && w.getUint32(a + 4, true) === w.getUint32(b + 4, true);
}
function nscvAnimationActive(w: DataView, at: number): boolean {
  const duration = w.getUint32(at + 16, true);
  if (!nscvAnimationId(w, at) || duration === 0) return false;
  if (w.getUint32(at + 20, true) !== 0) return true;
  const low = w.getUint32(20, true), high = w.getUint32(24, true);
  const startLow = w.getUint32(at + 8, true), startHigh = w.getUint32(at + 12, true);
  if (high < startHigh || high === startHigh && low <= startLow) return true;
  const borrow = low < startLow ? 1 : 0;
  const elapsedLow = low - startLow + borrow * 4294967296, elapsedHigh = high - startHigh - borrow;
  // A u32 millisecond duration fits exactly in a JavaScript number. The
  // elapsed u64 never becomes one: compare its two words independently.
  const span = duration * 1000000, spanHigh = Math.floor(span / 4294967296), spanLow = span - spanHigh * 4294967296;
  return elapsedHigh < spanHigh || elapsedHigh === spanHigh && elapsedLow < spanLow;
}
function nscvAnimationLifecycle(request: Uint8Array): Uint8Array {
  if (request.length < 80 || request[0] !== 72 || request[1] !== 1 || request[2]! > 3 || request[3]! > 15)
    throw new Error("invalid render animation header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, animations = w.getUint32(4, true), overrides = w.getUint32(8, true), commands = w.getUint32(12, true);
  const capacity = w.getUint32(16, true);
  if (w.getUint32(28, true) !== 0) throw new Error("invalid render animation reserved word");
  if (mode === 3) {
    if (request[3] !== 0 || w.getUint32(20, true) !== 0 || w.getUint32(24, true) !== 0) throw new Error("invalid animation admission facts");
    for (let at = 32; at < 80; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid animation admission tail");
    if (request.length !== 80 + (animations > capacity ? 0 : animations * 8)) throw new Error("invalid animation admission shape");
    const result = new Uint8Array(32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
    if (animations > capacity) out.setUint32(4, 1, true);
    else {
      for (let i = 0; i < animations; i++) if (!nscvAnimationId(w, 80 + i * 8)) { out.setUint32(4, 2, true); break; }
      if (animations === 0 && overrides === 0 && commands === 0) out.setUint32(8, 1, true);
    }
    return result;
  }
  if (capacity !== 0 || mode === 0 && (overrides !== 0 || commands !== 0) || mode === 1 && (animations !== 0 || commands !== 0) ||
      animations > Math.floor((request.length - 80) / 112) || overrides > Math.floor((request.length - 80 - animations * 112) / 40) ||
      request.length !== 80 + animations * 112 + overrides * 40 + commands * 16)
    throw new Error("invalid render animation shape");
  for (let i = 0; i < animations; i++) {
    const at = 80 + i * 112;
    if (w.getUint32(at + 20, true) > 2 || w.getUint32(at + 24, true) > 15) throw new Error("invalid render animation record");
    for (let end = at + 88; end < at + 112; end += 4) if (w.getUint32(end, true) !== 0) throw new Error("invalid animation record tail");
  }
  const overrideStart = 80 + animations * 112, commandStart = overrideStart + overrides * 40;
  for (let i = 0; i < overrides; i++) if (w.getUint32(overrideStart + i * 40 + 8, true) > 3) throw new Error("invalid animation override mask");
  for (let i = 0; i < commands; i++) if (w.getUint32(commandStart + i * 16 + 8, true) > 1 || w.getUint32(commandStart + i * 16 + 12, true) !== 0)
    throw new Error("invalid animation command identity");
  if (mode === 2) return nscvAnimationSchedule(request, w, animations, overrides, commands, overrideStart, commandStart);
  if (request[3] !== 0) throw new Error("invalid lifecycle numeric flags");
  for (let at = 32; at < 80; at += 4) if (w.getUint32(at, true) !== 0) throw new Error("invalid lifecycle continuation");
  const count = mode === 0 ? animations : overrides, result = new Uint8Array(32 + count), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, count, true);
  let active = false, pruned = false;
  for (let i = 0; i < count; i++) {
    const at = mode === 0 ? 80 + i * 112 : overrideStart + i * 40;
    const mask = w.getUint32(at + (mode === 0 ? 24 : 8), true);
    const noop = ((mask & 1) === 0 || w.getFloat32(at + (mode === 0 ? 28 : 12), true) === 1) &&
      ((mask & (mode === 0 ? 4 : 2)) === 0 || nscvAnimationIdentity(w, at + (mode === 0 ? 56 : 16)));
    const running = mode === 0 && nscvAnimationActive(w, at), keep = mode === 0 ? running || !noop : !noop;
    result[32 + i] = (keep ? 1 : 0) | (running ? 2 : 0);
    active = active || running; pruned = pruned || !keep;
  }
  out.setUint32(8, active ? 1 : 0, true); out.setUint32(12, pruned ? 1 : 0, true);
  return result;
}
function nscvAnimationSchedule(request: Uint8Array, w: DataView, animations: number, overrides: number, commands: number, overrideStart: number, commandStart: number): Uint8Array {
  const count = animations + overrides, flags = request[3]!;
  let cursor = w.getUint32(32, true), bounds = nscvRenderOptional(w, 36);
  const answer = w.getUint32(56, true), present = w.getUint32(60, true);
  if (cursor > count || w.getUint32(36, true) > 1 || present > 1 || answer !== 4294967295 && answer >= commands)
    throw new Error("invalid animation bounds continuation");
  if (cursor === 0 && w.getUint32(36, true) !== 0) throw new Error("invalid initial animation bounds");
  const result = new Uint8Array(64), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  let consumed = false;
  const include = (rect: NscSurfaceRect): void => {
    bounds = bounds === null ? nscvSurfaceNormalize(rect) : nscvRenderUnion(bounds, rect, flags);
  };
  for (; cursor < count; cursor++) {
    const old = cursor < overrides, at = old ? overrideStart + cursor * 40 : 80 + (cursor - overrides) * 112;
    if (!nscvAnimationId(w, at)) continue;
    let source = -1;
    for (let i = 0; i < commands; i++) {
      const commandAt = commandStart + i * 16;
      if (w.getUint32(commandAt + 8, true) !== 0 && nscvAnimationSame(w, at, commandAt)) { source = i; break; }
    }
    if (source < 0) continue;
    if (answer === 4294967295 || consumed) {
      out.setUint32(4, 1, true); out.setUint32(8, cursor, true); out.setUint32(12, source, true);
      nscvRenderPutOptional(out, 16, bounds); return result;
    }
    if (answer !== source) throw new Error("mismatched animation bounds capability");
    consumed = true;
    if (present === 0) continue;
    const rect = nscvRenderRect(w, 64); include(rect);
    const mask = w.getUint32(at + (old ? 8 : 24), true);
    if (old) {
      if ((mask & 2) !== 0) include(nscvRenderTransform(nscvRenderAffine(w, at + 16), rect, flags));
    } else {
      if ((mask & 2) !== 0) include(nscvRenderTransform(nscvRenderAffine(w, at + 32), rect, flags));
      if ((mask & 4) !== 0) include(nscvRenderTransform(nscvRenderAffine(w, at + 56), rect, flags));
      if ((mask & 8) !== 0) {
        const r = nscvSurfaceNormalize(rect), x = w.getFloat32(at + 80, true), y = w.getFloat32(at + 84, true), f = Math.fround;
        let radius = 0;
        for (let corner = 0; corner < 4; corner++) {
          const dx = f(((corner & 1) !== 0 ? nscvSurfaceRight(r) : r.x) - x);
          const dy = f((corner >= 2 ? nscvSurfaceBottom(r) : r.y) - y);
          radius = nscvRenderExtreme(radius, f(Math.sqrt(f(f(dx * dx) + f(dy * dy)))), flags, true);
        }
        include({ x: f(x - radius), y: f(y - radius), width: f(radius * 2), height: f(radius * 2) });
      }
    }
  }
  if (answer !== 4294967295 && !consumed) throw new Error("unconsumed animation bounds capability");
  out.setUint32(8, cursor, true); out.setUint32(12, 4294967295, true); nscvRenderPutOptional(out, 16, bounds); return result;
}
