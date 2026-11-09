/** Portable decoration and exact primitive identities. Native retains drawing,
 * font shaping, registered icons, and owned display-list/text/path storage. */
interface NscPrimitiveWord { primitiveLo: number; primitiveHi: number }
function nscvPrimitiveWord(w: DataView, at: number): NscPrimitiveWord {
  return { primitiveLo: w.getUint32(at, true), primitiveHi: w.getUint32(at + 4, true) };
}
function nscvPrimitiveWrite(w: DataView, at: number, word: NscPrimitiveWord): void {
  w.setUint32(at, word.primitiveLo, true); w.setUint32(at + 4, word.primitiveHi, true);
}
function nscvPrimitiveXor(a: NscPrimitiveWord, b: NscPrimitiveWord): NscPrimitiveWord {
  return { primitiveLo: (a.primitiveLo ^ b.primitiveLo) >>> 0, primitiveHi: (a.primitiveHi ^ b.primitiveHi) >>> 0 };
}
function nscvPrimitiveAdd(a: NscPrimitiveWord, b: NscPrimitiveWord, checked = false): NscPrimitiveWord {
  const lower = a.primitiveLo + b.primitiveLo, upper = a.primitiveHi + b.primitiveHi + (lower >= 4294967296 ? 1 : 0);
  if (checked && upper >= 4294967296) throw new Error("primitive slot overflow");
  return { primitiveLo: lower >>> 0, primitiveHi: upper >>> 0 };
}
function nscvPrimitivePart(id: NscPrimitiveWord, slot: NscPrimitiveWord): NscPrimitiveWord {
  if (id.primitiveLo === 0 && id.primitiveHi === 0) return id;
  const base = { primitiveLo: (id.primitiveLo << 4) >>> 0, primitiveHi: ((id.primitiveHi << 4) | (id.primitiveLo >>> 28)) >>> 0 };
  const part = nscvPrimitiveAdd(base, slot);
  return part.primitiveLo === 0 && part.primitiveHi === 0 ? id : part;
}
function nscvPrimitiveMultiply(a: NscPrimitiveWord, b: NscPrimitiveWord): { productLower: NscPrimitiveWord; productUpper: NscPrimitiveWord } {
  // Sixteen-bit limbs keep every intermediate exactly representable in f64.
  const left = [a.primitiveLo & 65535, a.primitiveLo >>> 16, a.primitiveHi & 65535, a.primitiveHi >>> 16];
  const right = [b.primitiveLo & 65535, b.primitiveLo >>> 16, b.primitiveHi & 65535, b.primitiveHi >>> 16];
  const limbs = [0, 0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) limbs[i + j] = limbs[i + j]! + left[i]! * right[j]!;
  for (let i = 0; i < 7; i++) { limbs[i + 1] = limbs[i + 1]! + Math.floor(limbs[i]! / 65536); limbs[i] = limbs[i]! % 65536; }
  return {
    productLower: { primitiveLo: (limbs[0]! + limbs[1]! * 65536) >>> 0, primitiveHi: (limbs[2]! + limbs[3]! * 65536) >>> 0 },
    productUpper: { primitiveLo: (limbs[4]! + limbs[5]! * 65536) >>> 0, primitiveHi: (limbs[6]! + limbs[7]! * 65536) >>> 0 },
  };
}
function nscvPrimitiveMix(a: NscPrimitiveWord, b: NscPrimitiveWord): NscPrimitiveWord {
  const product = nscvPrimitiveMultiply(a, b); return nscvPrimitiveXor(product.productLower, product.productUpper);
}
function nscvPrimitiveOverlay(seed: NscPrimitiveWord, id: NscPrimitiveWord, ordinal: NscPrimitiveWord): NscPrimitiveWord {
  // The native selected-glyph identity hashes exactly sixteen little-endian
  // bytes (widget id, rectangle ordinal) with the final Wyhash algorithm.
  const secret0 = { primitiveLo: 0x78bd642f, primitiveHi: 0xa0761d64 };
  const secret1 = { primitiveLo: 0xa0b428db, primitiveHi: 0xe7037ed1 };
  const state = nscvPrimitiveXor(seed, nscvPrimitiveMix(nscvPrimitiveXor(seed, secret0), secret1));
  const a = { primitiveLo: ordinal.primitiveLo, primitiveHi: id.primitiveLo };
  const b = { primitiveLo: id.primitiveHi, primitiveHi: ordinal.primitiveHi };
  const product = nscvPrimitiveMultiply(nscvPrimitiveXor(a, secret1), nscvPrimitiveXor(b, state));
  const value = nscvPrimitiveMix(nscvPrimitiveXor(nscvPrimitiveXor(product.productLower, secret0), { primitiveLo: 16, primitiveHi: 0 }), nscvPrimitiveXor(product.productUpper, secret1));
  return value.primitiveLo === 0 && value.primitiveHi === 0 ? { primitiveLo: 1, primitiveHi: 0 } : value;
}
function nscvControlPrimitives(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 47 || request[1]! > 2 || request[2] !== 1) throw new Error("invalid control primitive header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), op = request[1]!;
  if (op < 2) {
    if (request.length !== 32) throw new Error("invalid control identity shape");
    for (let i = 3; i < 8; i++) if (request[i] !== 0) throw new Error("invalid control identity reserved bytes");
    if (op === 0) for (let i = 24; i < 32; i++) if (request[i] !== 0) throw new Error("invalid control identity tail");
    const result = new Uint8Array(8), out = new DataView(result.buffer);
    nscvPrimitiveWrite(out, 0, op === 0 ? nscvPrimitivePart(nscvPrimitiveWord(w, 8), nscvPrimitiveWord(w, 16)) : nscvPrimitiveOverlay(nscvPrimitiveWord(w, 8), nscvPrimitiveWord(w, 16), nscvPrimitiveWord(w, 24)));
    return result;
  }
  if (request.length !== 40 || request[3]! > 1 || request[4]! > 5 || request[5]! > 15 || request[6]! > 31 || request[7]! > 31) throw new Error("invalid control radius facts");
  for (let i = 36; i < 40; i++) if (request[i] !== 0) throw new Error("invalid control radius tail");
  const numeric = request[5]!, flags = request[7]!, size = request[4]!, ownedAppearance = (flags & 8) !== 0;
  const f = Math.fround, v = (at: number): number => w.getFloat32(at, true);
  const nativeMax = (value: number, rawAt = -1): number => {
    const word = rawAt < 0 ? 0 : w.getUint32(rawAt, true);
    if ((word & 0x7f800000) === 0x7f800000 && (word & 0x007fffff) !== 0 && (word & 0x00400000) === 0 && (request[6]! & 16) !== 0) return value;
    return nscvRenderExtreme(0, value, numeric, true);
  };
  const sized = (value: number): number => size === 1 ? nativeMax(f(value - 2)) : size === 2 ? f(value + 2) : value;
  let radius: number;
  if (request[3] === 0) {
    // The existing owner has already resolved authored/visual precedence.
    // Copy its scalar, including arbitrary NaN payloads and signed zero.
    if (ownedAppearance && (flags & 3) !== 0) return request.slice(32, 36);
    if ((flags & 1) !== 0) radius = nativeMax(v(8), 8);
    else if ((flags & 2) !== 0) radius = nativeMax(sized(v(12)), size === 1 || size === 2 ? -1 : 12);
    else radius = nativeMax(v(16), 16);
  } else {
    if ((flags & 1) !== 0) radius = nativeMax(v(8), 8);
    else if ((flags & 2) !== 0) radius = ownedAppearance ? nativeMax(v(32), 32) : nativeMax(sized(v(12)), size === 1 || size === 2 ? -1 : 12);
    else if ((flags & 4) !== 0) radius = 0;
    else radius = nativeMax(f((ownedAppearance ? v(32) : sized((flags & 16) !== 0 ? v(20) : v(24))) - v(28)));
  }
  const result = new Uint8Array(4); new DataView(result.buffer).setFloat32(0, radius, true); return result;
}

/** Vector plans copy style and transform facts; path ranges never cross. */
function nscvControlVectors(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 48 || request[1]! > 1 || request[2] !== 1) throw new Error("invalid control vector header");
  const w = new DataView(request.buffer, request.byteOffset, request.byteLength), result = new Uint8Array(64), out = new DataView(result.buffer);
  out.setUint32(0, 1, true);
  if (request[1] === 0) {
    if (request.length !== 64 || request[3]! > 15) throw new Error("invalid vector transform facts");
    for (let i = 4; i < 8; i++) if (request[i] !== 0) throw new Error("invalid vector transform reserved bytes");
    for (let i = 40; i < 64; i++) if (request[i] !== 0) throw new Error("invalid vector transform tail");
    const f = Math.fround, frame = nscvSurfaceNormalize(nscvRenderRect(w, 8)), box = nscvRenderRect(w, 24);
    if (nscvRenderEmpty(frame)) return result;
    const scale = nscvRenderExtreme(f(frame.width / box.width), f(frame.height / box.height), request[3]!, false);
    if (!(scale > 0)) return result;
    const tx = f(f(frame.x + f(f(frame.width - f(box.width * scale)) * 0.5)) - f(box.x * scale));
    const ty = f(f(frame.y + f(f(frame.height - f(box.height * scale)) * 0.5)) - f(box.y * scale));
    const determinant = f(f(scale * scale) - f(0 * 0));
    if (Math.abs(determinant) <= f(0.000001)) return result;
    const inv = f(1 / determinant);
    const forward = [scale, 0, 0, scale, tx, ty];
    const inverse = [f(scale * inv), f(-0 * inv), f(-0 * inv), f(scale * inv), f(f(f(0 * ty) - f(scale * tx)) * inv), f(f(f(0 * tx) - f(scale * ty)) * inv)];
    out.setUint32(4, 1, true);
    for (let i = 0; i < 6; i++) { out.setFloat32(8 + i * 4, forward[i]!, true); out.setFloat32(32 + i * 4, inverse[i]!, true); }
    return result;
  }
  if (request.length !== 96 || request[3]! > 2 || request[4]! > 2 || request[5]! > 1 || request[6]! > 1 || request[7]! > 1) throw new Error("invalid vector paint facts");
  for (let i = 84; i < 96; i++) if (request[i] !== 0) throw new Error("invalid vector paint tail");
  const id = nscvPrimitiveWord(w, 8), first = nscvPrimitiveWord(w, 16), index = nscvPrimitiveWord(w, 24), checked = request[6] !== 0;
  // Request each paint immediately before emission: a successful fill must
  // remain in the display list if the later stroke fails.
  const fill = request[7] === 0 && request[3] !== 0, stroke = request[7] === 1 && request[4] !== 0 && w.getFloat32(80, true) > 0;
  out.setUint32(4, (fill ? 1 : 0) | (stroke ? 2 : 0), true);
  if (fill || stroke) {
    if (checked && index.primitiveHi >= 0x80000000) throw new Error("primitive slot overflow");
    const doubled = { primitiveLo: (index.primitiveLo << 1) >>> 0, primitiveHi: ((index.primitiveHi << 1) | (index.primitiveLo >>> 31)) >>> 0 };
    if (fill) {
      nscvPrimitiveWrite(out, 8, nscvPrimitivePart(id, nscvPrimitiveAdd(first, doubled, checked)));
      result.set(request.subarray(request[3] === 1 ? 32 : 48, request[3] === 1 ? 48 : 64), 24);
    }
    if (stroke) {
      nscvPrimitiveWrite(out, 16, nscvPrimitivePart(id, nscvPrimitiveAdd(nscvPrimitiveAdd(first, { primitiveLo: 1, primitiveHi: 0 }, checked), doubled, checked)));
      result.set(request.subarray(request[4] === 1 ? 32 : 64, request[4] === 1 ? 48 : 80), 40);
      result.set(request.subarray(80, 84), 56); out.setUint32(60, request[5]!, true);
    }
  }
  return result;
}
