/** Layout programs are copied across the ABI. Native executes measurement
 * capabilities and mutates its owned preorder buffer; no source tree, widget
 * pointer or compiler allocation is retained by these policies. */
function nscvLayoutU64Compare(w: DataView, a: number, b: number): number {
  const ah = w.getUint32(a + 4, true), bh = w.getUint32(b + 4, true);
  if (ah !== bh) return ah < bh ? -1 : 1;
  const al = w.getUint32(a, true), bl = w.getUint32(b, true);
  return al === bl ? 0 : al < bl ? -1 : 1;
}
function nscvLayoutModal(kind: number): boolean { return kind >= 19 && kind <= 21; }
function nscvLayoutAdmission(request: Uint8Array): Uint8Array {
  if (request.length !== 32 || request[0] !== 40 || request[1] !== 1 || request[2]! > 62 || request[3]! > 3)
    throw new Error("invalid layout admission header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (w.getUint32(4, true) !== 0) throw new Error("invalid layout admission reserved bytes");
  const result = new Uint8Array(4), kind = request[2]!, virtual = (request[3]! & 1) !== 0;
  // Depth wins over capacity, including counts beyond JavaScript's exact
  // integer range. Failed admission never initializes an output slot.
  if (w.getUint32(12, true) !== 0 || w.getUint32(8, true) >= 32) { result[0] = 1; return result; }
  if (nscvLayoutU64Compare(w, 16, 24) >= 0) { result[0] = 2; return result; }
  let route = 0;
  if (kind === 1 || kind === 8 || kind === 10 || kind === 11 || kind === 13 || kind === 42 || kind === 43) route = 1;
  else if (kind === 9) route = 2;
  else if (kind === 12) route = 3;
  else if (kind === 2 || kind === 59 || kind === 60 || kind === 24 || kind === 25) route = 4;
  else if (kind === 3) route = virtual ? 6 : 5;
  else if (kind === 4 || kind === 5 || kind === 7) route = virtual ? 7 : 4;
  else if (kind === 6) route = virtual ? 7 : 8;
  else if (kind === 57) route = 9;
  else if (kind === 14) route = 10;
  else if (kind === 17) route = 11;
  else if (kind === 0 || kind === 15 || kind === 16 || kind === 18 || kind === 22 || kind === 23 || nscvLayoutModal(kind)) route = 12;
  else if (kind === 26) route = 13;
  else if (kind === 44) route = (request[3]! & 2) !== 0 ? 13 : 1;
  result[1] = route; return result;
}

/** Ordered child plans: stack, modal, anchor, split, span hotspots, and
 * geometric split slides. Split clamping remains an explicit capability so
 * app-supplied interaction callbacks keep their existing semantics. */
function nscvLayoutChildren(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 41 || request[1] !== 1 || request[2]! > 5 || request[3]! > 15)
    throw new Error("invalid layout child header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, count = w.getUint32(4, true), spans = w.getUint32(8, true), ready = w.getUint32(12, true);
  if (request.length !== 64 + count * 64 + spans * 24 || ready > 1 || mode !== 4 && spans !== 0 || mode !== 3 && mode !== 5 && ready !== 0)
    throw new Error("invalid layout child shape");
  for (let i = 48; i < 64; i++) if (request[i] !== 0) throw new Error("invalid layout child reserved bytes");
  if (mode !== 5 && w.getUint32(44, true) !== 0) throw new Error("invalid layout child root");
  for (let i = 0; i < count; i++) {
    const at = 64 + i * 64;
    if (w.getUint32(at, true) > 62 || w.getUint32(at + 4, true) > 3 || w.getUint32(at + 56, true) !== 0 || w.getUint32(at + 60, true) !== 0)
      throw new Error("invalid layout child facts");
    if (mode !== 5) for (let j = 40; j < 56; j++) if (request[at + j] !== 0) throw new Error("invalid layout child retained facts");
  }
  const spanAt = (i: number): number => 64 + count * 64 + i * 24;
  for (let i = 0; i < spans; i++) {
    const at = spanAt(i), link = w.getUint32(at, true), state = w.getUint32(at + 4, true);
    if (link > 1 || state > 2 || link === 0 && state !== 0) throw new Error("invalid layout span facts");
    if (state !== 2) for (let j = 8; j < 24; j++) if (request[at + j] !== 0) throw new Error("invalid absent span bounds");
  }
  const result = new Uint8Array(32 + count * 32), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  const at = (i: number): number => 64 + i * 64;
  const flow = (i: number): boolean => (w.getUint32(at(i) + 4, true) & 1) === 0 && !nscvLayoutModal(w.getUint32(at(i), true));
  let used = 0;
  const emit = (i: number, flags: number, frame: NscSurfaceRect, value: number = 0): void => {
    const dest = 32 + used++ * 32;
    out.setUint32(dest, i, true); out.setUint32(dest + 4, flags, true); out.setFloat32(dest + 8, value, true);
    nscvRenderPutRect(out, dest + 16, frame);
  };
  const done = (): Uint8Array => { out.setUint32(8, used, true); return result; };
  const copied = (from: number, offset: number, length: number): void => {
    result.set(request.subarray(from, from + length), 32 + (used - 1) * 32 + 16 + offset);
  };
  const content = nscvRenderRect(w, 16), f = Math.fround;
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, request[3]!, true);
  if (mode <= 2) {
    for (let i = 0; i < count; i++) {
      const child = at(i), kind = w.getUint32(child, true), flags = w.getUint32(child + 4, true);
      if (mode === 1) { if (nscvLayoutModal(kind)) { emit(i, 2, content); copied(16, 0, 16); } }
      else if (mode === 2) { if (!nscvLayoutModal(kind) && (flags & 1) !== 0) { emit(i, 4, content); copied(16, 0, 16); } }
      else if (flow(i)) {
        const packet = new Uint8Array(84), p = new DataView(packet.buffer); packet[0] = 5; packet[1] = 3;
        p.setUint32(8, 1, true); packet.set(request.subarray(16, 32), 12); p.setUint32(36, 1 | (flags & 2), true);
        packet.set(request.subarray(child + 16, child + 24), 44); packet.set(request.subarray(child + 8, child + 16), 52);
        for (const [from, to] of [[24,60],[32,64],[28,68],[36,72]]) packet.set(request.subarray(child + from!, child + from! + 4), to!);
        const frame = nscvContainerLayout(packet); emit(i, 2, nscvRenderRect(new DataView(frame.buffer), 12));
      }
    }
    return done();
  }
  if (mode === 4) {
    if (spans === 0) return done();
    let child = 0;
    for (let span = 0; span < spans && child < count; span++) {
      const s = spanAt(span); if (w.getUint32(s, true) === 0) continue;
      const i = child++; if (!flow(i)) continue;
      const state = w.getUint32(s + 4, true);
      if (state === 0) {
        out.setUint32(4, 1, true); out.setUint32(8, i, true); out.setUint32(12, span, true); return result.slice(0, 32);
      }
      const bounds = nscvRenderRect(w, s + 8);
      emit(i, 2, state === 2 ? { x: f(content.x + bounds.x), y: f(content.y + bounds.y), width: bounds.width, height: bounds.height }
        : { x: content.x, y: content.y, width: 0, height: 0 });
      if (state === 2) copied(s + 16, 8, 8);
      else copied(16, 0, 8);
    }
    while (child < count) { const i = child++; if (flow(i)) { emit(i, 2, { x: content.x, y: content.y, width: 0, height: 0 }); copied(16, 0, 8); } }
    return done();
  }
  const root = w.getUint32(44, true);
  if (mode === 5 && root >= count) throw new Error("invalid layout slide root");
  let first = -1, second = -1, divider = -1;
  for (let i = mode === 5 ? root + 1 : 0; i < count; i++) {
    if (mode === 5) {
      if (nscvLayoutU64Compare(w, at(i) + 40, at(root) + 40) <= 0) break;
      if (w.getUint32(at(i) + 52, true) !== 0 || w.getUint32(at(i) + 48, true) !== root) continue;
    }
    if (!flow(i)) continue;
    if (w.getUint32(at(i), true) === 58) { if (divider < 0) divider = i; }
    else if (first < 0) first = i;
    else if (second < 0) second = i;
  }
  if (mode === 5 && (first < 0 || second < 0 || divider < 0)) return done();
  const authoredGap = max(0, w.getFloat32(32, true));
  const extent = divider < 0 ? 0 : mode === 5 ? w.getFloat32(at(divider) + 16, true) : authoredGap > 0 ? authoredGap : 9;
  const available = max(0, f(content.width - extent));
  const firstMin = first < 0 ? 0 : max(0, w.getFloat32(at(first) + 24, true));
  const secondMin = second < 0 ? 0 : max(0, w.getFloat32(at(second) + 24, true));
  if (ready === 0) {
    out.setUint32(4, 2, true); out.setFloat32(16, available, true); out.setFloat32(20, firstMin, true); out.setFloat32(24, secondMin, true);
    return result.slice(0, 32);
  }
  const fraction = w.getFloat32(40, true), width = second < 0 ? available : f(available * fraction);
  if (mode === 3) {
    let cursor = content.x;
    if (first >= 0) { emit(first, 2, { x: cursor, y: content.y, width, height: content.height }); copied(16, 0, 8); copied(28, 12, 4); cursor = f(cursor + width); }
    if (divider >= 0) { emit(divider, 3, { x: cursor, y: content.y, width: extent, height: content.height }, fraction); copied(20, 4, 4); copied(28, 12, 4); cursor = f(cursor + extent); }
    if (second >= 0) { emit(second, 2, { x: cursor, y: content.y, width: max(0, f(f(content.x + content.width) - cursor)), height: content.height }); copied(20, 4, 4); copied(28, 12, 4); }
    for (let i = second < 0 ? count : second + 1; i < count; i++) if (flow(i) && w.getUint32(at(i), true) !== 58) {
      emit(i, 2, { x: f(content.x + content.width), y: content.y, width: 0, height: 0 }); copied(20, 4, 4);
    }
    return done();
  }
  const firstFrame = nscvRenderRect(w, at(first) + 8), dividerFrame = nscvRenderRect(w, at(divider) + 8), secondFrame = nscvRenderRect(w, at(second) + 8);
  const dividerX = f(content.x + width), dx = f(dividerX - dividerFrame.x), secondX = f(dividerX + extent);
  emit(root, 1, nscvRenderRect(w, at(root) + 8), fraction);
  copied(at(root) + 8, 0, 16);
  emit(first, 2, { x: firstFrame.x, y: firstFrame.y, width, height: firstFrame.height });
  copied(at(first) + 8, 0, 8); copied(at(first) + 20, 12, 4);
  emit(divider, 3, { x: dividerX, y: dividerFrame.y, width: dividerFrame.width, height: dividerFrame.height }, fraction);
  copied(at(divider) + 12, 4, 12);
  emit(second, 2, { x: secondX, y: secondFrame.y, width: max(0, f(f(content.x + content.width) - secondX)), height: secondFrame.height });
  copied(at(second) + 12, 4, 4); copied(at(second) + 20, 12, 4);
  if (dx !== 0) for (let i = second + 1; i < count; i++) {
    if (nscvLayoutU64Compare(w, at(i) + 40, at(second) + 40) <= 0) break;
    const frame = nscvRenderRect(w, at(i) + 8); emit(i, 2, { x: f(frame.x + dx), y: frame.y, width: frame.width, height: frame.height });
    copied(at(i) + 12, 4, 12);
  }
  return done();
}

/** Retained parent/stratum walks and forward progress. Parents are exact
 * integer words; only a validated index becomes a JavaScript number. */
function nscvLayoutRetained(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 42 || request[1] !== 1 || request[2]! > 3 || request[3] !== 0)
    throw new Error("invalid retained layout header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), mode = request[2]!;
  if (request.length !== 32 + count * 24) throw new Error("invalid retained layout shape");
  for (let i = 24; i < 32; i++) if (request[i] !== 0) throw new Error("invalid retained layout reserved bytes");
  for (let i = 0; i < count; i++) if (w.getUint32(32 + i * 24, true) > 1 || w.getUint32(36 + i * 24, true) > 62)
    throw new Error("invalid retained layout facts");
  const parent = (i: number): number => {
    const at = 32 + i * 24 + 16, low = w.getUint32(at, true);
    return w.getUint32(at + 4, true) === 0 && low < count ? low : -1;
  };
  const nesting = (index: number): number => {
    let depth = 0, remaining = count;
    for (let i = index; i >= 0 && i < count && remaining-- > 0; i = parent(i)) if (w.getUint32(32 + i * 24, true) !== 0) depth++;
    return depth;
  };
  const result = new Uint8Array(16), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  if (mode === 0) {
    out.setUint32(8, w.getUint32(12, true) === 0 ? nesting(w.getUint32(8, true)) : 0, true);
  } else if (mode === 1) {
    let maximum = 0;
    for (let i = 0; i < count; i++) if (w.getUint32(32 + i * 24, true) !== 0) maximum = Math.max(maximum, nesting(i));
    out.setUint32(8, maximum, true);
  } else if (mode === 2) {
    if (w.getUint32(12, true) === 0 && w.getUint32(20, true) === 0) for (let i = Math.max(1, w.getUint32(8, true)); i < count; i++) {
      if (w.getUint32(32 + i * 24, true) === 0 || nscvLayoutModal(w.getUint32(36 + i * 24, true))) continue;
      const p = parent(i); if (p < 0 || nesting(p) !== w.getUint32(16, true)) continue;
      out.setUint32(4, 1, true); out.setUint32(8, i, true); out.setUint32(12, p, true); break;
    }
  } else {
    // Return the exact u64 cursor, including the carry when incrementing.
    if (nscvLayoutU64Compare(w, 16, 8) > 0) result.set(request.subarray(16, 24), 8);
    else {
      const lower = w.getUint32(8, true);
      if (lower === 4294967295 && w.getUint32(12, true) === 4294967295) throw new Error("retained layout cursor overflow");
      out.setUint32(8, lower === 4294967295 ? 0 : lower + 1, true);
      out.setUint32(12, w.getUint32(12, true) + (lower === 4294967295 ? 1 : 0), true);
    }
  }
  return result;
}
