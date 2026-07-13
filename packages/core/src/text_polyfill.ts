// The node-side half of the byte-text method surface: install the everyday
// string methods on Uint8Array.prototype with EXACTLY the semantics rt.zig's
// text helpers give the native build — same generated case tables
// (text_tables.ts, the mirror of rt.zig's), same strict UTF-8 walk, same
// invalid-byte passthrough, same aliasing (trim returns views, an at-length
// pad returns the receiver). The devhost installs this before importing a
// core, and the run-fidelity suite proves node ≡ native over the whole
// surface.
//
// This is HARNESS code, not subset code: it runs under node only (the
// native build lowers the same method calls onto rt.zig directly).

import { SIMPLE_UPPER_RANGES, SIMPLE_LOWER_RANGES } from "./text_tables.ts";

/// Simple case mapping of one code point over the flat quadruple table
/// [lo, count, stride, delta] — binary search, unmapped maps to itself
/// (the mirror of rt.zig's caseMapLookup).
function caseMapLookup(ranges: readonly number[], cp: number): number {
  let lo = 0;
  let hi = ranges.length / 4;
  while (lo < hi) {
    const mid = lo + ((hi - lo) >> 1);
    const rLo = ranges[mid * 4];
    const count = ranges[mid * 4 + 1];
    const stride = ranges[mid * 4 + 2];
    const last = rLo + (count - 1) * stride;
    if (cp < rLo) {
      hi = mid;
    } else if (cp > last) {
      lo = mid + 1;
    } else {
      if ((cp - rLo) % stride === 0) return cp + ranges[mid * 4 + 3];
      return cp;
    }
  }
  return cp;
}

interface Utf8Step {
  readonly cp: number;
  readonly len: number;
  readonly valid: boolean;
}

const INVALID: Utf8Step = { cp: 0, len: 1, valid: false };

/// One strict UTF-8 decode step (RFC 3629 well-formed: no overlongs, no
/// surrogates, nothing above U+10FFFF) — the mirror of rt.zig's
/// utf8DecodeAt. Invalid means: pass bytes[i] through, advance one byte.
function utf8DecodeAt(bytes: Uint8Array, i: number): Utf8Step {
  const b0 = bytes[i];
  if (b0 < 0x80) return { cp: b0, len: 1, valid: true };
  if (b0 < 0xc2) return INVALID;
  if (b0 < 0xe0) {
    if (i + 1 >= bytes.length) return INVALID;
    const b1 = bytes[i + 1];
    if ((b1 & 0xc0) !== 0x80) return INVALID;
    return { cp: ((b0 & 0x1f) << 6) | (b1 & 0x3f), len: 2, valid: true };
  }
  if (b0 < 0xf0) {
    if (i + 2 >= bytes.length) return INVALID;
    const b1 = bytes[i + 1];
    const b2 = bytes[i + 2];
    if ((b1 & 0xc0) !== 0x80 || (b2 & 0xc0) !== 0x80) return INVALID;
    if (b0 === 0xe0 && b1 < 0xa0) return INVALID; // overlong
    if (b0 === 0xed && b1 > 0x9f) return INVALID; // surrogate
    return { cp: ((b0 & 0x0f) << 12) | ((b1 & 0x3f) << 6) | (b2 & 0x3f), len: 3, valid: true };
  }
  if (b0 < 0xf5) {
    if (i + 3 >= bytes.length) return INVALID;
    const b1 = bytes[i + 1];
    const b2 = bytes[i + 2];
    const b3 = bytes[i + 3];
    if ((b1 & 0xc0) !== 0x80 || (b2 & 0xc0) !== 0x80 || (b3 & 0xc0) !== 0x80) return INVALID;
    if (b0 === 0xf0 && b1 < 0x90) return INVALID; // overlong
    if (b0 === 0xf4 && b1 > 0x8f) return INVALID; // above U+10FFFF
    return {
      cp: ((b0 & 0x07) << 18) | ((b1 & 0x3f) << 12) | ((b2 & 0x3f) << 6) | (b3 & 0x3f),
      len: 4,
      valid: true,
    };
  }
  return INVALID;
}

/// Decode the well-formed sequence ENDING at `end` (exclusive) — the
/// backward walk for trimEnd (rt.zig's utf8DecodeBefore).
function utf8DecodeBefore(bytes: Uint8Array, end: number): Utf8Step {
  for (let back = 1; back <= 4 && back <= end; back++) {
    const b = bytes[end - back];
    if ((b & 0xc0) !== 0x80) {
      const step = utf8DecodeAt(bytes, end - back);
      if (step.valid && step.len === back) return step;
      return INVALID;
    }
  }
  return INVALID;
}

function utf8EncodedLen(cp: number): number {
  if (cp < 0x80) return 1;
  if (cp < 0x800) return 2;
  if (cp < 0x10000) return 3;
  return 4;
}

function utf8EncodeInto(out: Uint8Array, at: number, cp: number): number {
  if (cp < 0x80) {
    out[at] = cp;
    return 1;
  }
  if (cp < 0x800) {
    out[at] = 0xc0 | (cp >> 6);
    out[at + 1] = 0x80 | (cp & 0x3f);
    return 2;
  }
  if (cp < 0x10000) {
    out[at] = 0xe0 | (cp >> 12);
    out[at + 1] = 0x80 | ((cp >> 6) & 0x3f);
    out[at + 2] = 0x80 | (cp & 0x3f);
    return 3;
  }
  out[at] = 0xf0 | (cp >> 18);
  out[at + 1] = 0x80 | ((cp >> 12) & 0x3f);
  out[at + 2] = 0x80 | ((cp >> 6) & 0x3f);
  out[at + 3] = 0x80 | (cp & 0x3f);
  return 4;
}

/// The JS WhiteSpace + LineTerminator set (what String.prototype.trim
/// strips) — the mirror of rt.zig's isJsWhitespace.
function isJsWhitespace(cp: number): boolean {
  return (
    (cp >= 0x09 && cp <= 0x0d) ||
    cp === 0x20 ||
    cp === 0xa0 ||
    cp === 0x1680 ||
    (cp >= 0x2000 && cp <= 0x200a) ||
    cp === 0x2028 ||
    cp === 0x2029 ||
    cp === 0x202f ||
    cp === 0x205f ||
    cp === 0x3000 ||
    cp === 0xfeff
  );
}

function caseMap(bytes: Uint8Array, ranges: readonly number[]): Uint8Array {
  // Exact-size two-pass, like rt.zig's textCaseMap.
  let outLen = 0;
  for (let i = 0; i < bytes.length; ) {
    const step = utf8DecodeAt(bytes, i);
    if (!step.valid) {
      outLen += 1;
      i += 1;
      continue;
    }
    outLen += utf8EncodedLen(caseMapLookup(ranges, step.cp));
    i += step.len;
  }
  const out = new Uint8Array(outLen);
  let at = 0;
  for (let i = 0; i < bytes.length; ) {
    const step = utf8DecodeAt(bytes, i);
    if (!step.valid) {
      out[at] = bytes[i];
      at += 1;
      i += 1;
      continue;
    }
    at += utf8EncodeInto(out, at, caseMapLookup(ranges, step.cp));
    i += step.len;
  }
  return out;
}

function trimStartOf(bytes: Uint8Array): Uint8Array {
  let i = 0;
  while (i < bytes.length) {
    const step = utf8DecodeAt(bytes, i);
    if (!step.valid || !isJsWhitespace(step.cp)) break;
    i += step.len;
  }
  return bytes.subarray(i);
}

function trimEndOf(bytes: Uint8Array): Uint8Array {
  let end = bytes.length;
  while (end > 0) {
    const step = utf8DecodeBefore(bytes, end);
    if (!step.valid || !isJsWhitespace(step.cp)) break;
    end -= step.len;
  }
  return bytes.subarray(0, end);
}

function substringIndexOf(hay: Uint8Array, needle: Uint8Array): number {
  if (needle.length > hay.length) return -1;
  outer: for (let s = 0; s + needle.length <= hay.length; s++) {
    for (let i = 0; i < needle.length; i++) {
      if (hay[s + i] !== needle[i]) continue outer;
    }
    return s;
  }
  return -1;
}

function substringLastIndexOf(hay: Uint8Array, needle: Uint8Array): number {
  if (needle.length > hay.length) return -1;
  outer: for (let s = hay.length - needle.length; s >= 0; s--) {
    for (let i = 0; i < needle.length; i++) {
      if (hay[s + i] !== needle[i]) continue outer;
    }
    return s;
  }
  return -1;
}

function define(name: string, fn: (this: Uint8Array, ...args: never[]) => unknown): void {
  Object.defineProperty(Uint8Array.prototype, name, {
    value: fn,
    writable: true,
    configurable: true,
    enumerable: false,
  });
}

let installed = false;

/// Define the byte-text methods on Uint8Array.prototype. Idempotent; the
/// devhost (and the run-fidelity node driver) call it before importing a
/// core. `includes`/`indexOf`/`lastIndexOf` dispatch by argument type —
/// a bytes needle takes the substring search, a number keeps the
/// TypedArray element search node already ships.
export function installTextMethods(): void {
  if (installed) return;
  installed = true;

  const proto = Uint8Array.prototype as unknown as Record<string, (...args: unknown[]) => unknown>;
  const nativeIncludes = proto.includes;
  const nativeIndexOf = proto.indexOf;
  const nativeLastIndexOf = proto.lastIndexOf;

  define("toUpperCase", function (this: Uint8Array): Uint8Array {
    return caseMap(this, SIMPLE_UPPER_RANGES);
  });
  define("toLowerCase", function (this: Uint8Array): Uint8Array {
    return caseMap(this, SIMPLE_LOWER_RANGES);
  });
  define("repeat", function (this: Uint8Array, count: number): Uint8Array {
    const n = Math.trunc(count);
    // The exact String.prototype.repeat refusal (native panics here).
    if (n < 0 || n === Infinity) throw new RangeError(`Invalid count value: ${count}`);
    const times = Number.isNaN(n) ? 0 : n;
    const out = new Uint8Array(this.length * times);
    for (let k = 0; k < times; k++) out.set(this, k * this.length);
    return out;
  });
  define("startsWith", function (this: Uint8Array, needle: Uint8Array): boolean {
    if (needle.length > this.length) return false;
    for (let i = 0; i < needle.length; i++) if (this[i] !== needle[i]) return false;
    return true;
  });
  define("endsWith", function (this: Uint8Array, needle: Uint8Array): boolean {
    if (needle.length > this.length) return false;
    const base = this.length - needle.length;
    for (let i = 0; i < needle.length; i++) if (this[base + i] !== needle[i]) return false;
    return true;
  });
  define("includes", function (this: Uint8Array, needle: unknown, ...rest: unknown[]): boolean {
    if (needle instanceof Uint8Array) return substringIndexOf(this, needle) !== -1;
    return nativeIncludes.call(this, needle, ...rest) as boolean;
  });
  define("indexOf", function (this: Uint8Array, needle: unknown, ...rest: unknown[]): number {
    if (needle instanceof Uint8Array) return substringIndexOf(this, needle);
    return nativeIndexOf.call(this, needle, ...rest) as number;
  });
  define("lastIndexOf", function (this: Uint8Array, needle: unknown, ...rest: unknown[]): number {
    if (needle instanceof Uint8Array) return substringLastIndexOf(this, needle);
    return nativeLastIndexOf.call(this, needle, ...rest) as number;
  });
  define("padStart", function (this: Uint8Array, n: number, fill?: Uint8Array): Uint8Array {
    const fillBytes = fill ?? Uint8Array.of(0x20);
    if (n <= this.length || fillBytes.length === 0) return this;
    const out = new Uint8Array(n);
    const pad = n - this.length;
    for (let off = 0; off < pad; off += fillBytes.length) {
      out.set(fillBytes.subarray(0, Math.min(fillBytes.length, pad - off)), off);
    }
    out.set(this, pad);
    return out;
  });
  define("padEnd", function (this: Uint8Array, n: number, fill?: Uint8Array): Uint8Array {
    const fillBytes = fill ?? Uint8Array.of(0x20);
    if (n <= this.length || fillBytes.length === 0) return this;
    const out = new Uint8Array(n);
    out.set(this, 0);
    for (let off = this.length; off < n; off += fillBytes.length) {
      out.set(fillBytes.subarray(0, Math.min(fillBytes.length, n - off)), off);
    }
    return out;
  });
  define("trimStart", function (this: Uint8Array): Uint8Array {
    return trimStartOf(this);
  });
  define("trimEnd", function (this: Uint8Array): Uint8Array {
    return trimEndOf(this);
  });
  define("trim", function (this: Uint8Array): Uint8Array {
    return trimEndOf(trimStartOf(this));
  });
  define("split", function (this: Uint8Array, sep: Uint8Array): Uint8Array[] {
    if (sep.length === 0) return [this];
    const out: Uint8Array[] = [];
    let start = 0;
    for (let i = 0; i + sep.length <= this.length; ) {
      let hit = true;
      for (let k = 0; k < sep.length; k++) {
        if (this[i + k] !== sep[k]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        out.push(this.subarray(start, i));
        i += sep.length;
        start = i;
      } else {
        i += 1;
      }
    }
    out.push(this.subarray(start));
    return out;
  });
  // `.at` stays node's own TypedArray method — its byte semantics are
  // already exactly the surface's.
}
