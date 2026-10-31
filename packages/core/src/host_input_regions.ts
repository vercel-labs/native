/** Complete host input-region planning over copied layout observations.
 * Native owns measurements, retained buffers, scroll execution and OS calls. */
interface NscHostNode {
  route: NscRouteNode; raw: NscSurfaceRect; padding: number[]; valueX: number;
  virtualLo: number; virtualHi: number; config: number; measured: boolean;
  extentY: number; extentX: number;
}
interface NscHostDriver {
  node: number; parent: number; mask: number; frame: NscSurfaceRect;
  width: number; height: number; x: number; y: number; flags: number;
}
interface NscHostRegion { frame: NscSurfaceRect; exclusion: boolean }
function nscvHostEligible(n: NscHostNode): boolean {
  return n.route.kind === 6 && (n.route.lo !== 0 || n.route.hi !== 0) &&
    ((n.config & 1) === 0 || n.virtualLo !== 0 || n.virtualHi !== 0);
}
function nscvHostViewport(n: NscHostNode): NscSurfaceRect {
  const f = Math.fround, r = n.raw, p = n.padding;
  return nscvSurfaceNormalize({ x: f(r.x + nscvSurfaceMin(p[3]!, r.width)), y: f(r.y + nscvSurfaceMin(p[0]!, r.height)),
    width: nscvSurfaceMax(0, f(f(r.width - p[3]!) - p[1]!)), height: nscvSurfaceMax(0, f(f(r.height - p[0]!) - p[2]!)) });
}
function nscvHostTransformed(n: NscRouteNode): NscSurfaceRect {
  const r = n.frame, t = n.transform, f = Math.fround;
  if (r.width <= 0 || r.height <= 0 || t[0] === 1 && t[1] === 0 && t[2] === 0 && t[3] === 1 && t[4] === 0 && t[5] === 0) return r;
  const xs = [r.x, f(r.x + r.width), r.x, f(r.x + r.width)];
  const ys = [r.y, r.y, f(r.y + r.height), f(r.y + r.height)];
  let minX = 0, minY = 0, maxX = 0, maxY = 0;
  for (let i = 0; i < 4; i++) {
    const x = f(f(f(t[0]! * xs[i]!) + f(t[2]! * ys[i]!)) + t[4]!);
    const y = f(f(f(t[1]! * xs[i]!) + f(t[3]! * ys[i]!)) + t[5]!);
    if (i === 0) { minX = x; maxX = x; minY = y; maxY = y; }
    else { minX = nscvSurfaceMin(minX, x); minY = nscvSurfaceMin(minY, y); maxX = nscvSurfaceMax(maxX, x); maxY = nscvSurfaceMax(maxY, y); }
  }
  return nscvSurfaceNormalize({ x: minX, y: minY, width: f(maxX - minX), height: f(maxY - minY) });
}
function nscvHostAncestor(nodes: NscRouteNode[], ancestor: number, child: number): boolean {
  let p = nodes[child]!.parent;
  while (p < nodes.length) { if (p === ancestor) return true; p = nodes[p]!.parent; }
  return false;
}
function nscvHostInputRegions(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 79 || request[1] !== 1 || request[2]! > 3 || request[3] !== 0)
    throw new Error("invalid host input-region header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), mode = request[2]!, missing = 4294967295, f = Math.fround;
  const count = w.getUint32(4, true), tracked = w.getUint32(8, true), previous = w.getUint32(12, true);
  const facts = w.getUint32(20, true), baseRubber = w.getUint32(24, true), capacity = w.getUint32(28, true);
  if (count > 1024 || tracked > 16 || previous > 32 || facts > 7 || baseRubber > 1 || capacity > 32 || w.getUint32(16, true) !== 0 ||
      request.length !== 64 + count * 128 + tracked * 16 + previous * 20 || mode === 3 && (count !== 0 || previous !== 0))
    throw new Error("invalid host input-region facts");
  const nodeFacts: NscHostNode[] = [], nodes: NscRouteNode[] = [], layers: number[] = [];
  for (let i = 0; i < 4; i++) layers.push(w.getInt32(48 + i * 4, true));
  for (let i = 0; i < count; i++) {
    const at = 64 + i * 128, kind = w.getUint32(at, true), role = w.getUint32(at + 4, true), parent = w.getUint32(at + 8, true);
    const flags = w.getUint32(at + 24, true), actions = w.getUint32(at + 28, true), config = w.getUint32(at + 108, true), known = w.getUint32(at + 112, true);
    if (kind > 62 || role > 26 || parent !== missing && parent >= i || flags > 4095 || actions > 2047 ||
        config > 63 || (config & 12) === 12 || (config & 48) === 48 || known > 1 || w.getUint32(at + 124, true) !== 0)
      throw new Error("invalid host input-region node");
    const raw = { x: w.getFloat32(at + 40, true), y: w.getFloat32(at + 44, true), width: w.getFloat32(at + 48, true), height: w.getFloat32(at + 52, true) };
    const transform: number[] = [], padding: number[] = [];
    for (let j = 0; j < 6; j++) transform.push(w.getFloat32(at + 56 + j * 4, true));
    for (let j = 0; j < 4; j++) padding.push(w.getFloat32(at + 80 + j * 4, true));
    const route = { kind, role, parent, depth: w.getUint32(at + 12, true), lo: w.getUint32(at + 16, true), hi: w.getUint32(at + 20, true), flags, actions,
      value: w.getFloat32(at + 32, true), layer: w.getInt32(at + 36, true), frame: nscvSurfaceNormalize(raw), transform };
    nodes.push(route); nodeFacts.push({ route, raw, padding, valueX: w.getFloat32(at + 96, true), virtualLo: w.getUint32(at + 100, true), virtualHi: w.getUint32(at + 104, true), config, measured: known !== 0,
      extentY: w.getFloat32(at + 116, true), extentX: w.getFloat32(at + 120, true) });
  }
  const trackedAt = 64 + count * 128, previousAt = trackedAt + tracked * 16;
  for (let i = 0; i < previous; i++) if (w.getUint32(previousAt + i * 20 + 16, true) > 1) throw new Error("invalid retained drag region");
  const stamps: number[] = [], drivers: NscHostDriver[] = [], occluders: NscSurfaceRect[] = [], occluderNodes: number[] = [], regions: NscHostRegion[] = [];
  let verdict = 0;
  const header = (status: number, detail: number): Uint8Array => {
    const result = new Uint8Array(32), out = new DataView(result.buffer);
    out.setUint32(0, 1, true); out.setUint32(4, mode, true); out.setUint32(8, status, true); out.setUint32(28, detail, true); return result;
  };
  if (mode === 0 || mode === 1) {
    if ((facts & 1) !== 0) for (let i = 0; i < count; i++) if (nscvHostEligible(nodeFacts[i]!)) stamps.push(i);
  }
  if (mode === 1 && (facts & 1) !== 0) {
    const vr = nscvSurfaceNormalize({ x: w.getFloat32(32, true), y: w.getFloat32(36, true), width: w.getFloat32(40, true), height: w.getFloat32(44, true) });
    const view = { x: 0, y: 0, width: vr.width, height: vr.height };
    let overflow = false;
    for (let i = 0; i < count; i++) {
      const n = nodes[i]!, modal = nscvRouteModal(n) && (nodeFacts[i]!.config & 2) !== 0;
      if (!((n.flags & 8) !== 0 && n.kind !== 40) && !modal || nscvRouteHidden(nodes, i) || nscvRouteConcealed(nodes, i)) continue;
      const frame = modal ? view : nscvHostTransformed(n);
      if (frame.width <= 0 || frame.height <= 0) continue;
      if (occluders.length >= 8) { overflow = true; break; }
      occluders.push(frame); occluderNodes.push(i);
    }
    if (overflow) { occluders.length = 0; occluders.push(view); }
    for (let i = 0; i < count; i++) {
      const n = nodeFacts[i]!;
      if (!nscvHostEligible(n) || drivers.length >= 16) continue;
      const viewport = nscvHostViewport(n);
      if (viewport.width <= 0 || viewport.height <= 0) continue;
      const virtual = (n.config & 1) !== 0, axes = (n.config >>> 2) & 3;
      const horizontal = !virtual && axes !== 0, vertical = virtual || axes !== 1;
      if (!n.measured) {
        const result = new Uint8Array(48), out = new DataView(result.buffer); result.set(header(1, i));
        out.setUint32(12, horizontal ? 3 : 1, true); nscvRenderPutRect(out, 32, viewport); return result;
      }
      let parent = n.route.parent, root = i;
      while (parent < count && !nscvHostEligible(nodeFacts[parent]!)) parent = nodes[parent]!.parent;
      while (root < count && !nscvRouteEscapes(nodes[root]!)) root = nodes[root]!.parent;
      let mask = overflow ? 1 : 0;
      if (!overflow) for (let b = 0; b < occluderNodes.length; b++) {
        const o = occluderNodes[b]!;
        if (o === i || o === root || nscvHostAncestor(nodes, o, i)) continue;
        if (root < count) {
          const rl = nscvRouteSurfaceLayer(nodes, root, layers), ol = nscvRouteSurfaceLayer(nodes, o, layers);
          if (ol < rl || ol === rl && o < root) continue;
        }
        mask |= 1 << b;
      }
      const x = horizontal ? n.valueX : 0, y = vertical ? n.route.value : 0;
      let matched = missing;
      for (let j = 0; j < tracked; j++) if (w.getUint32(trackedAt + j * 16, true) === n.route.lo && w.getUint32(trackedAt + j * 16 + 4, true) === n.route.hi) { matched = j; break; }
      const pushX = matched === missing || Math.abs(f(w.getFloat32(trackedAt + matched * 16 + 8, true) - x)) > 0.5;
      const pushY = matched === missing || Math.abs(f(w.getFloat32(trackedAt + matched * 16 + 12, true) - y)) > 0.5;
      const override = (n.config >>> 4) & 3, rubber = override === 2 || override === 0 && baseRubber !== 0;
      drivers.push({ node: i, parent, mask, frame: n.route.frame,
        width: horizontal ? f(n.route.frame.width + nscvSurfaceMax(0, f(n.extentX - viewport.width))) : n.route.frame.width,
        height: vertical ? f(n.route.frame.height + nscvSurfaceMax(0, f(n.extentY - viewport.height))) : n.route.frame.height,
        x, y, flags: (pushX ? 1 : 0) | (pushY ? 2 : 0) | (rubber ? 4 : 0) | (horizontal ? 8 : 0) | (vertical ? 16 : 0) });
    }
  } else if (mode === 2 && (facts & 2) !== 0) {
    for (let i = 0; i < count; i++) {
      const n = nodes[i]!;
      if (!nscvRouteLive(n) || (n.flags & 64) === 0 || nscvRouteHidden(nodes, i) || !nscvRouteVisible(nodes, i, false, 0, 0)) continue;
      const start = regions.length;
      if (start >= capacity) break;
      regions.push({ frame: n.frame, exclusion: false });
      let overflow = false;
      for (let j = 0; j < count; j++) {
        if (j === i || !nscvRouteClaims(nodes[j]!) || nscvRouteHidden(nodes, j) || !nscvRouteVisible(nodes, j, false, 0, 0) || !nscvHostAncestor(nodes, i, j)) continue;
        if (regions.length >= capacity) { overflow = true; break; }
        regions.push({ frame: nodes[j]!.frame, exclusion: true });
      }
      if (overflow) { regions.length = start; break; }
    }
    let same = regions.length === previous;
    for (let i = 0; i < regions.length && same; i++) {
      const r = regions[i]!, at = previousAt + i * 20;
      same = r.frame.x === w.getFloat32(at, true) && r.frame.y === w.getFloat32(at + 4, true) && r.frame.width === w.getFloat32(at + 8, true) && r.frame.height === w.getFloat32(at + 12, true) && r.exclusion === (w.getUint32(at + 16, true) !== 0);
    }
    verdict = (facts & 4) !== 0 ? same ? 0 : 1 : regions.length === 0 ? 0 : 1;
  } else if (mode === 3) {
    verdict = tracked < 16 ? tracked : missing;
    for (let i = 0; i < tracked; i++) if (w.getUint32(trackedAt + i * 16, true) === w.getUint32(40, true) && w.getUint32(trackedAt + i * 16 + 4, true) === w.getUint32(44, true)) { verdict = i; break; }
  }
  const result = new Uint8Array(32 + stamps.length * 4 + drivers.length * 64 + occluders.length * 16 + regions.length * 20), out = new DataView(result.buffer);
  result.set(header(0, verdict)); out.setUint32(12, stamps.length, true); out.setUint32(16, drivers.length, true); out.setUint32(20, occluders.length, true); out.setUint32(24, regions.length, true);
  let at = 32;
  for (const i of stamps) { out.setUint32(at, i, true); at += 4; }
  for (const driver of drivers) {
    const n = nodes[driver.node]!;
    out.setUint32(at, n.lo, true); out.setUint32(at + 4, n.hi, true);
    if (driver.parent < count) { out.setUint32(at + 8, nodes[driver.parent]!.lo, true); out.setUint32(at + 12, nodes[driver.parent]!.hi, true); }
    out.setUint32(at + 16, driver.mask, true); out.setUint32(at + 20, driver.flags, true); nscvRenderPutRect(out, at + 24, driver.frame);
    out.setFloat32(at + 40, driver.width, true); out.setFloat32(at + 44, driver.height, true); out.setFloat32(at + 48, driver.x, true); out.setFloat32(at + 52, driver.y, true); at += 64;
  }
  for (const frame of occluders) { nscvRenderPutRect(out, at, frame); at += 16; }
  for (const region of regions) { nscvRenderPutRect(out, at, region.frame); out.setUint32(at + 16, region.exclusion ? 1 : 0, true); at += 20; }
  return result;
}
