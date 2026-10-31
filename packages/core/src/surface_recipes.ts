/** Complete surface chrome recipes over copied appearance and measurement facts.
 * Command identities, fonts, registry paths and drawing storage stay native. */
function nscvSurfaceRecipes(request: Uint8Array): Uint8Array {
  if (request.length !== 560) throw new Error("invalid surface recipe shape");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const op = request[2]!, numeric = request[3]!, flags = w.getUint32(4, true), mask = w.getUint32(8, true);
  if (request[0] !== 31 || request[1] !== 1 || op > 14 || numeric > 15 || flags > 1023 || mask > 1023 || request[12]! > 5 || request[13]! > 2 || request[14]! > 1 || request[15]! > 31) throw new Error("invalid surface recipe header");
  for (let i = 156; i < 160; i++) if (request[i] !== 0) throw new Error("invalid surface recipe reserved bytes");
  for (let i = 464; i < 480; i++) if (request[i] !== 0) throw new Error("invalid surface recipe reserved bytes");
  for (let i = 528; i < 560; i++) if (request[i] !== 0) throw new Error("invalid surface recipe reserved bytes");
  const f = Math.fround, v = (at: number): number => w.getFloat32(at, true);
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, false);
  const r = (x: number, y: number, width: number, height: number): NscSurfaceRect => ({ x, y, width, height });
  const raw = nscvRenderRect(w, 16), frame = nscvSurfaceNormalize(raw), size = v(48), inset = v(52), iconSize = v(56), gap = v(60);
  const empty = (a: NscSurfaceRect): boolean => a.width <= 0 || a.height <= 0;
  const result = new Uint8Array(1088), out = new DataView(result.buffer); out.setUint32(0, 1, true); let count = 0;
  const auxiliary = (bits: number): void => out.setUint32(8, out.getUint32(8, true) | bits, true);
  const color = (at: number): Uint8Array => request.subarray(at, at + 16);
  const content = (kind: number, a: NscSurfaceRect, radius: Uint8Array, width: number, rawInput: boolean): Uint8Array => {
    const b = new Uint8Array(128), d = new DataView(b.buffer); b.set([30, 1, kind, numeric]); b[9] = request[15]!;
    d.setUint32(4, ((flags & 32) !== 0 ? 1 : 0) | ((flags & 64) !== 0 ? 2 : 0), true);
    nscvRenderPutRect(d, 16, a); if (rawInput) b.set(request.subarray(16, 32), 16); b.set(radius, 32); d.setFloat32(48, v(68), true); d.setFloat32(84, v(120), true); d.setFloat32(88, width, true);
    return nscvControlContent(b);
  };
  const zeroRadius = new Uint8Array(16);
  const snap = (a: NscSurfaceRect): NscSurfaceRect => nscvRenderRect(new DataView(content(0, a, zeroRadius, 0, false).buffer), 8);
  const point = (x: number, y: number, text: boolean): Uint8Array => content(text ? 2 : 1, r(x, y, 0, 0), zeroRadius, 0, false).subarray(56, 64);
  const radiusAll = (value: number): Uint8Array => { const b = new Uint8Array(16), d = new DataView(b.buffer); for (let i = 0; i < 4; i++) d.setFloat32(i * 4, value, true); return b; };
  const radius = request.subarray(32, 48);
  // Every command is a complete, zero-initialized record. Selected colors and
  // unsnapped input fields are copied as octets, including NaN payloads.
  const command = (kind: number, slot: number, a: NscSurfaceRect, arc: Uint8Array, ink: Uint8Array, width: number): number => {
    if (count >= 8) throw new Error("surface recipe command overflow");
    const at = 64 + count * 128; count++; out.setUint32(at, kind, true); out.setUint32(at + 4, slot, true);
    nscvRenderPutRect(out, at + 8, a); result.set(arc, at + 24); result.set(ink, at + 40); out.setFloat32(at + 56, width, true);
    const rawInput = (op < 5 || op === 13) && kind < 3;
    if (rawInput) result.set(request.subarray(16, 32), at + 8);
    if (kind === 1) {
      const crisp = content(10, a, arc, width, rawInput); result.set(crisp.subarray(8, 24), at + 8); result.set(crisp.subarray(40, 56), at + 24); result.set(crisp.subarray(64, 68), at + 56);
    }
    return at;
  };
  const fill = (slot: number, a: NscSurfaceRect, arc: Uint8Array, ink: Uint8Array): void => { command(0, slot, a, arc, ink, 0); };
  const border = (slot: number, a: NscSurfaceRect, arc: Uint8Array, ink: Uint8Array): void => { command(1, slot, a, arc, ink, v(100)); };
  const shadow = (): void => { if (v(88) !== 0 || v(92) !== 0 || v(96) !== 0) { const at = command(2, 1, raw, radius, color(224), 0); result.set(request.subarray(88, 100), at + 60); } };
  const text = (slot: number, x: number, y: number, width: number, wrap: number, alignment: number, overflow: number, ink: Uint8Array): void => {
    const at = command(3, slot, r(0, 0, 0, 0), zeroRadius, ink, 0); out.setFloat32(at + 60, size, true); out.setFloat32(at + 64, width, true); out.setFloat32(at + 68, f(size * 1.25), true);
    result.set(point(x, y, true), at + 72); out.setUint32(at + 80, wrap, true); out.setUint32(at + 84, alignment, true); out.setUint32(at + 88, overflow, true);
  };
  const line = (slot: number, x0: number, y0: number, x1: number, y1: number, ink: Uint8Array, width: number): void => {
    const at = command(4, slot, r(0, 0, 0, 0), zeroRadius, ink, width); result.set(point(x0, y0, false), at + 8); result.set(point(x1, y1, false), at + 16);
  };
  const icon = (slot: number, a: NscSurfaceRect, ink: Uint8Array, registry: number, flip: boolean): void => {
    const n = snap(nscvSurfaceNormalize(a)); if (empty(n)) return;
    const at = command(5, slot, n, zeroRadius, ink, 0); out.setUint32(at + 92, registry, true); out.setUint32(at + 80, flip ? 1 : 0, true);
    if (flip) { out.setFloat32(at + 96, -1, true); out.setFloat32(at + 108, -1, true); out.setFloat32(at + 112, f(f(n.x * 2) + n.width), true); out.setFloat32(at + 116, f(f(n.y * 2) + n.height), true); }
  };
  const grip = (): void => {
    if (empty(frame)) return;
    const pad = v(144), space = v(148), height = min(max(v(152), f(frame.height * f(0.48))), max(0, f(frame.height - f(pad * 2)))); if (height <= 0) return;
    const right = max(f(frame.x + pad), f(f(frame.x + frame.width) - pad)), left = max(f(frame.x + pad), f(right - space));
    const y0 = f(frame.y + f(f(frame.height - height) * 0.5)), y1 = f(y0 + height);
    line(4, left, y0, left, y1, color(192), v(104)); line(5, right, y0, right, y1, color(192), v(104));
  };
  const radiusAt = (flags & 256) !== 0 ? 112 : 108, radiusWord = w.getUint32(radiusAt, true);
  const bubbleRadius = radiusAll((flags & 256) !== 0 ? max(0, v(112)) : f(max(0, v(108)) + 12));
  // The native target can propagate a signaling operand through f32 max.
  // Preserve its quieted payload, including the fallback's subsequent add.
  if ((request[15]! & 16) !== 0 && (radiusWord & 0x7f800000) === 0x7f800000 && (radiusWord & 0x007fffff) !== 0 && (radiusWord & 0x00400000) === 0) {
    const arc = new DataView(bubbleRadius.buffer); for (let i = 0; i < 4; i++) arc.setUint32(i * 4, radiusWord | 0x00400000, true);
  }
  if (op === 5) { auxiliary(1); result.set(bubbleRadius, 16); }
  else if (op === 6) {
    const variant = request[12]!;
    const ink = variant === 1 ? (mask & 8) !== 0 ? color(448) : (mask & 64) !== 0 ? color(384) : color(304) : variant === 5 ? color(320) : variant < 3 && (mask & 64) !== 0 ? color(384) : null;
    if (ink !== null) { auxiliary(2); result.set(ink, 32); result.set(ink, 48); out.setFloat32(60, f(0.7), true); }
  } else if (op === 4) {
    const variant = request[12]!;
    const background = (mask & 1) !== 0 ? color(400) : variant === 0 || variant === 2 ? (mask & 16) !== 0 ? color(352) : color(256) : variant === 1 ? (mask & 4) !== 0 ? color(432) : color(288) : variant === 3 ? color(240) : variant === 5 ? (mask & 128) !== 0 ? color(336) : nscvAppearanceAlpha(color(320), f(0.10), numeric) : null;
    if (background !== null) fill(2, raw, bubbleRadius, background);
    const edge = (mask & 2) !== 0 ? color(416) : variant === 3 ? (mask & 32) !== 0 ? color(368) : color(176) : null;
    if (edge !== null) border(3, raw, bubbleRadius, edge);
  } else if (op === 7 || op === 8) {
    if ((flags & 513) === 513 && !empty(frame)) {
      if ((flags & 128) === 0) auxiliary(8);
      else {
        const height = f(f(size * 1.25) + 4), width = max(height, f(Math.ceil(v(116)) + 12));
        const x = request[13] === 0 ? f(frame.x + 12) : request[13] === 1 ? f(frame.x + f(f(frame.width - width) * 0.5)) : f(f(f(frame.x + frame.width) - 12) - width);
        const pill = r(x, f(f(frame.y + frame.height) - f(height * 0.25)), width, height); auxiliary(4); nscvRenderPutRect(out, 16, pill);
        if (op === 8) {
          const n = snap(pill), normalized = nscvSurfaceNormalize(n), ring = r(f(normalized.x - 3), f(normalized.y - 3), f(f(normalized.width + 3) + 3), f(f(normalized.height + 3) + 3));
          fill(4, ring, radiusAll(f(ring.height * 0.5)), color(240)); fill(5, n, radiusAll(f(n.height * 0.5)), color(256));
          text(6, f(n.x + 6), f(n.y + max(size, f(f(f(n.height - f(size * 1.25)) * 0.5) + size))), max(1, f(n.width - 6)), 1, 0, 0, color(272));
        }
      }
    }
  } else if (op === 0 || op === 1 || op === 2 || op === 3 || op === 13) {
    if (op === 2 || op === 13 || op === 3 && v(172) >= 1) shadow();
    const slot = op < 2 ? 1 : 2; fill(slot, raw, radius, color(160)); border(slot + 1, raw, radius, color(176));
    if (op === 3 && (flags & 8) !== 0) grip();
    if (op < 3 && (flags & 1) !== 0) {
      if (op === 0) {
        const height = f(size * 1.25), a = r(f(raw.x + inset), f(f(raw.y + inset) + f(f(height - iconSize) * 0.5)), iconSize, iconSize);
        icon(3, a, color(192), request[12] === 5 ? 1 : 0, false);
        text(10, f(f(a.x + iconSize) + gap), f(f(raw.y + inset) + f(f(height + f(size * f(0.7))) * 0.5)), max(1, f(f(f(raw.width - f(inset * 2)) - iconSize) - gap)), 1, request[13]!, 0, color(192));
      } else text(op === 1 ? 3 : 4, f(raw.x + inset), f(f(raw.y + inset) + size), max(1, f(raw.width - f(inset * 2))), 1, request[13]!, 0, color(192));
    }
  } else if (op === 9) {
    if (!empty(frame)) {
      if ((mask & 256) !== 0) fill(1, frame, radius, color(480));
      line(2, frame.x, f(frame.y + frame.height), f(frame.x + frame.width), f(frame.y + frame.height), color(176), v(100));
      const body = r(f(frame.x + min(v(84), frame.width)), f(frame.y + min(v(72), frame.height)), max(0, f(f(frame.width - v(84)) - v(76))), max(0, f(f(frame.height - v(72)) - v(80))));
      if (!empty(nscvSurfaceNormalize(body))) {
        const height = min(body.height, v(64));
        if ((flags & 1) !== 0) text(6, body.x, f(body.y + f(f(height + f(size * f(0.7))) * 0.5)), max(1, f(f(body.width - iconSize) - gap)), 0, request[13]!, request[14]!, color(192));
        icon(4, r(f(f(body.x + body.width) - iconSize), f(body.y + f(f(height - iconSize) * 0.5)), iconSize, iconSize), color(208), 2, (flags & 4) !== 0);
        if ((flags & 2) !== 0) {
          const bounds = content(8, raw, zeroRadius, 0, true), arc = content(9, raw, request.subarray(128, 144), 0, true);
          command(1, 7, nscvRenderRect(new DataView(bounds.buffer), 8), arc.subarray(40, 56), color(512), v(124));
        }
      }
    }
  } else if (op === 14) icon(3, raw, color(192), request[12] === 5 ? 1 : 0, false);
  else if (op === 10) icon(4, raw, color(208), 2, (flags & 4) !== 0);
  else if (op === 11) {
    if (!empty(frame)) {
      if ((flags & 16) === 0) { fill(1, frame, radius, color(160)); if ((mask & 512) !== 0) border(2, frame, radius, color(496)); }
      else {
        if ((mask & 256) !== 0) fill(1, frame, radius, color(480));
        const width = min(frame.height, v(100)); if (width > 0) command(6, 2, snap(r(frame.x, f(f(frame.y + frame.height) - width), frame.width, width)), zeroRadius, color(176), 0);
      }
    }
  } else if (op === 12) grip();
  out.setUint32(4, count, true); return result;
}
