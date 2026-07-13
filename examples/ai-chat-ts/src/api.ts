// ai-chat-ts api module: the OpenAI-compatible chat-completions wire
// format in pure subset TypeScript over bytes — request encoding on the
// way out, response parsing on the way back. No JSON runtime exists in a
// core (the binary carries no JS engine), and none is needed: the request
// is a byte concatenation with one escape routine, and the response walk
// reads exactly the two fields the app uses (`choices[0].message.content`
// on success, `error.message` on failure) and refuses everything
// malformed with `null` — a body that does not parse is a failed request,
// never a half-parsed conversation.
//
// Everything here is deterministic byte math, which is what makes the
// announcement trick work: the exact request bytes are pinned in the e2e
// suite, and a recorded conversation replays byte-identically with no
// network in the room.

import { asciiBytes } from "@native-sdk/core";

export type Bytes = Uint8Array;

export type Role = "user" | "assistant";

/// One conversation turn. Kept in the Model, so history is ordinary
/// committed state — record→replay carries the whole conversation.
export interface Turn {
  readonly id: number;
  readonly role: Role;
  readonly text: Bytes;
}

/// How deep a response's nesting may go before the scanner refuses it —
/// a bound on recursion, not on honest responses (a chat-completions
/// body nests four levels).
const MAX_JSON_DEPTH = 64;

// ------------------------------------------------------------- request

/// The chat-completions request body:
/// `{"model":…,"messages":[{"role":"system","content":…},…]}` with the
/// system prompt first and every conversation turn after it, in order.
/// The caller supplies the model name from the launch environment; the
/// turns are the Model's history including the just-appended user turn.
/// Helpers RETURN their bytes and this one builder assembles them in a
/// single literal — a parts buffer handed around between appends would
/// end its ownership at the first hand-off (a passed array escapes), so
/// each turn arrives pre-concatenated from `encodeTurn` instead.
export function encodeChatRequest(modelName: Bytes, systemPrompt: Bytes, turns: readonly Turn[]): Bytes {
  return concatAll([
    asciiBytes('{"model":'),
    jsonString(modelName),
    asciiBytes(',"messages":[{"role":"system","content":'),
    jsonString(systemPrompt),
    asciiBytes("}"),
    ...turns.map((turn) => encodeTurn(turn)),
    asciiBytes("]}"),
  ]);
}

/// One conversation turn as its complete message-object bytes:
/// `,{"role":…,"content":…}` — comma included, since every turn follows
/// the system message.
function encodeTurn(turn: Turn): Bytes {
  const open =
    turn.role === "user"
      ? asciiBytes(',{"role":"user","content":')
      : asciiBytes(',{"role":"assistant","content":');
  return concatAll([open, jsonString(turn.text), asciiBytes("}")]);
}

/// A JSON string literal (quotes included) from UTF-8 text bytes. Two
/// passes over one classification: measure, then fill — the fill writes
/// only the array this function just created (a buffer passed to a
/// helper would have escaped and become immutable), so every escape is
/// written inline. Non-ASCII UTF-8 bytes pass through raw (valid JSON).
export function jsonString(text: Bytes): Bytes {
  let len = 2;
  for (const b of text) {
    if (b === 0x22 || b === 0x5c || b === 0x08 || b === 0x09 || b === 0x0a || b === 0x0c || b === 0x0d) {
      len += 2;
    } else if (b < 0x20) {
      len += 6; // \u00XX
    } else {
      len += 1;
    }
  }
  const out = new Uint8Array(len);
  out[0] = 0x22;
  let at = 1;
  for (const b of text) {
    if (b === 0x22 || b === 0x5c) {
      out[at] = 0x5c;
      out[at + 1] = b;
      at += 2;
    } else if (b === 0x08 || b === 0x09 || b === 0x0a || b === 0x0c || b === 0x0d) {
      out[at] = 0x5c;
      out[at + 1] = escapeLetter(b);
      at += 2;
    } else if (b < 0x20) {
      out[at] = 0x5c;
      out[at + 1] = 0x75;
      out[at + 2] = 0x30;
      out[at + 3] = 0x30;
      out[at + 4] = hexDigit((b >> 4) & 0xf);
      out[at + 5] = hexDigit(b & 0xf);
      at += 6;
    } else {
      out[at] = b;
      at += 1;
    }
  }
  out[at] = 0x22;
  return out;
}

/// The letter of a two-byte JSON escape: \b \t \n \f \r.
function escapeLetter(b: number): number {
  if (b === 0x08) return 0x62;
  if (b === 0x09) return 0x74;
  if (b === 0x0a) return 0x6e;
  if (b === 0x0c) return 0x66;
  return 0x72;
}

function hexDigit(value: number): number {
  return value < 10 ? 0x30 + value : 0x57 + value; // 0-9, a-f
}

export function concatAll(parts: readonly Uint8Array[]): Bytes {
  let total = 0;
  for (const part of parts) total += part.length;
  const out = new Uint8Array(total);
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/// The `Authorization` header's value: `Bearer <key>`, built at runtime
/// from the launch-supplied key. Header VALUES may be runtime bytes
/// (`Cmd.fetch` header names stay compile-time), so the token rides the
/// standard header every hosted provider expects — never the URL, never
/// a server access log.
export function bearerToken(apiKey: Bytes): Bytes {
  return concatAll([asciiBytes("Bearer "), apiKey]);
}

// ------------------------------------------------------------ response

/// `choices[0].message.content` from a chat-completions success body, or
/// null when the body is not that shape (malformed JSON, empty choices,
/// a non-string content) — the caller turns null into the failed state.
export function parseChatContent(body: Bytes): Bytes | null {
  let at = skipWs(body, 0);
  if (at >= body.length || body[at] !== 0x7b) return null; // {
  const choicesAt = memberValue(body, at, asciiBytes("choices"));
  if (choicesAt === -1) return null;
  let cursor = skipWs(body, choicesAt);
  if (cursor >= body.length || body[cursor] !== 0x5b) return null; // [
  cursor = skipWs(body, cursor + 1);
  if (cursor >= body.length || body[cursor] === 0x5d) return null; // empty choices
  if (body[cursor] !== 0x7b) return null;
  const messageAt = memberValue(body, cursor, asciiBytes("message"));
  if (messageAt === -1) return null;
  cursor = skipWs(body, messageAt);
  if (cursor >= body.length || body[cursor] !== 0x7b) return null;
  const contentAt = memberValue(body, cursor, asciiBytes("content"));
  if (contentAt === -1) return null;
  cursor = skipWs(body, contentAt);
  if (cursor >= body.length || body[cursor] !== 0x22) return null; // a string
  return decodeJsonString(body, cursor);
}

/// `error.message` from a chat-completions error body, or null when the
/// body carries no such field (the caller falls back to the HTTP status).
export function parseErrorMessage(body: Bytes): Bytes | null {
  let at = skipWs(body, 0);
  if (at >= body.length || body[at] !== 0x7b) return null;
  const errorAt = memberValue(body, at, asciiBytes("error"));
  if (errorAt === -1) return null;
  let cursor = skipWs(body, errorAt);
  if (cursor >= body.length || body[cursor] !== 0x7b) return null;
  const messageAt = memberValue(body, cursor, asciiBytes("message"));
  if (messageAt === -1) return null;
  cursor = skipWs(body, messageAt);
  if (cursor >= body.length || body[cursor] !== 0x22) return null;
  return decodeJsonString(body, cursor);
}

function skipWs(b: Bytes, at: number): number {
  let i = at;
  while (i < b.length && (b[i] === 0x20 || b[i] === 0x09 || b[i] === 0x0a || b[i] === 0x0d)) i += 1;
  return i;
}

/// With `at` on an object's `{`, the index of the named member's value —
/// or -1 when the key is absent or the object is malformed. Keys in the
/// chat wire format are plain ASCII identifiers, so key comparison is
/// raw-byte (a key that needed escapes simply never matches).
function memberValue(b: Bytes, at: number, key: Bytes): number {
  let i = skipWs(b, at + 1);
  if (i < b.length && b[i] === 0x7d) return -1; // empty object
  for (let guard = 0; guard < 4096; guard++) {
    if (i >= b.length || b[i] !== 0x22) return -1;
    const keyStart = i + 1;
    const keyEnd = rawStringEnd(b, i);
    if (keyEnd === -1) return -1;
    i = skipWs(b, keyEnd + 1);
    if (i >= b.length || b[i] !== 0x3a) return -1; // :
    i = skipWs(b, i + 1);
    if (bytesEqualRange(b, keyStart, keyEnd, key)) return i;
    i = skipValue(b, i, 0);
    if (i === -1) return -1;
    i = skipWs(b, i);
    if (i >= b.length) return -1;
    if (b[i] === 0x7d) return -1; // } — key not present
    if (b[i] !== 0x2c) return -1; // ,
    i = skipWs(b, i + 1);
  }
  return -1;
}

function bytesEqualRange(b: Bytes, start: number, end: number, key: Bytes): boolean {
  if (end - start !== key.length) return false;
  for (let i = 0; i < key.length; i++) {
    if (b[start + i] !== key[i]) return false;
  }
  return true;
}

/// The index of a string's closing quote (escape-aware, undecoded), with
/// `at` on the opening quote — or -1 when the string never closes.
function rawStringEnd(b: Bytes, at: number): number {
  let i = at + 1;
  while (i < b.length) {
    if (b[i] === 0x5c) {
      i += 2;
    } else if (b[i] === 0x22) {
      return i;
    } else {
      i += 1;
    }
  }
  return -1;
}

/// The index just past any JSON value at `at` — or -1 on malformed input
/// (including nesting past MAX_JSON_DEPTH: a recursion bound, so a
/// hostile body cannot walk the stack off a cliff).
function skipValue(b: Bytes, at: number, depth: number): number {
  if (depth > MAX_JSON_DEPTH) return -1;
  if (at >= b.length) return -1;
  const c = b[at];
  if (c === 0x22) {
    const end = rawStringEnd(b, at);
    return end === -1 ? -1 : end + 1;
  }
  if (c === 0x7b || c === 0x5b) {
    const close = c === 0x7b ? 0x7d : 0x5d;
    let i = skipWs(b, at + 1);
    if (i < b.length && b[i] === close) return i + 1;
    for (let guard = 0; guard < 65536; guard++) {
      if (c === 0x7b) {
        if (i >= b.length || b[i] !== 0x22) return -1;
        const keyEnd = rawStringEnd(b, i);
        if (keyEnd === -1) return -1;
        i = skipWs(b, keyEnd + 1);
        if (i >= b.length || b[i] !== 0x3a) return -1;
        i = skipWs(b, i + 1);
      }
      i = skipValue(b, i, depth + 1);
      if (i === -1) return -1;
      i = skipWs(b, i);
      if (i >= b.length) return -1;
      if (b[i] === close) return i + 1;
      if (b[i] !== 0x2c) return -1;
      i = skipWs(b, i + 1);
    }
    return -1;
  }
  if (c === 0x74) return literalEnd(b, at, asciiBytes("true"));
  if (c === 0x66) return literalEnd(b, at, asciiBytes("false"));
  if (c === 0x6e) return literalEnd(b, at, asciiBytes("null"));
  // A number: sign, digits, dot, exponent — consume the token greedily
  // (structural validity is all the walk needs).
  if (c === 0x2d || (c >= 0x30 && c <= 0x39)) {
    let i = at + 1;
    while (i < b.length) {
      const d = b[i];
      const numeric =
        (d >= 0x30 && d <= 0x39) || d === 0x2e || d === 0x65 || d === 0x45 || d === 0x2b || d === 0x2d;
      if (!numeric) break;
      i += 1;
    }
    return i;
  }
  return -1;
}

function literalEnd(b: Bytes, at: number, literal: Bytes): number {
  if (at + literal.length > b.length) return -1;
  if (!bytesEqualRange(b, at, at + literal.length, literal)) return -1;
  return at + literal.length;
}

// ----------------------------------------------------- string decoding

/// One decoded step of a JSON string body at `i`: a raw byte copies
/// through as itself (UTF-8 passes raw), an escape resolves to a code
/// point (`\uXXXX` surrogate pairs combined; a lone surrogate becomes
/// U+FFFD). `point` is -1 for a raw byte (copy `raw` through), and null
/// means the escape is malformed.
interface DecodeStep {
  readonly next: number;
  /// The code point an escape resolved to; -1 when the step is a raw
  /// byte copy.
  readonly point: number;
  /// The raw byte to copy when `point` is -1.
  readonly raw: number;
}

function decodeStep(b: Bytes, i: number): DecodeStep | null {
  if (b[i] !== 0x5c) return { next: i + 1, point: -1, raw: b[i] };
  if (i + 1 >= b.length) return null;
  const e = b[i + 1];
  if (e === 0x22) return { next: i + 2, point: 0x22, raw: 0 };
  if (e === 0x5c) return { next: i + 2, point: 0x5c, raw: 0 };
  if (e === 0x2f) return { next: i + 2, point: 0x2f, raw: 0 };
  if (e === 0x62) return { next: i + 2, point: 0x08, raw: 0 };
  if (e === 0x66) return { next: i + 2, point: 0x0c, raw: 0 };
  if (e === 0x6e) return { next: i + 2, point: 0x0a, raw: 0 };
  if (e === 0x72) return { next: i + 2, point: 0x0d, raw: 0 };
  if (e === 0x74) return { next: i + 2, point: 0x09, raw: 0 };
  if (e !== 0x75) return null;
  const high = hexQuad(b, i + 2);
  if (high === -1) return null;
  if (high >= 0xd800 && high <= 0xdbff) {
    if (i + 11 < b.length && b[i + 6] === 0x5c && b[i + 7] === 0x75) {
      const low = hexQuad(b, i + 8);
      if (low >= 0xdc00 && low <= 0xdfff) {
        return { next: i + 12, point: 0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00), raw: 0 };
      }
    }
    return { next: i + 6, point: 0xfffd, raw: 0 }; // lone high surrogate
  }
  if (high >= 0xdc00 && high <= 0xdfff) return { next: i + 6, point: 0xfffd, raw: 0 }; // lone low surrogate
  return { next: i + 6, point: high, raw: 0 };
}

function utf8Length(point: number): number {
  if (point < 0x80) return 1;
  if (point < 0x800) return 2;
  if (point < 0x10000) return 3;
  return 4;
}

/// The decoded UTF-8 bytes of a JSON string with `at` on its opening
/// quote — or null when the string is malformed. Measure-then-fill over
/// decodeStep; the fill writes only the array this function created.
function decodeJsonString(b: Bytes, at: number): Bytes | null {
  let i = at + 1;
  let len = 0;
  let closed = false;
  while (i < b.length) {
    if (b[i] === 0x22) {
      closed = true;
      break;
    }
    const step = decodeStep(b, i);
    if (step === null) return null;
    len += step.point === -1 ? 1 : utf8Length(step.point);
    i = step.next;
  }
  if (!closed) return null;
  const out = new Uint8Array(len);
  i = at + 1;
  let w = 0;
  while (i < b.length && b[i] !== 0x22) {
    const step = decodeStep(b, i);
    if (step === null) return null;
    if (step.point === -1) {
      out[w] = step.raw;
      w += 1;
    } else if (step.point < 0x80) {
      out[w] = step.point;
      w += 1;
    } else if (step.point < 0x800) {
      out[w] = 0xc0 | (step.point >> 6);
      out[w + 1] = 0x80 | (step.point & 0x3f);
      w += 2;
    } else if (step.point < 0x10000) {
      out[w] = 0xe0 | (step.point >> 12);
      out[w + 1] = 0x80 | ((step.point >> 6) & 0x3f);
      out[w + 2] = 0x80 | (step.point & 0x3f);
      w += 3;
    } else {
      out[w] = 0xf0 | (step.point >> 18);
      out[w + 1] = 0x80 | ((step.point >> 12) & 0x3f);
      out[w + 2] = 0x80 | ((step.point >> 6) & 0x3f);
      out[w + 3] = 0x80 | (step.point & 0x3f);
      w += 4;
    }
    i = step.next;
  }
  return out;
}

/// Four hex digits at `at` as a number, or -1 when any is not hex.
function hexQuad(b: Bytes, at: number): number {
  let value = 0;
  for (let i = 0; i < 4; i++) {
    if (at + i >= b.length) return -1;
    const d = hexValue(b[at + i]);
    if (d === -1) return -1;
    value = value * 16 + d;
  }
  return value;
}

function hexValue(c: number): number {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x57;
  if (c >= 0x41 && c <= 0x46) return c - 0x37;
  return -1;
}
