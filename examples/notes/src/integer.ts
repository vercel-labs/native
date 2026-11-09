// Decimal bytes preserve the store's entire signed-i64 domain in both Node
// and compiled code. No timestamp or subtraction passes through f64.
import { asciiBytes } from "@native-sdk/core";
export function magnitude(a: Uint8Array): Uint8Array { return a[0] === 45 ? a.slice(1) : a; }
export function compareMagnitude(a: Uint8Array, b: Uint8Array): number {
  if (a.length !== b.length) return a.length < b.length ? -1 : 1;
  for (let i = 0; i < a.length; i += 1) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  return 0;
}
export function compareStamp(a: Uint8Array, b: Uint8Array): number {
  const an = a[0] === 45, bn = b[0] === 45;
  if (an !== bn) return an ? -1 : 1;
  const order = compareMagnitude(magnitude(a), magnitude(b));
  return an ? -order : order;
}
export function parseStamp(raw: Uint8Array): Uint8Array | null {
  let at = 0, negative = false;
  if (raw.length > 0 && (raw[0] === 45 || raw[0] === 43)) { negative = raw[0] === 45; at = 1; }
  if (at === raw.length || raw[at] === 95 || raw[raw.length - 1] === 95) return null;
  const digits: number[] = [];
  for (let i = at; i < raw.length; i += 1) {
    const byte = raw[i];
    if (byte === 95) continue;
    if (byte < 48 || byte > 57) return null;
    if (digits.length > 0 || byte !== 48) digits.push(byte);
  }
  if (digits.length === 0) {
    // parseInt permits separators between digits, never a separator-only token.
    let hasDigit = false;
    for (let i = at; i < raw.length; i += 1) if (raw[i] === 48) hasDigit = true;
    return hasDigit ? asciiBytes("0") : null;
  }
  const out = new Uint8Array(digits.length);
  for (let i = 0; i < digits.length; i += 1) out[i] = digits[i];
  const bound = asciiBytes(negative ? "9223372036854775808" : "9223372036854775807");
  if (compareMagnitude(out, bound) > 0) return null;
  if (!negative) return out;
  const signed = new Uint8Array(out.length + 1); signed[0] = 45; signed.set(out, 1); return signed;
}
function addMagnitude(a: Uint8Array, b: Uint8Array): Uint8Array {
  const width = Math.max(a.length, b.length), out = new Uint8Array(width + 1);
  let carry = 0;
  for (let i = 0; i < width; i += 1) {
    const ai = a.length - 1 - i, bi = b.length - 1 - i;
    const sum = (ai >= 0 ? a[ai] - 48 : 0) + (bi >= 0 ? b[bi] - 48 : 0) + carry;
    out[width - i] = 48 + sum % 10; carry = intDiv(sum, 10);
  }
  out[0] = 48 + carry; return carry === 0 ? out.slice(1) : out;
}
function subtractMagnitude(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length); let borrow = 0;
  for (let i = 0; i < a.length; i += 1) {
    const bi = b.length - 1 - i;
    let digit = a[a.length - 1 - i] - 48 - (bi >= 0 ? b[bi] - 48 : 0) - borrow;
    borrow = digit < 0 ? 1 : 0; if (digit < 0) digit += 10;
    out[a.length - 1 - i] = digit + 48;
  }
  let first = 0; while (first + 1 < out.length && out[first] === 48) first += 1;
  return out.slice(first);
}
export function subtractStamp(a: Uint8Array, b: Uint8Array): Uint8Array {
  const an = a[0] === 45, bn = b[0] === 45;
  const am = magnitude(a), bm = magnitude(b), order = compareMagnitude(am, bm);
  const negative = an !== bn ? an : an ? order > 0 : order < 0;
  const value = an !== bn ? addMagnitude(am, bm) : order >= 0 ? subtractMagnitude(am, bm) : subtractMagnitude(bm, am);
  if (!negative || value.length === 1 && value[0] === 48) return value;
  const out = new Uint8Array(value.length + 1); out[0] = 45; out.set(value, 1); return out;
}
export function divideMagnitude(a: Uint8Array, divisor: number): Uint8Array {
  const out = new Uint8Array(a.length); let remainder = 0;
  for (let i = 0; i < a.length; i += 1) {
    const value = remainder * 10 + a[i] - 48;
    out[i] = intDiv(value, divisor) + 48; remainder = value % divisor;
  }
  let first = 0; while (first + 1 < out.length && out[first] === 48) first += 1;
  return out.slice(first);
}

function intDiv(value: number, divisor: number): number {
  let result = 0, rest = value;
  while (rest >= divisor) { rest -= divisor; result += 1; }
  return result;
}
