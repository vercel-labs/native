import type { ExactCounter } from "./types.ts";

export function zeroCounter(): ExactCounter { return { counter_lower: 0, counter_upper: 0 }; }
export function initialFileKey(index: number): ExactCounter {
  return { counter_lower: (100 + index * 1000000) >>> 0, counter_upper: 0 };
}
export function counterEqual(a: ExactCounter, b: ExactCounter): boolean {
  return a.counter_lower === b.counter_lower && a.counter_upper === b.counter_upper;
}
export function counterZero(value: ExactCounter): boolean {
  return value.counter_lower === 0 && value.counter_upper === 0;
}
export function incrementCounter(value: ExactCounter): ExactCounter {
  return value.counter_lower === 4294967295
    ? { counter_lower: 0, counter_upper: (value.counter_upper + 1) >>> 0 }
    : { counter_lower: (value.counter_lower + 1) >>> 0, counter_upper: value.counter_upper };
}
export function incrementFileKey(value: ExactCounter): ExactCounter {
  const next = incrementCounter(value);
  return counterZero(next) ? initialFileKey(0) : next;
}
/** Exact decimal bytes, including the native full-u64 wrap boundary. */
export function counterBytes(value: ExactCounter): Uint8Array {
  const limbs = [value.counter_lower & 65535, value.counter_lower >>> 16,
    value.counter_upper & 65535, value.counter_upper >>> 16];
  const digits: number[] = [];
  do {
    let remainder = 0;
    for (let i = 3; i >= 0; i -= 1) {
      const whole = remainder * 65536 + limbs[i]!;
      limbs[i] = Math.floor(whole / 10);
      remainder = whole % 10;
    }
    digits.push(remainder + 48);
  } while (limbs[0] !== 0 || limbs[1] !== 0 || limbs[2] !== 0 || limbs[3] !== 0);
  const result = new Uint8Array(digits.length);
  for (let i = 0; i < digits.length; i += 1) result[i] = digits[digits.length - i - 1]!;
  return result;
}
