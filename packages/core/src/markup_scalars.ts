/** Scalar expression semantics (105). Exact signed i64 values use four
 * little-endian base-65536 limbs; no integer is converted to a JS number.
 * Native supplies the original f32 conversions and arithmetic/rounding
 * primitives. This owner selects results and all value-dependent failures.
 * String equality streams bounded copied blocks without a new length bound.
 * Replies are independently owned: value=0, teaching failure=1, compare=2.
 */
function nscvScalarNegate(a: readonly number[]): number[] {
  const out: number[] = []; let carry = 1;
  for (let i = 0; i < 4; i++) {
    const sum = 65535 - a[i]! + carry;
    out.push(sum % 65536); carry = Math.floor(sum / 65536);
  }
  return out;
}
function nscvScalarCompare(a: readonly number[], b: readonly number[]): number {
  if ((a[3]! >= 32768) !== (b[3]! >= 32768)) return a[3]! >= 32768 ? -1 : 1;
  for (let i = 3; i >= 0; i--) if (a[i] !== b[i]) return a[i]! < b[i]! ? -1 : 1;
  return 0;
}
function nscvScalarMinimum(a: readonly number[]): boolean {
  return a[0] === 0 && a[1] === 0 && a[2] === 0 && a[3] === 32768;
}
function nscvScalarInteger(cap: number, a: readonly number[], b: readonly number[]): number[] {
  const negativeA = a[3]! >= 32768, negativeB = b[3]! >= 32768;
  if (cap === 2 || cap === 29) {
    if (nscvScalarMinimum(a)) return [0, 0, 0, 0, cap === 2 ? 6 : 9];
    return [...(cap === 2 || negativeA ? nscvScalarNegate(a) : a), 0];
  }
  if (cap === 27 || cap === 28) {
    const comparison = nscvScalarCompare(a, b);
    return [...(cap === 27 ? comparison <= 0 ? a : b : comparison >= 0 ? a : b), 0];
  }
  if (cap >= 30) return [...a, 0];
  if (cap === 4 || cap === 5) {
    const right = cap === 5 ? nscvScalarNegate(b) : b;
    const out: number[] = []; let carry = 0;
    for (let i = 0; i < 4; i++) {
      const sum = a[i]! + right[i]! + carry;
      out.push(sum % 65536); carry = Math.floor(sum / 65536);
    }
    const negativeResult = out[3]! >= 32768;
    const overflow = cap === 4 ? negativeA === negativeB && negativeResult !== negativeA :
      negativeA !== negativeB && negativeResult !== negativeA;
    out.push(overflow ? 6 : 0); return out;
  }
  // Full unsigned 128-bit magnitude, then admit the signed 64-bit range.
  // Each multiply/add is below 2^33, and is exact in a binary64 number.
  const left = negativeA ? nscvScalarNegate(a) : a;
  const right = negativeB ? nscvScalarNegate(b) : b;
  const product = [0, 0, 0, 0, 0, 0, 0, 0];
  for (let i = 0; i < 4; i++) {
    let carry = 0;
    for (let j = 0; j < 4; j++) {
      const sum = product[i + j]! + left[i]! * right[j]! + carry;
      product[i + j] = sum % 65536; carry = Math.floor(sum / 65536);
    }
    product[i + 4] = carry;
  }
  const negative = negativeA !== negativeB;
  const overflow = product[4] !== 0 || product[5] !== 0 || product[6] !== 0 || product[7] !== 0 ||
    (negative ? product[3]! > 32768 || product[3] === 32768 &&
      (product[0] !== 0 || product[1] !== 0 || product[2] !== 0) : product[3]! >= 32768);
  const magnitude = product.slice(0, 4);
  return [...(negative ? nscvScalarNegate(magnitude) : magnitude), overflow ? 6 : 0];
}
function nscvMarkupScalars(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 105 || request[1] !== 1 ||
      !((request[2]! >= 2 && request[2]! <= 7) || (request[2]! >= 9 && request[2]! <= 16) ||
        (request[2]! >= 27 && request[2]! <= 32) || request[2] === 36) ||
      request[3]! < 1 || request[3]! > 4 || request[4]! < 1 || request[4]! > 4 ||
      request[5]! > 2 || request[6]! > 1 || request[7]! > 1)
    throw new Error("invalid scalar expression header");
  const cap = request[2]!, ak = request[3]!, bk = request[4]!;
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const out = new Uint8Array(16), result = new DataView(out.buffer);
  out[0] = 105; out[1] = 1;
  if (request[5] === 2) {
    if (request.length < 16 || cap !== 9 || ak !== 1 || bk !== 1 || request[6] !== 0 || request[7] !== 0 ||
        wire.getUint32(12, true) !== 0) throw new Error("invalid scalar comparison block");
    const al = wire.getUint16(8, true), bl = wire.getUint16(10, true);
    if (al > 256 || bl > 256 || request.length !== 16 + al + bl) throw new Error("invalid scalar comparison length");
    let equal = al === bl;
    if (equal) for (let i = 0; i < al; i++) if (request[16 + i] !== request[16 + al + i]) { equal = false; break; }
    out[3] = 4; out[5] = equal ? 1 : 0; return out;
  }
  if (request.length !== 48 || wire.getUint32(36, true) !== 0 || wire.getUint32(40, true) !== 0 ||
      wire.getUint32(44, true) !== 0 || request[5] === 1 && !((cap === 9 || cap === 10) && ak === 1 && bk === 1))
    throw new Error("invalid scalar expression payload");
  const a = [wire.getUint16(8, true), wire.getUint16(10, true), wire.getUint16(12, true), wire.getUint16(14, true)];
  const b = [wire.getUint16(16, true), wire.getUint16(18, true), wire.getUint16(20, true), wire.getUint16(22, true)];
  const fa = wire.getFloat32(24, true), fb = wire.getFloat32(28, true), primitive = wire.getFloat32(32, true);
  const an = ak === 2 || ak === 3, bn = bk === 2 || bk === 3;
  let failure = 0, boolean = false, kind = 0;
  if (cap === 36) {
    boolean = ak === 4 ? request[6] === 1 : ak === 3 ? fa !== 0 : a[0] !== 0 || a[1] !== 0 || a[2] !== 0 || a[3] !== 0;
    kind = 4;
  } else if (cap === 9 || cap === 10) {
    if (ak === 1 && bk === 1) {
      if (request[5] === 0 && nscvScalarCompare(a, b) === 0) { out[2] = 2; return out; }
      boolean = request[5] === 1 && request[6] === 1;
    } else if (ak === 2 && bk === 2) boolean = nscvScalarCompare(a, b) === 0;
    else if (an && bn) boolean = fa === fb;
    else if (ak === 4 && bk === 4) boolean = request[6] === request[7];
    boolean = cap === 10 ? !boolean : boolean; kind = 4;
  } else if (cap === 3 || cap === 15 || cap === 16) {
    if (ak !== 4 || cap !== 3 && bk !== 4) failure = 2;
    boolean = cap === 3 ? request[6] === 0 : cap === 15 ? request[6] === 1 && request[7] === 1 :
      request[6] === 1 || request[7] === 1;
    kind = 4;
  } else if (!an || ((cap >= 4 && cap <= 7 || cap >= 11 && cap <= 14 || cap === 27 || cap === 28) && !bn)) {
    failure = cap === 2 ? 1 : cap <= 7 ? 3 : cap <= 14 ? 4 : cap - 2;
  } else if (cap >= 11 && cap <= 14) {
    boolean = cap === 11 ? fa < fb : cap === 12 ? fa <= fb : cap === 13 ? fa > fb : fa >= fb;
    kind = 4;
  } else if (ak === 2 && (cap === 2 || cap === 29 || cap >= 30 || bk === 2 && cap !== 7)) {
    const integer = nscvScalarInteger(cap, a, b); failure = integer[4]!; kind = 2;
    for (let i = 0; i < 4; i++) result.setUint16(8 + 2 * i, integer[i]!, true);
  } else if (cap === 2 || cap === 29) {
    kind = 3;
    if (cap === 29 && Number.isNaN(fa)) failure = 8;
    result.setUint32(8, cap === 2 ? (wire.getUint32(8, true) ^ 0x80000000) >>> 0 : wire.getUint32(8, true) & 0x7fffffff, true);
  } else if (cap >= 30) {
    kind = 2;
    if (!Number.isFinite(fa)) failure = 8;
    else if (primitive < -9007199254740992 || primitive > 9007199254740992) failure = 10;
    else {
      let magnitude = Math.abs(primitive); const integer: number[] = [];
      for (let i = 0; i < 4; i++) { integer.push(magnitude % 65536); magnitude = Math.floor(magnitude / 65536); }
      const signed = primitive < 0 ? nscvScalarNegate(integer) : integer;
      for (let i = 0; i < 4; i++) result.setUint16(8 + 2 * i, signed[i]!, true);
    }
  } else {
    kind = 3;
    if (cap === 7 && fb === 0) failure = 7;
    else if (cap === 27 || cap === 28) { if (Number.isNaN(fa) || Number.isNaN(fb)) failure = 8; }
    else if (!Number.isFinite(primitive)) failure = 8;
    result.setUint32(8, wire.getUint32(32, true), true);
  }
  if (failure !== 0) { out.fill(0, 2); out[2] = 1; out[4] = failure; }
  else { out[3] = kind; out[5] = kind === 4 && boolean ? 1 : 0; }
  return out;
}
