// Byte-text construction shared by core imports and the focused bytes module.

/// The ASCII text intrinsic: turn a string literal or template whose code
/// units are all 0x00..0x7f into bytes. The transpiler recognizes calls BY
/// IDENTITY (this import, renames honored) and folds them at compile time —
/// a literal argument becomes rodata, a template becomes frame-arena bytes
/// via bufPrint — so no string ever exists at native runtime. Under node
/// this body runs as-is, byte for byte the same result. Use `utf8Bytes` for
/// user-visible text that may contain Unicode. Arguments must be literals
/// or templates; dynamic text lives in the model as Uint8Array from the
/// start.
export function asciiBytes(s: string): Uint8Array {
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) > 0x7f) {
      throw new RangeError("asciiBytes accepts ASCII only; use utf8Bytes for Unicode text");
    }
  }
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/// The UTF-8 text intrinsic. Like `asciiBytes`, literals become rodata and
/// templates become frame-arena bytes in a native core; under node this
/// implementation performs the same encoding directly. Invalid lone UTF-16
/// surrogates encode as U+FFFD, matching the platform TextEncoder contract.
export function utf8Bytes(s: string): Uint8Array {
  let byteLength = 0;
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code <= 0x7f) {
      byteLength += 1;
    } else if (code <= 0x7ff) {
      byteLength += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        byteLength += 4;
        i += 1;
      } else {
        byteLength += 3;
      }
    } else {
      byteLength += 3;
    }
  }

  const out = new Uint8Array(byteLength);
  let at = 0;
  for (let i = 0; i < s.length; i++) {
    let code = s.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i += 1;
      } else {
        code = 0xfffd;
      }
    } else if (code >= 0xd800 && code <= 0xdfff) {
      code = 0xfffd;
    }

    if (code <= 0x7f) {
      out[at] = code;
      at += 1;
    } else if (code <= 0x7ff) {
      out[at] = 0xc0 | (code >> 6);
      out[at + 1] = 0x80 | (code & 0x3f);
      at += 2;
    } else if (code <= 0xffff) {
      out[at] = 0xe0 | (code >> 12);
      out[at + 1] = 0x80 | ((code >> 6) & 0x3f);
      out[at + 2] = 0x80 | (code & 0x3f);
      at += 3;
    } else {
      out[at] = 0xf0 | (code >> 18);
      out[at + 1] = 0x80 | ((code >> 12) & 0x3f);
      out[at + 2] = 0x80 | ((code >> 6) & 0x3f);
      out[at + 3] = 0x80 | (code & 0x3f);
      at += 4;
    }
  }
  return out;
}

