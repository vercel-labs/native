/** Portable grid admission and first-row measurement. Native retains copied
 * requests, executes measurements, and traverses the resulting frames. */
function nscvGridMeasure(request: Uint8Array): Uint8Array {
  if (request.length < 128 || request[0] !== 38 || request[1] !== 1 || request[2]! > 15 || request[3]! > 1)
    throw new Error("invalid grid measurement header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true);
  if (request.length !== 128 + count * 64 || w.getUint32(8, true) !== 0 || w.getUint32(12, true) !== 0)
    throw new Error("invalid grid measurement shape");
  for (let i = 92; i < 128; i++) if (request[i] !== 0) throw new Error("invalid grid measurement reserved bytes");
  const packet = request.slice(16, 92), p = new DataView(packet.buffer), virtual = request[3] === 1;
  if (packet[0] !== 4 || packet[1] !== 0 || ((packet[2]! & 1) !== 0) !== virtual || p.getUint32(52, true) !== 0)
    throw new Error("invalid grid measurement allocation");
  let flows = 0;
  for (let i = 0; i < count; i++) {
    const at = 128 + i * 64, flags = w.getUint32(at, true), ready = w.getUint32(at + 4, true);
    if (flags > 3 || ready > 1 || (flags & 1) === 0 && ready !== 0)
      throw new Error("invalid grid measurement child");
    for (let j = 44; j < 64; j++) if (request[at + j] !== 0) throw new Error("invalid grid measurement child reserved bytes");
    if ((flags & 1) !== 0) flows++;
  }
  if (p.getUint32(4, true) !== flows || p.getUint32(8, true) !== 0) throw new Error("invalid grid measurement flow count");
  let grid = nscvGridLayout(packet), g = new DataView(grid.buffer);
  const result = new Uint8Array(32 + count * 32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  if (flows === 0) return result;
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, request[2]!, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, request[2]!, false);
  if (virtual && !(p.getFloat32(48, true) > 0)) {
    const columns = g.getUint32(0, true) + g.getUint32(4, true) * 4294967296;
    let flow = 0, height = 0;
    for (let i = 0; i < count && flow < columns; i++) {
      const at = 128 + i * 64;
      if ((w.getUint32(at, true) & 1) === 0) continue;
      const authored = w.getFloat32(at + 20, true);
      if (!(authored > 0) && w.getUint32(at + 4, true) === 0) {
        out.setUint32(4, 1, true); out.setUint32(8, i, true); return result.slice(0, 32);
      }
      const value = authored > 0 ? authored : w.getFloat32(at + 40, true), ceiling = w.getFloat32(at + 36, true);
      height = max(height, max(max(0, w.getFloat32(at + 28, true)), ceiling > 0 ? min(value, ceiling) : value));
      flow++;
    }
    p.setFloat32(52, height, true); grid = nscvGridLayout(packet); g = new DataView(grid.buffer);
  }
  out.setUint32(12, nscvFlowSemantic(nscvFlowInteger(g, 8)), true);
  result.set(grid.subarray(48, 52), 16); out.setUint32(24, 1, true);
  const columns = g.getUint32(0, true) + g.getUint32(4, true) * 4294967296;
  const start = g.getUint32(16, true) + g.getUint32(20, true) * 4294967296;
  const end = g.getUint32(24, true) + g.getUint32(28, true) * 4294967296;
  let flow = 0;
  for (let i = 0; i < count; i++) {
    const at = 128 + i * 64, flags = w.getUint32(at, true);
    if ((flags & 1) === 0) continue;
    const index = flow++; if (virtual && (Math.floor(index / columns) < start || Math.floor(index / columns) >= end)) continue;
    const cell = new Uint8Array(76), c = new DataView(cell.buffer);
    cell[0] = 4; cell[1] = 1; cell[2] = (virtual ? 1 : 0) | ((flags & 2) !== 0 ? 2 : 0);
    c.setUint32(4, index, true); cell.set(grid.subarray(0, 8), 12);
    cell.set(packet.subarray(28, 36), 20); cell.set(grid.subarray(32, 48), 28);
    cell.set(request.subarray(at + 8, at + 24), 44);
    cell.set(request.subarray(at + 24, at + 32), 60); cell.set(request.subarray(at + 32, at + 40), 68);
    const frame = nscvGridLayout(cell), dest = 32 + i * 32;
    out.setUint32(dest, 1, true); out.setUint32(dest + 4, index, true); out.setUint32(dest + 8, flows, true);
    result.set(frame.subarray(1, 17), dest + 16);
  }
  return result;
}

/** Measurement scheduling for uniform/variable virtual rows and scroll
 * shelves. Existing allocation operations retain their exact wire formats. */
function nscvFlowMeasure(request: Uint8Array): Uint8Array {
  if (request.length < 144 || request[0] !== 39 || request[1] !== 1 || (request[2] !== 0 && request[2] !== 2) || request[3]! > 15)
    throw new Error("invalid flow measurement header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), count = w.getUint32(4, true), ready = w.getUint32(8, true);
  if (request.length !== 144 + count * 72 || ready > 1 || w.getUint32(12, true) !== 0)
    throw new Error("invalid flow measurement shape");
  const packet = request.slice(16, 144 + count * 64), p = new DataView(packet.buffer), op = request[2]!;
  if (packet[0] !== 8 || packet[1] !== op || p.getUint32(4, true) !== count) throw new Error("invalid flow measurement allocation");
  const state = (i: number): number => 144 + count * 64 + i * 8;
  let flows = 0;
  for (let i = 0; i < count; i++) {
    const lane = p.getUint32(128 + i * 64, true), at = state(i);
    if (w.getUint32(at, true) > 1 || w.getUint32(at + 4, true) > 1 || lane === 0 && w.getUint32(at, true) !== 0)
      throw new Error("invalid flow measurement child state");
    if (lane === 1) flows++;
  }
  const initial = nscvVirtualFlow(packet), initialWire = new DataView(initial.buffer), mode = initialWire.getUint32(4, true);
  const result = new Uint8Array(32), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const command = (action: number, index: number, width: number = 0): Uint8Array => {
    out.setUint32(4, action, true); out.setUint32(8, index, true); out.setFloat32(16, width, true); return result;
  };
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, request[3]!, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, request[3]!, false);
  if (op === 0 && flows > 0) {
    for (let i = 0; i < count; i++) {
      const at = 128 + i * 64;
      if (p.getUint32(at, true) === 0) continue;
      const authored = p.getFloat32(at + 12, true);
      if (mode === 1) {
        if (!(authored > 0) && w.getUint32(state(i), true) === 0) return command(2, i, p.getFloat32(84, true));
      } else if (!(p.getFloat32(96, true) > 0)) {
        if (!(authored > 0) && ready === 0) return command(1, i);
        const value = authored > 0 ? authored : p.getFloat32(100, true), ceiling = p.getFloat32(at + 28, true);
        p.setFloat32(100, max(max(0, p.getFloat32(at + 24, true)), ceiling > 0 ? min(value, ceiling) : value), true);
        break;
      }
    }
  }
  if (op === 2) {
    for (let i = 0; i < count; i++) {
      const at = 128 + i * 64;
      if (p.getUint32(at, true) === 0) continue;
      const stack = new Uint8Array(84), s = new DataView(stack.buffer); stack[0] = 5; stack[1] = 3; s.setUint32(8, 1, true);
      stack.set(initial.subarray(24, 40), 12);
      s.setUint32(36, 1 | (w.getUint32(state(i) + 4, true) !== 0 ? 2 : 0), true);
      stack.set(packet.subarray(at + 8, at + 16), 44); stack.set(packet.subarray(at + 32, at + 40), 52);
      for (const [from, to] of [[16,60],[20,64],[24,68],[28,72]]) stack.set(packet.subarray(at + from!, at + from! + 4), to!);
      const frame = nscvContainerLayout(stack); packet.set(frame.subarray(12, 28), at + 48);
      if ((initialWire.getUint32(48 + i * 32, true) & 2) !== 0 && w.getUint32(state(i), true) === 0) return command(3, i);
    }
  }
  const final = nscvVirtualFlow(packet), complete = new Uint8Array(32 + final.length);
  out.setUint32(24, flows > 0 ? 1 : 0, true); complete.set(result); complete.set(final, 32); return complete;
}
