/** Ordered automation gestures over copied observations. Native retains event
 * delivery, clocks, borrowed labels/text/paths and callback failure cleanup.
 * All geometry operations follow the native f32 evaluation order.
 */
export function nscvAutomationInteractions(request: Uint8Array): Uint8Array {
  if (request.length !== 128 || request[0] !== 91 || request[1] !== 1 || request[2]! > 12 || request[3]! > 1)
    throw new Error("invalid automation interaction request");
  const mode = request[2]!, phase = request[3]!;
  if (phase !== 0 && mode > 2 && mode !== 10) throw new Error("invalid automation interaction phase");
  const input = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const facts = input.getUint32(4, true);
  if ((facts & ~4095) !== 0) throw new Error("invalid automation interaction observations");
  const has = (bit: number): boolean => (facts & bit) !== 0;
  const f = Math.fround;
  let x = input.getFloat32(8, true), y = input.getFloat32(12, true);
  let width = input.getFloat32(16, true), height = input.getFloat32(20, true);
  if (width < 0) { x = f(x + width); width = f(-width); }
  if (height < 0) { y = f(y + height); height = f(-height); }
  const empty = width <= 0 || height <= 0;
  const cx = f(x + f(width / 2)), cy = f(y + f(height / 2));
  const ax = input.getFloat32(24, true), ay = input.getFloat32(28, true);
  const dx = input.getFloat32(32, true), dy = input.getFloat32(36, true);
  let status = 0, flags = 4, ox = 0, oy = 0, ex = 0, ey = 0;
  const steps: { event: number; button: number; key: number; text: number; x: number; y: number; dx: number; dy: number; scale: number }[] = [];
  function step(event: number, px: number, py: number, sx: number, sy: number, scale: number, button: number, key: number, text: number): void {
    steps.push({ event, button, key, text, x: px, y: py, dx: sx, dy: sy, scale });
  }
  if (mode === 11) {
    flags = 0;
    status = !has(2048) ? 8 : !has(32) ? 7 : !has(1) ? 1 : !has(64) ? 9 : !has(128) ? 10 : has(256) ? 11 : !has(512) ? 12 : 0;
  } else if (mode === 12) {
    flags = 0;
    let armed = has(1024);
    for (let i = 0; i < 8; i++) if (request[64 + i] !== request[72 + i]) armed = false;
    status = !armed ? 13 : !has(32) ? 14 : 0;
    if (status === 14) flags = 32;
  } else if (mode === 10 && phase === 1) {
    flags = 0; status = !has(32) ? 7 : !has(2) ? 1 : 0;
  } else {
    if (mode <= 2) status = !has(2) || !has(1) || empty ? 1 : 0;
    else if (mode === 3) status = !has(1) ? 2 : !has(2) ? 3 : empty ? 4 : 0;
    else if (mode === 6 || mode === 9 || mode === 10) status = !has(2) || !has(1) || empty ? 1 : 0;
    else if (mode === 7 || mode === 8) status = !has(4) ? 1 : 0;
    if (status === 0 && phase === 0) {
      if (mode <= 2) {
        flags |= mode === 0 ? 1 : mode === 1 ? 16 : 0;
        step(0, ax, ay, 0, 0, 0, mode === 2 ? 1 : 0, 0, 0);
        if (mode === 1) step(9, 0, 0, 0, 0, 0, 0, 0, 0);
        step(1, ax, ay, 0, 0, 0, mode === 2 ? 1 : 0, 0, 0);
      } else if (mode === 3) step(3, cx, cy, dx, dy, 0, 0, 0, 0);
      else if (mode === 4) step(4, 0, 0, 0, 0, 0, 0, 0, 1);
      else if (mode === 5) {
        const scale = f(dx - 1);
        if (f(1 + scale) <= 0) status = 5;
        else {
          const px = has(8) ? ax : f(input.getFloat32(16, true) / 2), py = has(8) ? ay : f(input.getFloat32(20, true) / 2);
          step(6, px, py, 0, 0, 0, 0, 0, 0);
          step(7, px, py, 0, 0, scale, 0, 0, 0);
          step(8, px, py, 0, 0, 0, 0, 0, 0);
        }
      } else if (mode === 6) {
        flags |= 2;
        ox = f(x + f(width * input.getFloat32(40, true))); oy = f(y + f(height * input.getFloat32(44, true)));
        ex = f(x + f(width * input.getFloat32(48, true))); ey = f(y + f(height * input.getFloat32(52, true)));
        step(0, ox, oy, 0, 0, 0, 0, 0, 0);
        step(2, ex, ey, f(ex - ox), f(ey - oy), 0, 0, 0, 0);
        step(1, ex, ey, 0, 0, 0, 0, 0, 0);
      } else if (mode === 7) {
        step(4, 0, 0, 0, 0, 0, 0, 1, 0);
        step(has(16) ? 5 : 4, 0, 0, 0, 0, 0, 0, has(16) ? 0 : 2, has(16) ? 1 : 0);
      } else if (mode === 8) step(10, 0, 0, 0, 0, 0, 0, 0, 1);
      else if (mode === 9) {
        flags = 8; ox = cx; oy = cy; ex = f(cx + dx); ey = f(cy + dy);
        step(2, ex, ey, dx, dy, 0, 0, 0, 0); step(1, ex, ey, 0, 0, 0, 0, 0, 0);
      } else if (mode === 10) { flags = 0; step(11, cx, cy, 0, 0, 0, 0, 0, 0); }
    }
  }
  if (status !== 0) { steps.length = 0; if (mode !== 12) flags = 0; }
  const result = new Uint8Array(40 + steps.length * 36), out = new DataView(result.buffer);
  out.setUint32(0, 1, true); out.setUint32(4, mode, true); out.setUint32(8, status, true);
  out.setUint32(12, flags, true); out.setUint32(16, steps.length, true);
  out.setFloat32(20, ox, true); out.setFloat32(24, oy, true);
  out.setFloat32(28, ex, true); out.setFloat32(32, ey, true);
  for (let i = 0; i < steps.length; i++) {
    const value = steps[i]!, at = 40 + i * 36;
    out.setUint32(at, value.event, true); out.setUint32(at + 4, value.button, true);
    out.setUint32(at + 8, value.key, true); out.setUint32(at + 12, value.text, true);
    out.setFloat32(at + 16, value.x, true); out.setFloat32(at + 20, value.y, true);
    out.setFloat32(at + 24, value.dx, true); out.setFloat32(at + 28, value.dy, true); out.setFloat32(at + 32, value.scale, true);
  }
  return result;
}
