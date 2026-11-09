// Portable Markdown presentation. Sources and payloads remain raw bytes;
// native owns the copied recipe, typed routes, registered images and drawing.
interface NscMdLink { text: Uint8Array; target: Uint8Array; consumed: number }
interface NscMdTag { name: Uint8Array; attributes: Uint8Array; closing: boolean; selfClosing: boolean; consumed: number; kind: number; level: number }
interface NscMdSlot { valid: boolean; from: number; pos: number }
function nscMdSlot(): NscMdSlot { return { valid: false, from: 0, pos: -1 }; }
class NscMdCache {
  bracket = nscMdSlot(); paren = nscMdSlot(); angle = nscMdSlot(); space = nscMdSlot(); title = nscMdSlot(); scheme = nscMdSlot(); comment = nscMdSlot(); tick = nscMdSlot();
}
function nscMdBytes(s: string): Uint8Array {
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


function nscMdEqual(a: Uint8Array, b: Uint8Array, insensitive: boolean): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) { let x = a[i]!, y = b[i]!; if (insensitive) { if (x >= 65 && x <= 90) x += 32; if (y >= 65 && y <= 90) y += 32; } if (x !== y) return false; }
  return true;
}
function nscMdStarts(a: Uint8Array, at: number, text: string, insensitive: boolean): boolean {
  if (at + text.length > a.length) return false;
  for (let i = 0; i < text.length; i++) { let x = a[at + i]!, y = text.charCodeAt(i); if (insensitive) { if (x >= 65 && x <= 90) x += 32; if (y >= 65 && y <= 90) y += 32; } if (x !== y) return false; } return true;
}
function nscMdFind(a: Uint8Array, at: number, text: string, insensitive: boolean): number {
  for (let i = at; i + text.length <= a.length; i++) if (nscMdStarts(a, i, text, insensitive)) return i; return -1;
}
function nscMdFindByte(a: Uint8Array, at: number, byte: number): number { for (let i = at; i < a.length; i++) if (a[i] === byte) return i; return -1; }
function nscMdScan(slot: NscMdSlot, text: Uint8Array, from: number, pattern: string): number {
  if (slot.valid && from >= slot.from && (slot.pos < 0 || from <= slot.pos)) return slot.pos;
  slot.valid = true; slot.from = from; slot.pos = nscMdFind(text, from, pattern, false); return slot.pos;
}
function nscMdAlpha(b: number): boolean { return b >= 65 && b <= 90 || b >= 97 && b <= 122; }
function nscMdDigit(b: number): boolean { return b >= 48 && b <= 57; }
function nscMdWord(b: number): boolean { return nscMdAlpha(b) || nscMdDigit(b) || b === 95; }
function nscMdSpace(b: number): boolean { return b === 32 || b === 9; }
function nscMdWhite(b: number): boolean { return b === 32 || b >= 9 && b <= 13; }
function nscMdPunctuation(b: number): boolean { return b >= 33 && b <= 47 || b >= 58 && b <= 64 || b >= 91 && b <= 96 || b >= 123 && b <= 126; }
function nscMdTrim(a: Uint8Array, chars: string, left: boolean, right: boolean): Uint8Array {
  let start = 0, end = a.length;
  if (left) while (start < end && chars.indexOf(String.fromCharCode(a[start]!)) >= 0) start++;
  if (right) while (end > start && chars.indexOf(String.fromCharCode(a[end - 1]!)) >= 0) end--;
  return a.subarray(start, end);
}
function nscMdConcat(a: Uint8Array, b: Uint8Array): Uint8Array { const out = new Uint8Array(a.length + b.length); out.set(a); out.set(b, a.length); return out; }
class NscMdLines {
  source: Uint8Array; index = 0; pending: Uint8Array | null = null;
  constructor(source: Uint8Array) { this.source = source; }
  copy(): NscMdLines { const out = new NscMdLines(this.source); out.index = this.index; out.pending = this.pending; return out; }
  restore(other: NscMdLines): void { this.index = other.index; this.pending = other.pending; }
  next(): Uint8Array | null {
    if (this.pending !== null) { const line = this.pending; this.pending = null; return line; }
    if (this.index >= this.source.length) return null;
    const start = this.index, found = nscMdFindByte(this.source, start, 10), end = found < 0 ? this.source.length : found;
    this.index = Math.min(end + 1, this.source.length); return nscMdTrim(this.source.subarray(start, end), "\r", false, true);
  }
  prepend(line: Uint8Array): void { if (this.pending !== null) throw new Error("occupied Markdown line slot"); this.pending = line; }
  peek(): Uint8Array | null { return this.copy().next(); }
  second(): Uint8Array | null { const copy = this.copy(); if (copy.next() === null) return null; return copy.next(); }
}
// Tag kind numbers are recipe-local and deliberately independent of native enums.
function nscMdClassify(name: Uint8Array): number {
  const names = ["b strong", "i em var cite", "s strike del", "u ins", "code kbd samp tt", "mark", "small sub sup", "a", "img", "br", "wbr", "q", "", "hr", "p", "blockquote", "pre", "ol ul dl", "li dt dd", "table", "thead tbody tfoot", "tr", "td th", "abbr bdo caption center div span section article header footer main figure figcaption time ruby rt rp"];
  if (name.length === 2 && (name[0] === 104 || name[0] === 72) && name[1]! >= 49 && name[1]! <= 54) return 12;
  for (let kind = 0; kind < names.length; kind++) {
    const list = names[kind]!, words = list.split(" ");
    for (const word of words) if (word.length > 0 && nscMdEqual(name, nscMdBytes(word), true)) return kind;
  } return -1;
}
function nscMdTag(text: Uint8Array, at: number, classified: boolean): NscMdTag | null {
  if (at >= text.length || text[at] !== 60) return null;
  let i = at + 1, closing = false;
  if (i < text.length && text[i] === 47) { closing = true; i++; }
  if (i >= text.length || !nscMdAlpha(text[i]!)) return null;
  const start = i;
  while (i < text.length && (nscMdAlpha(text[i]!) || nscMdDigit(text[i]!) || text[i] === 45)) i++;
  const name = text.subarray(start, i), kind = nscMdClassify(name);
  if (classified && kind < 0) return null;
  if (i < text.length && text[i] !== 62 && text[i] !== 47 && !nscMdWhite(text[i]!)) return null;
  const attrs = i, limit = Math.min(text.length, at + 1024); let quote = -1;
  for (; i < limit; i++) {
    const b = text[i]!;
    if (quote >= 0) { if (b === quote) quote = -1; continue; }
    if (b === 34 || b === 39) { quote = b; continue; }
    if (b === 60) return null;
    if (b !== 62) continue;
    const attributes = text.subarray(attrs, i), trimmed = nscMdTrim(attributes, " \t\r\n", true, true);
    return { name, attributes, closing, selfClosing: !closing && trimmed.length > 0 && trimmed[trimmed.length - 1] === 47, consumed: i + 1 - at, kind, level: kind === 12 ? name[1]! - 48 : 0 };
  } return null;
}
function nscMdName(tag: NscMdTag, name: string): boolean { return nscMdEqual(tag.name, nscMdBytes(name), true); }
function nscMdAttr(tag: NscMdTag, wanted: string): Uint8Array | null {
  const a = tag.attributes; let i = 0;
  while (i < a.length) {
    while (i < a.length && nscMdWhite(a[i]!)) i++;
    if (i >= a.length || a[i] === 47) break;
    const start = i;
    while (i < a.length && (nscMdAlpha(a[i]!) || nscMdDigit(a[i]!) || a[i] === 45 || a[i] === 95 || a[i] === 58)) i++;
    if (i === start) { i++; continue; }
    const name = a.subarray(start, i);
    while (i < a.length && nscMdWhite(a[i]!)) i++;
    if (i >= a.length || a[i] !== 61) continue;
    i++; while (i < a.length && nscMdWhite(a[i]!)) i++;
    if (i >= a.length) return null;
    let value: Uint8Array;
    if (a[i] === 34 || a[i] === 39) { const quote = a[i++]!, v = i; while (i < a.length && a[i] !== quote) i++; if (i >= a.length) return null; value = a.subarray(v, i++); }
    else { const v = i; while (i < a.length && !nscMdWhite(a[i]!)) i++; value = a.subarray(v, i); }
    if (nscMdEqual(name, nscMdBytes(wanted), true)) return value;
  } return null;
}
function nscMdVoid(name: Uint8Array): boolean { for (const word of ["area", "base", "col", "embed", "input", "link", "meta", "param", "source", "track"]) if (nscMdEqual(name, nscMdBytes(word), true)) return true; return false; }
function nscMdBlock(tag: NscMdTag): boolean { return tag.kind >= 12 && tag.kind <= 22 || tag.kind === 23 && nscMdStructural(tag); }
function nscMdStructural(tag: NscMdTag): boolean {
  if (tag.kind !== 23) return tag.kind >= 12 && tag.kind <= 22;
  for (const word of ["center", "div", "section", "article", "header", "footer", "main", "figure", "figcaption", "caption"]) if (nscMdName(tag, word)) return true; return false;
}
function nscMdAlignment(tag: NscMdTag): number {
  if (nscMdName(tag, "center")) return 1;
  const value = nscMdAttr(tag, "align"); if (value === null) return -1;
  if (nscMdEqual(value, nscMdBytes("center"), true)) return 1;
  if (nscMdEqual(value, nscMdBytes("right"), true) || nscMdEqual(value, nscMdBytes("end"), true)) return 2;
  if (nscMdEqual(value, nscMdBytes("left"), true) || nscMdEqual(value, nscMdBytes("start"), true)) return 0; return -1;
}
class NscMdOpaque { name: Uint8Array = new Uint8Array(0); depth = 0; comment = false; active(): boolean { return this.depth > 0 || this.comment; } }
interface NscMdMatch { start: number; end: number; tag: NscMdTag }
class NscMdTagScan {
  cursor = 0; cache = new NscMdCache(); opaque: NscMdOpaque;
  constructor(opaque: NscMdOpaque) { this.opaque = opaque; }
  next(source: Uint8Array): NscMdMatch | null {
    while (this.cursor < source.length) {
      if (this.opaque.comment) { const close = nscMdFind(source, this.cursor, "-->", false); if (close < 0) { this.cursor = source.length; return null; } this.opaque.comment = false; this.cursor = close + 3; continue; }
      const start = nscMdFindByte(source, this.cursor, 60); if (start < 0) return null;
      if (this.opaque.depth === 0) {
        const tick = nscMdScan(this.cache.tick, source, this.cursor, "`");
        if (tick >= 0 && tick < start) { const end = nscMdScan(this.cache.tick, source, tick + 1, "`"); this.cursor = end < 0 ? tick + 1 : end + 1; continue; }
      }
      if (nscMdStarts(source, start, "<!--", false)) { const close = nscMdFind(source, start + 4, "-->", false); if (close < 0) { this.opaque.comment = true; this.cursor = source.length; return null; } this.cursor = close + 3; continue; }
      const tag = nscMdTag(source, start, false); if (tag === null) { this.cursor = start + 1; continue; }
      this.cursor = start + tag.consumed;
      if (this.opaque.depth > 0) {
        if (!nscMdEqual(tag.name, this.opaque.name, true)) continue;
        if (tag.closing) { this.opaque.depth--; if (this.opaque.depth === 0) this.opaque.name = new Uint8Array(0); }
        else if (!tag.selfClosing) this.opaque.depth++;
        continue;
      }
      if (tag.kind >= 0) return { start, end: this.cursor, tag };
      if (!tag.closing && !tag.selfClosing && !nscMdVoid(tag.name)) { this.opaque.name = tag.name; this.opaque.depth = 1; }
    } return null;
  }
}
function nscMdHasClose(source: Uint8Array, from: number, name: Uint8Array): boolean {
  const scan = new NscMdTagScan(new NscMdOpaque()); scan.cursor = from; let depth = 0;
  for (;;) { const match = scan.next(source); if (match === null) return false; const tag = match.tag; if (!nscMdEqual(tag.name, name, true)) continue; if (!tag.closing) { if (!tag.selfClosing) depth++; } else { if (depth === 0) return true; depth--; } }
}
function nscMdUnbalanced(source: Uint8Array, name: Uint8Array | null): NscMdMatch | null {
  const scan = new NscMdTagScan(new NscMdOpaque()); let depth = 0;
  for (;;) { const match = scan.next(source); if (match === null) return null; const tag = match.tag; if (name === null ? !nscMdStructural(tag) : !nscMdEqual(tag.name, name, true)) continue; if (!tag.closing) { if (!tag.selfClosing) depth++; } else { if (depth === 0) return match; depth--; } }
}
function nscMdUnsupported(source: Uint8Array, at: number, opening: NscMdTag): number {
  let cursor = at + opening.consumed, depth = 1; const cache = new NscMdCache();
  if (opening.closing || opening.selfClosing || nscMdVoid(opening.name)) return cursor;
  for (;;) {
    const start = nscMdFindByte(source, cursor, 60); if (start < 0) return source.length;
    const comment = nscMdComment(source, start, cache); if (comment >= 0) { cursor = start + comment; continue; }
    const tag = nscMdTag(source, start, false); if (tag === null) { cursor = start + 1; continue; }
    cursor = start + tag.consumed;
    if (!nscMdEqual(tag.name, opening.name, true)) continue;
    if (tag.closing) { depth--; if (depth === 0) return cursor; } else if (!tag.selfClosing) depth++;
  }
}
function nscMdComment(source: Uint8Array, at: number, cache: NscMdCache): number { if (!nscMdStarts(source, at, "<!--", false)) return -1; const end = nscMdScan(cache.comment, source, at + 4, "-->"); return end < 0 ? -1 : end + 3 - at; }
function nscMdSingle(line: Uint8Array, opening: NscMdTag): Uint8Array | null {
  if (opening.closing || opening.selfClosing) return null;
  let at = line.length - 1; while (at >= 0 && line[at] !== 60) at--;
  if (at < opening.consumed) return null;
  const closing = nscMdTag(line, at, true);
  if (closing === null || !closing.closing || closing.consumed !== line.length - at || !nscMdEqual(opening.name, closing.name, true)) return null;
  return line.subarray(opening.consumed, at);
}
function nscMdEntity(rest: Uint8Array): { text: Uint8Array; consumed: number } | null {
  const names = ["&amp;", "&lt;", "&gt;", "&quot;", "&apos;", "&nbsp;"], values = ["&", "<", ">", '"', "'", "\u00a0"];
  for (let i = 0; i < names.length; i++) if (nscMdStarts(rest, 0, names[i]!, false)) return { text: nscMdBytes(values[i]!), consumed: names[i]!.length };
  if (!nscMdStarts(rest, 0, "&#", false)) return null;
  const semi = nscMdFindByte(rest.subarray(0, Math.min(rest.length, 14)), 2, 59); if (semi < 0) return null;
  let at = 2, radix = 10; if (semi - at > 1 && (rest[at] === 120 || rest[at] === 88)) { radix = 16; at++; }
  if (at === semi) return null; let value = 0;
  // The unsigned parser accepts embedded underscores, never edge ones.
  if (rest[at] === 95 || rest[semi - 1] === 95) return null;
  let digits = 0;
  for (; at < semi; at++) { const b = rest[at]!; if (b === 95) continue; const d = b >= 48 && b <= 57 ? b - 48 : b >= 65 && b <= 70 ? b - 55 : b >= 97 && b <= 102 ? b - 87 : -1; if (d < 0 || d >= radix) return null; value = value * radix + d; digits++; if (value > 0x1fffff) return null; }
  if (digits === 0 || value === 0 || value > 0x10ffff || value >= 0xd800 && value <= 0xdfff) return null;
  const out = new Uint8Array(value <= 127 ? 1 : value <= 2047 ? 2 : value <= 65535 ? 3 : 4);
  if (out.length === 1) out[0] = value;
  else { for (let i = out.length - 1; i > 0; i--) { out[i] = 128 | value & 63; value = Math.floor(value / 64); } out[0] = (out.length === 2 ? 192 : out.length === 3 ? 224 : 240) | value; }
  return { text: out, consumed: semi + 1 };
}
function nscMdDecode(text: Uint8Array): Uint8Array {
  if (nscMdFindByte(text, 0, 38) < 0) return text;
  const out = new Uint8Array(text.length); let at = 0, len = 0;
  while (at < text.length) { const entity = text[at] === 38 ? nscMdEntity(text.subarray(at)) : null; if (entity !== null) { out.set(entity.text, len); len += entity.text.length; at += entity.consumed; } else out[len++] = text[at++]!; }
  return out.subarray(0, len);
}
function nscMdLink(text: Uint8Array, index: number, cache: NscMdCache): NscMdLink | null {
  if (text.length - index < 4 || text[index] !== 91) return null;
  const bracket = nscMdScan(cache.bracket, text, index, "]"); if (bracket < 0 || bracket + 1 >= text.length || text[bracket + 1] !== 40) return null;
  const paren = nscMdScan(cache.paren, text, bracket + 2, ")"); if (paren < 0) return null;
  const space = nscMdScan(cache.title, text, bracket + 2, " "), end = space >= 0 && space < paren ? space : paren;
  if (bracket === index + 1 || end === bracket + 2) return null;
  return { text: text.subarray(index + 1, bracket), target: text.subarray(bracket + 2, end), consumed: paren + 1 - index };
}
function nscMdAutolink(text: Uint8Array, index: number, cache: NscMdCache): NscMdLink | null {
  if (text.length - index < 3 || text[index] !== 60) return null;
  const close = nscMdScan(cache.angle, text, index, ">"); if (close < 0) return null;
  const sep = nscMdScan(cache.scheme, text, index + 1, "://"); if (sep < 0 || sep + 3 > close) return null;
  const space = nscMdScan(cache.space, text, index + 1, " "); if (space >= 0 && space < close) return null;
  const target = text.subarray(index + 1, close); return { text: target, target, consumed: close + 1 - index };
}
function nscMdBoundary(text: Uint8Array, at: number): boolean { return at === 0 || !nscMdWord(text[at - 1]!) && text[at - 1] !== 47 && text[at - 1] !== 38; }
function nscMdBare(rest: Uint8Array): NscMdLink | null {
  const prefix = nscMdStarts(rest, 0, "https://", false) ? 8 : nscMdStarts(rest, 0, "http://", false) ? 7 : 0; if (prefix === 0) return null;
  let end = prefix, balance = 0;
  for (; end < rest.length; end++) { const b = rest[end]!; if (nscMdSpace(b) || b === 10 || b === 60 || b === 62) break; if (b === 40) balance++; if (b === 41) balance--; }
  while (end > prefix) { const b = rest[end - 1]!; if (b === 41) { if (balance < 0) { end--; balance++; continue; } break; } if (b === 46 || b === 44 || b === 59 || b === 58 || b === 33 || b === 63 || b === 39 || b === 34) end--; else break; }
  if (end === prefix) return null; const target = rest.subarray(0, end); return { text: target, target, consumed: end };
}
function nscMdIssue(rest: Uint8Array): number { if (rest.length < 2 || rest[0] !== 35) return -1; let end = 1; while (end < rest.length && nscMdDigit(rest[end]!)) end++; return end === 1 || end < rest.length && nscMdWord(rest[end]!) ? -1 : end; }
function nscMdHeading(line: Uint8Array): number { let level = 0; while (level < line.length && line[level] === 35) level++; return level === 0 || level > 6 || level < line.length && line[level] !== 32 ? 0 : level; }
function nscMdRule(line: Uint8Array): boolean { if (line.length < 3 || line[0] !== 45 && line[0] !== 42 && line[0] !== 95) return false; let count = 0; for (const b of line) { if (b === line[0]) count++; else if (b !== 32) return false; } return count >= 3; }
interface NscMdMarker { kind: number; indent: number; label: Uint8Array; checked: boolean; content: Uint8Array }
function nscMdMarker(line: Uint8Array): NscMdMarker | null {
  let spaces = 0; while (spaces < line.length && line[spaces] === 32) spaces++;
  const indent = Math.min(Math.floor(spaces / 2), 3), rest = line.subarray(spaces); if (rest.length < 2) return null;
  if ((rest[0] === 45 || rest[0] === 42 || rest[0] === 43) && rest[1] === 32) {
    const content = nscMdTrim(rest.subarray(2), " \t", true, true); let kind = 0, checked = false, consumed = 0;
    if (nscMdStarts(content, 0, "[ ] ", false)) { kind = 2; consumed = 4; }
    else if (nscMdStarts(content, 0, "[x] ", true)) { kind = 2; consumed = 4; checked = true; }
    return { kind, indent, label: new Uint8Array(0), checked, content: content.subarray(consumed) };
  }
  let digits = 0; while (digits < rest.length && nscMdDigit(rest[digits]!)) digits++;
  if (digits > 0 && digits + 1 < rest.length && rest[digits] === 46 && rest[digits + 1] === 32) return { kind: 1, indent, label: rest.subarray(0, digits + 1), checked: false, content: nscMdTrim(rest.subarray(digits + 2), " \t", true, true) }; return null;
}
function nscMdReference(line: Uint8Array): boolean {
  let i = 0; while (i < line.length && line[i] === 32) i++; if (i > 3 || i >= line.length || line[i] !== 91) return false;
  i++; let content = false, closed = false;
  while (i < line.length) { const b = line[i]!; if (b === 92 && i + 1 < line.length && nscMdPunctuation(line[i + 1]!)) { content = content || !nscMdSpace(line[i + 1]!); i += 2; continue; } if (b === 91) return false; if (b === 93) { closed = true; i++; break; } content = content || !nscMdSpace(b); i++; }
  if (!closed || !content || i >= line.length || line[i] !== 58) return false;
  i++; while (i < line.length && nscMdSpace(line[i]!)) i++; if (i >= line.length) return false;
  const start = i;
  if (line[i] === 60) {
    i++; closed = false;
    while (i < line.length) { const b = line[i]!; if (b === 92 && i + 1 < line.length && nscMdPunctuation(line[i + 1]!)) { i += 2; continue; } if (b === 60 || b === 10 || b === 13) return false; if (b === 62) { i++; closed = true; break; } i++; } if (!closed) return false;
  } else {
    let depth = 0;
    while (i < line.length && !nscMdSpace(line[i]!)) { const b = line[i]!; if (b < 32 || b === 127 || b === 60) return false; if (b === 92 && i + 1 < line.length && nscMdPunctuation(line[i + 1]!)) { i += 2; continue; } if (b === 40) depth++; else if (b === 41) { if (depth === 0) return false; depth--; } i++; } if (i === start || depth !== 0) return false;
  }
  const end = i; while (i < line.length && nscMdSpace(line[i]!)) i++; if (i === line.length) return true; if (i === end) return false;
  const opener = line[i]!, close = opener === 34 || opener === 39 ? opener : opener === 40 ? 41 : -1; if (close < 0) return false;
  i++; closed = false;
  while (i < line.length) { if (line[i] === 92 && i + 1 < line.length && nscMdPunctuation(line[i + 1]!)) { i += 2; continue; } if (line[i++] === close) { closed = true; break; } }
  while (i < line.length && nscMdSpace(line[i]!)) i++; return closed && i === line.length;
}
function nscMdTable(line: Uint8Array): Uint8Array[] | null {
  let rest = nscMdTrim(line, " \t", true, true); if (rest.length === 0 || nscMdFindByte(rest, 0, 124) < 0) return null;
  if (rest[0] === 124) rest = rest.subarray(1);
  if (rest.length > 0 && rest[rest.length - 1] === 124 && !(rest.length > 1 && rest[rest.length - 2] === 92)) rest = rest.subarray(0, rest.length - 1);
  const cells: Uint8Array[] = []; let start = 0;
  for (let i = 0; i < rest.length; i++) { if (rest[i] === 92) { i++; continue; } if (rest[i] !== 124) continue; if (cells.length >= 8) return null; cells.push(nscMdTrim(rest.subarray(start, i), " \t", true, true)); start = i + 1; }
  if (cells.length >= 8) return null; cells.push(nscMdTrim(rest.subarray(Math.min(start, rest.length)), " \t", true, true)); return cells;
}
function nscMdDelimiters(line: Uint8Array): number[] | null {
  const cells = nscMdTable(line); if (cells === null) return null; const out: number[] = [];
  for (const cell of cells) { if (cell.length === 0) return null; let body = cell; const leading = body[0] === 58; if (leading) body = body.subarray(1); const trailing = body.length > 0 && body[body.length - 1] === 58; if (trailing) body = body.subarray(0, body.length - 1); if (body.length === 0) return null; for (const b of body) if (b !== 45) return null; out.push(leading && trailing ? 1 : trailing ? 2 : 0); } return out;
}
function nscMdTableStart(lines: NscMdLines): boolean { const first = lines.peek(), second = lines.second(); if (first === null || second === null) return false; const header = nscMdTable(first), align = nscMdDelimiters(second); return header !== null && align !== null && header.length === align.length; }
function nscMdNewBlock(line: Uint8Array): boolean {
  const trimmed = nscMdTrim(line, " \t", true, true); if (trimmed.length === 0 || nscMdStarts(trimmed, 0, "```", false) || nscMdHeading(trimmed) > 0 || nscMdRule(trimmed) || trimmed[0] === 62 || nscMdMarker(line) !== null || nscMdStarts(trimmed, 0, "<details", true) || nscMdStarts(trimmed, 0, "<!--", false)) return true;
  const tag = nscMdTag(trimmed, 0, true); return tag !== null && nscMdBlock(tag);
}
interface NscMdSpan { text: Uint8Array; link: Uint8Array; flags: number; scale: number }
function nscMdSpan(): NscMdSpan { return { text: new Uint8Array(0), link: new Uint8Array(0), flags: 0, scale: 0 }; }
class NscMdStyle {
  bold = false; italic = false; strike = false; htmlBold = 0; htmlItalic = 0; htmlStrike = 0; underline = 0; mono = 0; mark = 0; small = 0; heading = 0; link: Uint8Array = new Uint8Array(0);
}
function nscMdAppend(spans: NscMdSpan[], base: NscMdSpan, style: NscMdStyle, text: Uint8Array, link: Uint8Array, mono: boolean): void {
  if (text.length === 0 || spans.length >= 32) return;
  let flags = base.flags | (mono ? 4 : 0), scale = base.scale;
  if (style.bold || style.htmlBold > 0 || style.heading > 0) flags |= 1;
  if (style.italic || style.htmlItalic > 0) flags |= 2;
  if (style.strike || style.htmlStrike > 0) flags |= 16;
  if (style.underline > 0) flags |= 8;
  if (style.mono > 0) flags |= 4;
  if (style.mark > 0) flags |= 32;
  if (style.small > 0) scale = scale > 0 ? Math.fround(scale * 0.875) : 0.875;
  if (style.heading > 0) scale = style.heading === 1 ? 2 : style.heading === 2 ? 1.5 : 1.25;
  const target = link.length > 0 ? link : style.link; if (target.length > 0) flags |= 8;
  spans.push({ text, link: target, flags, scale });
}
function nscMdDepth(depth: number, tag: NscMdTag): number { return tag.closing ? Math.max(0, depth - 1) : !tag.selfClosing ? depth + 1 : depth; }
function nscMdApply(spans: NscMdSpan[], base: NscMdSpan, style: NscMdStyle, tag: NscMdTag): void {
  const empty = new Uint8Array(0);
  switch (tag.kind) {
    case 0: style.htmlBold = nscMdDepth(style.htmlBold, tag); break;
    case 1: style.htmlItalic = nscMdDepth(style.htmlItalic, tag); break;
    case 2: style.htmlStrike = nscMdDepth(style.htmlStrike, tag); break;
    case 3: style.underline = nscMdDepth(style.underline, tag); break;
    case 4: case 16: style.mono = nscMdDepth(style.mono, tag); break;
    case 5: style.mark = nscMdDepth(style.mark, tag); break;
    case 6: style.small = nscMdDepth(style.small, tag); break;
    case 12: style.heading = tag.closing || tag.selfClosing ? 0 : tag.level; break;
    case 7: { const href = nscMdAttr(tag, "href"); style.link = tag.closing || tag.selfClosing || href === null ? empty : nscMdDecode(href); break; }
    case 9: if (!tag.closing) nscMdAppend(spans, base, style, nscMdBytes("\n"), empty, false); break;
    case 10: if (!tag.closing) nscMdAppend(spans, base, style, nscMdBytes("\u200b"), empty, false); break;
    case 8: if (!tag.closing) { const alt = nscMdAttr(tag, "alt"); if (alt !== null) nscMdAppend(spans, base, style, nscMdDecode(alt), empty, false); } break;
    case 11: if (!tag.selfClosing) nscMdAppend(spans, base, style, nscMdBytes(tag.closing ? "”" : "“"), empty, false); break;
    case 18: if (!tag.selfClosing) nscMdAppend(spans, base, style, nscMdBytes(tag.closing ? "\n" : "• "), empty, false); break;
    case 22: if (tag.closing) nscMdAppend(spans, base, style, nscMdBytes("\t"), empty, false); break;
    case 21: if (tag.closing) nscMdAppend(spans, base, style, nscMdBytes("\n"), empty, false); break;
    case 13: if (!tag.closing) nscMdAppend(spans, base, style, nscMdBytes("\n"), empty, false); break;
  }
}
function nscMdInline(text: Uint8Array, base: NscMdSpan, issueBase: Uint8Array | null): NscMdSpan[] {
  const spans: NscMdSpan[] = [], style = new NscMdStyle(), cache = new NscMdCache(), tags: Uint8Array[] = [], empty = new Uint8Array(0);
  let literal = 0, index = 0, consumedHtml = false;
  while (index < text.length) {
    if (spans.length + 2 >= 32) break;
    const rest = text.subarray(index), byte = rest[0]!; let link: NscMdLink | null = null, advance = 0, handled = false;
    if (byte === 96) {
      const close = nscMdFindByte(rest, 1, 96);
      if (close >= 0) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); nscMdAppend(spans, base, style, rest.subarray(1, close), empty, true); advance = close + 1; }
    } else if (nscMdStarts(rest, 0, "**", false) || nscMdStarts(rest, 0, "__", false)) {
      const delimiter = byte === 42 ? "**" : "__";
      if (style.bold || nscMdFind(rest, 2, delimiter, false) >= 0) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); style.bold = !style.bold; advance = 2; }
    } else if (nscMdStarts(rest, 0, "~~", false)) {
      if (style.strike || nscMdFind(rest, 2, "~~", false) >= 0) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); style.strike = !style.strike; advance = 2; }
    } else if (byte === 42 || byte === 95) {
      const boundary = byte === 42 || index === 0 || !nscMdWord(text[index - 1]!);
      if (boundary && (style.italic || rest.length > 1 && !nscMdSpace(rest[1]!) && nscMdFindByte(rest, 1, byte) >= 0)) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); style.italic = !style.italic; advance = 1; }
    } else if (byte === 91) link = nscMdLink(text, index, cache);
    else if (byte === 33 && rest.length > 1 && rest[1] === 91) {
      const image = nscMdLink(text, index + 1, cache);
      if (image !== null) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); nscMdAppend(spans, base, style, image.text, empty, false); advance = image.consumed + 1; }
    } else if (byte === 60) {
      const comment = nscMdComment(text, index, cache);
      if (comment >= 0) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); consumedHtml = true; advance = comment; }
      else {
        link = nscMdAutolink(text, index, cache);
        if (link === null) {
          const tag = nscMdTag(text, index, true);
          if (tag !== null) {
            const required = tag.kind !== 8 && tag.kind !== 9 && tag.kind !== 10 && tag.kind !== 13;
            const accepted = tag.closing ? required && tags.length > 0 && nscMdEqual(tags[tags.length - 1]!, tag.name, true) : tag.selfClosing || !required || tags.length < 32 && nscMdHasClose(text, index + tag.consumed, tag.name);
            if (!accepted) { index += tag.consumed; handled = true; }
            else { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); consumedHtml = true; nscMdApply(spans, base, style, tag); if (tag.closing) tags.pop(); else if (required && !tag.selfClosing) tags.push(tag.name); advance = tag.consumed; }
          } else {
            const syntax = nscMdTag(text, index, false);
            if (syntax !== null) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); const end = nscMdUnsupported(text, index, syntax); nscMdAppend(spans, base, style, text.subarray(index, end), empty, false); advance = end - index; }
          }
        }
      }
    } else if (byte === 38) {
      const entity = nscMdEntity(rest); if (entity !== null) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); nscMdAppend(spans, base, style, entity.text, empty, false); consumedHtml = true; advance = entity.consumed; }
    } else if (byte === 104 && nscMdBoundary(text, index)) link = nscMdBare(rest);
    else if (byte === 35 && nscMdBoundary(text, index) && issueBase !== null) { const end = nscMdIssue(rest); if (end >= 0) link = { text: rest.subarray(0, end), target: nscMdConcat(issueBase, rest.subarray(1, end)), consumed: end }; }
    if (handled) continue;
    if (link !== null) { nscMdAppend(spans, base, style, text.subarray(literal, index), empty, false); nscMdAppend(spans, base, style, link.text, link.target, false); advance = link.consumed; }
    if (advance > 0) { index += advance; literal = index; } else index++;
  }
  nscMdAppend(spans, base, style, text.subarray(literal), empty, false);
  if (spans.length === 0 && !consumedHtml) spans.push({ text, link: empty, flags: base.flags, scale: base.scale });
  return spans;
}
interface NscMdImage { source: Uint8Array; lower: number; upper: number; width: number; height: number }
interface NscMdLeading { source: Uint8Array; alt: Uint8Array; link: Uint8Array; consumed: number; width: number | null; height: number | null }
function nscMdDimension(tag: NscMdTag, name: string): number | null {
  const raw = nscMdAttr(tag, name); if (raw === null) return null;
  const text = nscMdTrim(raw, " \t", true, true);
  const value = nscMdFloat(text); return Number.isFinite(value) && value > 0 ? value : null;
}
function nscMdLeading(text: Uint8Array): NscMdLeading | null {
  let cursor = 0; while (cursor < text.length && nscMdSpace(text[cursor]!)) cursor++;
  const empty = new Uint8Array(0);
  if (cursor + 1 < text.length && text[cursor] === 33 && text[cursor + 1] === 91) { const link = nscMdLink(text, cursor + 1, new NscMdCache()); return link === null ? null : { source: link.target, alt: link.text, link: empty, consumed: cursor + link.consumed + 1, width: null, height: null }; }
  const wrappers: Uint8Array[] = []; let link: Uint8Array = empty;
  while (cursor < text.length) {
    const tag = nscMdTag(text, cursor, true); if (tag === null || tag.closing) return null;
    if (tag.kind === 8) {
      const source = nscMdAttr(tag, "src"); if (source === null) return null; const alt = nscMdAttr(tag, "alt"); cursor += tag.consumed;
      while (wrappers.length > 0) { while (cursor < text.length && nscMdSpace(text[cursor]!)) cursor++; const closing = nscMdTag(text, cursor, true); if (closing === null || !closing.closing || !nscMdEqual(closing.name, wrappers[wrappers.length - 1]!, true)) return null; cursor += closing.consumed; wrappers.pop(); }
      return { source, alt: alt === null ? empty : alt, link, consumed: cursor, width: nscMdDimension(tag, "width"), height: nscMdDimension(tag, "height") };
    }
    if (!(tag.kind <= 3 || tag.kind === 5 || tag.kind === 6 || tag.kind === 7 || tag.kind === 23) || tag.selfClosing || wrappers.length >= 8) return null;
    if (tag.kind === 7) { const href = nscMdAttr(tag, "href"); link = href === null ? empty : href; }
    wrappers.push(tag.name); cursor += tag.consumed; while (cursor < text.length && nscMdSpace(text[cursor]!)) cursor++;
  } return null;
}
// Round directly to f32 by comparing exact decimal integers with adjacent
// binary midpoints. This also covers hexadecimal spelling without f64
// conversion or a second rounding at the ABI boundary.
interface NscMdDecimal { digits: number[]; exponent: number }
function nscMdDigitValue(byte: number): number { return byte >= 48 && byte <= 57 ? byte - 48 : byte >= 65 && byte <= 70 ? byte - 55 : byte >= 97 && byte <= 102 ? byte - 87 : -1; }
function nscMdNormalize(digits: number[], exponent: number): NscMdDecimal {
  let start = 0, end = digits.length;
  while (end > 0 && digits[end - 1] === 0) end--;
  if (end === 0) return { digits: [], exponent: 0 };
  while (start < end && digits[start] === 0) start++;
  return { digits: digits.slice(start, end), exponent: exponent + start };
}
function nscMdMultiply(digits: number[], factor: number, add: number): void {
  let carry = add;
  for (let i = 0; i < digits.length; i++) { const value = digits[i]! * factor + carry; digits[i] = value % 10; carry = Math.floor(value / 10); }
  while (carry > 0) { digits.push(carry % 10); carry = Math.floor(carry / 10); }
}
function nscMdMidpoint(word: number): NscMdDecimal {
  const field = Math.floor(word / 8388608), mantissa = field === 0 ? word : word % 8388608 + 8388608, power = field === 0 ? -150 : field - 151;
  let value = mantissa * 2 + 1; const digits: number[] = [];
  while (value > 0) { digits.push(value % 10); value = Math.floor(value / 10); }
  for (let i = 0; i < Math.abs(power); i++) nscMdMultiply(digits, power < 0 ? 5 : 2, 0);
  return nscMdNormalize(digits, Math.min(0, power));
}
function nscMdCompare(a: NscMdDecimal, b: NscMdDecimal): number {
  const x = a.digits.length + a.exponent, y = b.digits.length + b.exponent;
  if (x !== y) return x < y ? -1 : 1;
  const count = Math.max(a.digits.length, b.digits.length);
  for (let i = 0; i < count; i++) { const left = i < a.digits.length ? a.digits[a.digits.length - 1 - i]! : 0, right = i < b.digits.length ? b.digits[b.digits.length - 1 - i]! : 0; if (left !== right) return left < right ? -1 : 1; } return 0;
}
function nscMdFloat(text: Uint8Array): number {
  if (text.length === 0) return NaN;
  let at = 0; if (text[at] === 45) return NaN; if (text[at] === 43) at++;
  if (at >= text.length) return NaN;
  const hex = nscMdStarts(text, at, "0x", true); if (hex) at += 2;
  const digits: number[] = []; let fractional = 0, dot = false;
  while (at < text.length) {
    const byte = text[at]!, digit = nscMdDigitValue(byte);
    if (digit >= 0 && digit < (hex ? 16 : 10)) { digits.push(digit); if (dot) fractional++; at++; continue; }
    if (byte === 95) { const before = at > 0 ? nscMdDigitValue(text[at - 1]!) : -1, after = at + 1 < text.length ? nscMdDigitValue(text[at + 1]!) : -1; if (before < 0 || after < 0 || before >= (hex ? 16 : 10) || after >= (hex ? 16 : 10)) return NaN; at++; continue; }
    if (byte === 46 && !dot) { dot = true; at++; continue; } break;
  }
  if (digits.length === 0) return NaN;
  let exponent = 0;
  if (at < text.length && (text[at] === (hex ? 112 : 101) || text[at] === (hex ? 80 : 69))) {
    at++; let negative = false; if (at < text.length && (text[at] === 45 || text[at] === 43)) { negative = text[at] === 45; at++; }
    let count = 0;
    while (at < text.length) { const byte = text[at]!; if (byte === 95) { if (at === 0 || !nscMdDigit(text[at - 1]!) || at + 1 >= text.length || !nscMdDigit(text[at + 1]!)) return NaN; at++; continue; } if (!nscMdDigit(byte)) return NaN; if (exponent < 0x10000000) exponent = exponent * 10 + byte - 48; count++; at++; }
    if (count === 0) return NaN; if (negative) exponent = -exponent;
  }
  if (at !== text.length) return NaN;
  let decimal: NscMdDecimal;
  if (hex) {
    let start = 0; while (start < digits.length && digits[start] === 0) start++;
    if (start === digits.length) return 0;
    exponent -= fractional * 4;
    const extent = exponent + (digits.length - start) * 4; if (extent > 132) return Infinity; if (extent < -153) return 0;
    const out: number[] = []; for (let i = start; i < digits.length; i++) nscMdMultiply(out, 16, digits[i]!);
    for (let i = 0; i < Math.abs(exponent); i++) nscMdMultiply(out, exponent < 0 ? 5 : 2, 0);
    decimal = nscMdNormalize(out, Math.min(0, exponent));
  } else {
    const out: number[] = []; for (let i = digits.length - 1; i >= 0; i--) out.push(digits[i]!); decimal = nscMdNormalize(out, exponent - fractional);
  }
  if (decimal.digits.length === 0) return 0;
  let lo = 0, hi = 0x7f800000;
  while (lo < hi) { const mid = Math.floor((lo + hi) / 2), comparison = nscMdCompare(decimal, nscMdMidpoint(mid)); if (comparison > 0 || comparison === 0 && mid % 2 !== 0) lo = mid + 1; else hi = mid; }
  const bytes = new Uint8Array(4), wire = new DataView(bytes.buffer); wire.setUint32(0, lo, true); return wire.getFloat32(0, true);
}
interface NscMdNodeOptions { grow: number; padding: number; gap: number; width: number; height: number; alignment: number; main: number; flags: number; ordinal: number; lower: number; upper: number; language: number; label: Uint8Array; link: Uint8Array }
function nscMdOptions(): NscMdNodeOptions { return { grow: 0, padding: 0, gap: 0, width: 0, height: 0, alignment: 0, main: -1, flags: 0, ordinal: -1, lower: 0, upper: 0, language: 0, label: new Uint8Array(0), link: new Uint8Array(0) }; }
interface NscMdNode { operation: number; subtype: number; options: NscMdNodeOptions; children: number[]; spans: NscMdSpan[]; text: Uint8Array }
class NscMdWriter {
  parts: Uint8Array[] = []; length = 0;
  add(bytes: Uint8Array): void { this.parts.push(bytes); this.length += bytes.length; }
  u32(value: number): void { const bytes = new Uint8Array(4); new DataView(bytes.buffer).setUint32(0, value, true); this.add(bytes); }
  finish(): Uint8Array { const out = new Uint8Array(this.length); let at = 0; for (const part of this.parts) { out.set(part, at); at += part.length; } return out; }
}
function nscMdEncode(nodes: NscMdNode[], root: number): Uint8Array {
  const out = new NscMdWriter(); out.u32(1); out.u32(nodes.length); out.u32(root); out.u32(0);
  for (const node of nodes) {
    const o = node.options, bytes = new Uint8Array(64), wire = new DataView(bytes.buffer);
    bytes[0] = node.operation; bytes[1] = node.subtype; bytes[2] = o.alignment; bytes[3] = o.flags;
    wire.setFloat32(4, o.grow, true); wire.setFloat32(8, o.padding, true); wire.setFloat32(12, o.gap, true); wire.setFloat32(16, o.width, true); wire.setFloat32(20, o.height, true);
    wire.setUint32(24, o.lower, true); wire.setUint32(28, o.upper, true); wire.setInt32(32, o.ordinal, true);
    wire.setUint32(36, node.children.length, true); wire.setUint32(40, node.spans.length, true); wire.setUint32(44, node.text.length, true); wire.setUint32(48, o.label.length, true); wire.setUint32(52, o.link.length, true); wire.setUint32(56, o.language, true); wire.setInt32(60, o.main, true); out.add(bytes);
    for (const child of node.children) out.u32(child);
    for (const span of node.spans) { const header = new Uint8Array(16), d = new DataView(header.buffer); d.setUint32(0, span.flags, true); d.setFloat32(4, span.scale, true); d.setUint32(8, span.text.length, true); d.setUint32(12, span.link.length, true); out.add(header); out.add(span.text); out.add(span.link); }
    out.add(node.text); out.add(o.label); out.add(o.link);
  } return out.finish();
}
interface NscMdScope { name: Uint8Array; previous: number; list: number; ordinal: number }
interface NscMdPresentation { alignment: number; depth: number; overflow: number }
interface NscMdResolved { mapping: NscMdImage; consumed: number; alt: Uint8Array; link: Uint8Array; width: number; height: number }
function nscMdLanguage(opening: Uint8Array): number {
  const trimmed = nscMdTrim(opening, " \t", true, true); if (trimmed.length <= 3) return 0;
  let info = nscMdTrim(trimmed.subarray(3), " \t", true, true); if (nscMdStarts(info, 0, "{.", false)) info = info.subarray(2);
  let end = 0; while (end < info.length && (nscMdAlpha(info[end]!) || nscMdDigit(info[end]!) || info[end] === 95 || info[end] === 45 || info[end] === 43 || info[end] === 35)) end++;
  const name = info.subarray(0, end), aliases = ["plain text", "zig", "js mjs javascript", "ts typescript", "json jsonc", "yaml yml", "sh bash zsh shell", "py python", "rs rust", "c h cc cpp c++ cs csharp java kotlin swift", "go golang", "html xml svg", "css scss less", "sql", "jsx", "tsx", "md markdown"];
  for (let language = 0; language < aliases.length; language++) for (const alias of aliases[language]!.split(" ")) if (nscMdEqual(name, nscMdBytes(alias), true)) return language;
  return 0;
}
function nscMdCollapse(raw: Uint8Array): Uint8Array {
  const text = nscMdTrim(raw, " \t\r\n", true, true), out = new Uint8Array(text.length); let len = 0;
  for (let i = 0; i < text.length; i++) { if (text[i] === 13) { if (i + 1 < text.length && text[i + 1] === 10) i++; out[len++] = 32; } else out[len++] = text[i] === 10 ? 32 : text[i]!; } return out.subarray(0, len);
}
function nscMdUnescape(text: Uint8Array): Uint8Array { const out = new Uint8Array(text.length); let len = 0; for (let i = 0; i < text.length; i++) { if (text[i] === 92 && i + 1 < text.length && text[i + 1] === 124) continue; out[len++] = text[i]!; } return out.subarray(0, len); }
class NscMdBuilder {
  nodes: NscMdNode[] = []; details = 0; alignment = -1; scopes: NscMdScope[] = []; scopeDepth = 0; overflow = 0; blockDepth = 0;
  expanded: boolean[]; issue: Uint8Array | null; images: NscMdImage[];
  constructor(expanded: boolean[], issue: Uint8Array | null, images: NscMdImage[]) { this.expanded = expanded; this.issue = issue; this.images = images; }
  add(operation: number, subtype: number, options: NscMdNodeOptions, children: number[], spans: NscMdSpan[], text: Uint8Array): number {
    const index = this.nodes.length; this.nodes.push({ operation, subtype, options, children, spans, text }); return index;
  }
  container(row: boolean, gap: number, padding: number, grow: number, children: number[]): number { const o = nscMdOptions(); o.gap = gap; o.padding = padding; o.grow = grow; return this.add(row ? 1 : 0, 0, o, children, [], new Uint8Array(0)); }
  el(kind: number, options: NscMdNodeOptions, children: number[]): number { return this.add(5, kind, options, children, [], new Uint8Array(0)); }
  text(text: Uint8Array): number { return this.add(3, 0, nscMdOptions(), [], [], text); }
  plainText(node: number): Uint8Array { const item = this.nodes[node]!; if (item.operation !== 2) return item.text; const out = new NscMdWriter(); for (const span of item.spans) out.add(span.text); return out.finish(); }
  separator(): number { return this.add(4, 0, nscMdOptions(), [], [], new Uint8Array(0)); }
  quoteRail(): number { const o = nscMdOptions(); o.width = 3; return this.el(0, o, []); }
  code(source: Uint8Array, language: number): number { const o = nscMdOptions(); o.language = language; return this.add(7, 0, o, [], [], source); }
  resolved(text: Uint8Array): NscMdResolved | null {
    const image = nscMdLeading(text); if (image === null) return null; const source = nscMdDecode(image.source);
    let mapping: NscMdImage | null = null;
    for (let i = 0; i < Math.min(this.images.length, 16); i++) { const candidate = this.images[i]!; if (candidate.lower === 0 && candidate.upper === 0 || !Number.isFinite(candidate.width) || candidate.width <= 0 || !Number.isFinite(candidate.height) || candidate.height <= 0) continue; if (nscMdEqual(source, candidate.source, false)) { mapping = candidate; break; } }
    if (mapping === null) return null;
    let width = image.width === null ? mapping.width : image.width, height = image.height === null ? mapping.height : image.height;
    if (image.width !== null && image.height === null) height = Math.fround(Math.fround(width * mapping.height) / mapping.width);
    else if (image.width === null && image.height !== null) width = Math.fround(Math.fround(height * mapping.width) / mapping.height);
    const scale = Math.min(1, Math.min(Math.fround(512 / width), Math.fround(512 / height)));
    return { mapping, consumed: image.consumed, alt: nscMdDecode(image.alt), link: nscMdDecode(image.link), width: Math.fround(width * scale), height: Math.fround(height * scale) };
  }
  image(resolved: NscMdResolved): number { const o = nscMdOptions(); o.width = resolved.width; o.height = resolved.height; o.lower = resolved.mapping.lower; o.upper = resolved.mapping.upper; o.label = resolved.alt; o.link = resolved.link; return this.add(8, 0, o, [], [], new Uint8Array(0)); }
  paragraph(text: Uint8Array, base: NscMdSpan, options: NscMdNodeOptions): number {
    const resolved = this.resolved(text);
    if (resolved !== null) {
      const children = [this.image(resolved)], suffix = nscMdTrim(text.subarray(resolved.consumed), " \t", true, false);
      if (suffix.length > 0) { const o = nscMdOptions(); o.grow = 1; o.alignment = options.alignment; o.flags = options.flags & 1; children.push(this.add(2, 0, o, [], nscMdInline(suffix, base, this.issue), new Uint8Array(0))); }
      const o = nscMdOptions(); o.grow = options.grow; o.padding = options.padding; o.gap = 6; o.main = options.alignment; o.flags = 8; return this.add(1, 0, o, children, [], new Uint8Array(0));
    }
    return this.add(2, 0, options, [], nscMdInline(text, base, this.issue), new Uint8Array(0));
  }
  paragraphOptions(text: Uint8Array, grow: number, muted: boolean): number { const o = nscMdOptions(); o.grow = grow; o.flags = muted ? 1 : 0; o.alignment = Math.max(0, this.alignment); return this.paragraph(text, nscMdSpan(), o); }
  heading(level: number, text: Uint8Array, alignment: number): number { const base = nscMdSpan(), o = nscMdOptions(); base.flags = 1; base.scale = level === 1 ? 2 : level === 2 ? 1.5 : 1.25; o.alignment = alignment; return this.paragraph(text, base, o); }
  snapshot(): NscMdPresentation { return { alignment: this.alignment, depth: this.scopeDepth, overflow: this.overflow }; }
  restore(state: NscMdPresentation): void { this.alignment = state.alignment; this.scopeDepth = state.depth; this.overflow = state.overflow; }
  open(tag: NscMdTag): void {
    if (!nscMdStructural(tag) || tag.selfClosing) return;
    if (this.scopeDepth >= 16) { this.overflow++; return; }
    const scope: NscMdScope = { name: tag.name, previous: this.alignment, list: tag.kind === 17 ? nscMdName(tag, "ol") ? 1 : nscMdName(tag, "dl") ? 2 : 0 : -1, ordinal: 1 };
    this.scopes[this.scopeDepth++] = scope;
    const alignment = nscMdAlignment(tag); if (alignment >= 0) this.alignment = alignment;
  }
  close(tag: NscMdTag): boolean {
    if (!nscMdStructural(tag)) return true;
    if (this.overflow > 0) { this.overflow--; return true; }
    if (this.scopeDepth === 0) return false;
    const scope = this.scopes[this.scopeDepth - 1]!; if (!nscMdEqual(scope.name, tag.name, true)) return false;
    this.scopeDepth--; this.alignment = scope.previous; return true;
  }
  scopeName(): Uint8Array | null { return this.overflow > 0 || this.scopeDepth === 0 ? null : this.scopes[this.scopeDepth - 1]!.name; }
  blocks(lines: NscMdLines, details: boolean): number[] {
    const nodes: number[] = [];
    for (;;) {
      const line = lines.peek(); if (line === null) break; const trimmed = nscMdTrim(line, " \t", true, true);
      if (details && nscMdStarts(trimmed, 0, "</details>", true)) { lines.next(); break; }
      const name = this.scopeName(), close = name !== null || this.overflow > 0 ? nscMdUnbalanced(line, name) : null;
      if (close !== null) {
        lines.next(); const fragments = new NscMdLines(line.subarray(0, close.start));
        for (;;) { const fragment = fragments.peek(); if (fragment === null) break; if (nscMdTrim(fragment, " \t", true, true).length === 0) { fragments.next(); continue; } const node = this.block(fragments); if (node < 0) continue; if (nodes.length >= 64) break; nodes.push(node); }
        const suffix = line.subarray(close.end); if (suffix.length > 0) lines.prepend(suffix); this.close(close.tag); continue;
      }
      if (trimmed.length === 0) { lines.next(); continue; }
      const node = this.block(lines); if (node < 0) continue; if (nodes.length >= 64) break; nodes.push(node);
    } return nodes;
  }
  block(lines: NscMdLines): number {
    const line = lines.peek(); if (line === null) return -1; const trimmed = nscMdTrim(line, " \t", true, true);
    if (nscMdReference(line)) { lines.next(); return -1; }
    if (nscMdStarts(trimmed, 0, "```", false)) {
      const opening = lines.next()!; const start = lines.index; let end = start;
      for (;;) { const part = lines.next(); if (part === null || nscMdStarts(nscMdTrim(part, " \t", true, true), 0, "```", false)) break; end = lines.index; }
      return this.code(nscMdTrim(lines.source.subarray(start, Math.min(end, lines.source.length)), "\n", false, true), nscMdLanguage(opening));
    }
    const level = nscMdHeading(trimmed); if (level > 0) { lines.next(); return this.heading(level, nscMdTrim(trimmed.subarray(level), " \t#", true, true), Math.max(0, this.alignment)); }
    if (nscMdRule(trimmed)) { lines.next(); return this.separator(); }
    if (trimmed[0] === 62) { const text = this.joined(lines, true); if (text.length === 0) return -1; return this.container(true, 10, 0, 0, [this.quoteRail(), this.paragraphOptions(text, 1, true)]); }
    if (nscMdMarker(line) !== null) return this.list(lines, 0, 0);
    if (nscMdStarts(trimmed, 0, "<details", true)) return this.detail(lines);
    const html = this.htmlBlock(lines, trimmed); if (html !== -2) return html;
    if (nscMdTableStart(lines)) return this.table(lines);
    const text = this.joined(lines, false); return text.length === 0 ? -1 : this.paragraphOptions(text, 0, false);
  }
  joinPiece(lines: NscMdLines, quote: boolean, length: number, opaque: NscMdOpaque): Uint8Array | null {
    const line = lines.peek(); if (line === null) return null; const trimmed = nscMdTrim(line, " \t", true, true);
    if (quote) { if (trimmed.length === 0 || trimmed[0] !== 62) return null; let inner = trimmed.subarray(1); if (inner.length > 0 && inner[0] === 32) inner = inner.subarray(1); return nscMdTrim(inner, " \t", true, true); }
    if (!opaque.active()) {
      if (trimmed.length === 0) return null;
      if (length > 0) { const name = this.scopeName(), closes = name !== null || this.overflow > 0 ? nscMdUnbalanced(line, name) !== null : false; if (closes || nscMdNewBlock(line) || nscMdTableStart(lines)) return null; }
    }
    const scan = new NscMdTagScan(opaque); while (scan.next(line) !== null) {} return trimmed;
  }
  joined(lines: NscMdLines, quote: boolean): Uint8Array {
    const probe = lines.copy(), opaque = new NscMdOpaque(); let total = 0;
    for (;;) { const piece = this.joinPiece(probe, quote, total, opaque); if (piece === null) break; probe.next(); if (total > 0) total++; total += piece.length; }
    if (total === 0) { lines.restore(probe); return new Uint8Array(0); }
    const out = new Uint8Array(Math.min(total, 8192)), state = new NscMdOpaque(); let len = 0, joined = 0;
    for (;;) { const piece = this.joinPiece(lines, quote, joined, state); if (piece === null) break; lines.next(); if (joined > 0 && len < out.length) out[len++] = 32; if (joined > 0) joined++; joined += piece.length; const take = Math.min(piece.length, out.length - len); out.set(piece.subarray(0, take), len); len += take; } return out.subarray(0, len);
  }
  list(lines: NscMdLines, indent: number, depth: number): number {
    const items: number[] = [];
    for (;;) {
      const line = lines.peek(); if (line === null) break; const marker = nscMdMarker(line); if (marker === null || marker.indent < indent) break;
      if (marker.indent > indent) { if (items.length === 0 || depth + 1 >= 4) { lines.next(); continue; } const nested = this.list(lines, marker.indent, depth + 1); if (nested >= 0) items[items.length - 1] = this.container(false, 4, 0, 0, [items[items.length - 1]!, nested]); continue; }
      lines.next(); if (items.length >= 64) continue; items.push(this.listItem(marker, depth));
    } return items.length === 0 ? -1 : this.container(false, 4, 0, 0, items);
  }
  listItem(marker: NscMdMarker, depth: number): number {
    const content = this.paragraphOptions(marker.content, 1, false); let lead: number;
    if (marker.kind === 2) { const o = nscMdOptions(); o.flags = marker.checked ? 16 : 0; o.label = marker.content; lead = this.add(6, 0, o, [], [], new Uint8Array(0)); }
    else lead = this.text(marker.kind === 0 ? nscMdBytes("•") : marker.label);
    const top = this.container(false, 0, 0, 0, [lead]); if (depth === 0) return this.container(true, 8, 0, 0, [top, content]);
    const o = nscMdOptions(); o.width = depth * 16; const spacer = this.el(1, o, []); return this.container(true, 8, 0, 0, [spacer, top, content]);
  }
  collectHtml(lines: NscMdLines, name: Uint8Array): { content: Uint8Array; closed: boolean } {
    const probe = lines.copy(), opaque = new NscMdOpaque(); let depth = 1, total = 0, closed = false;
    for (;;) { const line = probe.next(); if (line === null) break; const scan = new NscMdTagScan(opaque); let end = line.length, closing = -1;
      for (;;) { const match = scan.next(line); if (match === null) break; if (!nscMdEqual(match.tag.name, name, true)) continue; if (!match.tag.closing) { if (!match.tag.selfClosing) depth++; } else { if (depth > 0) depth--; if (depth === 0) { end = match.start; closing = match.end; break; } } }
      total = Math.min(8192, total + end); if (closing >= 0) { const suffix = line.subarray(closing); if (suffix.length > 0) probe.prepend(suffix); closed = true; break; } total = Math.min(8192, total + 1);
    }
    if (!closed) return { content: new Uint8Array(0), closed: false };
    const out = new Uint8Array(total), state = new NscMdOpaque(); depth = 1; let len = 0;
    for (;;) { const line = lines.next(); if (line === null) break; const scan = new NscMdTagScan(state); let end = line.length, closing = -1;
      for (;;) { const match = scan.next(line); if (match === null) break; if (!nscMdEqual(match.tag.name, name, true)) continue; if (!match.tag.closing) { if (!match.tag.selfClosing) depth++; } else { if (depth > 0) depth--; if (depth === 0) { end = match.start; closing = match.end; break; } } }
      const take = Math.min(end, out.length - len); out.set(line.subarray(0, take), len); len += take;
      if (closing >= 0) { const suffix = line.subarray(closing); if (suffix.length > 0) lines.prepend(suffix); break; } if (len < out.length) out[len++] = 10;
    } return { content: out.subarray(0, len), closed: true };
  }
  htmlParagraph(content: Uint8Array, alignment: number, grow: number, bold: boolean): number { const o = nscMdOptions(), base = nscMdSpan(); o.grow = grow; o.alignment = alignment; base.flags = bold ? 1 : 0; return this.paragraph(content, base, o); }
  htmlItem(tag: NscMdTag, content: Uint8Array): number {
    if (nscMdName(tag, "dt")) return this.htmlParagraph(content, Math.max(0, this.alignment), 0, true);
    if (nscMdName(tag, "dd")) { const o = nscMdOptions(); o.width = 16; return this.container(true, 8, 0, 0, [this.el(1, o, []), this.htmlParagraph(content, Math.max(0, this.alignment), 1, false)]); }
    const marker: NscMdMarker = { kind: 0, indent: 0, label: new Uint8Array(0), checked: false, content };
    if (this.overflow === 0) for (let i = this.scopeDepth - 1; i >= 0; i--) { const scope = this.scopes[i]!; if (scope.list < 0) continue; if (scope.list === 1) { marker.kind = 1; marker.label = nscMdBytes(String(scope.ordinal) + "."); scope.ordinal++; } break; }
    return this.listItem(marker, 0);
  }
  htmlBlock(lines: NscMdLines, trimmed: Uint8Array): number {
    if (nscMdStarts(trimmed, 0, "<!--", false)) {
      const probe = lines.copy(), first = probe.next()!; const opening = nscMdFind(first, 0, "<!--", false); let close = nscMdFind(first, opening + 4, "-->", false), line = first;
      while (close < 0) { const next = probe.next(); if (next === null) return -2; line = next; close = nscMdFind(line, 0, "-->", false); }
      const suffix = line.subarray(close + 3); if (suffix.length > 0) probe.prepend(suffix); lines.restore(probe); return -1;
    }
    const opening = nscMdTag(trimmed, 0, true); if (opening === null) return -2;
    if (opening.closing || !nscMdBlock(opening)) { if (opening.consumed === trimmed.length && opening.closing && nscMdStructural(opening)) { if (!this.close(opening)) return -2; lines.next(); return -1; } return -2; }
    if (opening.kind === 13) { this.consumeOpening(lines, trimmed, opening); return this.separator(); }
    if (opening.kind === 15 || opening.kind === 16 || opening.kind === 12 || opening.kind === 14 || opening.kind === 18) {
      const before = lines.copy(); this.consumeOpening(lines, trimmed, opening); if (opening.selfClosing) return -1;
      if (opening.kind === 15 && this.blockDepth >= 8) { this.skipHtml(lines, opening.name); return -1; }
      const element = this.collectHtml(lines, opening.name); if (!element.closed) { lines.restore(before); return -2; }
      if (opening.kind === 15) {
        const state = this.snapshot(), align = nscMdAlignment(opening); if (align >= 0) this.alignment = align; this.blockDepth++;
        const blocks = this.blocks(new NscMdLines(element.content), false); this.blockDepth--; const node = this.container(true, 10, 0, 0, [this.quoteRail(), this.container(false, 12, 0, 1, blocks)]); this.restore(state); return node;
      }
      if (opening.kind === 16) { let content = nscMdTrim(element.content, "\r\n", true, true); const tag = nscMdTag(content, 0, true); if (tag !== null && tag.kind === 4 && !tag.closing) { const single = nscMdSingle(content, tag); if (single !== null) content = single; } return this.code(nscMdDecode(nscMdTrim(content, "\r\n", true, true)), 0); }
      const content = nscMdCollapse(element.content), align = nscMdAlignment(opening), alignment = align >= 0 ? align : Math.max(0, this.alignment);
      return opening.kind === 12 ? this.heading(opening.level, content, alignment) : opening.kind === 14 ? this.htmlParagraph(content, alignment, 0, false) : this.htmlItem(opening, content);
    }
    const single = nscMdSingle(trimmed, opening);
    if (single !== null) {
      const align = nscMdAlignment(opening), alignment = align >= 0 ? align : Math.max(0, this.alignment);
      if (opening.kind === 17) { lines.next(); const state = this.snapshot(); this.open(opening); const blocks = this.blocks(new NscMdLines(single), false); const node = this.container(false, 4, 0, 0, blocks); this.restore(state); return node; }
      if (opening.kind === 23 || opening.kind >= 19 && opening.kind <= 22) { lines.next(); return this.htmlParagraph(single, alignment, 0, false); }
      return -2;
    }
    if (opening.consumed === trimmed.length && nscMdStructural(opening)) { lines.next(); if (!opening.selfClosing) this.open(opening); return -1; }
    return -2;
  }
  consumeOpening(lines: NscMdLines, trimmed: Uint8Array, tag: NscMdTag): void { lines.next(); const suffix = trimmed.subarray(tag.consumed); if (suffix.length > 0) lines.prepend(suffix); }
  skipHtml(lines: NscMdLines, name: Uint8Array): void {
    const opaque = new NscMdOpaque(); let depth = 1;
    for (;;) { const line = lines.next(); if (line === null) return; const scan = new NscMdTagScan(opaque);
      for (;;) { const match = scan.next(line); if (match === null) break; if (!nscMdEqual(match.tag.name, name, true)) continue; if (!match.tag.closing) { if (!match.tag.selfClosing) depth++; } else { if (depth > 0) depth--; if (depth === 0) { const suffix = line.subarray(match.end); if (suffix.length > 0) lines.prepend(suffix); return; } } }
    }
  }
  skipDetails(lines: NscMdLines): void { let depth = 1; for (;;) { const line = lines.next(); if (line === null) return; const trimmed = nscMdTrim(line, " \t", true, true); if (nscMdStarts(trimmed, 0, "<details", true)) depth++; if (nscMdStarts(trimmed, 0, "</details>", true)) { depth--; if (depth === 0) return; } } }
  detail(lines: NscMdLines): number {
    lines.next(); const ordinal = this.details; if (ordinal >= 16) { this.skipDetails(lines); return -1; } this.details++;
    const expanded = ordinal < this.expanded.length && this.expanded[ordinal]!; let summary = nscMdBytes("Details"); const line = lines.peek();
    if (line !== null) { const trimmed = nscMdTrim(line, " \t", true, true); if (nscMdStarts(trimmed, 0, "<summary>", true)) { lines.next(); summary = trimmed.subarray(9); const close = nscMdFind(summary, 0, "</summary>", true); if (close >= 0) summary = summary.subarray(0, close); summary = nscMdTrim(summary, " \t", true, true); } }
    const indicator = nscMdBytes(expanded ? "▾" : "▸"), summaryNode = this.paragraphOptions(summary, 1, false), label = nscMdConcat(nscMdConcat(indicator, nscMdBytes(" ")), this.plainText(summaryNode));
    const o = nscMdOptions(); o.gap = 6; o.ordinal = ordinal; o.label = label; o.flags = expanded ? 4 : 0;
    const header = this.el(2, o, [this.text(indicator), summaryNode]);
    if (!expanded) { this.skipDetails(lines); return this.container(false, 4, 0, 0, [header]); }
    const blocks = this.blocks(lines, true), body = this.container(false, 12, 8, 0, blocks); return this.container(false, 4, 0, 0, [header, body]);
  }
  table(lines: NscMdLines): number {
    const header = nscMdTable(lines.next()!)!, alignments = nscMdDelimiters(lines.next()!)!, rows = [this.tableRow(header, alignments, true)];
    for (;;) { const line = lines.peek(); if (line === null) break; const trimmed = nscMdTrim(line, " \t", true, true); if (trimmed.length === 0 || nscMdFindByte(trimmed, 0, 124) < 0) break; const row = nscMdTable(line); if (row === null) break; lines.next(); if (rows.length >= 64) continue; rows.push(this.tableRow(row, alignments, false)); }
    return this.el(3, nscMdOptions(), rows);
  }
  tableRow(row: Uint8Array[], alignments: number[], header: boolean): number { const cells: number[] = []; for (let i = 0; i < alignments.length; i++) cells.push(this.tableCell(i < row.length ? row[i]! : new Uint8Array(0), alignments[i]!, header)); return this.el(4, nscMdOptions(), cells); }
  tableCell(content: Uint8Array, alignment: number, header: boolean): number {
    const text = nscMdUnescape(content), base = nscMdSpan(); base.flags = header ? 1 : 0; const resolved = this.resolved(text), o = nscMdOptions(); o.grow = 1; o.padding = 8; o.alignment = alignment;
    if (resolved !== null) { const children = [this.image(resolved)], suffix = nscMdTrim(text.subarray(resolved.consumed), " \t", true, false);
      if (suffix.length > 0) { const p = nscMdOptions(); p.grow = 1; p.alignment = alignment; children.push(this.add(2, 0, p, [], nscMdInline(suffix, base, this.issue), new Uint8Array(0))); }
      o.gap = 6; o.main = alignment; o.flags = 8; return this.el(5, o, children);
    }
    o.flags = 2; return this.add(2, 0, o, [], nscMdInline(text, base, this.issue), new Uint8Array(0));
  }
}
class NscMdDiscoveryState {
  opaque = new NscMdOpaque(); code: Uint8Array[] = []; overflow = 0;
  active(): boolean { return this.opaque.active() || this.code.length > 0 || this.overflow > 0; }
  visible(line: Uint8Array): Uint8Array {
    let first = this.active() ? 0 : -1, cursor = 0;
    while (cursor < line.length) {
      if (this.opaque.comment) { if (first < 0) first = cursor; const close = nscMdFind(line, cursor, "-->", false); if (close < 0) return line.subarray(0, first < 0 ? 0 : first); this.opaque.comment = false; cursor = close + 3; continue; }
      const start = nscMdFindByte(line, cursor, 60); if (start < 0) break;
      if (nscMdStarts(line, start, "<!--", false)) { if (first < 0) first = start; const close = nscMdFind(line, start + 4, "-->", false); if (close < 0) { this.opaque.comment = true; break; } cursor = close + 3; continue; }
      const tag = nscMdTag(line, start, false); if (tag === null) { cursor = start + 1; continue; } cursor = start + tag.consumed;
      if (this.opaque.depth > 0) { if (first < 0) first = start; if (!nscMdEqual(tag.name, this.opaque.name, true)) continue; if (tag.closing) { this.opaque.depth--; if (this.opaque.depth === 0) this.opaque.name = new Uint8Array(0); } else if (!tag.selfClosing) this.opaque.depth++; continue; }
      if (tag.kind < 0 && !nscMdName(tag, "details") && !nscMdName(tag, "summary")) { if (first < 0) first = start; if (!tag.closing && !tag.selfClosing && !nscMdVoid(tag.name)) { this.opaque.name = tag.name; this.opaque.depth = 1; } continue; }
      if (tag.kind !== 4 && tag.kind !== 16) continue;
      if (first < 0) first = start; if (tag.selfClosing) continue;
      if (tag.closing) { if (this.overflow > 0) this.overflow--; else if (this.code.length > 0 && nscMdEqual(this.code[this.code.length - 1]!, tag.name, true)) this.code.pop(); }
      else if (this.code.length < 8) this.code.push(tag.name); else this.overflow++;
    } return line.subarray(0, first < 0 ? line.length : first);
  }
}
class NscMdDiscovery {
  output: Uint8Array[] = []; capacity: number; paragraph = false; quote = false;
  constructor(capacity: number) { this.capacity = capacity; }
  append(text: Uint8Array): void {
    if (this.output.length >= this.capacity) return; const image = nscMdLeading(text); if (image === null || image.source.length === 0) return;
    const source = nscMdDecode(image.source); if (source.length > 2048) return;
    for (const existing of this.output) if (nscMdEqual(existing, source, false)) return; this.output.push(source);
  }
  html(trimmed: Uint8Array): boolean {
    if (nscMdStarts(trimmed, 0, "<summary>", true)) { let content = trimmed.subarray(9); const close = nscMdFind(content, 0, "</summary>", true); if (close >= 0) content = content.subarray(0, close); this.append(nscMdTrim(content, " \t", true, true)); this.paragraph = false; return true; }
    const syntax = nscMdTag(trimmed, 0, false); if (syntax !== null && (nscMdName(syntax, "details") || nscMdName(syntax, "summary"))) { this.paragraph = false; return true; }
    const opening = nscMdTag(trimmed, 0, true); if (opening === null || !nscMdBlock(opening)) return false;
    if (opening.kind === 13 || opening.selfClosing) { this.paragraph = false; return true; }
    if (opening.closing) { const suffix = nscMdTrim(trimmed.subarray(opening.consumed), " \t", true, false); if (suffix.length > 0) this.append(suffix); this.paragraph = suffix.length > 0; return true; }
    const single = nscMdSingle(trimmed, opening); if (single !== null) { this.append(nscMdTrim(single, " \t", true, true)); this.paragraph = false; return true; }
    const suffix = nscMdTrim(trimmed.subarray(opening.consumed), " \t", true, false); if (suffix.length > 0) this.append(suffix); this.paragraph = suffix.length > 0; return true;
  }
  collect(source: Uint8Array): Uint8Array[] {
    const lines = new NscMdLines(source), html = new NscMdDiscoveryState(); let fence = false;
    for (;;) {
      const line = lines.next(); if (line === null) break; const trimmed = nscMdTrim(line, " \t", true, true);
      if (html.active()) { html.visible(line); continue; }
      if (nscMdStarts(trimmed, 0, "```", false)) { fence = !fence; this.paragraph = false; this.quote = false; continue; } if (fence) continue;
      const visible = html.visible(line), vt = nscMdTrim(visible, " \t", true, true);
      if (vt.length === 0) {
        if (trimmed.length === 0) { this.paragraph = false; this.quote = false; }
        else { const tag = nscMdTag(trimmed, 0, true); this.paragraph = !(nscMdStarts(trimmed, 0, "<!--", false) || tag !== null && !tag.closing && tag.kind === 16); }
        continue;
      }
      if (nscMdReference(visible)) { this.paragraph = false; this.quote = false; continue; }
      const level = nscMdHeading(vt), marker = nscMdMarker(visible);
      if (level > 0) { this.append(nscMdTrim(vt.subarray(level), " \t#", true, true)); this.paragraph = false; this.quote = false; if (this.output.length >= this.capacity) break; continue; }
      if (marker !== null) { this.append(marker.content); this.paragraph = false; this.quote = false; if (this.output.length >= this.capacity) break; continue; }
      if (vt[0] === 62) { let inner = vt.subarray(1); if (inner.length > 0 && inner[0] === 32) inner = inner.subarray(1); inner = nscMdTrim(inner, " \t", true, true); if (!this.quote && inner.length > 0) this.append(inner); if (inner.length > 0) this.quote = true; this.paragraph = false; if (this.output.length >= this.capacity) break; continue; }
      this.quote = false;
      if (visible.length === line.length) {
        const header = nscMdTable(visible), delimiter = lines.peek(), alignments = delimiter === null ? null : nscMdDelimiters(delimiter);
        if (header !== null && alignments !== null && header.length === alignments.length) {
          for (const cell of header) this.append(cell); lines.next();
          for (;;) { const rowLine = lines.peek(); if (rowLine === null) break; const rowTrim = nscMdTrim(rowLine, " \t", true, true); if (rowTrim.length === 0 || nscMdFindByte(rowTrim, 0, 124) < 0) break; lines.next(); const row = nscMdTable(html.visible(rowLine)); if (row !== null) for (const cell of row) this.append(cell); if (this.output.length >= this.capacity) break; }
          this.paragraph = false; if (this.output.length >= this.capacity) break; continue;
        }
      }
      if (this.html(vt)) { if (this.output.length >= this.capacity) break; continue; }
      if (nscMdRule(vt)) { this.paragraph = false; continue; }
      if (!this.paragraph) this.append(visible); this.paragraph = true; if (this.output.length >= this.capacity) break;
    } return this.output;
  }
}
class NscMdReader {
  bytes: Uint8Array; wire: DataView; at = 0;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.wire = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  take(length: number): Uint8Array { if (length > this.bytes.length - this.at) throw new Error("truncated Markdown packet"); const out = this.bytes.subarray(this.at, this.at + length); this.at += length; return out; }
  u32(): number { const at = this.at; this.take(4); return this.wire.getUint32(at, true); }
  f32(): number { const at = this.at; this.take(4); return this.wire.getFloat32(at, true); }
}
function nscvMarkdownContentPolicy(request: Uint8Array): Uint8Array {
  const reader = new NscMdReader(request), header = reader.take(4);
  if (header[0] !== 22 || header[1]! > 1 || header[2] !== 1 || header[3]! > 1) throw new Error("invalid Markdown operation");
  const sourceLength = reader.u32(), issueLength = reader.u32(), detailsLength = reader.u32(), imageCount = reader.u32(), capacity = reader.u32();
  if (imageCount > 16 || header[3] === 0 && issueLength !== 0 || header[1] === 1 && (header[3] !== 0 || issueLength !== 0 || detailsLength !== 0 || imageCount !== 0) || header[1] === 0 && capacity !== 0) throw new Error("invalid Markdown request facts");
  const source = reader.take(sourceLength), issue = reader.take(issueLength), detailBytes = reader.take(detailsLength), expanded: boolean[] = [], images: NscMdImage[] = [];
  for (const byte of detailBytes) { if (byte > 1) throw new Error("invalid Markdown expanded flag"); expanded.push(byte === 1); }
  for (let i = 0; i < imageCount; i++) { const lower = reader.u32(), upper = reader.u32(), width = reader.f32(), height = reader.f32(), length = reader.u32(); images.push({ source: reader.take(length), lower, upper, width, height }); }
  if (reader.at !== request.length) throw new Error("trailing Markdown bytes");
  if (header[1] === 1) { const sources = new NscMdDiscovery(capacity).collect(source), out = new NscMdWriter(); out.u32(1); out.u32(sources.length); for (const value of sources) { out.u32(value.length); out.add(value); } return out.finish(); }
  const builder = new NscMdBuilder(expanded, header[3] === 1 ? issue : null, images), blocks = builder.blocks(new NscMdLines(source), false), root = builder.container(false, 12, 0, 0, blocks); return nscMdEncode(builder.nodes, root);
}
function nscvMarkdownRecipe(source: Uint8Array, expanded: readonly boolean[], issue: Uint8Array | null, mappings: readonly { source: Uint8Array; image: number; width: number; height: number }[]): number[] {
  const flags: boolean[] = []; for (const flag of expanded) flags.push(flag);
  const images: NscMdImage[] = [];
  for (let i = 0; i < Math.min(mappings.length, 16); i++) {
    const mapping = mappings[i]!, identity = mapping.image;
    if (!Number.isSafeInteger(identity) || identity < 0) throw new Error("Markdown registered image identity is not exact");
    images.push({ source: mapping.source, lower: identity % 4294967296, upper: Math.floor(identity / 4294967296), width: Math.fround(mapping.width), height: Math.fround(mapping.height) });
  }
  const builder = new NscMdBuilder(flags, issue, images), blocks = builder.blocks(new NscMdLines(source), false), root = builder.container(false, 12, 0, 0, blocks), recipe = nscMdEncode(builder.nodes, root), output: number[] = [];
  for (const byte of recipe) output.push(byte); return output;
}

function nscvMarkdownRecipeWords(source: Uint8Array, expanded: readonly boolean[], issue: Uint8Array | null, mappings: readonly { source: Uint8Array; image: { imageLower: number; imageUpper: number }; width: number; height: number }[]): number[] {
  const flags: boolean[] = []; for (const flag of expanded) flags.push(flag);
  const images: NscMdImage[] = [];
  for (let i = 0; i < Math.min(mappings.length, 16); i++) {
    const mapping = mappings[i]!, identity = mapping.image;
    if (!Number.isInteger(identity.imageLower) || !Number.isInteger(identity.imageUpper) || identity.imageLower < 0 || identity.imageLower > 4294967295 || identity.imageUpper < 0 || identity.imageUpper >= 2147483648) throw new Error("Markdown registered image identity is not exact");
    images.push({ source: mapping.source, lower: identity.imageLower, upper: identity.imageUpper, width: Math.fround(mapping.width), height: Math.fround(mapping.height) });
  }
  const builder = new NscMdBuilder(flags, issue, images), blocks = builder.blocks(new NscMdLines(source), false), root = builder.container(false, 12, 0, 0, blocks), recipe = nscMdEncode(builder.nodes, root), output: number[] = [];
  for (const byte of recipe) output.push(byte); return output;
}

/** Discover canonical image sources using the same bounded parser as the view. */
export interface MarkdownImageSource { readonly source: Uint8Array; }
export function markdownImageSources(source: Uint8Array, capacity: number): readonly MarkdownImageSource[] {
  if (!Number.isSafeInteger(capacity) || capacity < 0 || capacity > 16) throw new Error("invalid Markdown image capacity");
  const output: MarkdownImageSource[] = [];
  for (const value of new NscMdDiscovery(capacity).collect(source)) output.push({ source: value });
  return output;
}
