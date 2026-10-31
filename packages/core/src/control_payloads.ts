/** Primitive payload decisions over copied appearance and geometry facts.
 * Native owns drawing storage and resolves fonts and registered icons. */
function nscvControlPayloads(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 46 || request[1]! > 1) throw new Error("invalid control payload header");
  if (request[1] === 1) return nscvControlPayloadGeometry(request);
  if (request.length !== 560 || request[2]! > 16 || request[3]! > 7 || request[4]! > 7 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid control payload color");
  const bytes = request.subarray(8, 504), wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (bytes[0] !== 16 || bytes[1] !== 2 || bytes[2] !== 0 || bytes[3]! >= nscvAppearanceKinds.length || bytes[4]! > 5 || bytes[5]! > 5 || bytes[6]! > 31 || bytes[7]! > 3)
    throw new Error("invalid payload appearance context");
  const c = nscvAppearanceContext(bytes), v = c.visual.colors, p = c.palette;
  const family = request[2]!, role = request[3]!, selected = c.selected || wire.getFloat32(552, true) >= 0.5;
  const border = request.subarray(504, 520), muted = request.subarray(520, 536), focus = request.subarray(536, 552);
  const underline = (request[4]! & 1) !== 0, focused = (request[4]! & 2) !== 0, rawHovered = (request[4]! & 4) !== 0;
  if (wire.getUint32(556, true) !== 0) throw new Error("invalid control payload reserved bytes");
  const bg = (fallback: NscAppearanceColor): NscAppearanceColor => nscvAppearanceBackground(c, fallback);
  const accent = (fallback: NscAppearanceColor): NscAppearanceColor => nscvAppearanceAccent(c, fallback);
  const ink = (fallback: NscAppearanceColor): NscAppearanceColor => nscvAppearanceForeground(c, fallback, false);
  const wash = (value: NscAppearanceColor, disabled: boolean): NscAppearanceColor => nscvAppearanceWash(value, disabled, c.alpha[0]!, c.numeric);
  const state = (active: boolean, hover: boolean, fallback: NscAppearanceColor): NscAppearanceColor => nscvAppearanceState(c.visual, active, hover, fallback);
  const neutral = (): NscAppearanceColor => c.style[4] ?? v[8] ?? border;
  const selection = (value: NscAppearanceColor, foreground: boolean, background = false): NscAppearanceColor => {
    if (!c.disabled) return value;
    if (foreground && v[5] !== null) return v[5]!;
    if (background && v[4] !== null) return v[4]!;
    return wash(value, v[4] === null && v[5] === null);
  };
  let color: NscAppearanceColor;
  if (family <= 1) color = role === 0 ? nscvAppearanceButtonFill(c) : role === 1 ? nscvAppearanceButtonBorder(c) : nscvAppearanceButtonText(c);
  else if (family === 2) color = role === 0 ? bg(state(c.pressed, c.hovered, p[0]!)) : role === 1 ? neutral() : role === 3 ? ink(muted) : ink(v[6] ?? (role === 4 ? muted : p[6]!));
  else if (family >= 3 && family <= 5) {
    if (role === 0) color = c.disabled ? v[4] ?? wash(bg(state(false, false, p[0]!)), true) : bg(state(false, c.hovered, p[0]!));
    else if (role === 1) color = neutral();
    else color = ink(role === 3 ? family === 5 ? v[6] ?? muted : muted : v[6] ?? (role === 4 ? muted : p[6]!));
  } else if (family === 6) color = role === 0 ? accent(state(c.pressed || c.selected, c.hovered, p[3]!)) : nscvAppearanceForeground(c, v[6] ?? p[4]!, true);
  else if (family >= 7 && family <= 10) {
    if (role === 0 || family === 7 && role === 7) {
      if (family === 7) { const attention = c.pressed ? v[3] ?? state(true, false, p[2]!) : focused || c.hovered ? state(false, true, p[1]!) : nscvAppearanceTransparent(); color = role === 7 ? attention : bg(attention); }
      else color = nscvAppearanceListFill(c);
    } else color = role === 1 ? neutral() : ink(v[6] ?? p[6]!);
  } else if (family === 11) {
    if (role === 0) color = accent(v[2] ?? p[0]!);
    else if (role === 5) color = bg(state(false, c.hovered, c.style[0] ?? v[0] ?? nscvAppearanceTransparent()));
    else if (role === 6) color = accent(v[2] ?? p[6]!);
    else if (role === 1) color = neutral();
    else {
      const activeInk = underline ? c.style[1] ?? v[6] ?? p[6]! : ink(v[6] ?? p[6]!);
      color = selected || underline && rawHovered && !c.disabled ? activeInk : ink(v[6] ?? muted);
    }
  } else if (family <= 14) {
    if (role === 0) color = selection(family !== 13 && selected ? accent(v[2] ?? p[3]!) : bg(state(false, c.hovered, p[family === 14 ? 2 : 0]!)), false, true);
    else if (role === 1) color = selection(family === 12 && selected ? accent(v[8] ?? v[2] ?? p[3]!) : neutral(), false);
    else if (role === 4) color = selection(family === 13 ? accent(v[2] ?? p[3]!) : c.style[3] ?? v[6] ?? p[4]!, true);
    else color = selection(c.style[1] ?? v[6] ?? p[6]!, true);
  } else if (family === 15) {
    const washed = c.disabled && v[4] === null && v[5] === null;
    if (role === 0) color = wash(bg(v[0] ?? p[1]!), washed);
    else if (role === 5) color = c.disabled ? v[4] ?? wash(accent(v[2] ?? p[3]!), true) : accent(v[2] ?? p[3]!);
    else if (role === 6) {
      const white = new Uint8Array(16), view = new DataView(white.buffer); for (let i = 0; i < 4; i++) view.setFloat32(i * 4, 1, true);
      const rest = bg(v[6] ?? white); color = c.disabled ? v[5] ?? wash(rest, washed) : rest;
    } else color = c.style[4] ?? wash(v[8] ?? focus, washed);
  } else color = role === 0 ? bg(v[0] ?? p[1]!) : accent(v[2] ?? p[3]!);
  return new Uint8Array(color);
}

function nscvControlPayloadGeometry(request: Uint8Array): Uint8Array {
  if (request.length !== 128 || request[2]! > 11 || request[3]! > 15 || request[4]! > 31) throw new Error("invalid control payload geometry");
  for (let i = 5; i < 16; i++) if (request[i] !== 0) throw new Error("invalid control payload geometry reserved bytes");
  for (let i = 64; i < 128; i++) if (request[i] !== 0) throw new Error("invalid control payload geometry tail");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), op = request[2]!, f = Math.fround;
  const v = (at: number): number => w.getFloat32(at, true), numeric = request[3]!;
  const max = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, true);
  const min = (a: number, b: number): number => nscvRenderExtreme(a, b, numeric, false);
  const signaling = (at: number): boolean => { const word = w.getUint32(at, true); return (word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0; };
  // Reuse the native target's existing signaling-operand numeric capability.
  const rawMin = (at: number, other: number): number => signaling(at) && (request[4]! & 2) !== 0 ? v(at) : min(v(at), other);
  const pairMin = (a: number, b: number): number => signaling(a) && (request[4]! & 2) !== 0 ? v(a) : signaling(b) && (request[4]! & 4) !== 0 ? v(b) : min(v(a), v(b));
  const x = v(16), y = v(20), width = v(24), height = v(28), size = v(48), inset = v(52), gap = v(56), stroke = v(60);
  const result = new Uint8Array(64), out = new DataView(result.buffer); out.setUint32(0, 1, true);
  const rect = (slot: number, a: number, b: number, c: number, d: number): void => {
    const at = 8 + slot * 16; out.setFloat32(at, a, true); out.setFloat32(at + 4, b, true); out.setFloat32(at + 8, c, true); out.setFloat32(at + 12, d, true);
  };
  if (op === 0) {
    const left = f(v(32) + f(size * 0.5)); rect(0, left, f(y - stroke), max(0, f(f(f(x + width) + stroke) - left)), f(height + f(stroke * 2)));
  } else if (op === 1) {
    rect(0, f(x + inset), y, max(1, f(f(width - f(inset * 2)) - f(size + inset))), height);
    rect(1, f(f(f(x + width) - inset) - size), f(y + f(f(height - size) * 0.5)), size, size);
  } else if (op === 2) rect(0, f(x + f(f(width - size) * 0.5)), f(y + f(f(height - size) * 0.5)), size, size);
  else if (op === 3) {
    const extent = max(8, f(size - 2)); rect(0, f(x + inset), f(y + max(0, f(f(height - extent) * 0.5))), extent, extent);
  } else if (op === 4) {
    rect(0, x, y, max(1, f(f(width - size) - gap)), height);
    rect(1, f(x + inset), f(y + f(f(height - size) * 0.5)), size, size);
    rect(2, f(f(f(x + width) - inset) - size), f(y + f(f(height - size) * 0.5)), size, size);
  } else if (op === 5 || op === 11) {
    const shift = f(size + gap); rect(0, f(x + shift), y, max(1, f(width - shift)), height);
    if (op === 5) rect(1, f(x + inset), f(y + f(f(height - size) * 0.5)), size, size);
  } else if (op === 6) {
    rect(0, f(x + f(width * f(0.26))), f(y + f(height * f(0.54))), 0, 0);
    rect(1, f(x + f(width * f(0.43))), f(y + f(height * f(0.70))), 0, 0);
    rect(2, f(x + f(width * f(0.76))), f(y + f(height * f(0.32))), 0, 0);
  } else if (op === 7) {
    const dot = max(0, f(height * 0.5)); rect(0, f(x + f(f(width - dot) * 0.5)), f(y + f(f(height - dot) * 0.5)), dot, dot);
  } else if (op === 8) rect(0, rawMin(48, f(height * 0.5)), 0, 0, 0);
  else if (op === 9) rect(0, f(height * 0.5), f(pairMin(40, 44) * 0.5), 0, 0);
  else rect(0, f(f(x + width) + inset), 0, 0, 0);
  if (op === 1) { result.set(request.subarray(20, 24), 12); result.set(request.subarray(28, 32), 20); }
  // Uncomputed extents retain their original words, including signaling NaNs.
  // A float read/write would quiet those words before the native consumer.
  if (op === 2) { result.set(request.subarray(48, 52), 16); result.set(request.subarray(48, 52), 20); }
  if (op === 1 || op === 4 || op === 5) { result.set(request.subarray(48, 52), 32); result.set(request.subarray(48, 52), 36); }
  if (op === 4) { result.set(request.subarray(48, 52), 48); result.set(request.subarray(48, 52), 52); }
  if (op === 4 || op === 5 || op === 11) {
    result.set(request.subarray(20, 24), 12); result.set(request.subarray(28, 32), 20);
    if (op === 4) result.set(request.subarray(16, 20), 8);
  }
  return result;
}
