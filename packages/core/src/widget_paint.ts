/** Retained paint geometry over copied widget/token facts. Font measurement
 * is an explicit two-pass capability; no native damage verdict crosses here.
 * Every intermediate follows the reference's f32 evaluation order. */
interface NscPaintNode {
  readonly paint_kind: number; readonly paint_size: number; readonly paint_variant: number;
  readonly paint_parent: number; readonly paint_depth: number; readonly paint_depth_high: number; readonly paint_flags: number;
  readonly paint_state: number; readonly paint_blur_token: number; readonly paint_frame: NscSurfaceRect;
  readonly paint_authored_frame: NscSurfaceRect; readonly paint_transform: NscRenderAffine;
  readonly paint_value: number; readonly paint_stroke: number; readonly paint_border: readonly number[];
  readonly paint_blur: number; readonly paint_text_width: number;
}
interface NscPaintContext {
  readonly paint_numeric: number; readonly paint_tokens: readonly number[];
  readonly paint_strokes: readonly (number | null)[];
}
function nscvPaintMax(c: NscPaintContext, a: number, b: number): number { return nscvRenderExtreme(a, b, c.paint_numeric, true); }
function nscvPaintMin(c: NscPaintContext, a: number, b: number): number { return nscvRenderExtreme(a, b, c.paint_numeric, false); }
function nscvPaintPositive(c: NscPaintContext, v: number): number { return nscvPaintMax(c, 0, v); }
function nscvPaintUnion(c: NscPaintContext, a: NscSurfaceRect | null, b: NscSurfaceRect | null): NscSurfaceRect | null {
  return a === null ? b === null ? null : nscvSurfaceNormalize(b) : b === null ? nscvSurfaceNormalize(a) : nscvRenderUnion(a, b, c.paint_numeric);
}
function nscvPaintInflate(r: NscSurfaceRect, amount: number): NscSurfaceRect {
  const f = Math.fround;
  return { x: f(r.x - amount), y: f(r.y - amount), width: f(f(r.width + amount) + amount), height: f(f(r.height + amount) + amount) };
}
function nscvPaintStroke(c: NscPaintContext, r: NscSurfaceRect, width: number): NscSurfaceRect { return nscvPaintInflate(nscvSurfaceNormalize(r), Math.fround(nscvPaintPositive(c, width) * 0.5)); }
function nscvPaintDensity(c: NscPaintContext): number { return c.paint_tokens[4] === 0 ? 0.875 : c.paint_tokens[4] === 2 ? 1.125 : 1; }
function nscvPaintSized(c: NscPaintContext, n: NscPaintNode, value: number): number {
  return Math.fround(Math.fround(value * nscvPaintDensity(c)) * (n.paint_size === 0 ? 0.875 : n.paint_size === 2 ? 1.125 : 1));
}
function nscvPaintTextSize(c: NscPaintContext, n: NscPaintNode): number {
  const f = Math.fround, base = n.paint_kind === 46 && c.paint_tokens[27] === 1 ? nscvPaintMax(c, 8, f(c.paint_tokens[7]! + c.paint_tokens[8]!)) : c.paint_tokens[7]!;
  return n.paint_size === 0 ? nscvPaintMax(c, 8, f(base - 1)) : n.paint_size === 2 ? f(base + 1) : base;
}
function nscvPaintSnap(c: NscPaintContext, raw: NscSurfaceRect): NscSurfaceRect {
  const scale = c.paint_tokens[6]!;
  if (c.paint_tokens[5] === 0 || !Number.isFinite(scale) || scale <= 0) return raw;
  const r = nscvSurfaceNormalize(raw), f = Math.fround;
  // Zig round uses ties away from zero; JS round uses ties toward +infinity.
  const snap = (v: number): number => { const x = f(v * scale); return f((x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5)) / scale); };
  const x = snap(r.x), y = snap(r.y);
  return { x, y, width: nscvPaintPositive(c, f(snap(nscvSurfaceRight(r)) - x)), height: nscvPaintPositive(c, f(snap(nscvSurfaceBottom(r)) - y)) };
}
function nscvPaintChrome(c: NscPaintContext, n: NscPaintNode): NscSurfaceRect {
  const r = n.paint_authored_frame, f = Math.fround, kind = n.paint_kind;
  if (kind === 47 || kind === 48) {
    const size = nscvPaintMin(c, nscvPaintMax(c, nscvPaintSized(c, n, 16), f(r.height * 0.55)), nscvPaintSized(c, n, 20));
    return nscvPaintSnap(c, { x: r.x, y: f(r.y + f(f(r.height - size) * 0.5)), width: size, height: size });
  }
  if (kind === 49) {
    const width = nscvPaintMin(c, r.width, nscvPaintMax(c, nscvPaintSized(c, n, 44), f(r.height * 1.75))), height = nscvPaintMin(c, r.height, nscvPaintSized(c, n, 24));
    return nscvPaintSnap(c, { x: r.x, y: f(r.y + f(f(r.height - height) * 0.5)), width, height });
  }
  if (kind === 51) {
    const width = nscvPaintMin(c, r.width, nscvPaintSized(c, n, c.paint_tokens[14]!)), height = nscvPaintMin(c, r.height, nscvPaintSized(c, n, c.paint_tokens[15]!));
    const clamp = (v: number, lo: number, hi: number): number => nscvPaintMax(c, lo, nscvPaintMin(c, v, hi));
    const value = clamp(n.paint_value, 0, 1), x = clamp(f(f(r.x + f(r.width * value)) - f(width * 0.5)), r.x, f(r.x + nscvPaintPositive(c, f(r.width - width))));
    return nscvPaintSnap(c, { x, y: f(r.y + f(f(r.height - height) * 0.5)), width, height });
  }
  return r;
}
function nscvPaintWidth(c: NscPaintContext, n: NscPaintNode): number {
  const kind = n.paint_kind, surface = [14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25].includes(kind), button = [31, 32, 33, 50].includes(kind);
  const input = [35, 36, 37, 38, 39, 60].includes(kind), select = kind === 34, selection = [46, 47, 48, 49, 51].includes(kind), cell = kind === 44;
  const component = kind === 29 || kind === 30;
  if (kind === 41 || kind === 42) return (n.paint_state & 4) !== 0 ? c.paint_tokens[0]! : 0;
  if (!surface && !button && !input && !select && !selection && !cell && !component) return 0;
  if (!surface && !component && (n.paint_state & 4) !== 0) return c.paint_tokens[0]!;
  const family = button ? 0 : input ? 1 : selection ? 2 : surface ? 3 : component ? 4 : cell ? 5 : 6;
  const header = new Uint8Array(8);
  header.set([16, 0, family, kind, n.paint_variant, n.paint_size === 0 ? 1 : n.paint_size === 1 ? 0 : n.paint_size, 0, ((n.paint_flags & 256) !== 0 ? 1 : 0) | (c.paint_tokens[26] === 1 ? 2 : 0)]);
  const tables = nscvControlAppearance(header), primary = tables[0]!, fallback = tables[1]!;
  const table = primary === 255 ? null : c.paint_strokes[primary] ?? null, inherited = tables[2] === 1 && fallback !== 255 ? c.paint_strokes[fallback] ?? null : null;
  const authored = (n.paint_flags & 128) !== 0 ? n.paint_stroke : null, visual = table ?? inherited;
  if (authored !== null || visual !== null) return nscvPaintPositive(c, authored ?? visual ?? 0);
  if (button && ((n.paint_flags & 256) !== 0 && c.paint_tokens[26] === 1 || n.paint_variant === 4 || n.paint_variant === 5)) return 0;
  const fallbackWidth = surface || cell || component ? c.paint_tokens[3]! : c.paint_tokens[2]!;
  return button ? fallbackWidth : nscvPaintPositive(c, fallbackWidth);
}
function nscvPaintFocus(c: NscPaintContext, n: NscPaintNode): NscSurfaceRect | null {
  if ((n.paint_state & 4) === 0 || ![31, 32, 33, 34, 35, 36, 37, 38, 39, 60, 41, 42, 44, 46, 47, 48, 49, 50, 51, 62].includes(n.paint_kind) || c.paint_tokens[0]! <= 0) return null;
  return nscvPaintStroke(c, nscvPaintInflate(nscvSurfaceNormalize(nscvPaintChrome(c, n)), nscvPaintPositive(c, c.paint_tokens[1]!)), c.paint_tokens[0]!);
}
function nscvPaintFrameStroke(c: NscPaintContext, n: NscPaintNode): NscSurfaceRect | null {
  const width = nscvPaintWidth(c, n);
  return width <= 0 ? null : nscvPaintStroke(c, nscvPaintChrome(c, n), width);
}
function nscvPaintBlur(c: NscPaintContext, n: NscPaintNode): NscSurfaceRect | null {
  const explicit = nscvPaintPositive(c, n.paint_blur), radius = explicit > 0 ? explicit : n.paint_blur_token === 4294967295 ? 0 : nscvPaintPositive(c, c.paint_tokens[22 + n.paint_blur_token]!);
  return radius <= 0 ? null : nscvPaintInflate(nscvSurfaceNormalize(n.paint_authored_frame), radius);
}
function nscvPaintFramed(n: NscPaintNode, frame: NscSurfaceRect, state: number): NscPaintNode { return { ...n, paint_authored_frame: frame, paint_state: state }; }
function nscvPaintFull(c: NscPaintContext, n: NscPaintNode, transform: NscRenderAffine): NscSurfaceRect {
  let bounds = nscvSurfaceNormalize(n.paint_frame);
  const stroke = nscvPaintFrameStroke(c, n); if (stroke !== null) bounds = nscvRenderUnion(bounds, nscvSurfaceNormalize(stroke), c.paint_numeric);
  const shadow = [14, 15, 16, 22, 40].includes(n.paint_kind) ? 16 : [19, 20, 21, 23, 24, 25].includes(n.paint_kind) ? 19 : -1;
  if (shadow >= 0) {
    const y = c.paint_tokens[shadow]!, blur = c.paint_tokens[shadow + 1]!, spread = c.paint_tokens[shadow + 2]!;
    if (y !== 0 || blur !== 0 || spread !== 0) {
      const r = nscvSurfaceNormalize(n.paint_authored_frame), rect = { ...r, x: Math.fround(r.x + 0), y: Math.fround(r.y + y) };
      bounds = nscvRenderUnion(bounds, nscvSurfaceNormalize(nscvPaintInflate(rect, Math.fround(nscvPaintPositive(c, Math.abs(spread)) + nscvPaintPositive(c, blur)))), c.paint_numeric);
    }
  }
  const backdrop = nscvPaintBlur(c, n); if (backdrop !== null) bounds = nscvRenderUnion(bounds, nscvSurfaceNormalize(backdrop), c.paint_numeric);
  const r = nscvSurfaceNormalize(n.paint_frame), f = Math.fround;
  if (n.paint_kind === 15 && (n.paint_flags & 16) !== 0 && !nscvRenderEmpty(r)) {
    const height = f(f(nscvPaintTextSize(c, n) * 1.25) + 4), width = nscvPaintMax(c, height, f(Math.ceil(n.paint_text_width) + 12));
    // Alignment is a per-node fact; the low two high flag bits carry it.
    const align = (n.paint_flags >>> 9) & 3;
    const x = align === 0 ? f(r.x + 12) : align === 1 ? f(r.x + f(f(r.width - width) * 0.5)) : f(f(nscvSurfaceRight(r) - 12) - width);
    bounds = nscvRenderUnion(bounds, nscvSurfaceNormalize(nscvPaintInflate({ x, y: f(nscvSurfaceBottom(r) - f(height * 0.25)), width, height }, 3)), c.paint_numeric);
  }
  if (n.paint_kind === 46 && c.paint_tokens[27] === 1 && !nscvRenderEmpty(r)) {
    const thickness = nscvPaintMin(c, r.height, nscvPaintSized(c, n, c.paint_tokens[13]!)), textSize = nscvPaintTextSize(c, n);
    const icon = (n.paint_flags & 32) !== 0 ? f(f(textSize + c.paint_tokens[11]!) + ((n.paint_flags & 16) !== 0 ? f(c.paint_tokens[12]! * nscvPaintDensity(c)) : 0)) : 0;
    const content = f(icon + n.paint_text_width), base = nscvPaintPositive(c, c.paint_tokens[9]!), step = c.paint_tokens[10]!;
    const inset = f((n.paint_size === 0 ? nscvPaintPositive(c, f(base - step)) : n.paint_size === 2 ? f(base + step) : base) * nscvPaintDensity(c));
    const width = content > 0 ? nscvPaintMin(c, r.width, f(content + f(inset * 2))) : r.width;
    const bar = nscvPaintSnap(c, { x: f(r.x + f(f(r.width - width) * 0.5)), y: f(nscvSurfaceBottom(r) - thickness), width, height: thickness });
    bounds = nscvRenderUnion(bounds, nscvSurfaceNormalize(bar), c.paint_numeric);
  }
  return nscvSurfaceNormalize(nscvRenderTransform(transform, bounds, c.paint_numeric));
}
function nscvPaintHidden(nodes: readonly NscPaintNode[], slot: number): boolean {
  let n = slot;
  for (let guard = 0; n !== 4294967295 && guard <= nodes.length; guard++) { if (n >= nodes.length) return false; if ((nodes[n]!.paint_flags & 1) !== 0) return true; n = nodes[n]!.paint_parent; }
  if (n !== 4294967295) throw new Error("cyclic paint ancestry");
  return false;
}
function nscvPaintClipped(c: NscPaintContext, nodes: readonly NscPaintNode[], slot: number, raw: NscSurfaceRect | null): NscSurfaceRect | null {
  if (slot >= nodes.length || nscvPaintHidden(nodes, slot) || raw === null) return null;
  let bounds = nscvSurfaceNormalize(raw), current = slot;
  for (let guard = 0; guard <= nodes.length; guard++) {
    const n = nodes[current]!;
    if ((n.paint_flags & 4) !== 0 || [19, 20, 21].includes(n.paint_kind)) return bounds;
    if (n.paint_parent === 4294967295) return bounds;
    if (n.paint_parent >= nodes.length) return null;
    const parent = nodes[n.paint_parent]!;
    if (parent.paint_kind === 6 || (parent.paint_flags & 2) !== 0) { bounds = nscvRenderIntersection(bounds, nscvSurfaceNormalize(parent.paint_frame), c.paint_numeric); if (nscvRenderEmpty(bounds)) return null; }
    current = n.paint_parent;
  }
  throw new Error("cyclic paint clipping");
}
function nscvPaintAccumulated(nodes: readonly NscPaintNode[], slot: number): NscRenderAffine {
  const slots: number[] = []; let current = slot;
  while (current !== 4294967295 && current < nodes.length && slots.length < 32) { slots.push(current); current = nodes[current]!.paint_parent; }
  let t: NscRenderAffine = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
  for (let i = slots.length - 1; i >= 0; i--) t = nscvRenderMultiply(t, nodes[slots[i]!]!.paint_transform);
  return t;
}
function nscvPaintDepthAbove(n: NscPaintNode, root: NscPaintNode): boolean { return n.paint_depth_high > root.paint_depth_high || n.paint_depth_high === root.paint_depth_high && n.paint_depth > root.paint_depth; }
function nscvPaintSubtree(c: NscPaintContext, nodes: readonly NscPaintNode[], slot: number): NscSurfaceRect | null {
  if (slot >= nodes.length) return null;
  const root = nodes[slot]!; let hidden: NscPaintNode | null = null, bounds: NscSurfaceRect | null = null;
  for (let i = slot; i < nodes.length; i++) {
    const n = nodes[i]!;
    if (i !== slot && !nscvPaintDepthAbove(n, root)) break;
    if (hidden !== null) { if (nscvPaintDepthAbove(n, hidden)) continue; hidden = null; }
    if ((n.paint_flags & 1) !== 0) { hidden = n; continue; }
    bounds = nscvPaintUnion(c, bounds, nscvPaintClipped(c, nodes, i, nscvPaintFull(c, n, nscvPaintAccumulated(nodes, i))));
  }
  return bounds;
}
function nscvPaintModal(c: NscPaintContext, n: NscPaintNode, root: NscSurfaceRect | null): NscSurfaceRect | null {
  return (n.paint_flags & 8) !== 0 && [19, 20, 21].includes(n.paint_kind) && (c.paint_tokens[25]! > 0 || nscvPaintPositive(c, c.paint_tokens[28]!) > 0) ? root : null;
}
function nscvPaintStrokeChanged(c: NscPaintContext, a: NscPaintNode, b: NscPaintNode): boolean {
  if (nscvPaintWidth(c, a) !== nscvPaintWidth(c, b) || (a.paint_flags & 64) !== (b.paint_flags & 64)) return true;
  if ((a.paint_flags & 64) !== 0) for (let i = 0; i < 4; i++) if (a.paint_border[i] !== b.paint_border[i]) return true;
  return false;
}
function nscvPaintChanged(c: NscPaintContext, a: NscPaintNode, b: NscPaintNode, render: boolean): NscSurfaceRect | null {
  let bounds: NscSurfaceRect | null = render ? null : nscvPaintUnion(c, a.paint_authored_frame, b.paint_authored_frame);
  if (nscvPaintStrokeChanged(c, a, b)) { bounds = nscvPaintUnion(c, bounds, nscvPaintFrameStroke(c, a)); bounds = nscvPaintUnion(c, bounds, nscvPaintFrameStroke(c, b)); }
  if (!render || (a.paint_state & 4) !== (b.paint_state & 4)) { bounds = nscvPaintUnion(c, bounds, nscvPaintFocus(c, a)); bounds = nscvPaintUnion(c, bounds, nscvPaintFocus(c, b)); }
  if (!render) { bounds = nscvPaintUnion(c, bounds, nscvPaintBlur(c, a)); bounds = nscvPaintUnion(c, bounds, nscvPaintBlur(c, b)); }
  else if ((a.paint_state & 3) !== (b.paint_state & 3)) { bounds = nscvPaintUnion(c, bounds, nscvPaintChrome(c, a)); bounds = nscvPaintUnion(c, bounds, nscvPaintChrome(c, b)); }
  return bounds;
}
function nscvWidgetPaint(request: Uint8Array): Uint8Array {
  if (request.length < 544 || request[0] !== 26 || request[1]! > 2 || request[2] !== 1 || request[3]! > 15) throw new Error("invalid widget paint header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[1]!, beforeCount = w.getUint32(4, true), afterCount = w.getUint32(8, true), payloadSize = w.getUint32(12, true), total = beforeCount + afterCount;
  if (request.length !== 544 + total * 128 + payloadSize || w.getUint32(16, true) < 1 || w.getUint32(16, true) > 2 || w.getUint32(20, true) !== 0 || w.getUint32(24, true) !== 0 || w.getUint32(28, true) > 3) throw new Error("invalid widget paint shape");
  const tokens: number[] = [], strokes: (number | null)[] = [], nodes: NscPaintNode[] = [];
  for (let i = 0; i < 32; i++) tokens.push(w.getFloat32(64 + i * 4, true));
  if (![0, 1, 2].includes(tokens[4]!) || ![0, 1].includes(tokens[5]!) || ![0, 1].includes(tokens[26]!) || ![0, 1].includes(tokens[27]!) || tokens[29] !== 0 || tokens[30] !== 0 || tokens[31] !== 0) throw new Error("invalid widget paint tokens");
  for (let i = 0; i < 43; i++) { const at = 192 + i * 8, presence = w.getUint32(at, true); if (presence > 1) throw new Error("invalid paint stroke presence"); strokes.push(presence === 0 ? null : w.getFloat32(at + 4, true)); }
  for (let i = 536; i < 544; i++) if (request[i] !== 0) throw new Error("invalid widget paint padding");
  for (let i = 0; i < total; i++) {
    const at = 544 + i * 128, kind = w.getUint32(at, true), size = w.getUint32(at + 4, true), variant = w.getUint32(at + 8, true), flags = w.getUint32(at + 20, true), state = w.getUint32(at + 24, true), blurToken = w.getUint32(at + 28, true);
    if (kind > 62 || size > 5 || variant > 5 || flags > 2047 || ((flags >>> 9) & 3) > 2 || state > 1023 || blurToken !== 4294967295 && blurToken > 2 || w.getUint32(at + 124, true) !== 0) throw new Error("invalid widget paint node");
    const border: number[] = []; for (let j = 0; j < 4; j++) border.push(w.getFloat32(at + 96 + j * 4, true));
    nodes.push({ paint_kind: kind, paint_size: size, paint_variant: variant, paint_parent: w.getUint32(at + 12, true), paint_depth: w.getUint32(at + 16, true), paint_depth_high: w.getUint32(at + 120, true), paint_flags: flags, paint_state: state, paint_blur_token: blurToken, paint_frame: nscvRenderRect(w, at + 32), paint_authored_frame: nscvRenderRect(w, at + 48), paint_transform: nscvRenderAffine(w, at + 64), paint_value: w.getFloat32(at + 88, true), paint_stroke: w.getFloat32(at + 92, true), paint_border: border, paint_blur: w.getFloat32(at + 112, true), paint_text_width: w.getFloat32(at + 116, true) });
  }
  const c: NscPaintContext = { paint_numeric: request[3]!, paint_tokens: tokens, paint_strokes: strokes };
  if (mode === 0) {
    const selected: boolean[] = [], order: number[] = []; for (let i = 0; i < total; i++) selected.push(false);
    const planAt = 544 + total * 128, planMode = w.getUint32(16, true);
    if (payloadSize < (planMode === 1 ? 16 : 32) || request[planAt] !== 1 || request[planAt + 1] !== (planMode === 1 ? 0 : 1)) throw new Error("invalid paint measurement payload");
    const length = w.getUint32(planAt + 4, true);
    const mark = (slot: number, offset: number, limit: number, subtree: boolean): void => {
      if (slot >= limit) throw new Error("invalid paint measurement reference");
      const include = (i: number): void => { if (!selected[i]) { selected[i] = true; order.push(i); } };
      if (!subtree) { include(offset + slot); return; }
      const root = nodes[offset + slot]!; let hidden: NscPaintNode | null = null;
      for (let i = slot; i < limit; i++) { const n = nodes[offset + i]!; if (i !== slot && !nscvPaintDepthAbove(n, root)) break; if (hidden !== null) { if (nscvPaintDepthAbove(n, hidden)) continue; hidden = null; } if ((n.paint_flags & 1) !== 0) { hidden = n; continue; } include(offset + i); }
    };
    if (planMode === 1) {
      if (payloadSize !== 16 + length * 16) throw new Error("invalid paint measurement diff");
      for (let i = 0; i < length; i++) { const p = planAt + 16 + i * 16, kind = w.getUint32(p, true), a = w.getUint32(p + 4, true), b = w.getUint32(p + 8, true), flags = w.getUint32(p + 12, true); if (kind > 2 || flags > 127) throw new Error("invalid paint measurement entry"); if (kind === 0) mark(a, 0, beforeCount, false); else if (kind === 2) mark(b, beforeCount, afterCount, false); else if ((flags & 121) !== 0) { mark(a, 0, beforeCount, (flags & 48) !== 0); mark(b, beforeCount, afterCount, (flags & 48) !== 0); } }
    } else {
      if (afterCount !== 0 || payloadSize !== 32 + length * 16 + (w.getUint32(planAt + 8, true) + w.getUint32(planAt + 12, true)) * 4) throw new Error("invalid paint measurement render");
      for (let i = 0; i < length; i++) { const p = planAt + 32 + i * 16; if ((w.getUint32(p + 4, true) & 2) !== 0) mark(w.getUint32(p, true), 0, beforeCount, false); }
    }
    const result = new Uint8Array(8 + total * 8), out = new DataView(result.buffer); result[0] = 1;
    let count = 0;
    for (let position = 0; position < order.length; position++) {
      const i = order[position]!;
      const n = nodes[i]!;
      if (selected[i] && (n.paint_kind === 15 && (n.paint_flags & 16) !== 0 || n.paint_kind === 46 && tokens[27] === 1) && !nscvRenderEmpty(nscvSurfaceNormalize(n.paint_frame))) { out.setUint32(8 + count * 8, i, true); out.setFloat32(12 + count * 8, nscvPaintTextSize(c, n), true); count++; }
    }
    out.setUint32(4, count, true); return result.subarray(0, 8 + count * 8);
  }
  if (mode !== w.getUint32(16, true)) throw new Error("inconsistent paint plan mode");
  const at = 544 + total * 128, presence = w.getUint32(28, true), previousRoot = (presence & 1) !== 0 ? nscvRenderRect(w, 32) : null, nextRoot = (presence & 2) !== 0 ? nscvRenderRect(w, 48) : null;
  const before = nodes.slice(0, beforeCount), after = nodes.slice(beforeCount);
  if (payloadSize < 16 || w.getUint8(at) !== 1 || w.getUint8(at + 1) !== (mode === 1 ? 0 : 1)) throw new Error("invalid paint plan payload");
  const length = w.getUint32(at + 4, true), result = new Uint8Array(8 + (mode === 1 ? length : 1) * 20), out = new DataView(result.buffer); result[0] = 1; result[1] = mode;
  out.setUint32(4, mode === 1 ? length : 1, true);
  if (mode === 1) {
    if (payloadSize !== 16 + length * 16) throw new Error("invalid paint diff payload");
    for (let i = 0; i < length; i++) {
      const p = at + 16 + i * 16, kind = w.getUint32(p, true), a = w.getUint32(p + 4, true), b = w.getUint32(p + 8, true), flags = w.getUint32(p + 12, true);
      if (kind > 2 || flags > 127 || kind !== 2 && a >= before.length || kind !== 0 && b >= after.length) throw new Error("invalid paint diff entry");
      let bounds: NscSurfaceRect | null = null;
      if (kind === 0) { const n = before[a]!; bounds = nscvPaintClipped(c, before, a, nscvPaintUnion(c, nscvPaintFull(c, n, n.paint_transform), nscvPaintModal(c, n, previousRoot))); }
      else if (kind === 2) { const n = after[b]!; bounds = nscvPaintClipped(c, after, b, nscvPaintUnion(c, nscvPaintFull(c, n, n.paint_transform), nscvPaintModal(c, n, nextRoot))); }
      else {
        const x = before[a]!, y = after[b]!;
        if ((flags & 48) !== 0) bounds = nscvPaintUnion(c, nscvPaintUnion(c, nscvPaintSubtree(c, before, a), nscvPaintModal(c, x, previousRoot)), nscvPaintUnion(c, nscvPaintSubtree(c, after, b), nscvPaintModal(c, y, nextRoot)));
        else {
          const full = (): NscSurfaceRect | null => nscvPaintUnion(c, nscvPaintFull(c, x, x.paint_transform), nscvPaintFull(c, y, y.paint_transform));
          const raw = (flags & 8) !== 0 ? nscvPaintUnion(c, full(), nscvPaintUnion(c, previousRoot, nextRoot)) : (flags & 81) !== 0 ? full() : (flags & 2) !== 0 ? nscvPaintChanged(c, x, y, false) : null;
          bounds = nscvPaintUnion(c, nscvPaintClipped(c, before, a, raw), nscvPaintClipped(c, after, b, raw));
        }
      }
      nscvRenderPutOptional(out, 8 + i * 20, bounds);
    }
  } else {
    if (afterCount !== 0 || payloadSize < 32) throw new Error("invalid paint render shape");
    const g0 = w.getUint32(at + 8, true), g1 = w.getUint32(at + 12, true);
    if (payloadSize !== 32 + length * 16 + (g0 + g1) * 4) throw new Error("invalid paint render payload");
    let bounds: NscSurfaceRect | null = null;
    for (let i = 0; i < length; i++) {
      const p = at + 32 + i * 16, slot = w.getUint32(p, true), flags = w.getUint32(p + 4, true), a = w.getUint32(p + 8, true), b = w.getUint32(p + 12, true);
      if (slot >= before.length || flags > 3 || a > 1023 || b > 1023) throw new Error("invalid paint render entry");
      const n = before[slot]!;
      if ((flags & 2) !== 0) bounds = nscvPaintUnion(c, bounds, nscvPaintClipped(c, before, slot, nscvPaintFull(c, n, nscvPaintAccumulated(before, slot))));
      if ((flags & 1) !== 0) bounds = nscvPaintUnion(c, bounds, nscvPaintClipped(c, before, slot, nscvPaintChanged(c, nscvPaintFramed(n, n.paint_frame, a), nscvPaintFramed(n, n.paint_frame, b), true)));
    }
    const groups = [g0, g1]; let position = at + 32 + length * 16;
    for (let g = 0; g < 2; g++) {
      let group: NscSurfaceRect | null = null;
      for (let i = 0; i < groups[g]!; i++) { const slot = w.getUint32(position, true); position += 4; if (slot >= before.length || before[slot]!.paint_kind !== 60) throw new Error("invalid paint focus group"); const n = before[slot]!; group = nscvPaintUnion(c, group, nscvPaintClipped(c, before, slot, nscvPaintFocus(c, nscvPaintFramed(n, n.paint_frame, n.paint_state | 4)))); }
      bounds = nscvPaintUnion(c, bounds, group);
    }
    nscvRenderPutOptional(out, 8, bounds);
  }
  return result;
}
