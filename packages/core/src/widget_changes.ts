/** Retained widget change planning over copied scalar and byte facts. The
 * renderer supplies solved frames and retains paint-footprint construction;
 * this owner matches keys and classifies every layout, paint and semantic
 * dependency. Integers are opaque octets, so identities and counters never
 * round through a JavaScript number. Floating equality follows the reference:
 * signed zeros compare equal, while even identical NaNs compare unequal. */
interface NscChangeNode {
  change_key: string;
  change_flags: number;
  change_groups: Uint8Array[];
}
interface NscChangeComparison {
  change_equal: boolean;
  change_left_end: number;
  change_right_end: number;
}
function nscvChangeView(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}
function nscvChangeNeed(bytes: Uint8Array, at: number, length: number): void {
  if (length > bytes.length - at || at < 0) throw new Error("truncated widget change fact");
}
function nscvChangeEnd(bytes: Uint8Array, at: number, depth: number): number {
  if (depth > 32) throw new Error("widget change fact depth exceeded");
  nscvChangeNeed(bytes, at, 1);
  const tag = bytes[at++]!, view = nscvChangeView(bytes);
  if (tag === 0) {
    nscvChangeNeed(bytes, at, 1);
    if (bytes[at]! > 1) throw new Error("invalid widget change boolean");
    return at + 1;
  }
  if (tag === 1 || tag === 2 || tag === 3 || tag === 4) {
    const length = tag === 1 ? 16 : tag === 4 ? 8 : 4;
    nscvChangeNeed(bytes, at, length); return at + length;
  }
  if (tag === 5) {
    nscvChangeNeed(bytes, at, 1);
    const present = bytes[at++]!;
    if (present > 1) throw new Error("invalid widget change optional");
    return present === 0 ? at : nscvChangeEnd(bytes, at, depth + 1);
  }
  if (tag === 6 || tag === 7) {
    nscvChangeNeed(bytes, at, 4);
    const count = view.getUint32(at, true); at += 4;
    if (tag === 7) { nscvChangeNeed(bytes, at, count); return at + count; }
    // Every element contains at least a tag, bounding the loop by the packet.
    nscvChangeNeed(bytes, at, count);
    for (let i = 0; i < count; i++) at = nscvChangeEnd(bytes, at, depth + 1);
    return at;
  }
  throw new Error("invalid widget change fact tag");
}
function nscvChangeEqual(a: Uint8Array, b: Uint8Array, left: number, right: number): NscChangeComparison {
  const tag = a[left++]!;
  if (tag !== b[right++]!) return { change_equal: false, change_left_end: nscvChangeEnd(a, left - 1, 0), change_right_end: nscvChangeEnd(b, right - 1, 0) };
  const av = nscvChangeView(a), bv = nscvChangeView(b);
  if (tag === 3 || tag === 4) {
    const equal = tag === 3 ? av.getFloat32(left, true) === bv.getFloat32(right, true) : av.getFloat64(left, true) === bv.getFloat64(right, true);
    return { change_equal: equal, change_left_end: left + (tag === 3 ? 4 : 8), change_right_end: right + (tag === 3 ? 4 : 8) };
  }
  if (tag === 5) {
    const present = a[left++]!, other = b[right++]!;
    if (present !== other) return { change_equal: false, change_left_end: present === 0 ? left : nscvChangeEnd(a, left, 0), change_right_end: other === 0 ? right : nscvChangeEnd(b, right, 0) };
    return present === 0 ? { change_equal: true, change_left_end: left, change_right_end: right } : nscvChangeEqual(a, b, left, right);
  }
  if (tag === 6) {
    const count = av.getUint32(left, true), other = bv.getUint32(right, true); left += 4; right += 4;
    if (count !== other) return { change_equal: false, change_left_end: nscvChangeEnd(a, left - 5, 0), change_right_end: nscvChangeEnd(b, right - 5, 0) };
    let equal = true;
    for (let i = 0; i < count; i++) {
      const result = nscvChangeEqual(a, b, left, right);
      equal = equal && result.change_equal; left = result.change_left_end; right = result.change_right_end;
    }
    return { change_equal: equal, change_left_end: left, change_right_end: right };
  }
  let length = tag === 0 ? 1 : tag === 1 ? 16 : 4;
  if (tag === 7) {
    length = av.getUint32(left, true);
    const other = bv.getUint32(right, true); left += 4; right += 4;
    if (length !== other) return { change_equal: false, change_left_end: left + length, change_right_end: right + other };
  }
  let equal = true;
  for (let i = 0; i < length; i++) if (a[left + i] !== b[right + i]) equal = false;
  return { change_equal: equal, change_left_end: left + length, change_right_end: right + length };
}
function nscvChangeGroupEqual(a: NscChangeNode, b: NscChangeNode, group: number): boolean {
  return nscvChangeEqual(a.change_groups[group]!, b.change_groups[group]!, 0, 0).change_equal;
}
function nscvWidgetChanges(request: Uint8Array): Uint8Array {
  if (request[2] === 1) return nscvWidgetRenderChanges(request);
  if (request.length < 64 || request[0] !== 25 || request[1] !== 1 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid widget change header");
  const view = nscvChangeView(request), beforeCount = view.getUint32(4, true), afterCount = view.getUint32(8, true), capacity = view.getUint32(12, true), rootFlags = view.getUint32(16, true);
  if (rootFlags > 3 || view.getUint32(20, true) !== 0 || view.getUint32(56, true) !== 0 || view.getUint32(60, true) !== 0 || beforeCount + afterCount > Math.floor((request.length - 64) / 52))
    throw new Error("invalid widget change counts or reserved fields");
  let rootChanged = (rootFlags & 1) !== ((rootFlags >> 1) & 1);
  if (rootFlags === 3) for (let i = 0; i < 4; i++) if (view.getFloat32(24 + i * 4, true) !== view.getFloat32(40 + i * 4, true)) rootChanged = true;
  let at = 64;
  const nodes: NscChangeNode[] = [];
  for (let n = 0; n < beforeCount + afterCount; n++) {
    nscvChangeNeed(request, at, 52);
    const low = view.getUint32(at, true), high = view.getUint32(at + 4, true), flags = view.getUint32(at + 8, true), groups: Uint8Array[] = [];
    if (flags > 15 || view.getUint32(at + 12, true) !== 0) throw new Error("invalid widget change node flags");
    const lengths: number[] = [];
    for (let i = 0; i < 9; i++) lengths.push(view.getUint32(at + 16 + i * 4, true));
    at += 52;
    for (let i = 0; i < 9; i++) {
      const length = lengths[i]!; nscvChangeNeed(request, at, length);
      const group = request.subarray(at, at + length);
      if (nscvChangeEnd(group, 0, 0) !== length) throw new Error("trailing widget change group facts");
      groups.push(group); at += length;
    }
    nodes.push({ change_key: low === 0 && high === 0 ? "" : String(high) + ":" + String(low), change_flags: flags, change_groups: groups });
  }
  if (at !== request.length) throw new Error("trailing widget change bytes");
  const beforeKeys = new Map<string, number>(), afterKeys = new Map<string, number>();
  let duplicate = false;
  for (let n = 0; n < nodes.length; n++) {
    const key = nodes[n]!.change_key;
    if (key.length === 0) continue;
    const table = n < beforeCount ? beforeKeys : afterKeys;
    if (table.has(key)) duplicate = true;
    table.set(key, n < beforeCount ? n : n - beforeCount);
  }
  const entries: number[] = [];
  let status = duplicate ? 1 : 0;
  const append = (kind: number, before: number, after: number, flags: number): void => {
    if (entries.length / 4 >= capacity) { status = 2; return; }
    entries.push(kind, before, after, flags);
  };
  const missing = 4294967295;
  if (!duplicate) {
    for (let n = 0; n < beforeCount && status === 0; n++) {
      const previous = nodes[n]!, key = previous.change_key;
      if (key.length === 0) continue;
      const found = afterKeys.get(key);
      if (found === undefined) { append(0, n, missing, 7); continue; }
      const next = nodes[beforeCount + found]!;
      const root = rootChanged && (previous.change_flags & next.change_flags & 1) !== 0;
      const layout = root || !nscvChangeGroupEqual(previous, next, 0);
      const content = !nscvChangeGroupEqual(previous, next, 1) || ((previous.change_flags | next.change_flags) & 4) !== 0 ||
        (((previous.change_flags | next.change_flags) & 2) === 0 && !nscvChangeGroupEqual(previous, next, 7));
      const behavior = !nscvChangeGroupEqual(previous, next, 2), visual = !nscvChangeGroupEqual(previous, next, 3), state = !nscvChangeGroupEqual(previous, next, 4);
      const visibility = ((previous.change_flags ^ next.change_flags) & 8) !== 0, layer = !nscvChangeGroupEqual(previous, next, 6);
      const semantics = layout || content || behavior || state || !nscvChangeGroupEqual(previous, next, 5);
      const paint = layout || content || visual || state || visibility || layer;
      if (layout || paint || semantics) append(1, n, found, (layout ? 1 : 0) | (paint ? 2 : 0) | (semantics ? 4 : 0) | (root ? 8 : 0) | (visibility ? 16 : 0) | (!nscvChangeGroupEqual(previous, next, 8) ? 32 : 0) | (layer ? 64 : 0));
    }
    for (let n = 0; n < afterCount && status === 0; n++) {
      const key = nodes[beforeCount + n]!.change_key;
      if (key.length !== 0 && !beforeKeys.has(key)) append(2, missing, n, 7);
    }
  }
  const result = new Uint8Array(16 + entries.length * 4), out = nscvChangeView(result);
  result[0] = 1; result[2] = status; out.setUint32(4, entries.length / 4, true);
  for (let i = 0; i < entries.length; i++) out.setUint32(16 + i * 4, entries[i]!, true);
  return result;
}

interface NscChangeRenderState {
  change_presence: number;
  change_ids: string[];
  change_points: number[];
}
interface NscChangeRenderNode {
  change_kind: number;
  change_parent: number;
  change_id: string;
  change_state: number;
  change_terminal: number;
}
function nscvChangeId(view: DataView, at: number): string {
  const low = view.getUint32(at, true), high = view.getUint32(at + 4, true);
  return low === 0 && high === 0 ? "" : String(high) + ":" + String(low);
}
function nscvWidgetRenderChanges(request: Uint8Array): Uint8Array {
  if (request.length < 160 || request[0] !== 25 || request[1] !== 1 || request[2] !== 1 || request[3] !== 0)
    throw new Error("invalid render change header");
  const view = nscvChangeView(request), count = view.getUint32(4, true);
  if (request.length !== 160 + count * 24 || view.getUint32(8, true) !== 0 || view.getUint32(12, true) !== 0)
    throw new Error("invalid render change length");
  const states: NscChangeRenderState[] = [];
  for (let s = 0; s < 2; s++) {
    const at = 16 + s * 72, flags = view.getUint32(at, true), ids: string[] = [], points: number[] = [];
    if (flags > 255 || view.getUint32(at + 4, true) !== 0) throw new Error("invalid render change state");
    for (let i = 0; i < 5; i++) ids.push(nscvChangeId(view, at + 8 + i * 8));
    for (let i = 0; i < 6; i++) points.push(view.getFloat32(at + 48 + i * 4, true));
    states.push({ change_presence: flags, change_ids: ids, change_points: points });
  }
  const before = states[0]!, after = states[1]!, nodes: NscChangeRenderNode[] = [];
  for (let n = 0; n < count; n++) {
    const at = 160 + n * 24, kind = view.getUint32(at, true), parent = view.getUint32(at + 4, true), state = view.getUint32(at + 16, true), terminal = view.getUint32(at + 20, true);
    if (kind > 62 || state > 1023 || terminal > 7) throw new Error("invalid render change node");
    nodes.push({ change_kind: kind, change_parent: parent, change_id: nscvChangeId(view, at + 8), change_state: state, change_terminal: terminal });
  }
  const idEqual = (slot: number): boolean => ((before.change_presence >> slot) & 1) === ((after.change_presence >> slot) & 1) && before.change_ids[slot] === after.change_ids[slot];
  const pointEqual = (slot: number, at: number): boolean => {
    const a = (before.change_presence >> slot) & 1, b = (after.change_presence >> slot) & 1;
    return a === b && (a === 0 || before.change_points[at] === after.change_points[at] && before.change_points[at + 1] === after.change_points[at + 1]);
  };
  const activeChanged = (before.change_presence & 128) !== (after.change_presence & 128);
  const ids: string[] = [];
  const include = (s: NscChangeRenderState, slot: number): void => {
    const id = s.change_ids[slot]!;
    if ((s.change_presence & (1 << slot)) === 0 || id.length === 0 || ids.includes(id) || ids.length >= 8) return;
    ids.push(id);
  };
  if (!idEqual(0)) { include(before, 0); include(after, 0); }
  if (activeChanged) { include(before, 0); include(after, 0); }
  for (let slot = 1; slot < 4; slot++) if (!idEqual(slot)) { include(before, slot); include(after, slot); }
  const project = (n: NscChangeRenderNode, s: NscChangeRenderState): number => {
    let bits = n.change_state;
    if ((s.change_presence & 3) !== 0) {
      const slot = n.change_kind === 41 ? 0 : 1;
      bits = (bits & ~4) | ((s.change_presence & (1 << slot)) !== 0 && n.change_id.length !== 0 && n.change_id === s.change_ids[slot] ? 4 : 0);
    }
    if ((s.change_presence & 4) !== 0) bits = (bits & ~1) | (n.change_id.length !== 0 && n.change_id === s.change_ids[2] ? 1 : 0);
    if ((s.change_presence & 8) !== 0) bits = (bits & ~2) | (n.change_id.length !== 0 && n.change_id === s.change_ids[3] ? 2 : 0);
    return bits;
  };
  const logical = (n: NscChangeRenderNode, s: NscChangeRenderState): boolean => {
    if ((s.change_presence & 128) === 0) return false;
    if ((s.change_presence & 3) !== 0) return (s.change_presence & 1) !== 0 && n.change_id.length !== 0 && n.change_id === s.change_ids[0];
    return (n.change_state & 4) !== 0;
  };
  const terminal = (n: NscChangeRenderNode): boolean => n.change_kind === 62 && n.change_terminal === 7 && logical(n, before) !== logical(n, after);
  const entries: number[] = [];
  for (let i = 0; i < ids.length; i++) {
    const found = nodes.findIndex(n => n.change_id === ids[i]);
    if (found < 0) continue;
    const n = nodes[found]!, a = project(n, before), b = project(n, after), flags = (a !== b ? 1 : 0) | (terminal(n) ? 2 : 0);
    if (flags !== 0) entries.push(found, flags, a, b);
  }
  if (activeChanged && (before.change_presence & 3) === 0 && (after.change_presence & 3) === 0)
    for (let n = 0; n < nodes.length; n++) if (terminal(nodes[n]!)) entries.push(n, 2, project(nodes[n]!, before), project(nodes[n]!, after));
  const groups: number[][] = [[], []];
  if (!idEqual(1)) for (let s = 0; s < 2; s++) {
    const state = states[s]!, id = state.change_ids[1]!;
    if ((state.change_presence & 2) === 0 || id.length === 0) continue;
    let n = nodes.findIndex(candidate => candidate.change_id === id);
    if (n < 0) continue;
    n = nodes[n]!.change_parent;
    let visited = 0;
    while (n < nodes.length) {
      if (visited++ >= nodes.length) throw new Error("cyclic render change ancestors");
      if (nodes[n]!.change_kind === 60) groups[s]!.push(n);
      n = nodes[n]!.change_parent;
    }
  }
  const chart = !idEqual(2) || !pointEqual(5, 0);
  const drag = !idEqual(4) || !pointEqual(6, 2) || before.change_points[4] !== after.change_points[4] || before.change_points[5] !== after.change_points[5];
  const result = new Uint8Array(32 + entries.length * 4 + (groups[0]!.length + groups[1]!.length) * 4), out = nscvChangeView(result);
  result.set([1, 1, 0, 0]); out.setUint32(4, entries.length / 4, true); out.setUint32(8, groups[0]!.length, true); out.setUint32(12, groups[1]!.length, true); out.setUint32(16, (chart ? 1 : 0) | (drag ? 2 : 0), true);
  for (let i = 0; i < entries.length; i++) out.setUint32(32 + i * 4, entries[i]!, true);
  let at = 32 + entries.length * 4;
  for (let s = 0; s < 2; s++) for (let i = 0; i < groups[s]!.length; i++) { out.setUint32(at, groups[s]![i]!, true); at += 4; }
  return result;
}
