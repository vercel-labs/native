// The byte-text method surface on core text — ambient declaration merging
// into lib.esnext's generic Uint8Array. These methods are part of the
// app-core subset's type environment (the transpiler adds this file to
// every core's program) and of the editor surface the scaffold ships; at
// runtime they exist natively in the emitted core (rt.zig's text helpers)
// and under node through the devhost polyfill (src/text_polyfill.ts) —
// both built from the same generated Unicode tables.
//
// Byte-honest semantics, the one contract worth memorizing: every length,
// offset, and index below is a BYTE length/offset, search is byte-wise,
// and case mapping is Unicode SIMPLE case mapping (code point -> code
// point, locale-free, no special casing — ß stays ß). Invalid UTF-8
// passes through case mapping unchanged, byte by byte.
//
// The `never`-returning tail is the STAYS-OUT set: declared here only so
// the subset checker can teach each spelling with its reason (UTF-16 code
// units, ambient locale state, regex engines) instead of tsc's bare
// "property does not exist".

interface Uint8Array<TArrayBuffer extends ArrayBufferLike = ArrayBufferLike> {
  /// Unicode simple-case uppercase over UTF-8 (locale-free; invalid bytes
  /// pass through). Fresh bytes.
  toUpperCase(): Uint8Array;
  /// Unicode simple-case lowercase over UTF-8 (locale-free; invalid bytes
  /// pass through). Fresh bytes.
  toLowerCase(): Uint8Array;
  /// The receiver repeated `count` times (`repeat(0)` is empty). A negative
  /// count is JS's RangeError — guard first; native panics there.
  repeat(count: number): Uint8Array;
  /// Byte-wise prefix test; the empty needle is always true.
  startsWith(searchBytes: Uint8Array): boolean;
  /// Byte-wise suffix test; the empty needle is always true.
  endsWith(searchBytes: Uint8Array): boolean;
  /// Byte-substring containment (a BYTES needle). A NUMBER argument keeps
  /// TypedArray element search — one byte value, SameValueZero.
  includes(searchBytes: Uint8Array): boolean;
  /// First byte offset of the byte substring, -1 when absent (empty needle
  /// matches at 0). A NUMBER argument searches one byte value.
  indexOf(searchBytes: Uint8Array): number;
  /// Last byte offset of the byte substring, -1 when absent (empty needle
  /// matches at byte length). A NUMBER argument searches one byte value.
  lastIndexOf(searchBytes: Uint8Array): number;
  /// Pad on the left to `targetByteLength` BYTES (not characters) with
  /// `fillBytes` (default " "), the last repetition truncated; at-or-under
  /// target returns the receiver.
  padStart(targetByteLength: number, fillBytes?: Uint8Array): Uint8Array;
  /// Pad on the right to `targetByteLength` BYTES — see padStart.
  padEnd(targetByteLength: number, fillBytes?: Uint8Array): Uint8Array;
  /// Strip the JS whitespace set (decoded over UTF-8) from both ends — a
  /// view, no copy.
  trim(): Uint8Array;
  /// Strip leading JS whitespace — a view.
  trimStart(): Uint8Array;
  /// Strip trailing JS whitespace — a view.
  trimEnd(): Uint8Array;
  /// Split on a BYTES separator, String.split shapes exactly (adjacent /
  /// leading / trailing separators produce empty elements; no match is
  /// [whole]). Elements are views; the array is locally owned. An empty
  /// separator literal is a taught stop (per-code-point splitting would
  /// expose the encoding seam).
  split(separator: Uint8Array): Uint8Array[];

  // ------------------------------------------------------ stays out (taught)
  /// STAYS OUT: reads UTF-16 code units (NS1060 teaches the byte read).
  charCodeAt(index: number): never;
  /// STAYS OUT: reads UTF-16 code units (NS1060 teaches the byte read).
  charAt(index: number): never;
  /// STAYS OUT: a code-point index walk over the UTF-16 seam (NS1060).
  codePointAt(index: number): never;
  /// STAYS OUT: Unicode normalization tables are a host-edge concern (NS1060).
  normalize(form?: string): never;
  /// STAYS OUT: locale-dependent collation is ambient state (NS1005).
  localeCompare(other: Uint8Array): never;
  /// STAYS OUT: locale-dependent casing is ambient state (NS1005).
  toLocaleUpperCase(locales?: string): never;
  /// STAYS OUT: locale-dependent casing is ambient state (NS1005).
  toLocaleLowerCase(locales?: string): never;
  /// STAYS OUT: takes a regular expression (NS1040).
  match(pattern: unknown): never;
  /// STAYS OUT: takes a regular expression (NS1040).
  matchAll(pattern: unknown): never;
  /// STAYS OUT: takes a regular expression (NS1040).
  search(pattern: unknown): never;
  /// STAYS OUT in v1: rebuild with split/indexOf and a push-builder (NS1060).
  replace(pattern: unknown, replacement: unknown): never;
  /// STAYS OUT in v1: rebuild with split/indexOf and a push-builder (NS1060).
  replaceAll(pattern: unknown, replacement: unknown): never;
}
