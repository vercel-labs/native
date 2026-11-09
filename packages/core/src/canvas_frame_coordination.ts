/** Frame admission and surface preparation over copied native observations.
 * Native keeps resource/buffer storage, command observation and OS/GPU calls. */
function nscvCanvasFrameCoordination(request: Uint8Array): Uint8Array {
  if (request.length !== 320 || request[0] !== 75 || request[1] !== 1 || request[2]! > 6 || request[3] !== 0)
    throw new Error("invalid canvas frame coordination header");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const mode = request[2]!, facts = wire.getUint32(4, true);
  if (facts > 127 || wire.getUint32(312, true) !== 0 || wire.getUint32(316, true) !== 0)
    throw new Error("invalid canvas frame coordination facts");
  const result = new Uint8Array(64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  let flags = 0;
  const zero = (at: number): boolean => wire.getUint32(at, true) === 0 && wire.getUint32(at + 4, true) === 0;
  const equal64 = (a: number, b: number): boolean => wire.getUint32(a, true) === wire.getUint32(b, true) && wire.getUint32(a + 4, true) === wire.getUint32(b + 4, true);
  const copy = (to: number, from: number): void => { out.setUint32(to, wire.getUint32(from, true), true); };
  const empty = (at: number): boolean => wire.getFloat32(at, true) <= 0 || wire.getFloat32(at + 4, true) <= 0;
  const normalizedScale = (): void => {
    const wanted = wire.getFloat32(32, true), fallback = wire.getFloat32(36, true);
    if ((facts & 32) !== 0 && Number.isFinite(wanted) && wanted > 0) copy(16, 32);
    else if (Number.isFinite(fallback) && fallback > 0) copy(16, 36);
    else out.setFloat32(16, 1, true);
  };
  if (mode === 0) {
    const at = empty(8) ? empty(16) ? 24 : 16 : 8;
    copy(8, at); copy(12, at + 4);
    if (zero(96)) flags |= 1;
    if (zero(104)) flags |= 2;
    let unset = true;
    for (let at = 128; at < 312; at += 8) if (!zero(at)) unset = false;
    if (unset) flags |= 4;
  } else if (mode === 1 || mode === 2) {
    const changed = !equal64(64, 72);
    const surfaceChanged = wire.getFloat32(8, true) !== wire.getFloat32(40, true) ||
      wire.getFloat32(12, true) !== wire.getFloat32(44, true) || wire.getFloat32(32, true) !== wire.getFloat32(48, true);
    const full = (facts & 1) !== 0 || (facts & 2) === 0 || surfaceChanged ||
      changed && ((facts & 4) !== 0 || mode === 2 && (facts & 8) !== 0);
    if (mode === 1) {
      if ((facts & 1) === 0 && (facts & 2) !== 0 && !changed && !surfaceChanged && zero(80) && zero(88)) flags |= 8;
      if (changed) flags |= 16;
      if (surfaceChanged) flags |= 32;
      // Request the current unkeyed observation only when native's original
      // short-circuit would reach it, after the ordered frame planners finish.
      if (!full && changed) flags |= 64;
    } else if (!full && changed && (facts & 16) !== 0 &&
      wire.getFloat32(8, true) === wire.getFloat32(52, true) &&
      wire.getFloat32(12, true) === wire.getFloat32(56, true) &&
      wire.getFloat32(32, true) === wire.getFloat32(60, true)) flags |= 256;
    if (full) flags |= 128;
  } else if (mode === 3) {
    const width = wire.getFloat32(8, true), height = wire.getFloat32(12, true);
    if (!(Math.abs(width) <= 0 || Math.abs(height) <= 0)) {
      flags |= 512;
      // Preserve copied float32 payloads, including signed zero and NaNs.
      // A negative extent moves the zero origin and flips its extent sign.
      if (width < 0) { copy(20, 8); out.setUint32(28, (wire.getUint32(8, true) ^ 2147483648) >>> 0, true); }
      else copy(28, 8);
      if (height < 0) { copy(24, 12); out.setUint32(32, (wire.getUint32(12, true) ^ 2147483648) >>> 0, true); }
      else copy(32, 12);
    } else if ((facts & 64) !== 0) {
      flags |= 512;
      for (let i = 0; i < 4; i++) copy(20 + i * 4, 112 + i * 4);
    }
  } else if (mode === 4) {
    normalizedScale();
  } else if (mode === 5) {
    const rawScale = wire.getFloat32(32, true), scale = Number.isFinite(rawScale) && rawScale > 0 ? rawScale : 1;
    const width = Math.fround(wire.getFloat32(8, true) * scale), height = Math.fround(wire.getFloat32(12, true) * scale);
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0 || width > 16384 || height > 16384) flags |= 1024;
    else {
      const w = Math.ceil(width), h = Math.ceil(height);
      // The extent cap proves all three products fit every supported usize,
      // including the 32-bit targets; the largest byte length is 1 GiB.
      out.setUint32(36, w, true); out.setUint32(40, h, true); out.setUint32(44, w * h * 4, true);
    }
  } else {
    const at = empty(16) ? 24 : 16;
    copy(8, at); copy(12, at + 4); normalizedScale();
  }
  out.setUint32(4, flags, true);
  return result;
}
