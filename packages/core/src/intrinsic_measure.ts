/** Per-node measurement continuations. Native supplies widget facts and executes
 * the requested measurements; this policy selects recipes, order and stopping. */
function nscvIntrinsicMeasure(request: Uint8Array): Uint8Array {
  if (request.length < 288 || request[0] !== 33 || request[1] !== 1 || request[2]! > 1 || request[3]! > 31)
    throw new Error("invalid intrinsic measurement header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(12, true);
  if (request.length !== 288 + count * 44 || w.getUint32(16, true) > 3 || w.getUint32(60, true) !== 0)
    throw new Error("invalid intrinsic measurement shape");
  const metric = request.slice(64, 288), m = new DataView(metric.buffer), kind = metric[7]!, flags = request[3]!, ready = w.getUint32(16, true);
  if (metric[2] !== 32) throw new Error("invalid intrinsic measurement register operation");
  const f = Math.fround, max = (a: number, b: number): number => nscvRenderExtreme(a, b, metric[3]!, true);
  const v = (at: number): number => m.getFloat32(at, true), put = (at: number, value: number): void => { m.setFloat32(at, value, true); };
  const scalar = (op: number, base: number = 0): number => {
    metric[2] = op; put(16, base);
    const r = nscvWidgetMetrics(metric); return new DataView(r.buffer).getFloat32(8, true);
  };
  // Validate the complete register packet even for a short-circuited container.
  scalar(29);
  const result = new Uint8Array(32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const command = (action: number, index: number = 0, value: number = 0): Uint8Array => {
    out.setUint32(4, action, true); out.setUint32(8, index, true);
    out.setFloat32(action === 1 ? 20 : 24, value, true); return result;
  };
  const done = (width: number, height: number): Uint8Array => { out.setFloat32(12, width, true); out.setFloat32(16, height, true); return result; };
  const stopped = w.getUint32(4, true) >= w.getUint32(8, true);
  const virtual = (flags & 1) !== 0, hasTitle = (m.getUint32(12, true) & 1) !== 0;
  let op = 2, axis = 0;
  if (kind === 1 || kind >= 8 && kind <= 13 || kind === 42 || kind === 44) op = 1;
  else if (kind === 2 || kind === 4 || kind === 5 || kind === 7 || kind === 24 || kind === 25 || kind === 59 || kind === 60) { op = 1; axis = 1; }
  else if (kind === 3) op = 4;
  else if (kind === 6) op = 3;
  else if (kind === 14) op = 7;
  else if (kind === 18) op = 8;
  else if (kind >= 19 && kind <= 21) op = 9;
  else if (kind === 17) op = 10;
  else if (!(kind === 0 || kind === 15 || kind === 16 || kind === 22 || kind === 23)) throw new Error("intrinsic measurement requires a container");
  if ((kind === 3 || kind === 4 || kind === 5 || kind === 7) && virtual || kind === 6 && (virtual || (flags & 8) === 0)) return done(0, 0);
  let textSize = 0;
  if (op >= 8) textSize = kind === 17 ? scalar(1) : scalar(4, kind === 18 ? f(v(20) + 1) : v(40));
  if (op >= 8 && (ready & 1) === 0) return command(1, 0, textSize);
  if (kind === 42 && (ready & 2) === 0) return command(2);
  const allowed = !stopped && !(kind === 14 && (flags & 4) === 0);
  const statuses = 288 + count * 40;
  for (let i = 0; i < count; i++) {
    const childFlags = w.getUint32(288 + i * 40, true), status = w.getUint32(statuses + i * 4, true);
    if (childFlags > 3 || status > 3 || status === 2 || (childFlags & 1) === 0 && status !== 0)
      throw new Error("invalid intrinsic measurement child");
    if (!allowed || (childFlags & 1) === 0) continue;
    if (status === 0) return command(3, i);
    if (op === 3 && status === 1) {
      const child = new Uint8Array(136), cw = new DataView(child.buffer);
      child[0] = 6; cw.setUint32(4, 1, true); child.set(request.subarray(288 + i * 40, 328 + i * 40), 96);
      const bounded = nscvIntrinsicLayout(child, metric[3]!, metric[8]!, request[2]!); return command(4, i, new DataView(bounded.buffer).getFloat32(20, true));
    }
  }
  const aggregate = new Uint8Array(96 + count * 40), a = new DataView(aggregate.buffer);
  aggregate[0] = 6; aggregate[1] = op; aggregate[2] = axis; aggregate[3] = (stopped ? 1 : 0) | (hasTitle ? 2 : 0); a.setUint32(4, count, true);
  aggregate.set(request.subarray(40, 56), 8);
  const set = (at: number, value: number): void => { a.setFloat32(at, value, true); };
  aggregate.set(metric.subarray(188, 196), 24);
  for (let i = 0; i < 4; i++) aggregate.set(metric.subarray(152 + i * 4, 156 + i * 4), 32 + i * 4);
  let gap = v(196);
  if (kind === 9 || kind === 12) {
    gap = max(0, gap);
    if (!(gap > 0) && (kind === 9 ? (flags & 16) !== 0 : metric[6] === 1)) gap = max(0, w.getFloat32(kind === 9 ? 32 : 36, true));
  }
  set(48, gap);
  if ((flags & 2) !== 0 && (kind === 17 || kind === 12 && metric[6] === 1)) {
    const padding = scalar(kind === 17 ? 20 : 26); for (let i = 0; i < 4; i++) set(32 + i * 4, padding);
  }
  if (op >= 8) {
    // The reference always measures text, including an empty title, but folds
    // the single title line rather than the paragraph's maximum span scale.
    aggregate.set(request.subarray(20, 24), 60); set(64, scalar(5, textSize));
    const floorWidth = kind === 20 ? 360 : kind === 21 ? 320 : op === 9 ? 420 : 240;
    const floorHeight = kind === 20 ? 280 : kind === 21 ? 420 : op === 9 ? 220 : op === 10 ? 52 : 120;
    set(68, scalar(27, floorWidth)); set(72, scalar(27, floorHeight));
    set(76, scalar(19, op === 9 ? w.getFloat32(56, true) : v(116)));
    if (op === 10) { set(80, scalar(27, 16)); set(84, scalar(19, v(112))); set(88, scalar(30, v(120))); }
  } else if (op === 7) set(64, max(scalar(10), f(scalar(5, scalar(1)) + f(scalar(19, v(116)) * 2))));
  if (allowed) aggregate.set(request.subarray(288, statuses), 96);
  const composed = nscvIntrinsicLayout(aggregate, metric[3]!, metric[8]!, request[2]!), c = new DataView(composed.buffer);
  let width = c.getFloat32(4, true), height = c.getFloat32(8, true);
  const signalingResult = (at: number): boolean => {
    const word = c.getUint32(at, true);
    return (metric[8]! & 16) !== 0 && (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0;
  };
  if (kind === 42) {
    width = signalingResult(4) ? width : max(w.getFloat32(24, true), width); height = signalingResult(8) ? height : max(w.getFloat32(28, true), height);
    if ((m.getUint32(12, true) & 128) !== 0 && Number.isFinite(v(124)) && v(124) > 0) width = f(Math.ceil(f(width * v(124))) / v(124));
  }
  done(width, height);
  // Unmodified signaling floors stay raw through the copied ABI. A list row's
  // optional snap performs arithmetic and therefore quiets its width instead.
  if (op < 8) {
    if (kind !== 42 || signalingResult(4) && ((m.getUint32(12, true) & 128) === 0 || !Number.isFinite(v(124)) || !(v(124) > 0))) result.set(composed.subarray(4, 8), 12);
    if (kind !== 42 || signalingResult(8)) result.set(composed.subarray(8, 12), 16);
  }
  return result;
}
