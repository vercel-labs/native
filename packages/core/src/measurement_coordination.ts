/** Copied measurement continuations. Native executes queries and retains the
 * buffers; portable policy owns admission, ordering and recipe composition. */
function nscvWrappedMeasure(request: Uint8Array): Uint8Array {
  if (request.length < 288 || request[0] !== 34 || request[1] !== 1 || request[2]! > 2 || request[3]! > 7)
    throw new Error("invalid wrapped measurement header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), mode = request[2]!;
  if (request.length !== 288 + count * 32 || w.getUint32(40, true) > 3)
    throw new Error("invalid wrapped measurement shape");
  for (let i = 44; i < 64; i++) if (request[i] !== 0) throw new Error("invalid wrapped measurement reserved bytes");
  const metric = request.slice(64, 288), m = new DataView(metric.buffer), kind = metric[7]!, flags = m.getUint32(12, true);
  if (metric[2] !== 32 || mode === 2 && kind !== 14) throw new Error("invalid wrapped measurement registers");
  const f = Math.fround, max = (a: number, b: number): number => nscvRenderExtreme(a, b, metric[3]!, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, metric[3]!, false);
  const v = (at: number): number => m.getFloat32(at, true);
  const scalar = (op: number, base: number = 0): number => {
    metric[2] = op; m.setFloat32(16, base, true);
    const r = nscvWidgetMetrics(metric); return new DataView(r.buffer).getFloat32(8, true);
  };
  scalar(29); // Validate complete registers before any short circuit.
  const packet = new Uint8Array(80 + count * 16), p = new DataView(packet.buffer);
  packet[0] = 7; packet[1] = mode === 2 ? 2 : 0; packet[2] = kind;
  packet[3] = ((flags & 4) !== 0 ? 1 : 0) | ((request[3]! & 1) !== 0 ? 2 : 0) |
    ((flags & 1) !== 0 ? 4 : 0) | ((request[3]! & 4) !== 0 ? 8 : 0) | (mode === 1 ? 16 : 0);
  p.setUint32(4, count, true); packet.set(request.subarray(8, 32), 8);
  packet.set(metric.subarray(152, 168), 32);
  if (mode !== 1 && (request[3]! & 2) !== 0 && (kind === 17 || kind === 12 && metric[6] === 1)) {
    const padding = scalar(kind === 17 ? 20 : 26);
    for (let i = 0; i < 4; i++) p.setFloat32(32 + i * 4, padding, true);
  }
  const textSize = scalar(1), line = scalar(5, textSize);
  p.setFloat32(48, v(196), true);
  p.setFloat32(52, kind === 14 ? max(scalar(10), f(line + f(scalar(19, v(116)) * 2))) : line, true);
  p.setFloat32(56, f(scalar(27, 16) + scalar(19, v(112))), true);
  p.setFloat32(60, scalar(27, 52), true);
  packet.set(request.subarray(36, 40), 64); packet.set(request.subarray(32, 36), 68);
  p.setFloat32(72, scalar(20), true); p.setFloat32(76, scalar(30, v(120)), true);
  for (let i = 0; i < count; i++) {
    const at = 288 + i * 32, childFlags = w.getUint32(at, true), status = w.getUint32(at + 16, true);
    if (childFlags > 7 || status > 3 || w.getUint32(at + 28, true) !== 0 || (childFlags & 1) === 0 && status !== 0)
      throw new Error("invalid wrapped measurement child");
    const authored = w.getFloat32(at + 4, true), cap = (childFlags & 6) === 2 && authored <= 0 && w.getFloat32(at + 24, true) <= 0;
    const dest = 80 + i * 16;
    p.setUint32(dest, (childFlags & 1) | (cap ? 2 : 0) | ((status & 1) !== 0 ? 4 : 0), true);
    packet.set(request.subarray(at + 4, at + 16), dest + 4);
  }
  let planned = nscvWrappedLayout(packet), q = new DataView(planned.buffer), inner = q.getFloat32(8, true);
  // Bubble queries return the intrinsic width; policy applies the thread cap.
  for (let i = 0; i < count; i++) {
    const at = 288 + i * 32, dest = 80 + i * 16;
    if ((p.getUint32(dest, true) & 6) === 6 && q.getUint32(16, true) === 2) {
      const fitted = min(inner, w.getFloat32(at + 8, true));
      p.setFloat32(dest + 8, inner > 0 ? min(fitted, max(f(inner * f(0.8)), max(0, w.getFloat32(at + 20, true)))) : fitted, true);
    }
  }
  planned = nscvWrappedLayout(packet); q = new DataView(planned.buffer);
  const result = new Uint8Array(32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const command = (action: number, index: number = 0, width: number = 0): Uint8Array => {
    out.setUint32(4, action, true); out.setUint32(8, index, true); out.setFloat32(16, width, true); return result;
  };
  const action = q.getUint32(4, true), ready = w.getUint32(40, true);
  if (action === 0 && (ready & 1) === 0) {
    if (w.getFloat32(20, true) > 0) p.setFloat32(68, max(max(0, w.getFloat32(24, true)), w.getFloat32(28, true) > 0 ? min(w.getFloat32(20, true), w.getFloat32(28, true)) : w.getFloat32(20, true)), true);
    else return command(1);
  }
  if (action === 2 && (ready & 2) === 0) return command(2, 0, inner);
  if (action === 3) {
    // Preserve the shipped coordinator's separate width and height passes.
    // Each width query may independently repeat intrinsic measurements.
    for (let i = 0; i < count; i++) {
      const query = q.getUint32(24 + i * 8, true);
      if (query !== 0) return command(query === 1 ? 3 : 4, i, inner);
    }
    for (let i = 0; i < count; i++) {
      const at = 288 + i * 32;
      if ((w.getUint32(at, true) & 1) !== 0 && (w.getUint32(at + 16, true) & 2) === 0)
        return command(5, i, q.getFloat32(20 + i * 8, true));
    }
  }
  if (action === 0 && (ready & 1) !== 0) {
    const value = w.getFloat32(32, true), ceiling = w.getFloat32(28, true);
    p.setFloat32(68, max(max(0, w.getFloat32(24, true)), ceiling > 0 ? min(value, ceiling) : value), true);
  }
  packet[1] = mode === 2 ? 2 : 1;
  const final = nscvWrappedLayout(packet);
  result.set(final.subarray(12, 16), 12);
  return result;
}

function nscvAxisChildMeasure(request: Uint8Array): Uint8Array {
  if (request.length !== 80 || request[0] !== 35 || request[1] !== 1 || request[2]! > 1 || request[3]! > 31 || request[4]! > 62 || request[5]! > 5 || request[6]! > 15 || request[7] !== 0)
    throw new Error("invalid axis measurement header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), ready = w.getUint32(8, true);
  if (ready > 3 || w.getUint32(12, true) !== 0) throw new Error("invalid axis measurement state");
  for (let i = 60; i < 80; i++) if (request[i] !== 0) throw new Error("invalid axis measurement reserved bytes");
  const horizontal = request[2] === 0, options = request[3]!, kind = request[4]!, primary = request[5] === 0 || request[5] === 1;
  const main = horizontal ? 24 : 28, cross = horizontal ? 28 : 24;
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, request[6]!, true);
  const result = new Uint8Array(64), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const needMain = !(w.getFloat32(main, true) > 0 || max(0, w.getFloat32(48, true)) > 0);
  const needCross = (options & 4) !== 0 && !(w.getFloat32(cross, true) > 0);
  if (needMain && (ready & 1) === 0 || needCross && (ready & 2) === 0) {
    const query = needMain && (ready & 1) === 0 ? 1 : 2;
    out.setUint32(4, query, true);
    out.setUint32(8, (query === 1 ? horizontal ? 0 : 1 : horizontal ? 1 : 0) ^ (kind === 53 && horizontal ? 1 : 0), true);
    return result;
  }
  out.setUint32(16, 1 | ((options & 1) !== 0 && kind === 12 && primary ? 2 : 0) |
    ((options & 24) === 24 && kind === 12 && primary ? 4 : 0) | (kind === 15 && request[5] !== 4 ? 8 : 0) |
    ((options & 2) !== 0 && kind === 46 ? 16 : 0), true);
  result.set(request.subarray(48, 52), 20);
  const copy = (from: number, to: number): void => { result.set(request.subarray(from, from + 4), to); };
  copy(main, 24); copy(cross, 28); copy(horizontal ? 16 : 20, 32); copy(horizontal ? 20 : 16, 36);
  copy(horizontal ? 32 : 36, 40); copy(horizontal ? 40 : 44, 44);
  copy(horizontal ? 36 : 32, 48); copy(horizontal ? 44 : 40, 52);
  if (needMain) result.set(request.subarray(52, 56), 56);
  if (needCross) result.set(request.subarray(56, 60), 60);
  return result;
}

function nscvSpanSubtree(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 36 || request[1] !== 1 || request[2]! > 62 || request[3]! > 1)
    throw new Error("invalid span subtree header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(12, true);
  if (request.length !== 16 + count * 4) throw new Error("invalid span subtree length");
  for (let i = 0; i < count; i++) if (w.getUint32(16 + i * 4, true) > 2) throw new Error("invalid span subtree child");
  const result = new Uint8Array(16), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  if (w.getUint32(4, true) >= w.getUint32(8, true)) return result;
  if ((request[2] === 26 || request[2] === 44) && request[3] === 1) { out.setUint32(12, 1, true); return result; }
  for (let i = 0; i < count; i++) {
    const value = w.getUint32(16 + i * 4, true);
    if (value === 0) { out.setUint32(4, 1, true); out.setUint32(8, i, true); return result; }
    if (value === 2) { out.setUint32(12, 1, true); return result; }
  }
  return result;
}

/** Axis preparation, subtree admission, cross-width and wrapped-height passes
 * keep their reference order. Allocation arithmetic remains operation 5. */
function nscvAxisMeasure(request: Uint8Array): Uint8Array {
  if (request.length < 64 || request[0] !== 37 || request[1] !== 1 || request[2]! > 15 || request[3] !== 0)
    throw new Error("invalid axis coordination header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true);
  if (request.length !== 64 + count * 64 || w.getUint32(8, true) !== 0 || w.getUint32(12, true) !== 0)
    throw new Error("invalid axis coordination shape");
  for (let i = 52; i < 64; i++) if (request[i] !== 0) throw new Error("invalid axis coordination reserved bytes");
  const packet = new Uint8Array(36 + count * 48); packet.set(request.subarray(16, 52));
  const p = new DataView(packet.buffer);
  if (packet[0] !== 5 || packet[1] !== 0 || p.getUint32(8, true) !== count) throw new Error("invalid axis coordination allocation");
  const eligible = (at: number): boolean => packet[2] === 1 && nscvRenderExtreme(0, w.getFloat32(at + 4, true), request[2]!, true) === 0 && w.getFloat32(at + 8, true) <= 0;
  for (let i = 0; i < count; i++) {
    const at = 64 + i * 64, state = w.getUint32(at + 48, true);
    if (w.getUint32(at, true) > 31 || state > 15 || w.getUint32(at + 52, true) > 1 || w.getUint32(at + 56, true) > 1 || (w.getUint32(at, true) & 1) === 0 && state !== 0)
      throw new Error("invalid axis coordination child");
    packet.set(request.subarray(at, at + 48), 36 + i * 48);
    if ((state & 8) !== 0) packet.set(request.subarray(at + 60, at + 64), 76 + i * 48);
  }
  // Complete allocation validation precedes even the first measurement.
  nscvContainerLayout(packet);
  const result = new Uint8Array(32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const command = (action: number, index: number, width: number = 0): Uint8Array => {
    out.setUint32(4, action, true); out.setUint32(8, index, true); out.setFloat32(16, width, true); return result;
  };
  let needsWrapped = false;
  for (let i = 0; i < count; i++) {
    const at = 64 + i * 64, state = w.getUint32(at + 48, true);
    if ((w.getUint32(at, true) & 1) === 0) continue;
    if ((state & 1) === 0) return command(1, i);
    if (eligible(at)) {
      if ((state & 2) === 0) return command(2, i);
      if (w.getUint32(at + 52, true) !== 0) needsWrapped = true;
    }
  }
  if (needsWrapped) {
    const cross = nscvContainerLayout(packet), c = new DataView(cross.buffer);
    for (let i = 0; i < count; i++) {
      const at = 64 + i * 64, state = w.getUint32(at + 48, true);
      if ((w.getUint32(at, true) & 1) === 0 || !eligible(at)) continue;
      if ((state & 4) === 0) return command(3, i);
      if (w.getUint32(at + 56, true) !== 0 && (state & 8) === 0) return command(4, i, c.getFloat32(12 + i * 4, true));
    }
  }
  packet[1] = 1;
  const allocated = nscvContainerLayout(packet), complete = new Uint8Array(32 + allocated.length);
  complete.set(result); complete.set(allocated, 32); return complete;
}
