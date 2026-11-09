/** Routing over copied, solved widget facts. Identities remain two raw words;
 * this owner chooses hit targets, containment, capture/bubble paths and focus.
 * Scroll range is supplied by the separate portable semantic observation owner.
 * Every geometric operation retains the reference's f32 evaluation order. */
interface NscRouteNode {
  kind: number; role: number; parent: number; depth: number; lo: number; hi: number;
  flags: number; actions: number; value: number; layer: number;
  frame: NscSurfaceRect; transform: number[];
}
interface NscRouteEntry { index: number; phase: number }
interface NscRouteObservation { routing_observation_slot: number }
function nscvRouteModal(n: NscRouteNode): boolean { return n.kind >= 19 && n.kind <= 21; }
function nscvRouteEscapes(n: NscRouteNode): boolean { return (n.flags & 8) !== 0 || nscvRouteModal(n); }
function nscvRouteClips(n: NscRouteNode): boolean { return n.kind === 6 || (n.flags & 16) !== 0; }
function nscvRouteLive(n: NscRouteNode): boolean { return (n.lo !== 0 || n.hi !== 0) && (n.flags & 2) === 0; }
function nscvRouteClaims(n: NscRouteNode): boolean {
  const k = n.kind;
  return nscvRouteLive(n) && ((n.actions & 262) !== 0 || k >= 31 && k <= 39 || k === 41 || k === 42 || k === 44 || k >= 46 && k <= 51 || k === 6 || k === 14 || k === 16 || k >= 19 && k <= 21 || k >= 23 && k <= 25 || k === 58 || k === 62);
}
function nscvRouteHit(n: NscRouteNode, hover: boolean): boolean {
  if (!nscvRouteLive(n)) return false;
  if ((n.actions & 262) !== 0 || (n.flags & 64) !== 0 || hover && (n.flags & 32) !== 0) return true;
  const k = n.kind;
  if (k === 56) return (n.flags & 1024) !== 0;
  return k === 6 || k >= 14 && k <= 26 || k >= 31 && k <= 39 || k === 41 || k === 42 || k >= 44 && k <= 52 || k === 58 || k === 62;
}
function nscvRouteDefaultFocus(n: NscRouteNode): boolean {
  const k = n.kind;
  return n.role === 25 || k === 6 || k === 14 || k >= 31 && k <= 39 || k === 41 || k === 42 || k === 44 || k >= 46 && k <= 51 || k === 58 || k === 62;
}
function nscvRouteContains(r: NscSurfaceRect, x: number, y: number): boolean {
  return !(r.width <= 0 || r.height <= 0) && x >= r.x && y >= r.y && x < Math.fround(r.x + r.width) && y < Math.fround(r.y + r.height);
}
function nscvRouteLocal(n: NscRouteNode, x: number, y: number): { x: number; y: number; valid: boolean } {
  const t = n.transform, a = t[0]!, b = t[1]!, c = t[2]!, d = t[3]!, tx = t[4]!, ty = t[5]!, f = Math.fround;
  if (a === 1 && b === 0 && c === 0 && d === 1 && tx === 0 && ty === 0) return { x, y, valid: true };
  const det = f(f(a * d) - f(b * c));
  if (Math.abs(det) <= f(0.000001)) return { x: 0, y: 0, valid: false };
  const inv = f(1 / det);
  return { x: f(f(f(f(d * inv) * x) + f(f(-c * inv) * y)) + f(f(f(c * ty) - f(d * tx)) * inv)),
    y: f(f(f(f(-b * inv) * x) + f(f(a * inv) * y)) + f(f(f(b * tx) - f(a * ty)) * inv)), valid: true };
}
function nscvRouteSettled(nodes: NscRouteNode[], index: number): boolean {
  const n = nodes[index]!, f = Math.fround;
  if ((n.flags & 4) === 0 && !(n.value >= 0.5)) return false;
  let bottom = -Infinity, i = index + 1;
  while (i < nodes.length && nodes[i]!.depth > n.depth) {
    const child = nodes[i]!;
    if (!nscvRouteEscapes(child)) bottom = nscvSurfaceMax(bottom, f(child.frame.y + child.frame.height));
    if (nscvRouteEscapes(child) || child.kind === 14) {
      i++; while (i < nodes.length && nodes[i]!.depth > child.depth) i++;
    } else i++;
  }
  return bottom === -Infinity || bottom <= f(f(n.frame.y + n.frame.height) + 0.5);
}
function nscvRouteHidden(nodes: NscRouteNode[], index: number): boolean {
  let i = index;
  while (i < nodes.length) { const n = nodes[i]!; if ((n.flags & 1) !== 0) return true; i = n.parent; }
  return false;
}
function nscvRouteConcealed(nodes: NscRouteNode[], index: number): boolean {
  let i = nodes[index]!.parent;
  while (i < nodes.length) { const n = nodes[i]!; if (n.kind === 14 && !nscvRouteSettled(nodes, i)) return true; i = n.parent; }
  return false;
}
function nscvRouteVisible(nodes: NscRouteNode[], index: number, point: boolean, x: number, y: number): boolean {
  const r = nodes[index]!.frame, f = Math.fround;
  if (!point && (r.width <= 0 || r.height <= 0)) return false;
  let i = index;
  while (i < nodes.length) {
    if (nscvRouteEscapes(nodes[i]!)) return true;
    i = nodes[i]!.parent; if (i >= nodes.length) return true;
    const p = nodes[i]!;
    if (nscvRouteClips(p)) {
      if (point) { if (!nscvRouteContains(p.frame, x, y)) return false; }
      else {
        const a = nscvSurfaceMax(r.x, p.frame.x), b = nscvSurfaceMax(r.y, p.frame.y);
        const c = nscvSurfaceMin(f(r.x + r.width), f(p.frame.x + p.frame.width)), d = nscvSurfaceMin(f(r.y + r.height), f(p.frame.y + p.frame.height));
        if (c <= a || d <= b || f(c - a) <= 0 || f(d - b) <= 0) return false;
      }
    }
  }
  return true;
}
function nscvRouteLayer(n: NscRouteNode, layers: number[], surface: boolean): number {
  if ((n.flags & 512) !== 0) return n.layer;
  return nscvRouteModal(n) ? layers[2]! : surface && (n.flags & 8) !== 0 || n.kind >= 23 && n.kind <= 25 ? layers[1]! : n.kind === 40 ? layers[3]! : layers[0]!;
}
function nscvRouteSurfaceLayer(nodes: NscRouteNode[], index: number, layers: number[]): number {
  const n = nodes[index]!;
  let layer = nscvRouteLayer(n, layers, true), p = n.parent;
  if ((n.flags & 512) !== 0) return layer;
  while (p < nodes.length) { const ancestor = nodes[p]!; if (nscvRouteEscapes(ancestor)) layer = Math.max(layer, nscvRouteLayer(ancestor, layers, true)); p = ancestor.parent; }
  return layer;
}
function nscvRouteHitChildren(nodes: NscRouteNode[], parent: number, x: number, y: number, layers: number[], hover: boolean): number {
  const missing = 4294967295;
  let previous = missing, previousLayer = 0;
  for (let tested = 0; tested < nodes.length; tested++) {
    let best = missing, layer = 0;
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i]!; if (n.parent !== parent) continue;
      const l = nscvRouteLayer(n, layers, false);
      if (previous !== missing && (l > previousLayer || l === previousLayer && i >= previous)) continue;
      if (best === missing || l > layer || l === layer && i > best) { best = i; layer = l; }
    }
    if (best === missing) return missing;
    previous = best; previousLayer = layer;
    if (!nscvRouteEscapes(nodes[best]!)) { const hit = nscvRouteHitNode(nodes, best, x, y, layers, hover); if (hit !== missing) return hit; }
  }
  return missing;
}
function nscvRouteHitNode(nodes: NscRouteNode[], index: number, x: number, y: number, layers: number[], hover: boolean): number {
  const n = nodes[index]!, missing = 4294967295;
  if ((n.flags & 1) !== 0) return missing;
  const p = nscvRouteLocal(n, x, y);
  if (!p.valid || nscvRouteClips(n) && !nscvRouteContains(n.frame, p.x, p.y)) return missing;
  if (n.kind !== 14 || nscvRouteSettled(nodes, index)) { const hit = nscvRouteHitChildren(nodes, index, p.x, p.y, layers, hover); if (hit !== missing) return hit; }
  return nscvRouteHit(n, hover) && nscvRouteContains(n.frame, p.x, p.y) ? index : missing;
}
function nscvRouteHitTree(nodes: NscRouteNode[], x: number, y: number, layers: number[], hover: boolean): number {
  const missing = 4294967295;
  let previous = missing, previousLayer = 0;
  for (let tested = 0; tested < nodes.length; tested++) {
    let best = missing, layer = 0;
    for (let i = 0; i < nodes.length; i++) {
      if (!nscvRouteEscapes(nodes[i]!)) continue;
      const l = nscvRouteSurfaceLayer(nodes, i, layers);
      if (previous !== missing && (l > previousLayer || l === previousLayer && i >= previous)) continue;
      if (best === missing || l > layer || l === layer && i > best) { best = i; layer = l; }
    }
    if (best === missing) break;
    previous = best; previousLayer = layer;
    if (nscvRouteHidden(nodes, best) || nscvRouteConcealed(nodes, best)) continue;
    const hit = nscvRouteHitNode(nodes, best, x, y, layers, hover); if (hit !== missing) return hit;
  }
  return nscvRouteHitChildren(nodes, missing, x, y, layers, hover);
}
function nscvRoutePress(nodes: NscRouteNode[], index: number): number {
  let i = index; while (i < nodes.length) { if (nscvRouteClaims(nodes[i]!)) return i; i = nodes[i]!.parent; } return 4294967295;
}
function nscvRouteFocus(nodes: NscRouteNode[], index: number, logical: boolean, observation: NscRouteObservation): boolean {
  const n = nodes[index]!;
  if (!nscvRouteLive(n) || nscvRouteHidden(nodes, index) || nscvRouteConcealed(nodes, index)) return false;
  if ((n.flags & 128) === 0 && (n.actions & 1) === 0 && !nscvRouteDefaultFocus(n)) {
    // Ask for a semantic observation only at the same eligibility gate as
    // the reference. Native copies that fact, then resumes this query.
    if ((n.flags & 2048) === 0) {
      if (observation.routing_observation_slot === 4294967295) observation.routing_observation_slot = index;
      return false;
    }
    if ((n.flags & 256) === 0) return false;
  }
  return logical || nscvRouteVisible(nodes, index, false, 0, 0);
}
function nscvRouteGap(a: number, sizeA: number, b: number, sizeB: number): number {
  const f = Math.fround, endA = f(a + sizeA), endB = f(b + sizeB);
  if (nscvSurfaceMin(endA, endB) > nscvSurfaceMax(a, b)) return 0;
  return b >= endA ? f(b - endA) : f(a - endB);
}
function nscvRouteSpatial(nodes: NscRouteNode[], current: number, direction: number, observation: NscRouteObservation): number {
  const missing = 4294967295, f = Math.fround;
  if (!nscvRouteFocus(nodes, current, false, observation)) return missing;
  const a = nodes[current]!.frame, ax = f(a.x + f(a.width / 2)), ay = f(a.y + f(a.height / 2));
  let best = missing, bestScore = Infinity;
  for (let i = 0; i < nodes.length; i++) {
    if (i === current || !nscvRouteFocus(nodes, i, false, observation)) continue;
    const b = nodes[i]!.frame;
    if (!(direction === 2 ? f(b.x + b.width) <= ax : direction === 3 ? b.x >= ax : direction === 4 ? f(b.y + b.height) <= ay : b.y >= ay)) continue;
    const bx = f(b.x + f(b.width / 2)), by = f(b.y + f(b.height / 2)), dx = Math.abs(f(bx - ax)), dy = Math.abs(f(by - ay));
    const score = direction === 2 || direction === 3 ? f(f(f(dx * 4096) + f(nscvRouteGap(a.y, a.height, b.y, b.height) * 4096)) + dy) : f(f(f(dy * 4096) + f(nscvRouteGap(a.x, a.width, b.x, b.width) * 4096)) + dx);
    if (score < bestScore || score === bestScore && (best === missing || i < best)) { best = i; bestScore = score; }
  }
  return best;
}
function nscvWidgetRouting(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 24 || request[1] !== 1 || request[2]! > 13) throw new Error("invalid widget routing header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength), op = request[2]!, param = request[3]!;
  const count = wire.getUint32(4, true), subject = wire.getUint32(8, true), capacity = wire.getUint32(12, true), missing = 4294967295;
  if (request.length !== 64 + count * 96 || (op >= 2 && op <= 5 || op >= 12) && subject !== missing && subject >= count ||
      (op === 6 || op === 10 ? param > 5 : op === 8 ? param > 1 : op === 3 ? param > 7 : param !== 0)) throw new Error("invalid widget routing query");
  if (wire.getUint32(48, true) > 1) throw new Error("invalid routing identity presence");
  for (let at = 52; at < 64; at += 4) if (wire.getUint32(at, true) !== 0) throw new Error("invalid widget routing reserved bytes");
  const nodes: NscRouteNode[] = [], layers: number[] = [];
  for (let i = 0; i < 4; i++) layers.push(wire.getInt32(32 + i * 4, true));
  for (let i = 0; i < count; i++) {
    const at = 64 + i * 96, kind = wire.getUint32(at, true), role = wire.getUint32(at + 4, true), parent = wire.getUint32(at + 8, true), flags = wire.getUint32(at + 24, true), actions = wire.getUint32(at + 28, true);
    // Solved trees are preorder. Requiring an earlier parent also excludes
    // cycles before any recursive or ancestor walk can begin.
    if (kind > 62 || role > 26 || parent !== missing && parent >= i || flags > 4095 || actions > 2047) throw new Error("invalid widget routing node facts");
    for (let r = 80; r < 96; r += 4) if (wire.getUint32(at + r, true) !== 0) throw new Error("invalid widget routing node reserved bytes");
    const transform: number[] = []; for (let t = 0; t < 6; t++) transform.push(wire.getFloat32(at + 56 + t * 4, true));
    nodes.push({ kind, role, parent, depth: wire.getUint32(at + 12, true), lo: wire.getUint32(at + 16, true), hi: wire.getUint32(at + 20, true), flags, actions,
      value: wire.getFloat32(at + 32, true), layer: wire.getInt32(at + 36, true), transform,
      frame: nscvSurfaceNormalize({ x: wire.getFloat32(at + 40, true), y: wire.getFloat32(at + 44, true), width: wire.getFloat32(at + 48, true), height: wire.getFloat32(at + 52, true) }) });
  }
  const lo = wire.getUint32(16, true), hi = wire.getUint32(20, true), x = wire.getFloat32(24, true), y = wire.getFloat32(28, true);
  const lookup = (): number => { if (lo === 0 && hi === 0) return missing; for (let i = 0; i < count; i++) if (nodes[i]!.lo === lo && nodes[i]!.hi === hi) return i; return missing; };
  let target = missing, press = missing, status = 0, keepHit = false;
  const observation: NscRouteObservation = { routing_observation_slot: missing };
  const entries: NscRouteEntry[] = [];
  if (op <= 1) target = nscvRouteHitTree(nodes, x, y, layers, op === 1);
  else if (op === 2) target = nscvRoutePress(nodes, subject);
  else if (op === 3 && subject < count) {
    // Hover receives a typed hit which may carry caller-supplied role,
    // state and geometry. Preserve that complete record when the reference
    // keeps it, rather than reconstructing it from a different node record.
    if ((param & 1) !== 0 && (param & 2) === 0) { target = subject; keepHit = true; }
    else { const claimed = nscvRoutePress(nodes, subject); keepHit = claimed === missing; target = keepHit ? subject : claimed;
      const cell = keepHit ? (param & 4) !== 0 : nodes[target]!.kind === 44;
      if (cell) { let p = nodes[target]!.parent; while (p < count) { if (nodes[p]!.kind === 43) { target = p; keepHit = false; break; } p = nodes[p]!.parent; } }
    }
  } else if (op === 4) {
    const chain: number[] = []; let i = subject;
    while (i < count) { const n = nodes[i]!; if (nscvRouteLive(n) && (n.flags & 32) !== 0 && chain.length < 32) chain.push(i); i = n.parent; }
    for (let c = 0; c < Math.min(chain.length, capacity); c++) entries.push({ index: chain[chain.length - 1 - c]!, phase: 0 });
  } else if (op === 5) {
    let i = subject; while (i < count) { const n = nodes[i]!; if (nscvRouteClaims(n)) break; if (nscvRouteLive(n) && (n.flags & 64) !== 0) { target = i; break; } i = n.parent; }
  } else if (op === 6) {
    if (wire.getUint32(48, true) === 1 && (param === 2 || param === 3 || param === 4)) {
      const i = lookup(); if (i < count && nscvRouteHit(nodes[i]!, false) && !nscvRouteHidden(nodes, i) && !nscvRouteConcealed(nodes, i) && nscvRouteVisible(nodes, i, false, 0, 0)) target = i;
    } else target = nscvRouteHitTree(nodes, x, y, layers, false);
    press = nscvRoutePress(nodes, target);
  } else if (op === 7 || op === 11) { const i = lookup(); if (i < count && nscvRouteFocus(nodes, i, false, observation)) target = i; }
  else if (op === 8 && param === 1) {
    for (let i = count - 1; i >= 0; i--) { const n = nodes[i]!; if (nscvRouteLive(n) && (n.flags & 1) === 0 && (n.actions & 512) !== 0 && !nscvRouteHidden(nodes, i) && !nscvRouteConcealed(nodes, i) && nscvRouteContains(n.frame, x, y) && nscvRouteVisible(nodes, i, true, x, y)) { target = i; break; } }
  } else if (op === 9) {
    let i = lookup(); while (i < count) { const n = nodes[i]!;
      if (nscvRouteLive(n) && (n.flags & 1) === 0 && ((n.actions & 256) !== 0 || n.kind === 16 || n.kind === 58)) { if (!nscvRouteHidden(nodes, i) && !nscvRouteConcealed(nodes, i) && nscvRouteVisible(nodes, i, false, 0, 0)) target = i; break; } i = n.parent;
    }
  } else if (op === 10) {
    const current = lookup();
    if (param >= 2) { if (current < count) target = nscvRouteSpatial(nodes, current, param, observation); }
    else if (param === 0) {
      for (let i = current === missing ? 0 : current + 1; i < count; i++) if (nscvRouteFocus(nodes, i, false, observation)) { target = i; break; }
      if (target === missing) for (let i = 0; i < (current === missing ? count : current); i++) if (nscvRouteFocus(nodes, i, false, observation)) { target = i; break; }
    } else {
      for (let i = (current === missing ? count : current) - 1; i >= 0; i--) if (nscvRouteFocus(nodes, i, false, observation)) { target = i; break; }
      if (target === missing) for (let i = count - 1; i >= (current === missing ? 0 : current + 1); i--) if (nscvRouteFocus(nodes, i, false, observation)) { target = i; break; }
    }
  } else if ((op === 12 || op === 13) && subject < count && nscvRouteFocus(nodes, subject, op === 13, observation)) target = subject;
  if (observation.routing_observation_slot !== missing) {
    const pending = new Uint8Array(24), out = new DataView(pending.buffer);
    pending.set([1, op, 3, 0]); out.setUint32(4, observation.routing_observation_slot, true); out.setUint32(8, missing, true);
    return pending;
  }
  if (op >= 6 && op <= 9 && target < count) {
    const path: number[] = []; let i = target;
    while (i < count) { if (path.length >= 32) { status = 1; break; } path.push(i); i = nodes[i]!.parent; }
    if (status === 0) {
      const route: NscRouteEntry[] = [];
      for (let p = path.length - 1; p > 0; p--) route.push({ index: path[p]!, phase: 0 });
      route.push({ index: target, phase: 1 });
      for (let p = 1; p < path.length; p++) route.push({ index: path[p]!, phase: 2 });
      for (const e of route) { if (entries.length >= capacity) { status = 2; break; } entries.push(e); }
    }
  }
  const result = new Uint8Array(24 + entries.length * 8), out = new DataView(result.buffer);
  result.set([1, op, status, keepHit ? 1 : 0]); out.setUint32(4, target, true); out.setUint32(8, press, true); out.setUint32(12, entries.length, true);
  for (let i = 0; i < entries.length; i++) { out.setUint32(24 + i * 8, entries[i]!.index, true); out.setUint32(28 + i * 8, entries[i]!.phase, true); }
  return result;
}
