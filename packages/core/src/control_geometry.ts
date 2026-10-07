/** Portable control chrome geometry over copied f32 facts. Drawing and font
 * measurement remain explicit native capabilities; no borrowed result escapes. */
function nscvControlGeometry(request: Uint8Array): Uint8Array {
  if (request.length < 160) throw new Error("invalid control geometry shape");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const op = request[2]!, numeric = request[3]!, flags = w.getUint32(4, true), count = w.getUint32(12, true);
  if (request[0] !== 29 || request[1] !== 1 || op > 8 || numeric > 15 || flags > 4095 || request[8]! > 2 || request[9]! > 5 || request[10]! > 31 || request[11] !== 0 || request.length !== 160 + count * 16 || (op !== 6 && count !== 0)) throw new Error("invalid control geometry header");
  for (let at = 148; at < 160; at++) if (request[at] !== 0) throw new Error("invalid control geometry reserved bytes");
  const f = Math.fround, v = (at: number): number => w.getFloat32(at, true);
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, false);
  const clamp = (x: number, lo: number, hi: number): number => { if (!(lo <= hi)) throw new Error("unordered control geometry bounds"); return max(min(x, hi), lo); };
  const signalingAt = (at: number): boolean => { const word = w.getUint32(at, true); return (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0; };
  const rawMin = (at: number, other: number): number => signalingAt(at) && (request[10]! & 2) !== 0 ? v(at) : min(v(at), other);
  const rawMax = (other: number, at: number): number => signalingAt(at) && (request[10]! & 16) !== 0 ? v(at) : max(other, v(at));
  const density = request[8] === 0 ? 0.875 : request[8] === 2 ? 1.125 : 1;
  const size = request[9] === 1 ? 0.875 : request[9] === 2 ? 1.125 : 1;
  const d = (x: number): number => f(x * density), sized = (x: number): number => f(d(x) * size);
  const raw = nscvRenderRect(w, 16), scale = v(32);
  const rect = (x: number, y: number, width: number, height: number): NscSurfaceRect => ({ x, y, width, height });
  const round = (x: number): number => x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5);
  const snapValue = (x: number): number => f(round(f(x * scale)) / scale);
  const snap = (r: NscSurfaceRect, components = false): NscSurfaceRect => {
    if ((flags & 1) === 0 || !Number.isFinite(scale) || scale <= 0) return r;
    if (components) return rect(snapValue(r.x), snapValue(r.y), snapValue(r.width), snapValue(r.height));
    const n = nscvSurfaceNormalize(r), x = snapValue(n.x), y = snapValue(n.y);
    return rect(x, y, max(0, f(snapValue(f(n.x + n.width)) - x)), max(0, f(snapValue(f(n.y + n.height)) - y)));
  };
  const result = new Uint8Array(96), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const put = (slot: number, r: NscSurfaceRect): void => { out.setUint32(4, out.getUint32(4, true) | (1 << slot), true); nscvRenderPutRect(out, 8 + slot * 16, r); };
  const value = (): number => {
    const word = w.getUint32(36, true), signaling = (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0;
    return signaling && (request[10]! & 1) !== 0 ? 0 : clamp(v(36), 0, 1);
  };
  if (op === 0) {
    const extent = min(max(sized(16), f(raw.height * f(0.55))), sized(20));
    put(0, snap(rect(raw.x, f(raw.y + f(f(raw.height - extent) * 0.5)), extent, extent)));
  } else if (op === 1) {
    const width = rawMin(24, max(sized(44), f(raw.height * 1.75))), height = rawMin(28, sized(24));
    const track = snap(rect(raw.x, f(raw.y + f(f(raw.height - height) * 0.5)), width, height));
    const inset = sized(2), extent = max(0, f(track.height - f(inset * 2)));
    const off = snap(rect(f(track.x + inset), f(track.y + inset), extent, extent));
    const on = snap(rect(f(f(f(track.x + track.width) - extent) - inset), f(track.y + inset), extent, extent));
    put(0, track); put(1, off); put(2, on); out.setFloat32(88, f(on.x - off.x), true);
  } else if (op === 2) {
    const x = value(), height = rawMin(28, sized(v(44)));
    const track = snap(rect(raw.x, f(raw.y + f(f(raw.height - height) * 0.5)), raw.width, height));
    const kw = rawMin(24, sized(v(48))), kh = rawMin(28, sized(v(52)));
    const kx = clamp(f(f(raw.x + f(raw.width * x)) - f(kw * 0.5)), raw.x, f(raw.x + max(0, f(raw.width - kw))));
    put(0, track); put(1, snap(rect(kx, f(raw.y + f(f(raw.height - kh) * 0.5)), kw, kh)));
    put(2, snap(rect(track.x, track.y, f(track.width * x), track.height)));
    out.setFloat32(88, x, true); if (x > 0) out.setUint32(4, out.getUint32(4, true) | 8, true);
  } else if (op === 3) {
    const x = value(); put(0, snap(rect(raw.x, raw.y, f(raw.width * x), raw.height))); out.setFloat32(88, x, true);
    out.setUint32(4, out.getUint32(4, true) | (x > 0 ? 8 : 0) | (x < 1 ? 16 : 0), true);
  } else if (op === 4 || op === 5) {
    const horizontal = (flags & 4) !== 0;
    const thickness = (h: boolean): number => min(max(d(3), f((h ? raw.height : raw.width) * f(0.0125))), d(6));
    const visible = (at: number, bit: number): boolean => (flags & bit) !== 0 && rawMax(0, at + 4) > 0 && rawMax(0, at + 8) > rawMax(0, at + 4);
    if (op === 5) {
      if (visible(84, 16) && visible(100, 32)) out.setFloat32(88, f(thickness(!horizontal) + d(3)), true);
    } else {
      const viewport = rawMax(0, 88), content = rawMax(0, 92), range = max(0, f(content - viewport));
      if ((flags & 16) === 0 || raw.width <= 0 || raw.height <= 0 || viewport <= 0 || content <= viewport || range <= 0) return result;
      const inset = d(3), width = thickness(horizontal), extent = max(0, f(f((horizontal ? raw.width : raw.height) - f(inset * 2)) - rawMax(0, 80)));
      if (extent <= 0 || width <= 0) return result;
      const track = horizontal ? rect(f(raw.x + inset), f(f(f(raw.y + raw.height) - inset) - width), extent, width) : rect(f(f(f(raw.x + raw.width) - inset) - width), f(raw.y + inset), width, extent);
      const thumb = min(extent, max(min(extent, d(18)), f(extent * clamp(f(viewport / content), 0, 1))));
      const travel = max(0, f(extent - thumb)), ratio = clamp(f(rawMax(0, 84) / range), 0, 1);
      const handle = horizontal ? rect(f(track.x + f(travel * ratio)), track.y, thumb, track.height) : rect(track.x, f(track.y + f(travel * ratio)), track.width, thumb);
      put(0, (flags & 1024) !== 0 ? snap(track, true) : track); put(1, (flags & 1024) !== 0 ? snap(handle, true) : handle);
    }
  } else if (op === 6) {
    const viewport = nscvSurfaceNormalize(rect(f(raw.x + min(v(112), raw.width)), f(raw.y + min(v(120), raw.height)), max(0, f(f(raw.width - v(112)) - v(116))), max(0, f(f(raw.height - v(120)) - v(124)))));
    if ((flags & 512) === 0 || viewport.width <= 0 || viewport.height <= 0) return result;
    for (let axis = 0; axis < 2; axis++) {
      if (axis === 0 ? (flags & 64) === 0 && (flags & 128) === 0 : (flags & 64) !== 0 || (flags & 256) === 0) continue;
      const start = axis === 0 ? viewport.y : viewport.x, extent = axis === 0 ? viewport.height : viewport.width, offset = axis === 0 ? v(36) : v(40);
      let end = f(start + extent);
      for (let i = 0; (flags & 64) === 0 && i < count; i++) { const child = nscvRenderRect(w, 160 + i * 16); end = max(end, f(f((axis === 0 ? child.y : child.x) + (axis === 0 ? child.height : child.width)) + offset)); }
      const content = (flags & 64) !== 0 ? max(extent, v(128)) : max(0, f(end - start)), at = 56 + axis * 16;
      out.setUint32(at, 1, true); out.setFloat32(at + 4, clamp(rawMax(0, axis === 0 ? 36 : 40), 0, max(0, f(content - extent))), true); out.setFloat32(at + 8, extent, true); out.setFloat32(at + 12, content, true);
    }
  } else if (op === 7) {
    const frame = nscvSurfaceNormalize(raw);
    if ((flags & 8) === 0 || frame.width <= 0 || frame.height <= 0) return result;
    const thickness = signalingAt(28) && (request[10]! & 2) !== 0 ? v(28) : min(frame.height, sized(v(56))), content = f(v(60) + v(64));
    const width = content > 0 ? signalingAt(24) && (request[10]! & 2) !== 0 ? v(24) : min(frame.width, f(content + f(v(68) * 2))) : frame.width;
    put(0, snap(rect(f(frame.x + f(f(frame.width - width) * 0.5)), f(f(frame.y + frame.height) - thickness), width, thickness)));
  } else {
    const segment = w.getUint32(80, true); if (segment > 3) throw new Error("invalid control segment");
    out.setUint32(4, 1, true);
    for (let i = 0; i < 4; i++) {
      const keep = (flags & 2048) !== 0 || segment === 0 || segment === 1 && (i === 0 || i === 3) || segment === 3 && (i === 1 || i === 2);
      if (keep) result.set(request.subarray(132 + i * 4, 136 + i * 4), 8 + i * 4);
    }
  }
  // Unsnapped passthrough coordinates never enter an arithmetic conversion.
  // Copy their words so even signaling payloads retain native storage fidelity.
  if ((flags & 1) === 0 || !Number.isFinite(scale) || scale <= 0) {
    if (op === 0 || op === 1 || op === 2 || op === 3) result.set(request.subarray(16, 20), 8);
    if (op === 2) { result.set(request.subarray(24, 28), 16); result.set(request.subarray(16, 20), 40); }
    if (op === 7 && (out.getUint32(4, true) & 1) !== 0 && !(f(v(60) + v(64)) > 0) && !(raw.width < 0)) result.set(request.subarray(24, 28), 16);
    if (op === 3) { result.set(request.subarray(20, 24), 12); result.set(request.subarray(28, 32), 20); }
  }
  return result;
}
