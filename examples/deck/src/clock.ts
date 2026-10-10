// Exact little-endian u64 clocks. Decimal host values never pass through
// an imprecise number before subtraction, comparison or millisecond division.
import { asciiBytes } from "@native-sdk/core";

export function zero(): Uint8Array { return new Uint8Array(8); }
export function parse(text: Uint8Array): Uint8Array {
  const out = zero();
  if (text.length === 0) return out;
  for (const digit of text) {
    if (digit < 48 || digit > 57) return zero();
    let carry = digit - 48;
    for (let i = 0; i < 8; i++) {
      const value = (out[i] ?? 0) * 10 + carry;
      out[i] = value % 256;
      carry = Math.floor(value / 256);
    }
    if (carry !== 0) return zero();
  }
  return out;
}
export function isZero(value: Uint8Array): boolean {
  for (const byte of value) if (byte !== 0) return false;
  return true;
}
export function before(a: Uint8Array, b: Uint8Array): boolean {
  for (let i = 7; i >= 0; i--) {
    if ((a[i] ?? 0) < (b[i] ?? 0)) return true;
    if ((a[i] ?? 0) > (b[i] ?? 0)) return false;
  }
  return false;
}
export function subtract(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = zero();
  let borrow = 0;
  for (let i = 0; i < 8; i++) {
    const value = (a[i] ?? 0) - (b[i] ?? 0) - borrow;
    out[i] = value < 0 ? value + 256 : value;
    borrow = value < 0 ? 1 : 0;
  }
  return out;
}
interface ClockOverflow { readonly kind: "clock_overflow"; }
export function fourTimes(value: Uint8Array): Uint8Array {
  const out = zero();
  let carry = 0;
  for (let i = 0; i < 8; i++) {
    const word = (value[i] ?? 0) * 4 + carry;
    out[i] = word % 256;
    carry = Math.floor(word / 256);
  }
  if (carry !== 0) throw { kind: "clock_overflow" } as ClockOverflow;
  return out;
}
export function number(value: Uint8Array): number {
  const upper = (((value[7] ?? 0) * 256 + (value[6] ?? 0)) * 256 + (value[5] ?? 0)) * 256 + (value[4] ?? 0);
  const lower = (((value[3] ?? 0) * 256 + (value[2] ?? 0)) * 256 + (value[1] ?? 0)) * 256 + (value[0] ?? 0);
  return upper * 4294967296 + lower;
}
export function milliseconds(value: Uint8Array): number {
  const out = zero();
  let carry = 0;
  for (let i = 7; i >= 0; i--) {
    const word = carry * 256 + (value[i] ?? 0);
    out[i] = Math.floor(word / 1000000);
    carry = word % 1000000;
  }
  return number(out);
}
// Direct integer-to-f32 rounding, including ties to even. Converting a
// large u64 to f64 first can lose the bit that distinguishes a tie.
export function f32(value: Uint8Array): number {
  let top = -1;
  for (let bit = 63; bit >= 0; bit--) {
    if (((value[bit >>> 3] ?? 0) >>> (bit & 7)) & 1) { top = bit; break; }
  }
  if (top < 24) return Math.fround(number(value));
  const shift = top - 23;
  let significand = 0;
  let odd = false;
  for (let bit = top; bit >= shift; bit--) {
    const one = ((value[bit >>> 3] ?? 0) >>> (bit & 7)) & 1;
    significand = significand * 2 + one;
    odd = one !== 0;
  }
  const guard = ((value[(shift - 1) >>> 3] ?? 0) >>> ((shift - 1) & 7)) & 1;
  let sticky = false;
  for (let bit = shift - 2; bit >= 0; bit--) if (((value[bit >>> 3] ?? 0) >>> (bit & 7)) & 1) sticky = true;
  if (guard !== 0 && (sticky || odd)) significand = significand + 1;
  return Math.fround(Math.fround(significand) * (2 ** Math.fround(shift)));
}
export function decimal(value: Uint8Array): Uint8Array {
  if (isZero(value)) return asciiBytes("0");
  const words = value.slice(), reverse: number[] = [];
  let more = true;
  while (more) {
    let carry = 0;
    more = false;
    for (let i = 7; i >= 0; i--) {
      const word = carry * 256 + (words[i] ?? 0);
      words[i] = Math.floor(word / 10);
      carry = word % 10;
      if (words[i] !== 0) more = true;
    }
    reverse.push(48 + carry);
  }
  reverse.reverse();
  return new Uint8Array(reverse);
}
