/** Retained paint scheduling over copied layout, state and command identities.
 * Native executes drawing capabilities; this plan owns traversal decisions. */
interface NscWalkNode {
  readonly walk_kind: number; readonly walk_flags: number;
  readonly walk_parent: number; readonly walk_parent_high: number;
  readonly walk_id: number; readonly walk_id_high: number;
  readonly walk_preview_id: number; readonly walk_preview_id_high: number;
  readonly walk_depth: number; readonly walk_depth_high: number; readonly walk_layer: number;
  readonly walk_frame: NscSurfaceRect; readonly walk_transform: NscRenderAffine;
  readonly walk_opacity: number; readonly walk_opacity_word: number; readonly walk_value: number; readonly walk_gap: number;
}
interface NscWalkMotion extends NscPresentationMotion { readonly walk_dx_word: number; readonly walk_dy_word: number; }
interface NscWalkOrder { readonly walk_slot: number; readonly walk_layer: number; }
interface NscWalkContext {
  readonly walk_nodes: readonly NscWalkNode[]; readonly walk_motions: readonly NscWalkMotion[];
  readonly walk_reveals: readonly number[]; readonly walk_ids: readonly number[];
  readonly walk_flags: number; readonly walk_scalar: number; readonly walk_numeric: number; readonly walk_nan: number; readonly walk_layers: readonly number[];
}
function nscvWalkHoisted(n: NscWalkNode): boolean { return (n.walk_flags & 2) !== 0 || n.walk_kind === 19 || n.walk_kind === 20 || n.walk_kind === 21; }
function nscvWalkParent(c: NscWalkContext, n: NscWalkNode): number {
  return (n.walk_flags & 1) === 0 ? -1 : n.walk_parent_high !== 0 || n.walk_parent >= c.walk_nodes.length ? c.walk_nodes.length : n.walk_parent;
}
function nscvWalkSameParent(a: NscWalkNode, b: NscWalkNode): boolean {
  return (a.walk_flags & 1) === (b.walk_flags & 1) && ((a.walk_flags & 1) === 0 || (a.walk_parent === b.walk_parent && a.walk_parent_high === b.walk_parent_high));
}
function nscvWalkId(n: NscWalkNode, ids: readonly number[], at: number): boolean { return n.walk_id === ids[at] && n.walk_id_high === ids[at + 1]; }
function nscvWalkNonzero(n: NscWalkNode): boolean { return n.walk_id !== 0 || n.walk_id_high !== 0; }
function nscvWalkLayer(c: NscWalkContext, n: NscWalkNode, surface: boolean): number {
  if ((n.walk_flags & 8) !== 0) return n.walk_layer;
  if (n.walk_kind === 19 || n.walk_kind === 20 || n.walk_kind === 21) return c.walk_layers[3]!;
  if ((surface && (n.walk_flags & 2) !== 0) || n.walk_kind === 23 || n.walk_kind === 24 || n.walk_kind === 25) return c.walk_layers[1]!;
  return c.walk_layers[n.walk_kind === 40 ? 2 : 0]!;
}
function nscvWalkSurfaceLayer(c: NscWalkContext, slot: number): number {
  const n = c.walk_nodes[slot]!;
  let layer = nscvWalkLayer(c, n, true);
  if ((n.walk_flags & 8) !== 0) return layer;
  let parent = nscvWalkParent(c, n);
  while (parent >= 0 && parent < c.walk_nodes.length) {
    const ancestor = c.walk_nodes[parent]!;
    if (nscvWalkHoisted(ancestor)) layer = Math.max(layer, nscvWalkLayer(c, ancestor, true));
    parent = nscvWalkParent(c, ancestor);
  }
  return layer;
}
function nscvWalkCompare(a: NscWalkOrder, b: NscWalkOrder): number { return a.walk_layer === b.walk_layer ? a.walk_slot - b.walk_slot : a.walk_layer - b.walk_layer; }
function nscvWalkDeeper(a: NscWalkNode, b: NscWalkNode): boolean { return a.walk_depth_high > b.walk_depth_high || (a.walk_depth_high === b.walk_depth_high && a.walk_depth > b.walk_depth); }
function nscvWalkSelected(n: NscWalkNode): boolean { return (n.walk_flags & 128) !== 0 || n.walk_value >= 0.5; }
function nscvWalkSettled(c: NscWalkContext, slot: number): boolean {
  const n = c.walk_nodes[slot]!;
  if (!nscvWalkSelected(n)) return false;
  let bottom = -Infinity, i = slot + 1;
  while (i < c.walk_nodes.length && nscvWalkDeeper(c.walk_nodes[i]!, n)) {
    const child = c.walk_nodes[i]!;
    if (!nscvWalkHoisted(child)) bottom = nscvRenderExtreme(bottom, nscvSurfaceBottom(nscvSurfaceNormalize(child.walk_frame)), c.walk_numeric, true);
    i++;
    if (nscvWalkHoisted(child) || child.walk_kind === 14) while (i < c.walk_nodes.length && nscvWalkDeeper(c.walk_nodes[i]!, child)) i++;
  }
  return bottom === -Infinity || bottom <= Math.fround(nscvSurfaceBottom(nscvSurfaceNormalize(n.walk_frame)) + 0.5);
}
function nscvWalkVisible(c: NscWalkContext, slot: number): boolean {
  let current = slot;
  while (current >= 0 && current < c.walk_nodes.length) {
    const n = c.walk_nodes[current]!;
    if ((n.walk_flags & 4) !== 0 || (current !== slot && n.walk_kind === 14 && !nscvWalkSettled(c, current))) return false;
    current = nscvWalkParent(c, n);
  }
  return true;
}
function nscvWalkMotion(c: NscWalkContext, n: NscWalkNode, preview: boolean): NscWalkMotion | null {
  if (preview || (c.walk_flags & 64) !== 0 || !nscvWalkNonzero(n)) return null;
  for (const m of c.walk_motions) if (m.presentation_id === n.walk_id && m.presentation_id_high === n.walk_id_high) return m;
  return null;
}
function nscvWalkWithin(c: NscWalkContext, slot: number, target: number): boolean {
  let current = slot;
  while (current >= 0 && current < c.walk_nodes.length) {
    if (current === target) return true;
    current = nscvWalkParent(c, c.walk_nodes[current]!);
  }
  return false;
}
function nscvWalkGroupFocus(c: NscWalkContext, slot: number, preview: boolean, focused: boolean): boolean {
  if (focused) return true;
  if (!preview && (c.walk_flags & 6) !== 0) {
    if ((c.walk_flags & 4) === 0 || (c.walk_ids[2] === 0 && c.walk_ids[3] === 0)) return false;
    for (let i = 0; i < c.walk_nodes.length; i++) if (nscvWalkId(c.walk_nodes[i]!, c.walk_ids, 2)) return nscvWalkWithin(c, i, slot);
    return false;
  }
  for (let i = 0; i < c.walk_nodes.length; i++) if (i !== slot && (c.walk_nodes[i]!.walk_flags & 16) !== 0 && nscvWalkWithin(c, i, slot)) return true;
  return false;
}
function nscvWalkDisclosure(c: NscWalkContext, slot: number, preview: boolean): number {
  const n = c.walk_nodes[slot]!;
  if (n.walk_kind !== 14 || nscvWalkSelected(n)) return nscvWalkSettled(c, slot) || n.walk_kind !== 14 ? 2 : 1;
  const remapped = preview || (c.walk_flags & 64) !== 0, low = remapped ? n.walk_preview_id : n.walk_id, high = remapped ? n.walk_preview_id_high : n.walk_id_high;
  if (low === 0 && high === 0) return 0;
  for (let i = 0; i < c.walk_reveals.length; i += 2) if (low === c.walk_reveals[i] && high === c.walk_reveals[i + 1]) return 1;
  return 0;
}
// The target supplies the invalid-operation NaN word. JavaScript does not
// specify its sign; transferred NaN operands retain their own payload/sign.
function nscvWalkMultiply(c: NscWalkContext, a: number, b: number): number {
  if (Number.isNaN(a)) return a;
  if (Number.isNaN(b)) return b;
  if ((a === 0 && !Number.isFinite(b)) || (b === 0 && !Number.isFinite(a))) return c.walk_nan;
  return Math.fround(a * b);
}
function nscvWalkSubtract(c: NscWalkContext, a: number, b: number): number {
  if (Number.isNaN(a)) return a;
  if (Number.isNaN(b)) return b;
  return !Number.isFinite(a) && a === b ? c.walk_nan : Math.fround(a - b);
}
function nscvWalkDivide(c: NscWalkContext, a: number, b: number): number {
  if (Number.isNaN(a)) return a;
  if (Number.isNaN(b)) return b;
  return (a === 0 && b === 0) || (!Number.isFinite(a) && !Number.isFinite(b)) ? c.walk_nan : Math.fround(a / b);
}
function nscvWalkNegativeMultiply(c: NscWalkContext, a: number, b: number): number {
  return (c.walk_scalar & 2) !== 0 ? -nscvWalkMultiply(c, a, b) : nscvWalkMultiply(c, -a, b);
}
function nscvWalkInverse(c: NscWalkContext, t: NscRenderAffine): NscRenderAffine | null {
  const det = nscvWalkSubtract(c, nscvWalkMultiply(c, t.a, t.d), nscvWalkMultiply(c, t.b, t.c));
  if (Math.abs(det) <= Math.fround(0.000001)) return null;
  const inv = nscvWalkDivide(c, 1, det);
  return { a: nscvWalkMultiply(c, t.d, inv), b: nscvWalkNegativeMultiply(c, t.b, inv), c: nscvWalkNegativeMultiply(c, t.c, inv), d: nscvWalkMultiply(c, t.a, inv), tx: nscvWalkMultiply(c, nscvWalkSubtract(c, nscvWalkMultiply(c, t.c, t.ty), nscvWalkMultiply(c, t.d, t.tx)), inv), ty: nscvWalkMultiply(c, nscvWalkSubtract(c, nscvWalkMultiply(c, t.b, t.tx), nscvWalkMultiply(c, t.a, t.ty)), inv) };
}
function nscvWalkPutLane(out: DataView, at: number, c: NscWalkContext, slot: number, preview: boolean): void {
  const n = c.walk_nodes[slot]!, nonzero = nscvWalkNonzero(n), runtimeFocus = !preview && (c.walk_flags & 6) !== 0;
  const focusMask = n.walk_kind === 41 ? 2 : 4, focusAt = n.walk_kind === 41 ? 0 : 2;
  const focused = runtimeFocus ? nonzero && (c.walk_flags & focusMask) !== 0 && nscvWalkId(n, c.walk_ids, focusAt) : (n.walk_flags & 16) !== 0;
  const hovered = !preview && (c.walk_flags & 8) !== 0 ? nonzero && nscvWalkId(n, c.walk_ids, 4) : (n.walk_flags & 32) !== 0;
  const pressed = !preview && (c.walk_flags & 16) !== 0 ? nonzero && nscvWalkId(n, c.walk_ids, 6) : (n.walk_flags & 64) !== 0;
  const logicalId = (c.walk_flags & 64) !== 0 ? n.walk_preview_id === c.walk_ids[0] && n.walk_preview_id_high === c.walk_ids[1] : nscvWalkId(n, c.walk_ids, 0);
  const logical = (preview || (c.walk_flags & 1) !== 0) && (runtimeFocus ? nonzero && (c.walk_flags & 2) !== 0 && logicalId : (n.walk_flags & 16) !== 0);
  const skip = (n.walk_flags & 4) !== 0 || (!preview && (c.walk_flags & 64) === 0 && (c.walk_flags & 32) !== 0 && nscvWalkId(n, c.walk_ids, 8) && n.walk_kind !== 16 && n.walk_kind !== 58);
  const signaling = (n.walk_opacity_word & 0x7f800000) === 0x7f800000 && (n.walk_opacity_word & 0x7fffff) !== 0 && (n.walk_opacity_word & 0x400000) === 0;
  const opacity = signaling && (c.walk_scalar & 1) !== 0 ? 0 : nscvRenderExtreme(0, nscvRenderExtreme(n.walk_opacity, 1, c.walk_numeric, false), c.walk_numeric, true), m = nscvWalkMotion(c, n, preview), t = n.walk_transform;
  const wrapTransform = t.a !== 1 || t.b !== 0 || t.c !== 0 || t.d !== 1 || t.tx !== 0 || t.ty !== 0;
  const inverse = wrapTransform ? nscvWalkInverse(c, t) : nscvPresentationIdentity();
  const flags = (focused ? 1 : 0) | (hovered ? 2 : 0) | (pressed ? 4 : 0) | (logical ? 8 : 0) | ((n.walk_kind === 60 ? nscvWalkGroupFocus(c, slot, preview, focused) : focused) ? 16 : 0) | (skip ? 32 : 0) | (opacity < 1 ? 64 : 0) | (m !== null && (m.presentation_dx !== 0 || m.presentation_dy !== 0) ? 128 : 0) | (wrapTransform ? 256 : 0) | (nscvWalkHoisted(n) || (m !== null && m.presentation_escape) ? 512 : 0) | (nscvWalkDisclosure(c, slot, preview) << 10);
  out.setUint32(at, flags, true); if (Number.isNaN(opacity)) out.setUint32(at + 4, n.walk_opacity_word, true); else out.setFloat32(at + 4, opacity, true); out.setUint32(at + 8, m === null ? 0 : m.walk_dx_word, true); out.setUint32(at + 12, m === null ? 0 : m.walk_dy_word, true);
  nscvPresentationPutTransform(out, at + 16, inverse);
}
function nscvWidgetPaintWalk(request: Uint8Array): Uint8Array {
  if (request.length < 80 || request[1] !== 1 || request[2]! > 15 || request[3]! > 3) throw new Error("invalid paint walk header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), motionCount = w.getUint32(8, true), revealCount = w.getUint32(12, true), flags = w.getUint32(16, true);
  if (flags > 255 || !Number.isNaN(w.getFloat32(76, true)) || request.length !== 80 + count * 96 + motionCount * 24 + revealCount * 8) throw new Error("invalid paint walk shape");
  const nodes: NscWalkNode[] = [], motions: NscWalkMotion[] = [], reveals: number[] = [], ids: number[] = [], layers: number[] = [];
  for (let i = 0; i < 4; i++) layers.push(w.getInt32(20 + i * 4, true));
  for (let i = 0; i < 10; i++) ids.push(w.getUint32(36 + i * 4, true));
  for (let i = 0; i < count; i++) {
    const at = 80 + i * 96, kind = w.getUint32(at, true), nodeFlags = w.getUint32(at + 4, true);
    if (kind > 62 || nodeFlags > 255) throw new Error("invalid paint walk node");
    nodes.push({ walk_kind: kind, walk_flags: nodeFlags, walk_parent: w.getUint32(at + 8, true), walk_parent_high: w.getUint32(at + 12, true), walk_id: w.getUint32(at + 16, true), walk_id_high: w.getUint32(at + 20, true), walk_preview_id: w.getUint32(at + 24, true), walk_preview_id_high: w.getUint32(at + 28, true), walk_depth: w.getUint32(at + 32, true), walk_depth_high: w.getUint32(at + 36, true), walk_layer: w.getInt32(at + 40, true), walk_frame: nscvRenderRect(w, at + 44), walk_transform: nscvRenderAffine(w, at + 60), walk_opacity: w.getFloat32(at + 84, true), walk_opacity_word: w.getUint32(at + 84, true), walk_value: w.getFloat32(at + 88, true), walk_gap: w.getFloat32(at + 92, true) });
  }
  for (let i = 0; i < motionCount; i++) {
    const at = 80 + count * 96 + i * 24;
    if (w.getUint32(at + 16, true) > 1 || w.getUint32(at + 20, true) !== 0) throw new Error("invalid paint walk motion");
    motions.push({ presentation_id: w.getUint32(at, true), presentation_id_high: w.getUint32(at + 4, true), presentation_dx: w.getFloat32(at + 8, true), presentation_dy: w.getFloat32(at + 12, true), presentation_escape: w.getUint32(at + 16, true) === 1, walk_dx_word: w.getUint32(at + 8, true), walk_dy_word: w.getUint32(at + 12, true) });
  }
  for (let i = 0; i < revealCount * 2; i++) reveals.push(w.getUint32(80 + count * 96 + motionCount * 24 + i * 4, true));
  const c: NscWalkContext = { walk_nodes: nodes, walk_motions: motions, walk_reveals: reveals, walk_ids: ids, walk_flags: flags, walk_scalar: request[3]!, walk_numeric: request[2]!, walk_nan: w.getFloat32(76, true), walk_layers: layers };
  // Retained parent links may point forward or be present but out of range.
  // Cycles cannot be traversed by the native renderer; reject them explicitly.
  for (let i = 0; i < count; i++) { let p = i, steps = 0; while (p >= 0 && p < count) { if (steps++ >= count) throw new Error("invalid paint walk cycle"); p = nscvWalkParent(c, nodes[p]!); } }
  const orders: NscWalkOrder[] = [], surfaces: NscWalkOrder[] = [], escaping: number[] = [];
  let preview = -1;
  for (let i = 0; i < count; i++) {
    const n = nodes[i]!, visible = nscvWalkVisible(c, i), m = nscvWalkMotion(c, n, false);
    orders.push({ walk_slot: i, walk_layer: nscvWalkLayer(c, n, false) });
    if (nscvWalkHoisted(n) && visible) surfaces.push({ walk_slot: i, walk_layer: nscvWalkSurfaceLayer(c, i) });
    if (!nscvWalkHoisted(n) && m !== null && m.presentation_escape && visible) escaping.push(i);
    if (preview === -1 && (flags & 32) !== 0 && nscvWalkNonzero(n) && nscvWalkId(n, ids, 8)) preview = i;
  }
  if (preview !== -1 && (nodes[preview]!.walk_kind === 16 || nodes[preview]!.walk_kind === 58 || !nscvWalkVisible(c, preview))) preview = -1;
  const ordered = orders.toSorted(nscvWalkCompare), sortedSurfaces = surfaces.toSorted(nscvWalkCompare), result = new Uint8Array(24 + count * 120), out = new DataView(result.buffer);
  result[0] = 1; out.setUint32(4, count, true);
  for (let at = 8; at < result.length; at += 4) out.setUint32(at, 0xffffffff, true);
  out.setUint32(12, sortedSurfaces.length === 0 ? 0xffffffff : sortedSurfaces[0]!.walk_slot, true); out.setUint32(16, escaping.length === 0 ? 0xffffffff : escaping[0]!, true); out.setUint32(20, preview === -1 ? 0xffffffff : preview, true);
  for (const o of ordered) if ((nodes[o.walk_slot]!.walk_flags & 1) === 0) { out.setUint32(8, o.walk_slot, true); break; }
  for (let i = 0; i < count; i++) {
    const at = 24 + i * 120, n = nodes[i]!;
    out.setInt32(at, nscvWalkLayer(c, n, false), true); out.setInt32(at + 4, nscvWalkSurfaceLayer(c, i), true);
    let next = -1, first = -1, childCount = 0;
    for (const o of ordered) {
      const child = nodes[o.walk_slot]!;
      if (nscvWalkSameParent(n, child) && nscvWalkCompare(orders[i]!, o) < 0 && next === -1) next = o.walk_slot;
      if ((child.walk_flags & 1) !== 0 && child.walk_parent_high === 0 && child.walk_parent === i) { if (first === -1) first = o.walk_slot; childCount++; }
    }
    out.setUint32(at + 8, next === -1 ? 0xffffffff : next, true); out.setUint32(at + 12, first === -1 ? 0xffffffff : first, true); out.setUint32(at + 24, childCount, true);
    let segment = 0, total = 0, ordinal = 0;
    const parent = nscvWalkParent(c, n);
    if (parent >= 0 && parent < count && nodes[parent]!.walk_kind === 9 && ((flags & 128) !== 0 || nodes[parent]!.walk_gap <= 0)) {
      for (let j = 0; j < count; j++) if (nscvWalkSameParent(n, nodes[j]!) && (nodes[j]!.walk_flags & 4) === 0) { if (j === i) ordinal = total; total++; }
      if (total > 1) segment = ordinal === 0 ? 1 : ordinal === total - 1 ? 3 : 2;
    }
    out.setUint32(at + 28, segment, true); nscvWalkPutLane(out, at + 32, c, i, false); nscvWalkPutLane(out, at + 76, c, i, true);
  }
  for (let i = 0; i < sortedSurfaces.length; i++) out.setUint32(24 + sortedSurfaces[i]!.walk_slot * 120 + 16, i + 1 < sortedSurfaces.length ? sortedSurfaces[i + 1]!.walk_slot : 0xffffffff, true);
  for (let i = 0; i < escaping.length; i++) out.setUint32(24 + escaping[i]! * 120 + 20, i + 1 < escaping.length ? escaping[i + 1]! : 0xffffffff, true);
  return result;
}
