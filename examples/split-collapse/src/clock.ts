import { asciiBytes } from "@native-sdk/core";

export function zeroClock(): Uint8Array { return new Uint8Array(8); }

// std.fmt.parseInt(u64, bytes, 10) semantics: optional sign, interior
// underscores, checked accumulation, and negative zero only.
export function parseClock(text: Uint8Array): Uint8Array {
  const out = new Uint8Array(8);
  if (text.length === 0) return out;
  const signed = text[0] === 43 || text[0] === 45;
  const first = signed ? 1 : 0;
  if (first === text.length || text[first] === 95 || text[text.length - 1] === 95) return out;
  for (let i = first; i < text.length; i++) {
    const digit = text[i];
    if (digit === 95) continue;
    if (digit === undefined || digit < 48 || digit > 57) return zeroClock();
    let carry = digit - 48;
    for (let j = 0; j < 8; j++) {
      const value = (out[j] ?? 0) * 10 + carry;
      out[j] = value % 256;
      carry = Math.floor(value / 256);
    }
    if (carry !== 0) return zeroClock();
  }
  if (text[0] === 45 && !clockZero(out)) return zeroClock();
  return out;
}

export function clockZero(clock: Uint8Array): boolean {
  for (const byte of clock) if (byte !== 0) return false;
  return true;
}

export function clockNumber(clock: Uint8Array): number {
  // Both words and the power-of-two scaling are exact. Round once at
  // the final sum, matching the native u64-to-f64 conversion.
  const upper = (((clock[7] ?? 0) * 256 + (clock[6] ?? 0)) * 256 + (clock[5] ?? 0)) * 256 + (clock[4] ?? 0);
  const lower = (((clock[3] ?? 0) * 256 + (clock[2] ?? 0)) * 256 + (clock[1] ?? 0)) * 256 + (clock[0] ?? 0);
  return upper * 4294967296 + lower;
}

export function clockBefore(a: Uint8Array, b: Uint8Array): boolean {
  for (let i = 7; i >= 0; i--) {
    if ((a[i] ?? 0) < (b[i] ?? 0)) return true;
    if ((a[i] ?? 0) > (b[i] ?? 0)) return false;
  }
  return false;
}

export function clockSubtract(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(8);
  if (clockBefore(a, b)) return out;
  let borrow = 0;
  for (let i = 0; i < 8; i++) {
    const value = (a[i] ?? 0) - (b[i] ?? 0) - borrow;
    out[i] = value < 0 ? value + 256 : value;
    borrow = value < 0 ? 1 : 0;
  }
  return out;
}

export function clockDecimal(clock: Uint8Array): Uint8Array {
  if (clockZero(clock)) return asciiBytes("0");
  const words = clock.slice(), reverse: number[] = [];
  let more = true;
  while (more) {
    let carry = 0;
    more = false;
    for (let i = 7; i >= 0; i--) {
      const value = carry * 256 + (words[i] ?? 0);
      words[i] = Math.floor(value / 10);
      carry = value % 10;
      if (words[i] !== 0) more = true;
    }
    reverse.push(48 + carry);
  }
  reverse.reverse();
  return new Uint8Array(reverse);
}
