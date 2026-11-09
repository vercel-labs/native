/** Retained presentation geometry over copied layout and motion facts. */
interface NscPresentationNode {
  readonly presentation_kind: number; readonly presentation_flags: number;
  readonly presentation_parent: number; readonly presentation_parent_high: number;
  readonly presentation_id: number; readonly presentation_id_high: number;
  readonly presentation_frame: NscSurfaceRect; readonly presentation_transform: NscRenderAffine;
}
interface NscPresentationMotion {
  readonly presentation_id: number; readonly presentation_id_high: number;
  readonly presentation_dx: number; readonly presentation_dy: number; readonly presentation_escape: boolean;
}
interface NscPresentationContext {
  readonly presentation_nodes: readonly NscPresentationNode[]; readonly presentation_motions: readonly NscPresentationMotion[];
  readonly presentation_numeric: number; readonly presentation_flags: number; readonly presentation_root: NscSurfaceRect | null;
  readonly presentation_drag: number; readonly presentation_drag_high: number;
  readonly presentation_origin_x: number; readonly presentation_origin_y: number;
  readonly presentation_offset_x: number; readonly presentation_offset_y: number; readonly presentation_scale: number;
}
function nscvPresentationIdentity(): NscRenderAffine { return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }; }
function nscvPresentationHoisted(n: NscPresentationNode): boolean { return (n.presentation_flags & 2) !== 0 || n.presentation_kind === 19 || n.presentation_kind === 20 || n.presentation_kind === 21; }
function nscvPresentationParent(c: NscPresentationContext, n: NscPresentationNode): number {
  return (n.presentation_flags & 1) === 0 ? -1 : n.presentation_parent_high !== 0 || n.presentation_parent >= c.presentation_nodes.length ? c.presentation_nodes.length : n.presentation_parent;
}
function nscvPresentationMotion(c: NscPresentationContext, n: NscPresentationNode, preview: boolean): NscPresentationMotion | null {
  if (preview || (n.presentation_id === 0 && n.presentation_id_high === 0)) return null;
  for (const m of c.presentation_motions) if (m.presentation_id === n.presentation_id && m.presentation_id_high === n.presentation_id_high) return m;
  return null;
}
function nscvPresentationTransform(c: NscPresentationContext, slot: number, motion: boolean, preview: boolean, outer: NscRenderAffine): NscRenderAffine | null {
  const indices: number[] = [];
  let current = slot;
  while (current !== -1) {
    if (current >= c.presentation_nodes.length || indices.length >= 32) return null;
    indices.push(current);
    const n = c.presentation_nodes[current]!;
    if (nscvPresentationHoisted(n)) break;
    current = nscvPresentationParent(c, n);
  }
  let t = outer;
  for (let i = indices.length - 1; i >= 0; i--) {
    const n = c.presentation_nodes[indices[i]!]!, m = motion ? nscvPresentationMotion(c, n, preview) : null;
    if (m !== null && (m.presentation_dx !== 0 || m.presentation_dy !== 0)) t = nscvRenderMultiply(t, { ...nscvPresentationIdentity(), tx: m.presentation_dx, ty: m.presentation_dy });
    t = nscvRenderMultiply(t, n.presentation_transform);
  }
  return t;
}
function nscvPresentationAncestor(c: NscPresentationContext, slot: number): NscRenderAffine | null {
  if (slot >= c.presentation_nodes.length) return null;
  const n = c.presentation_nodes[slot]!;
  if (nscvPresentationHoisted(n)) return nscvPresentationIdentity();
  const p = nscvPresentationParent(c, n);
  return p === -1 ? nscvPresentationIdentity() : nscvPresentationTransform(c, p, false, false, nscvPresentationIdentity());
}
function nscvPresentationDrag(c: NscPresentationContext): NscRenderAffine | null {
  if ((c.presentation_flags & 2) === 0 || (c.presentation_drag === 0 && c.presentation_drag_high === 0)) return null;
  for (let i = 0; i < c.presentation_nodes.length; i++) {
    const n = c.presentation_nodes[i]!;
    if (n.presentation_id !== c.presentation_drag || n.presentation_id_high !== c.presentation_drag_high) continue;
    const t = nscvPresentationAncestor(c, i); if (t === null) return null;
    const r = nscvSurfaceNormalize(n.presentation_frame), f = Math.fround;
    const x = (c.presentation_flags & 4) !== 0 ? c.presentation_origin_x : r.x, y = (c.presentation_flags & 4) !== 0 ? c.presentation_origin_y : r.y;
    const currentX = f(f(f(t.a * r.x) + f(t.c * r.y)) + t.tx), currentY = f(f(f(t.b * r.x) + f(t.d * r.y)) + t.ty);
    const sourceX = f(f(f(t.a * x) + f(t.c * y)) + t.tx), sourceY = f(f(f(t.b * x) + f(t.d * y)) + t.ty);
    return { ...nscvPresentationIdentity(), tx: f(f(sourceX + c.presentation_offset_x) - currentX), ty: f(f(sourceY + c.presentation_offset_y) - currentY) };
  }
  return null;
}
function nscvPresentationInverse(t: NscRenderAffine): NscRenderAffine | null {
  const f = Math.fround, determinant = f(f(t.a * t.d) - f(t.b * t.c));
  if (Math.abs(determinant) <= Math.fround(0.000001)) return null;
  const inv = f(1 / determinant);
  return { a: f(t.d * inv), b: f(-t.b * inv), c: f(-t.c * inv), d: f(t.a * inv), tx: f(f(f(t.c * t.ty) - f(t.d * t.tx)) * inv), ty: f(f(f(t.b * t.tx) - f(t.a * t.ty)) * inv) };
}
function nscvPresentationSnap(c: NscPresentationContext, raw: NscSurfaceRect): NscSurfaceRect {
  const scale = c.presentation_scale;
  if ((c.presentation_flags & 8) === 0 || !Number.isFinite(scale) || scale <= 0) return raw;
  const f = Math.fround, r = nscvSurfaceNormalize(raw);
  const snap = (v: number): number => { const x = f(v * scale); return f((x < 0 || 1 / x < 0 ? -Math.floor(-x + 0.5) : Math.floor(x + 0.5)) / scale); };
  const x = snap(r.x), y = snap(r.y);
  return { x, y, width: nscvRenderExtreme(0, f(snap(nscvSurfaceRight(r)) - x), c.presentation_numeric, true), height: nscvRenderExtreme(0, f(snap(nscvSurfaceBottom(r)) - y), c.presentation_numeric, true) };
}
function nscvPresentationVisible(c: NscPresentationContext, slot: number, preview: boolean, outer: NscRenderAffine | null): NscSurfaceRect | null {
  if (c.presentation_root === null || outer === null) return null;
  let visible = nscvSurfaceNormalize(c.presentation_root), current = slot;
  for (let guard = 0; guard <= c.presentation_nodes.length; guard++) {
    const n = c.presentation_nodes[current]!;
    const dragRoot = preview && (c.presentation_flags & 2) !== 0 && c.presentation_drag === n.presentation_id && c.presentation_drag_high === n.presentation_id_high;
    const m = nscvPresentationMotion(c, n, preview);
    if (nscvPresentationHoisted(n) || dragRoot || (m !== null && m.presentation_escape)) break;
    const parent = nscvPresentationParent(c, n);
    if (parent === -1) break;
    if (parent >= c.presentation_nodes.length || guard === c.presentation_nodes.length) return null;
    const p = c.presentation_nodes[parent]!;
    if (p.presentation_kind === 6 || (p.presentation_flags & 4) !== 0) {
      const transform = nscvPresentationTransform(c, parent, true, preview, outer); if (transform === null) return null;
      visible = nscvRenderIntersection(visible, nscvRenderTransform(transform, nscvSurfaceNormalize(p.presentation_frame), c.presentation_numeric), c.presentation_numeric);
      if (nscvRenderEmpty(visible)) return null;
    }
    current = parent;
  }
  const transform = nscvPresentationTransform(c, slot, true, preview, outer); if (transform === null) return null;
  const inverse = nscvPresentationInverse(transform); if (inverse === null) return null;
  const local = nscvRenderTransform(inverse, visible, c.presentation_numeric);
  const clipped = nscvRenderIntersection(nscvSurfaceNormalize(nscvPresentationSnap(c, c.presentation_nodes[slot]!.presentation_frame)), nscvSurfaceNormalize(local), c.presentation_numeric);
  return nscvRenderEmpty(clipped) ? null : clipped;
}
function nscvPresentationPutTransform(w: DataView, at: number, t: NscRenderAffine | null): void {
  w.setUint32(at, t === null ? 0 : 1, true);
  nscvRenderPutAffine(w, at + 4, t ?? { a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0 });
}
function nscvWidgetPresentation(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[1]! > 1 || request[2] !== 1 || request[3]! > 15) throw new Error("invalid presentation header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), motionCount = w.getUint32(8, true), flags = w.getUint32(12, true);
  if (flags > 31 || request.length !== 64 + count * 64 + motionCount * 24 || w.getUint32(60, true) !== 0 || (request[1] === 0 && motionCount !== 0)) throw new Error("invalid presentation shape");
  const nodes: NscPresentationNode[] = [], motions: NscPresentationMotion[] = [];
  for (let i = 0; i < count; i++) {
    const at = 64 + i * 64, kind = w.getUint32(at, true), nodeFlags = w.getUint32(at + 4, true);
    if (kind > 62 || nodeFlags > 15) throw new Error("invalid presentation node");
    nodes.push({ presentation_kind: kind, presentation_flags: nodeFlags, presentation_parent: w.getUint32(at + 8, true), presentation_parent_high: w.getUint32(at + 12, true), presentation_id: w.getUint32(at + 16, true), presentation_id_high: w.getUint32(at + 20, true), presentation_frame: nscvRenderRect(w, at + 24), presentation_transform: nscvRenderAffine(w, at + 40) });
  }
  for (let i = 0; i < motionCount; i++) {
    const at = 64 + count * 64 + i * 24;
    if (w.getUint32(at + 16, true) > 1 || w.getUint32(at + 20, true) !== 0) throw new Error("invalid presentation motion");
    motions.push({ presentation_id: w.getUint32(at, true), presentation_id_high: w.getUint32(at + 4, true), presentation_dx: w.getFloat32(at + 8, true), presentation_dy: w.getFloat32(at + 12, true), presentation_escape: w.getUint32(at + 16, true) === 1 });
  }
  let root: NscSurfaceRect | null = (flags & 1) !== 0 ? nscvSurfaceNormalize(nscvRenderRect(w, 16)) : null;
  if ((flags & 1) === 0) for (const n of nodes) if ((n.presentation_flags & 1) === 0) { const r = nscvSurfaceNormalize(n.presentation_frame); root = root === null ? r : nscvRenderUnion(root, r, request[3]!); }
  const c: NscPresentationContext = { presentation_nodes: nodes, presentation_motions: motions, presentation_numeric: request[3]!, presentation_flags: flags, presentation_root: root, presentation_drag: w.getUint32(32, true), presentation_drag_high: w.getUint32(36, true), presentation_origin_x: w.getFloat32(40, true), presentation_origin_y: w.getFloat32(44, true), presentation_offset_x: w.getFloat32(48, true), presentation_offset_y: w.getFloat32(52, true), presentation_scale: w.getFloat32(56, true) };
  const resultCount = request[1] === 0 ? 0 : count, result = new Uint8Array(56 + resultCount * 152), out = new DataView(result.buffer), drag = request[1] === 0 ? null : nscvPresentationDrag(c), preview = (flags & 16) !== 0;
  result.set([1, request[1]!, 0, 0]); out.setUint32(4, resultCount, true); nscvRenderPutOptional(out, 8, root); nscvPresentationPutTransform(out, 28, drag);
  for (let i = 0; i < resultCount; i++) {
    const at = 56 + i * 152, ordinary = nscvPresentationTransform(c, i, false, false, nscvPresentationIdentity()), outer = preview ? drag : nscvPresentationIdentity();
    nscvPresentationPutTransform(out, at, ordinary); nscvPresentationPutTransform(out, at + 28, nscvPresentationAncestor(c, i));
    nscvPresentationPutTransform(out, at + 56, !preview && motionCount === 0 ? ordinary : outer === null ? null : nscvPresentationTransform(c, i, true, preview, outer));
    nscvPresentationPutTransform(out, at + 84, drag === null ? null : nscvPresentationTransform(c, i, true, true, drag));
    const text = (nodes[i]!.presentation_flags & 8) !== 0;
    nscvRenderPutOptional(out, at + 112, text ? nscvPresentationVisible(c, i, preview, outer) : null);
    nscvRenderPutOptional(out, at + 132, text ? nscvPresentationVisible(c, i, true, drag) : null);
  }
  return result;
}
