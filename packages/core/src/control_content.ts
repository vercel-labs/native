/** Control content and editing chrome over copied native measurements.
 * Font shaping, command identities and storage remain native capabilities. */
function nscvControlContent(request: Uint8Array): Uint8Array {
  if (request.length !== 128) throw new Error("invalid control content shape");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const op = request[2]!, numeric = request[3]!, flags = w.getUint32(4, true), alignment = request[8]!;
  if (request[0] !== 30 || request[1] !== 1 || op > 18 || numeric > 15 || flags > 31 || alignment > (op === 7 ? 5 : 2) || request[9] !== 0 || request[10] !== 0 || request[11] !== 0 || w.getUint32(12, true) !== 0) throw new Error("invalid control content header");
  for (let at = 92; at < 128; at++) if (request[at] !== 0) throw new Error("invalid control content reserved bytes");
  const f = Math.fround, v = (at: number): number => w.getFloat32(at, true);
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, false);
  const raw = nscvRenderRect(w, 16), scale = v(48), size = v(52), inset = v(56);
  const rect = (x: number, y: number, width: number, height: number): NscSurfaceRect => ({ x, y, width, height });
  const round = (x: number): number => x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5);
  const snapValue = (x: number): number => f(round(f(x * scale)) / scale);
  const snaps = (bit: number): boolean => (flags & bit) !== 0 && Number.isFinite(scale) && scale > 0;
  const snap = (r: NscSurfaceRect): NscSurfaceRect => {
    if (!snaps(1)) return r;
    const n = nscvSurfaceNormalize(r), x = snapValue(n.x), y = snapValue(n.y);
    return rect(x, y, max(0, f(snapValue(f(n.x + n.width)) - x)), max(0, f(snapValue(f(n.y + n.height)) - y)));
  };
  const result = new Uint8Array(80), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const mark = (bit: number): void => out.setUint32(4, out.getUint32(4, true) | bit, true);
  const putRect = (slot: number, r: NscSurfaceRect): void => { mark(1 << slot); nscvRenderPutRect(out, 8 + slot * 16, r); };
  const scalar = (value: number, auxiliary = false): void => { mark(auxiliary ? 32 : 16); out.setFloat32(auxiliary ? 68 : 64, value, true); };
  const point = (x: number, y: number): void => { mark(8); out.setFloat32(56, x, true); out.setFloat32(60, y, true); };
  const baseline = (): number => f(raw.y + max(size, f(f(f(raw.height - f(size * 1.25)) * 0.5) + size)));
  if (op === 0) {
    putRect(0, snap(raw));
    if (!snaps(1)) result.set(request.subarray(16, 32), 8);
  } else if (op === 1 || op === 2) {
    const bit = op === 1 ? 1 : 2;
    point(snaps(bit) ? snapValue(raw.x) : raw.x, snaps(bit) ? snapValue(raw.y) : raw.y);
    if (!snaps(bit)) result.set(request.subarray(16, 24), 56);
  } else if (op === 3 || op === 6) {
    const available = max(0, f(raw.width - f(inset * 2)));
    const offset = op === 3 || alignment === 0 ? 0 : alignment === 1 ? max(0, f(f(available - v(60)) * 0.5)) : max(0, f(available - v(60)));
    point(op === 3 ? f(raw.x + inset) : f(f(raw.x + inset) + offset), baseline());
  } else if (op === 4) {
    scalar(max(1, f(raw.width - f(inset * 2)))); scalar(f(size * 1.25), true);
  } else if (op === 5) {
    putRect(0, rect(inset, raw.y, max(1, f(f(raw.x + raw.width) - inset)), raw.height));
    result.set(request.subarray(56, 60), 8); result.set(request.subarray(20, 24), 12); result.set(request.subarray(28, 32), 20);
  } else if (op === 7) {
    scalar(raw.height > 0 ? min(max(v(72), f(raw.height * f(alignment === 1 ? 0.44 : alignment === 2 ? 0.52 : 0.48))), max(v(72), v(76))) : v(80));
    if (!(raw.height > 0)) result.set(request.subarray(80, 84), 64);
  } else if (op === 8) {
    const n = nscvSurfaceNormalize(raw), offset = max(0, v(84));
    // RectF.inflate normalizes first, then performs left/right additions.
    putRect(0, rect(f(n.x - offset), f(n.y - offset), f(f(n.width + offset) + offset), f(f(n.height + offset) + offset)));
  } else if (op === 9) {
    mark(4); const offset = max(0, v(84));
    for (let i = 0; i < 4; i++) out.setFloat32(40 + i * 4, f(v(32 + i * 4) + offset), true);
  } else if (op === 10) {
    putRect(0, raw); mark(4); scalar(v(88)); result.set(request.subarray(16, 32), 8); result.set(request.subarray(32, 48), 40); result.set(request.subarray(88, 92), 64);
    if (!snaps(1)) return result;
    const exact = f(max(0, v(88)) * scale), rounded = round(exact);
    if (rounded < 1 || rounded > 2) return result;
    const width = max(1, Math.floor(exact)), n = nscvSurfaceNormalize(raw);
    if (n.width <= 0 || n.height <= 0) return result;
    const half = f(width * 0.5), x0 = f(f(round(f(n.x * scale)) + half) / scale), y0 = f(f(round(f(n.y * scale)) + half) / scale);
    const x1 = f(f(round(f(f(n.x + n.width) * scale)) - half) / scale), y1 = f(f(round(f(f(n.y + n.height) * scale)) - half) / scale);
    if (x1 <= x0 || y1 <= y0) return result;
    putRect(0, rect(x0, y0, f(x1 - x0), f(y1 - y0))); scalar(f(width / scale));
    const shrink = f(half / scale);
    for (let i = 0; i < 4; i++) out.setFloat32(40 + i * 4, max(0, f(v(32 + i * 4) - shrink)), true);
  } else if (op === 11) {
    const extent = v(64), gap = v(68), y = f(raw.y + f(f(raw.height - extent) * 0.5));
    if ((flags & 8) === 0) { putRect(0, rect(f(raw.x + f(f(raw.width - extent) * 0.5)), y, extent, extent)); return result; }
    const available = max(0, f(raw.width - f(inset * 2))), content = min(available, f(f(extent + gap) + v(60)));
    const start = f(f(raw.x + inset) + max(0, f(f(available - content) * 0.5)));
    const iconX = (flags & 4) === 0 ? start : (flags & 16) !== 0 ? f(start + f(content - extent)) : f(f(start + content) - extent);
    const textX = (flags & 4) !== 0 ? start : f(f(start + extent) + gap), end = (flags & 4) !== 0 ? f(iconX - gap) : f(f(raw.x + raw.width) - inset);
    putRect(0, rect(iconX, y, extent, extent)); putRect(1, rect(textX, raw.y, max(1, f(end - textX)), raw.height));
    result.set(request.subarray(20, 24), 28); result.set(request.subarray(28, 32), 36);
  } else if (op === 12) {
    const snapped = snap(raw), thickness = v(88);
    putRect(0, snap(rect(snapped.x, f(f(snapped.y + snapped.height) - thickness), snapped.width, thickness)));
  } else if (op === 13) {
    const n = nscvSurfaceNormalize(raw), vertical = v(60), trailing = v(64);
    putRect(0, rect(f(n.x + min(inset, n.width)), f(n.y + min(vertical, n.height)), max(0, f(f(n.width - inset) - trailing)), max(0, f(f(n.height - vertical) - vertical))));
  } else if (op === 14) {
    if ((flags & 4) !== 0) point(f(f(raw.x + inset) - v(64)), f(f(raw.y + size) - v(68)));
    else if ((flags & 8) !== 0) point(f(raw.x + inset), f(f(f(raw.y + v(60)) + size) - v(68)));
    else point(f(f(raw.x + inset) - v(64)), baseline());
  } else if (op === 15) {
    const line = f(size * 1.25);
    scalar(max(1, f(f(raw.width - inset) - v(64)))); scalar(line, true);
    const wrap = (flags & 4) !== 0 ? (flags & 8) === 0 : alignment === 2 || alignment === 1 && raw.height >= f(line * 2.25);
    out.setUint32(72, wrap ? 1 : 0, true);
  } else if (op === 16) {
    const extent = max(8, f(size - 4));
    putRect(0, rect(f(f(f(raw.x + raw.width) - inset) - extent), f(raw.y + max(0, f(f(raw.height - extent) * 0.5))), extent, extent));
  } else if (op === 17) {
    const left = max(raw.x, f(v(60) - v(64)));
    putRect(0, rect(left, raw.y, max(0, f(f(raw.x + raw.width) - left)), raw.height));
    result.set(request.subarray(20, 24), 12); result.set(request.subarray(28, 32), 20);
  } else {
    scalar((flags & 4) !== 0 ? 0 : (flags & 24) !== 0 ? f(inset + max(8, f(size - 4))) : inset);
    if ((flags & 28) === 0) result.set(request.subarray(56, 60), 64);
  }
  return result;
}
