/** Retained scroll geometry over copied preorder facts. Tag 94 uses a
 * 48-byte header and 56 bytes per node; results contain a 24-byte header
 * followed by one translation bit per node. Native owns frames, exact IDs,
 * virtual-content measurements and the buffers on both sides of the ABI.
 * Operations: 0 = both content extents, 1 = moving descendants, 2 = the
 * next newly selected tab. Tab plans are refreshed after every mutation.
 * Node fields: depth/parent/flags u32, offsets y/x f32, frame and inset
 * viewport (four f32 each), anchored stratum u32. Flag bits describe a
 * root modal, anchor, escaping clip, clip scope, virtual region, concealed
 * disclosure, horizontal scroll grant, selected tab and prior selection.
 */
function nscvScrollTree(request: Uint8Array): Uint8Array {
  if (request.length < 48 || request[0] !== 94 || request[1]! > 2 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid scroll tree header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = w.getUint32(4, true), target = w.getUint32(8, true), mode = request[1]!;
  if (count > 1024 || request.length !== 48 + count * 56 || target > count || mode !== 2 && target === count)
    throw new Error("invalid scroll tree shape");
  for (let i = 36; i < 48; i++) if (request[i] !== 0) throw new Error("invalid scroll tree reserved bytes");
  const at = (i: number): number => 48 + i * 56;
  const flags = (i: number): number => w.getUint32(at(i) + 8, true);
  const depth = (i: number): number => w.getUint32(at(i), true);
  const parent = (i: number): number => w.getUint32(at(i) + 4, true);
  for (let i = 0; i < count; i++) {
    const p = parent(i);
    if (flags(i) > 511 || p !== 0xffffffff && p >= i) throw new Error("invalid scroll tree node");
  }
  const result = new Uint8Array(24 + count), out = new DataView(result.buffer);
  result[0] = 94; result[1] = mode; out.setUint32(4, count, true); out.setUint32(8, 0xffffffff, true);
  const f = Math.fround;
  const maximum = (a: number, b: number): number => Number.isNaN(a) ? b : Number.isNaN(b) ? a : Math.max(a, b);
  const skip = (i: number): number => { let next = i + 1; while (next < count && depth(next) > depth(i)) next++; return next; };
  const stationary = (i: number, root: number): boolean => (flags(i) & 1) !== 0 || (flags(i) & 2) !== 0 && parent(i) === root;
  const moves = (root: number): void => {
    let i = root + 1;
    while (i < count && depth(i) > depth(root)) {
      if (stationary(i, root)) i = skip(i);
      else { result[24 + i] = 1; i++; }
    }
  };
  if (mode === 1) { moves(target); return result; }
  if (mode === 0) {
    const x = w.getFloat32(16, true), y = w.getFloat32(20, true), width = w.getFloat32(24, true), height = w.getFloat32(28, true);
    let right = f(x + width), bottom = f(y + height);
    if ((flags(target) & 16) !== 0) {
      out.setFloat32(12, width, true); out.setFloat32(16, maximum(height, w.getFloat32(32, true)), true); return result;
    }
    const offsetY = w.getFloat32(at(target) + 12, true), offsetX = w.getFloat32(at(target) + 16, true);
    let i = target + 1;
    while (i < count && depth(i) > depth(target)) {
      if (stationary(i, target)) { i = skip(i); continue; }
      bottom = maximum(bottom, f(f(w.getFloat32(at(i) + 24, true) + w.getFloat32(at(i) + 32, true)) + offsetY)); i++;
    }
    i = target + 1;
    while (i < count && depth(i) > depth(target)) {
      const bits = flags(i);
      if ((bits & 4) !== 0) { i = skip(i); continue; }
      right = maximum(right, f(f(w.getFloat32(at(i) + 20, true) + w.getFloat32(at(i) + 28, true)) + offsetX));
      i = (bits & (8 | 16 | 32)) !== 0 ? skip(i) : i + 1;
    }
    out.setFloat32(12, maximum(0, f(right - x)), true); out.setFloat32(16, maximum(0, f(bottom - y)), true); return result;
  }
  const stratum = w.getUint32(12, true);
  let tab = target;
  while (tab < count && ((flags(tab) & (128 | 256)) !== 128 || stratum !== 0xffffffff && w.getUint32(at(tab) + 52, true) !== stratum)) tab++;
  out.setUint32(20, tab < count ? tab + 1 : count, true);
  if (tab === count) return result;
  let ancestor = parent(tab);
  while (ancestor !== 0xffffffff) {
    if ((flags(ancestor) & (64 | 16)) === 64) {
      const a = at(ancestor), t = at(tab);
      const vx = w.getFloat32(a + 36, true), vy = w.getFloat32(a + 40, true), vw = w.getFloat32(a + 44, true), vh = w.getFloat32(a + 48, true);
      let tx = w.getFloat32(t + 20, true), tw = w.getFloat32(t + 28, true), th = w.getFloat32(t + 32, true);
      if (tw < 0) { tx = f(tx + tw); tw = -tw; }
      if (th < 0) th = -th;
      if (vw <= 0 || vh <= 0 || tw <= 0 || th <= 0) break;
      const delta = tx < vx ? f(tx - vx) : f(tx + tw) > f(vx + vw) ? f(f(tx + tw) - f(vx + vw)) : 0;
      if (delta === 0) break;
      const current = w.getFloat32(a + 16, true), next = maximum(0, f(current + delta));
      if (next === current) break;
      out.setUint32(8, ancestor, true); out.setFloat32(12, -f(next - current), true); out.setFloat32(16, next, true); moves(ancestor); break;
    }
    ancestor = parent(ancestor);
  }
  return result;
}
