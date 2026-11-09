/** Portable accessibility and layout review of solved widget trees.
 * Native supplies raw widget facts and font/paragraph measurements. This
 * owner decides every rule, traversal, suppression and finding order. Names
 * remain opaque bytes; no decoding or normalization changes announcements. */
interface NscAuditDescendant { parent: number; hidden: boolean; label: Uint8Array; text: Uint8Array }
interface NscAuditNode {
  parent: number; kind: number; role: number; flags: number; identified: boolean;
  opacity: number; offsetX: number; transformed: boolean; frame: NscSurfaceRect;
  size: number; clipText: boolean; children: number; spans: number; layer: number;
  label: Uint8Array; text: Uint8Array; placeholder: Uint8Array; descendants: NscAuditDescendant[];
  measuredWidth: number; measuredHeight: number; availableWidth: number; availableHeight: number; lines: number;
}
interface NscAuditFinding { rule: number; node: number; other: number; x: number; y: number; lines: number }
function nscvAuditBlank(bytes: Uint8Array): boolean {
  for (let i = 0; i < bytes.length; i++) if (bytes[i] !== 32 && bytes[i] !== 9 && bytes[i] !== 13 && bytes[i] !== 10) return false;
  return true;
}
function nscvAuditEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function nscvAuditNeedsName(role: number): boolean {
  return role === 5 || role === 6 || role === 17 || role === 18 || role === 19 || role === 20 || role === 21 || role === 10 || role === 16 || role === 3 || role === 25 || role === 12;
}
function nscvAuditFocusKind(k: number): boolean {
  return k === 6 || k === 14 || k >= 31 && k <= 39 || k === 41 || k === 42 || k === 44 || k >= 46 && k <= 51 || k === 58 || k === 62;
}
function nscvAuditPointerKind(k: number): boolean {
  return k >= 31 && k <= 39 || k === 41 || k === 42 || k >= 46 && k <= 51 || k === 62;
}
function nscvAuditFlow(n: NscAuditNode): boolean {
  const k = n.kind;
  return k >= 1 && k <= 5 || k >= 7 && k <= 13 || k === 43 || k === 42 || k === 24 || k === 25 || k === 57 || k === 59 || k === 6 && (n.flags & 2) !== 0;
}
function nscvAuditEscapes(n: NscAuditNode): boolean { return (n.flags & 4) !== 0 || n.kind >= 19 && n.kind <= 21; }
function nscvAuditClips(n: NscAuditNode): boolean { return n.kind === 6 || (n.flags & 10) !== 0; }
function nscvAuditVertical(n: NscAuditNode): boolean { return n.kind === 6 && (n.flags & 32) !== 0 || (n.flags & 2) !== 0; }
function nscvAuditHorizontal(n: NscAuditNode): boolean { return n.kind === 6 && (n.flags & 16) !== 0 && (n.flags & 2) === 0; }
function nscvAuditArea(r: NscSurfaceRect): boolean { return r.width > 0.5 && r.height > 0.5; }
function nscvAuditOverrun(a: number, b: number): number { const v = Math.fround(a - b); return v > 0.5 ? v : 0; }
function nscvAuditName(n: NscAuditNode): Uint8Array { const label = n.label.length > 0 ? n.label : n.text; return nscvAuditBlank(label) ? n.placeholder : label; }
function nscvAuditControl(n: NscAuditNode): boolean {
  return n.kind === 31 || n.kind === 32 || n.kind === 50 ? n.size !== 3 : n.kind === 30 || n.kind === 47 || n.kind === 48 || n.kind === 49 || n.kind === 46 || n.kind === 40 || n.kind === 41 || n.kind === 45 || n.kind === 44 || n.kind === 42 && n.children === 0;
}
function nscvWidgetAudits(request: Uint8Array): Uint8Array {
  if (request.length < 56 || request[0] !== 23 || request[1] !== 1 || request[2]! > 1 || request[3]! > 3 || request[2] === 0 && (request[3]! & 2) !== 0) throw new Error("invalid widget audit header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const count = wire.getUint32(4, true), capacity = wire.getUint32(8, true), family = request[2]!;
  if (wire.getUint32(12, true) !== 0 || wire.getUint32(52, true) > 2 || count > (request.length - 56) / 128) throw new Error("invalid widget audit count or tokens");
  const rect = (at: number): NscSurfaceRect => nscvSurfaceNormalize({ x: wire.getFloat32(at, true), y: wire.getFloat32(at + 4, true), width: wire.getFloat32(at + 8, true), height: wire.getFloat32(at + 12, true) });
  const window = rect(16), nodes: NscAuditNode[] = [], missing = 4294967295, f = Math.fround;
  let at = 56;
  const bytes = (length: number): Uint8Array => { if (length > request.length - at) throw new Error("truncated widget audit text"); const value = request.subarray(at, at + length); at += length; return value; };
  for (let i = 0; i < count; i++) {
    if (request.length - at < 128) throw new Error("truncated widget audit node");
    const p = at, parent = wire.getUint32(p, true), kind = wire.getUint32(p + 4, true), role = wire.getUint32(p + 8, true), flags = wire.getUint32(p + 12, true);
    const size = wire.getUint32(p + 72, true), overflow = wire.getUint32(p + 76, true), descendantCount = wire.getUint32(p + 104, true);
    if (parent !== missing && parent >= count || kind > 62 || role > 26 || flags > 4095 || size > 5 || overflow > 1) throw new Error("invalid widget audit facts");
    let transformed = false;
    for (let j = 0; j < 6; j++) if (wire.getFloat32(p + 32 + j * 4, true) !== (j === 0 || j === 3 ? 1 : 0)) transformed = true;
    const frame = rect(p + 56);
    at += 128;
    const label = bytes(wire.getUint32(p + 92, true)), text = bytes(wire.getUint32(p + 96, true)), placeholder = bytes(wire.getUint32(p + 100, true));
    if (descendantCount > (request.length - at) / 16) throw new Error("invalid widget audit descendants");
    const descendants: NscAuditDescendant[] = [];
    for (let j = 0; j < descendantCount; j++) {
      if (request.length - at < 16) throw new Error("truncated widget audit descendant");
      const d = at, ancestor = wire.getUint32(d, true), hidden = wire.getUint32(d + 4, true); at += 16;
      if (ancestor !== missing && ancestor >= j || hidden > 1) throw new Error("invalid widget audit descendant facts");
      descendants.push({ parent: ancestor, hidden: hidden === 1, label: bytes(wire.getUint32(d + 8, true)), text: bytes(wire.getUint32(d + 12, true)) });
    }
    nodes.push({ parent, kind, role, flags, identified: wire.getUint32(p + 16, true) !== 0 || wire.getUint32(p + 20, true) !== 0,
      opacity: wire.getFloat32(p + 24, true), offsetX: wire.getFloat32(p + 28, true), transformed, frame, size, clipText: overflow === 1,
      children: wire.getUint32(p + 80, true), spans: wire.getUint32(p + 84, true), layer: wire.getInt32(p + 88, true), label, text, placeholder, descendants,
      measuredWidth: wire.getFloat32(p + 108, true), measuredHeight: wire.getFloat32(p + 112, true), availableWidth: wire.getFloat32(p + 116, true), availableHeight: wire.getFloat32(p + 120, true), lines: wire.getUint32(p + 124, true) });
  }
  if (at !== request.length) throw new Error("trailing widget audit bytes");
  // Validate the complete ancestor graph, including ancestors outside the
  // 1024-node inspected prefix. Valid solved trees may have detached roots.
  const colors: number[] = []; for (let i = 0; i < count; i++) colors.push(0);
  for (let i = 0; i < count; i++) {
    let p = i;
    while (p !== missing && colors[p] === 0) { colors[p] = 1; p = nodes[p]!.parent; }
    if (p !== missing && colors[p] === 1) throw new Error("cyclic widget audit parents");
    p = i; while (p !== missing && colors[p] === 1) { colors[p] = 2; p = nodes[p]!.parent; }
  }
  const inspected = Math.min(count, 1024), findings: NscAuditFinding[] = [], flagged: boolean[] = [];
  let total = 0;
  const emit = (rule: number, node: number, other: number, x: number, y: number, lines: number): void => { total++; if (findings.length < capacity) findings.push({ rule, node, other, x, y, lines }); };
  const painted = (index: number): boolean => { let i = index; while (i !== missing) { const n = nodes[i]!; if ((n.flags & 1) !== 0 || n.opacity <= 0) return false; i = n.parent; } return true; };
  const transformed = (index: number): boolean => { let i = index; while (i !== missing) { const n = nodes[i]!; if (n.transformed) return true; i = n.parent; } return false; };
  const roleOf = (n: NscAuditNode): number => n.role || nscvSemanticRoles[n.kind]!;
  const layer = (n: NscAuditNode): number => (n.flags & 2048) !== 0 ? n.layer : wire.getInt32(n.kind >= 19 && n.kind <= 21 ? 48 : n.kind === 23 || n.kind === 24 || n.kind === 25 ? 44 : n.kind === 40 ? 40 : 36, true);
  if ((request[3]! & 2) !== 0) {
    // Select measurements in the same order as rule traversal. Invisible,
    // transformed, elided and composite labels do not call the font seam.
    const queries: number[] = [], modes: number[] = [];
    for (let i = 0; i < inspected; i++) {
      if (!painted(i) || transformed(i)) continue;
      const n = nodes[i]!;
      if (n.spans > 0 && (n.kind === 26 || n.kind === 44)) { queries.push(i); modes.push(1); }
      else if (n.text.length > 0 && n.kind === 26) { queries.push(i); modes.push(0); }
      else if (n.text.length > 0 && n.clipText && nscvAuditControl(n)) { queries.push(i); modes.push(2); }
    }
    const result = new Uint8Array(16 + queries.length * 24), out = new DataView(result.buffer);
    result[0] = 1; result[1] = 1; result[2] = 2; out.setUint32(4, queries.length, true); out.setUint32(8, queries.length, true);
    for (let i = 0; i < queries.length; i++) { out.setUint32(16 + i * 24, modes[i]!, true); out.setUint32(20 + i * 24, queries[i]!, true); out.setUint32(24 + i * 24, missing, true); }
    return result;
  }
  for (let i = 0; i < inspected; i++) flagged.push(false);
  for (let i = 0; i < inspected; i++) {
    if (!painted(i)) continue;
    const n = nodes[i]!, frame = n.frame, role = roleOf(n);
    if (family === 0) {
      if (n.identified && nscvAuditArea(frame) && nscvAuditNeedsName(role)) {
        const entry = n.kind >= 35 && n.kind <= 39;
        let named = !nscvAuditBlank(n.label) || !entry && !nscvAuditBlank(n.text) || n.kind >= 34 && n.kind <= 39 && !nscvAuditBlank(n.placeholder);
        if (!named && (role === 25 || role === 12 || role === 16 || role === 3)) {
          const hidden: boolean[] = [];
          for (const d of n.descendants) {
            const concealed = d.hidden || d.parent !== missing && hidden[d.parent]!; hidden.push(concealed);
            if (!concealed && (!nscvAuditBlank(d.label) || !nscvAuditBlank(d.text))) named = true;
          }
        }
        if (!named) emit(0, i, missing, 0, 0, 0);
      }
      const defaultFocus = (n.flags & 512) !== 0 ? (n.flags & 1024) !== 0 : n.role === 25 || nscvAuditFocusKind(n.kind);
      if (n.identified && (n.flags & 64) === 0 && ((n.flags & 384) !== 0 || defaultFocus) && nscvAuditArea(frame)) {
        let current = i, vertical = false, horizontal = false;
        while (true) {
          if (nscvAuditEscapes(nodes[current]!)) break;
          const p = nodes[current]!.parent; if (p === missing) break;
          const parent = nodes[p]!, scope = parent.frame, pv = nscvAuditVertical(parent), ph = nscvAuditHorizontal(parent);
          if (nscvAuditClips(parent)) {
            const outsideX = nscvSurfaceRight(frame) <= scope.x || frame.x >= nscvSurfaceRight(scope), outsideY = nscvSurfaceBottom(frame) <= scope.y || frame.y >= nscvSurfaceBottom(scope);
            const leading = ph && !horizontal && f(nscvSurfaceRight(frame) + parent.offsetX) <= scope.x;
            if (outsideX && !(horizontal || ph) || outsideY && !(vertical || pv) || leading) { emit(1, i, p, 0, 0, 0); break; }
          }
          vertical = vertical || pv; horizontal = horizontal || ph; current = p;
        }
      }
      if (n.parent !== missing && n.identified && nscvAuditArea(frame) && nscvAuditNeedsName(role)) {
        const name = nscvAuditName(n);
        if (!nscvAuditBlank(name)) for (let j = n.parent + 1; j < i && j < inspected; j++) {
          const other = nodes[j]!;
          if (other.parent === n.parent && other.identified && painted(j) && nscvAuditArea(other.frame) && roleOf(other) === role && nscvAuditEqual(nscvAuditName(other), name)) { emit(2, i, j, 0, 0, 0); break; }
        }
      }
      continue;
    }
    if (transformed(i)) continue;
    const paragraph = n.spans > 0 && (n.kind === 26 || n.kind === 44), plain = n.kind === 26;
    const control = nscvAuditControl(n);
    if (paragraph || n.text.length > 0 && (plain || control && n.clipText)) {
      const x = paragraph || n.clipText ? nscvAuditOverrun(n.measuredWidth, paragraph ? n.availableWidth : frame.width) : 0;
      const y = paragraph || plain && n.lines > 1 ? nscvAuditOverrun(n.measuredHeight, paragraph ? n.availableHeight : frame.height) : 0;
      if (x > 0 || y > 0) emit(0, i, missing, x, y, n.lines);
    }
    if (nscvAuditPointerKind(n.kind) && n.role !== 3 && nscvAuditArea(frame)) {
      const density = wire.getUint32(52, true), floor = f(f(wire.getFloat32(32, true) * (density === 0 ? 0.875 : density === 2 ? 1.125 : 1)) * (n.size === 0 ? 0.875 : n.size === 2 ? 1.125 : 1));
      const x = nscvAuditOverrun(floor, frame.width), y = nscvAuditOverrun(floor, frame.height);
      if (x > 0 || y > 0) emit(3, i, missing, x, y, 0);
    }
    if (i !== 0 && nscvAuditArea(frame)) {
      let scopeIndex = missing;
      if (!nscvAuditEscapes(n)) {
        let p = n.parent;
        while (p !== missing) { const ancestor = nodes[p]!; if (nscvAuditClips(ancestor)) { scopeIndex = p; break; } if (nscvAuditEscapes(ancestor)) break; p = ancestor.parent; }
      }
      let suppressed = false, ancestor = n.parent;
      while (ancestor !== missing) { if (ancestor === scopeIndex) break; if (ancestor < 1024 && flagged[ancestor]) { suppressed = true; break; } ancestor = nodes[ancestor]!.parent; }
      if (!suppressed) {
        const scope = scopeIndex === missing ? window : nodes[scopeIndex]!.frame;
        const horizontal = scopeIndex !== missing && nscvAuditHorizontal(nodes[scopeIndex]!), vertical = scopeIndex !== missing && nscvAuditVertical(nodes[scopeIndex]!);
        const x = horizontal ? nscvSurfaceMax(0, nscvAuditOverrun(scope.x, f(frame.x + nodes[scopeIndex]!.offsetX))) : nscvSurfaceMax(nscvAuditOverrun(nscvSurfaceRight(frame), nscvSurfaceRight(scope)), nscvAuditOverrun(scope.x, frame.x));
        const y = vertical ? 0 : nscvSurfaceMax(nscvAuditOverrun(nscvSurfaceBottom(frame), nscvSurfaceBottom(scope)), nscvAuditOverrun(scope.y, frame.y));
        if (x > 0 || y > 0) { flagged[i] = true; emit(2, i, scopeIndex, x, y, 0); }
      }
    }
    if (nscvAuditFlow(n)) for (let first = i + 1; first < inspected; first++) {
      const a = nodes[first]!;
      if (a.parent !== i || nscvAuditEscapes(a) || (a.flags & 1) !== 0 || a.opacity <= 0 || a.transformed || !nscvAuditArea(a.frame)) continue;
      for (let second = first + 1; second < inspected; second++) {
        const b = nodes[second]!;
        if (b.parent !== i || nscvAuditEscapes(b) || (b.flags & 1) !== 0 || b.opacity <= 0 || b.transformed || !nscvAuditArea(b.frame) || layer(a) !== layer(b)) continue;
        const x0 = nscvSurfaceMax(a.frame.x, b.frame.x), y0 = nscvSurfaceMax(a.frame.y, b.frame.y), x1 = nscvSurfaceMin(nscvSurfaceRight(a.frame), nscvSurfaceRight(b.frame)), y1 = nscvSurfaceMin(nscvSurfaceBottom(a.frame), nscvSurfaceBottom(b.frame));
        if (x1 <= x0 || y1 <= y0) continue;
        const x = f(x1 - x0), y = f(y1 - y0); if (x <= 0.5 || y <= 0.5) continue;
        emit(1, second, first, x, y, 0);
      }
    }
  }
  const result = new Uint8Array(16 + findings.length * 24), out = new DataView(result.buffer);
  result[0] = 1; result[1] = family; out.setUint32(4, findings.length, true); out.setUint32(8, total, true);
  for (let i = 0; i < findings.length; i++) {
    const finding = findings[i]!, p = 16 + i * 24;
    out.setUint32(p, finding.rule, true); out.setUint32(p + 4, finding.node, true); out.setUint32(p + 8, finding.other, true);
    out.setFloat32(p + 12, finding.x, true); out.setFloat32(p + 16, finding.y, true); out.setUint32(p + 20, finding.lines, true);
  }
  return result;
}
