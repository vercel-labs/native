/** Portable byte-preserving code presentation. The host owns source storage,
 * span slices and text measurement; scriptc owns lexical and recipe decisions.
 * Carried counters use exact u64 words, including inactive context slots.
 */
interface NscCodeWord { lowerBits: number; upperBits: number }
interface NscCodeState {
  inTag: boolean; expectName: boolean; opened: boolean;
  htmlComment: boolean; blockComment: boolean; lineComment: boolean;
  preprocessor: boolean; lineStart: boolean;
  depth: NscCodeWord; base: NscCodeWord;
  tagBases: NscCodeWord[]; tagNames: boolean[]; tagOpened: boolean[];
  tagCount: number; elementBases: NscCodeWord[]; elementCount: number;
  previous: number; quote: number; fence: number; fenceLength: number; inlineLength: number;
}
interface NscCodeSpan { start: number; end: number; color: number }
interface NscCodeFence { start: number; end: number; lineEnd: number; closes: boolean }

function nscCodeWordEqual(a: NscCodeWord, b: NscCodeWord): boolean { return a.lowerBits === b.lowerBits && a.upperBits === b.upperBits; }
function nscCodeWordPositive(a: NscCodeWord): boolean { return a.lowerBits !== 0 || a.upperBits !== 0; }
function nscCodeWordAbove(a: NscCodeWord, b: NscCodeWord): boolean { return a.upperBits > b.upperBits || a.upperBits === b.upperBits && a.lowerBits > b.lowerBits; }
function nscCodeWordStep(a: NscCodeWord, increment: boolean): NscCodeWord {
  if (increment) {
    if (a.lowerBits === 4294967295 && a.upperBits === 4294967295) throw new Error("code depth overflow");
    return { lowerBits: (a.lowerBits + 1) >>> 0, upperBits: (a.upperBits + (a.lowerBits === 4294967295 ? 1 : 0)) >>> 0 };
  }
  if (!nscCodeWordPositive(a)) throw new Error("code depth underflow");
  return { lowerBits: (a.lowerBits - 1) >>> 0, upperBits: (a.upperBits - (a.lowerBits === 0 ? 1 : 0)) >>> 0 };
}
function nscCodeReadWord(wire: DataView, at: number): NscCodeWord { return { lowerBits: wire.getUint32(at, true), upperBits: wire.getUint32(at + 4, true) }; }
function nscCodeWriteWord(wire: DataView, at: number, word: NscCodeWord): void { wire.setUint32(at, word.lowerBits, true); wire.setUint32(at + 4, word.upperBits, true); }
function nscCodeSizeWord(value: number): NscCodeWord { return { lowerBits: value % 4294967296, upperBits: Math.floor(value / 4294967296) }; }
function nscCodeReadState(bytes: Uint8Array): NscCodeState {
  if (bytes.length !== 608) throw new Error("invalid code state size");
  const wire = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), flags = wire.getUint32(0, true);
  if (flags > 255 || bytes[20]! > 32 || bytes[21]! > 32 || bytes[23]! > 1 || bytes[23] === 0 && bytes[24] !== 0 || wire.getUint32(28, true) !== 0)
    throw new Error("invalid code state");
  const bases: NscCodeWord[] = [], names: boolean[] = [], opened: boolean[] = [], elements: NscCodeWord[] = [];
  for (let i = 0; i < 32; i++) {
    if (bytes[288 + i]! > 1 || bytes[320 + i]! > 1) throw new Error("invalid code context flags");
    bases.push(nscCodeReadWord(wire, 32 + i * 8)); names.push(bytes[288 + i] === 1);
    opened.push(bytes[320 + i] === 1); elements.push(nscCodeReadWord(wire, 352 + i * 8));
  }
  return { inTag: (flags & 1) !== 0, expectName: (flags & 2) !== 0, opened: (flags & 4) !== 0,
    htmlComment: (flags & 8) !== 0, blockComment: (flags & 16) !== 0, lineComment: (flags & 32) !== 0,
    preprocessor: (flags & 64) !== 0, lineStart: (flags & 128) !== 0,
    depth: nscCodeReadWord(wire, 4), base: nscCodeReadWord(wire, 12),
    tagBases: bases, tagNames: names, tagOpened: opened, tagCount: bytes[20]!, elementBases: elements,
    elementCount: bytes[21]!, previous: bytes[22]!, quote: bytes[23] === 1 ? bytes[24]! : -1,
    fence: bytes[25]!, fenceLength: bytes[26]!, inlineLength: bytes[27]! };
}
function nscCodeWriteState(bytes: Uint8Array, state: NscCodeState): void {
  const wire = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  wire.setUint32(0, (state.inTag ? 1 : 0) | (state.expectName ? 2 : 0) | (state.opened ? 4 : 0) |
    (state.htmlComment ? 8 : 0) | (state.blockComment ? 16 : 0) | (state.lineComment ? 32 : 0) |
    (state.preprocessor ? 64 : 0) | (state.lineStart ? 128 : 0), true);
  nscCodeWriteWord(wire, 4, state.depth); nscCodeWriteWord(wire, 12, state.base);
  bytes[20] = state.tagCount; bytes[21] = state.elementCount; bytes[22] = state.previous;
  bytes[23] = state.quote >= 0 ? 1 : 0; bytes[24] = state.quote >= 0 ? state.quote : 0;
  bytes[25] = state.fence; bytes[26] = state.fenceLength; bytes[27] = state.inlineLength;
  for (let i = 0; i < 32; i++) {
    nscCodeWriteWord(wire, 32 + i * 8, state.tagBases[i]!); bytes[288 + i] = state.tagNames[i] ? 1 : 0;
    bytes[320 + i] = state.tagOpened[i] ? 1 : 0; nscCodeWriteWord(wire, 352 + i * 8, state.elementBases[i]!);
  }
}
function nscCodeAlpha(byte: number): boolean { return byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122; }
function nscCodeDigit(byte: number): boolean { return byte >= 48 && byte <= 57; }
function nscCodeHex(byte: number): boolean { return nscCodeDigit(byte) || byte >= 65 && byte <= 70 || byte >= 97 && byte <= 102; }
function nscCodeIdentifier(byte: number): boolean { return nscCodeAlpha(byte) || byte === 95 || byte === 64 || byte === 36; }
function nscCodeContinue(byte: number): boolean { return nscCodeIdentifier(byte) || nscCodeDigit(byte); }
function nscCodeSpace(byte: number): boolean { return byte === 32 || byte === 9 || byte === 13 || byte === 10; }
function nscCodeStarts(source: Uint8Array, start: number, text: string): boolean {
  if (start + text.length > source.length) return false;
  for (let i = 0; i < text.length; i++) if (source[start + i] !== text.charCodeAt(i)) return false;
  return true;
}
function nscCodeFind(source: Uint8Array, start: number, text: string): number {
  for (let i = start; i + text.length <= source.length; i++) if (nscCodeStarts(source, i, text)) return i;
  return -1;
}
function nscCodeWordIn(source: Uint8Array, start: number, end: number, list: string, ignoreCase: boolean): boolean {
  let at = 0;
  while (at < list.length) {
    let stop = at; while (stop < list.length && list.charCodeAt(stop) !== 32) stop++;
    if (stop - at === end - start) {
      let equal = true;
      for (let i = 0; i < end - start; i++) {
        let a = source[start + i]!, b = list.charCodeAt(at + i);
        if (ignoreCase) { if (a >= 65 && a <= 90) a += 32; if (b >= 65 && b <= 90) b += 32; }
        if (a !== b) { equal = false; break; }
      }
      if (equal) return true;
    }
    at = stop + 1;
  }
  return false;
}
function nscCodePush(spans: NscCodeSpan[], length: number, start: number, end: number, color: number): boolean {
  if (end <= start) return true;
  if (spans.length > 0) {
    const previous = spans[spans.length - 1]!;
    if (previous.color === color && previous.end === start) { previous.end = end; return true; }
  }
  if (spans.length + 1 >= 32) { spans.push({ start, end: length, color: 0 }); return false; }
  spans.push({ start, end, color }); return true;
}
function nscCodeStructural(language: number, source: Uint8Array, end: number): number {
  let cursor = end; while (cursor < source.length && (source[cursor] === 32 || source[cursor] === 9)) cursor++;
  if (cursor >= source.length || source[cursor] === 10) return -1;
  if (source[cursor] === 40 && language !== 0 && language !== 4) return 4;
  if (language === 12 && source[cursor] === 58) return 5;
  if (language === 12 && source[cursor] === 123) return 3;
  return -1;
}
function nscCodeHtml(language: number): boolean { return language === 11 || language === 14 || language === 15; }
function nscCodeScript(language: number): number { return language === 14 ? 2 : language === 11 || language === 15 ? 3 : language; }
function nscCodePushTag(state: NscCodeState): void {
  if (!state.inTag || state.tagCount >= 32) return;
  state.tagBases[state.tagCount] = state.base; state.tagNames[state.tagCount] = state.expectName;
  state.tagOpened[state.tagCount] = state.opened; state.tagCount++;
}
function nscCodeRestoreTag(state: NscCodeState): boolean {
  if (state.tagCount === 0) return false;
  state.tagCount--; state.inTag = true; state.base = state.tagBases[state.tagCount]!;
  state.expectName = state.tagNames[state.tagCount]!; state.opened = state.tagOpened[state.tagCount]!; return true;
}
function nscCodeTagOpener(source: Uint8Array, index: number, language: number, state: NscCodeState): boolean {
  if (index + 1 >= source.length) return false;
  const next = source[index + 1]!;
  if (!nscCodeIdentifier(next) && next !== 47 && next !== 33 && next !== 63 && next !== 62) return false;
  if (language === 11 && !nscCodeWordPositive(state.depth)) return true;
  if (!state.inTag && state.elementCount > 0 && nscCodeWordEqual(state.depth, state.elementBases[state.elementCount - 1]!)) return true;
  let cursor = index, previous = state.previous;
  while (cursor > 0) {
    cursor--; const byte = source[cursor]!; if (nscCodeSpace(byte)) continue;
    if (nscCodeContinue(byte)) {
      const end = cursor + 1; while (cursor > 0 && nscCodeContinue(source[cursor - 1]!)) cursor--;
      return nscCodeWordIn(source, cursor, end, "return throw yield", false);
    }
    previous = byte; break;
  }
  return previous === 0 || previous === 123 || previous === 40 || previous === 91 || previous === 44 ||
    previous === 58 || previous === 63 || previous === 61 || previous === 62 || previous === 33 ||
    previous === 38 || previous === 124 || previous === 59;
}
function nscCodePrevious(state: NscCodeState, source: Uint8Array, start: number, end: number): void {
  let cursor = end; while (cursor > start) { cursor--; if (!nscCodeSpace(source[cursor]!)) { state.previous = source[cursor]!; return; } }
}
function nscCodeEscapes(language: number, state: NscCodeState, quote: number): boolean {
  if (language === 11) return nscCodeWordPositive(state.depth);
  if (language === 14 || language === 15) return !state.inTag || nscCodeWordAbove(state.depth, state.base);
  if (language === 6) return quote !== 39;
  if (language === 5) return quote === 34;
  return language !== 13;
}
function nscCodeQuote(language: number, byte: number): boolean {
  if (language === 0 || language === 11 || language === 16) return false;
  if (language === 4 || language === 8) return byte === 34;
  return byte === 34 || byte === 39 || (language === 6 || language === 2 || language === 3 || language === 14 || language === 15 || language === 10) && byte === 96;
}
function nscCodeComment(language: number, source: Uint8Array, at: number): boolean {
  if (language === 1 || language === 2 || language === 3 || language === 14 || language === 15 || language === 8 || language === 9 || language === 10)
    return nscCodeStarts(source, at, "//");
  if (language === 6 || language === 7) return source[at] === 35;
  if (language === 5) return source[at] === 35 && (at === 0 || nscCodeSpace(source[at - 1]!));
  return language === 13 && nscCodeStarts(source, at, "--");
}
function nscCodeBlocks(language: number): boolean { return language === 1 || language === 2 || language === 3 || language === 14 || language === 15 || language === 8 || language === 9 || language === 10 || language === 12 || language === 13; }
function nscCodeYamlKey(source: Uint8Array, start: number): number {
  if (start >= source.length) return -1;
  if ((source[start] === 45 || source[start] === 63) && start + 1 < source.length && (source[start + 1] === 32 || source[start + 1] === 9)) return -1;
  let before = start; while (before > 0 && (source[before - 1] === 32 || source[before - 1] === 9)) before--;
  if (before > 0) { const b = source[before - 1]!; if (b !== 10 && b !== 13 && b !== 123 && b !== 91 && b !== 44 && b !== 45 && b !== 63) return -1; }
  let quote = -1, cursor = start;
  while (cursor < source.length) {
    const byte = source[cursor]!;
    if (quote >= 0) {
      if (quote === 34 && byte === 92 && cursor + 1 < source.length) { cursor += 2; continue; }
      if (byte === quote) { if (quote === 39 && cursor + 1 < source.length && source[cursor + 1] === 39) { cursor += 2; continue; } quote = -1; }
      cursor++; continue;
    }
    if (byte === 34 || byte === 39) { quote = byte; cursor++; continue; }
    if (byte === 58) {
      const next = cursor + 1 < source.length ? source[cursor + 1]! : -1;
      if (next !== -1 && !nscCodeSpace(next) && next !== 44 && next !== 125 && next !== 93) { cursor++; continue; }
      let end = cursor; while (end > start && (source[end - 1] === 32 || source[end - 1] === 9)) end--;
      return end > start ? end : -1;
    }
    if (byte === 10 || byte === 13 || byte === 44 || byte === 125 || byte === 93) return -1;
    cursor++;
  }
  return -1;
}
function nscCodeScalarLength(byte: number): number { return byte < 128 ? 1 : byte >= 192 && byte < 224 ? 2 : byte >= 224 && byte < 240 ? 3 : byte >= 240 && byte < 248 ? 4 : 0; }
function nscCodeRustChar(source: Uint8Array, start: number): number {
  if (start + 3 > source.length || source[start] !== 39) return 0;
  let cursor = start + 1;
  if (source[cursor] === 92) {
    cursor++; if (cursor >= source.length) return 0;
    if (source[cursor] === 120) { cursor++; if (cursor + 2 > source.length || !nscCodeHex(source[cursor]!) || !nscCodeHex(source[cursor + 1]!)) return 0; cursor += 2; }
    else if (source[cursor] === 117) {
      cursor++; if (cursor >= source.length || source[cursor] !== 123) return 0; cursor++; let digits = 0;
      while (cursor < source.length && source[cursor] !== 125) { const b = source[cursor++]!; if (b === 95) continue; if (!nscCodeHex(b)) return 0; digits++; }
      if (digits === 0 || cursor >= source.length) return 0; cursor++;
    } else cursor++;
  } else {
    const length = nscCodeScalarLength(source[cursor]!); if (length === 0 || cursor + length > source.length) return 0;
    const first = source[cursor]!;
    for (let i = 1; i < length; i++) if (source[cursor + i]! < 128 || source[cursor + i]! > 191) return 0;
    if (length === 2 && first < 194 || length === 3 && (first === 224 && source[cursor + 1]! < 160 || first === 237 && source[cursor + 1]! >= 160) || length === 4 && (first > 244 || first === 240 && source[cursor + 1]! < 144 || first === 244 && source[cursor + 1]! > 143)) return 0;
    cursor += length;
  }
  return cursor < source.length && source[cursor] === 39 ? cursor + 1 - start : 0;
}

function nscCodeKeywords(language: number): string {
  switch (language) {
    case 2:
    case 14:
      return "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static switch throw try typeof var void while with yield";
    case 3:
    case 15:
      return "abstract any as asserts async await bigint boolean break case catch class const constructor continue declare default delete do else enum export extends finally for from function get if implements import in infer interface instanceof is keyof let module namespace never new number object of override private protected public readonly require return satisfies set static string super switch symbol this throw try type typeof undefined unique unknown var void while with yield";
    case 4:
      return "";
    case 5:
      return "";
    case 6:
      return "case coproc do done elif else esac fi for function if in select then time until while";
    case 7:
      return "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield";
    case 8:
      return "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while";
    case 9:
      return "abstract alignas alignof asm auto break case catch class const constexpr continue default delete do else enum explicit export extends extern final finally for foreach friend goto if implements import in inline interface internal namespace native new noexcept operator override package private protected public register reinterpret_cast return sealed signed sizeof static strictfp struct switch synchronized template this throw throws trait transient try typedef typeid typename union unsigned using virtual volatile while";
    case 10:
      return "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var";
    case 11:
      return "";
    case 12:
      return "and important inherit initial none not only or revert unset";
    case 13:
      return "add all alter and any as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full grant group having in index inner insert intersect into is join key left like limit not null on or order outer primary references right rollback row select set table then union unique update values view when where with";
    case 16:
      return "";
    default: return "";
  }
}

function nscCodeTypes(language: number): string {
  switch (language) {
    case 8:
      return "bool char str String Vec Option Result Box i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64";
    case 9:
      return "bool boolean byte char decimal double float int long object sbyte short string uint ulong ushort void";
    case 10:
      return "any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr";
    case 2:
    case 3:
    case 14:
    case 15:
      return "Array BigInt Boolean Date Error Map Number Object Promise RegExp Set String Symbol";
    case 7:
      return "bool bytes dict float int list object set str tuple";
    default: return "";
  }
}
function nscCodeColor(language: number, source: Uint8Array, start: number, end: number): number {
  if (end > start && source[start] === 64) return 4;
  if (language === 1) {
    if (nscCodeWordIn(source, start, end, "addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while", false)) return 2;
    if (nscCodeWordIn(source, start, end, "anyerror bool comptime_float comptime_int f16 f32 f64 f80 f128 false i8 i16 i32 i64 i128 isize noreturn null true type u8 u16 u32 u64 u128 undefined usize void", false)) return 3;
    return -1;
  }
  if (language === 7 && nscCodeWordIn(source, start, end, "True False None", false)) return 3;
  if (language === 5 && nscCodeWordIn(source, start, end, "true false null yes no on off", true)) return 3;
  if (nscCodeWordIn(source, start, end, "true false null nil none undefined this self super", language === 13)) return 3;
  if (nscCodeWordIn(source, start, end, nscCodeKeywords(language), language === 13)) return 2;
  if (nscCodeWordIn(source, start, end, nscCodeTypes(language), false)) return 3;
  return -1;
}

function nscCodeRun(source: Uint8Array, start: number, byte: number): number {
  let end = start; while (end < source.length && source[end] === byte) end++; return end - start;
}
function nscCodeFenceLine(source: Uint8Array, start: number, state: NscCodeState): NscCodeFence | null {
  let marker = start, indent = 0;
  while (marker < source.length && indent < 3 && source[marker] === 32) { marker++; indent++; }
  if (marker >= source.length || source[marker] !== 96 && source[marker] !== 126) return null;
  const run = nscCodeRun(source, marker, source[marker]!); if (run < 3) return null;
  const newline = nscCodeFind(source, marker + run, "\n"), lineEnd = newline >= 0 ? newline + 1 : source.length;
  if (state.fence === 0) return { start: marker, end: marker + run, lineEnd, closes: false };
  if (source[marker] !== state.fence || run < state.fenceLength) return null;
  const suffixEnd = newline >= 0 ? newline : source.length;
  for (let i = marker + run; i < suffixEnd; i++) if (source[i] !== 32 && source[i] !== 9 && source[i] !== 13) return null;
  return { start: marker, end: marker + run, lineEnd, closes: true };
}
function nscCodeListMarker(source: Uint8Array, start: number): number {
  if (start >= source.length) return -1;
  const b = source[start]!;
  if ((b === 45 || b === 43 || b === 42) && start + 1 < source.length && (source[start + 1] === 32 || source[start + 1] === 9)) return start + 1;
  if (!nscCodeDigit(b)) return -1;
  let end = start + 1; while (end < source.length && nscCodeDigit(source[end]!)) end++;
  if (end >= source.length || source[end] !== 46 && source[end] !== 41 || end + 1 >= source.length || source[end + 1] !== 32 && source[end + 1] !== 9) return -1;
  return end + 1;
}
function nscCodeInlineEnd(source: Uint8Array, start: number, delimiter: number): number {
  let cursor = start;
  while (cursor < source.length) {
    if (source[cursor] === 96) { const run = nscCodeRun(source, cursor, 96); if (run === delimiter) return cursor + run; cursor += run; }
    else cursor++;
  }
  return -1;
}
function nscCodeMarkdown(source: Uint8Array, state: NscCodeState): NscCodeSpan[] {
  const spans: NscCodeSpan[] = []; let full = false, index = 0;
  const push = (start: number, end: number, color: number): void => { if (!full && !nscCodePush(spans, source.length, start, end, color)) full = true; };
  while (index < source.length) {
    if (state.lineStart) {
      const fence = nscCodeFenceLine(source, index, state);
      if (fence !== null) {
        push(index, fence.start, 0); push(fence.start, fence.end, 2); push(fence.end, fence.lineEnd, fence.closes ? 0 : 6);
        state.fence = fence.closes ? 0 : source[fence.start]!; state.fenceLength = fence.closes ? 0 : Math.min(fence.end - fence.start, 255);
        state.lineStart = fence.lineEnd > fence.end && source[fence.lineEnd - 1] === 10; index = fence.lineEnd; continue;
      }
      if (state.fence !== 0) {
        const newline = nscCodeFind(source, index, "\n"), end = newline >= 0 ? newline + 1 : source.length;
        push(index, end, 3); state.lineStart = newline >= 0; index = end; continue;
      }
      let content = index, indent = 0; while (content < source.length && indent < 3 && source[content] === 32) { content++; indent++; }
      push(index, content, 0);
      if (content < source.length && source[content] === 35) {
        const run = nscCodeRun(source, content, 35);
        if (run <= 6 && content + run < source.length && (source[content + run] === 32 || source[content + run] === 9)) { push(content, content + run, 2); index = content + run; state.lineStart = false; continue; }
      }
      if (content < source.length && source[content] === 62) { push(content, content + 1, 2); index = content + 1; state.lineStart = false; continue; }
      const marker = nscCodeListMarker(source, content);
      if (marker >= 0) { push(content, marker, 2); index = marker; state.lineStart = false; continue; }
      index = content; state.lineStart = false; if (index >= source.length) break;
    }
    if (source[index] === 10) { push(index, index + 1, 0); index++; state.lineStart = true; continue; }
    if (state.htmlComment || nscCodeStarts(source, index, "<!--")) {
      const close = nscCodeFind(source, index + (state.htmlComment ? 0 : 4), "-->"), end = close >= 0 ? close + 3 : source.length;
      push(index, end, 1); state.htmlComment = close < 0; index = end; continue;
    }
    if (state.inlineLength !== 0) {
      const end = nscCodeInlineEnd(source, index, state.inlineLength); push(index, end >= 0 ? end : source.length, 3);
      if (end >= 0) state.inlineLength = 0; index = end >= 0 ? end : source.length; continue;
    }
    if (source[index] === 96) {
      const run = nscCodeRun(source, index, 96), end = nscCodeInlineEnd(source, index + run, run);
      push(index, end >= 0 ? end : source.length, 3); state.inlineLength = end >= 0 ? 0 : Math.min(run, 255); index = end >= 0 ? end : source.length; continue;
    }
    if (source[index] === 92 && index + 1 < source.length) { push(index, index + 2, 6); index += 2; continue; }
    if (nscCodeStarts(source, index, "![")) { push(index, index + 2, 2); index += 2; continue; }
    if (source[index] === 91 || source[index] === 93) { push(index, index + 1, 5); index++; continue; }
    if (source[index] === 40 && index > 0 && source[index - 1] === 93) { const close = nscCodeFind(source, index + 1, ")"), end = close >= 0 ? close + 1 : source.length; push(index, end, 3); index = end; continue; }
    if (source[index] === 60 && (nscCodeStarts(source, index, "<http://") || nscCodeStarts(source, index, "<https://"))) { const close = nscCodeFind(source, index + 1, ">"), end = close >= 0 ? close + 1 : source.length; push(index, end, 3); index = end; continue; }
    if (source[index] === 42 || source[index] === 95 || source[index] === 126) { const run = Math.min(nscCodeRun(source, index, source[index]!), 2); push(index, index + run, 2); index += run; continue; }
    const start = index;
    while (index < source.length && source[index] !== 10 && source[index] !== 96 && source[index] !== 92 && source[index] !== 91 && source[index] !== 93 && source[index] !== 40 && source[index] !== 60 && source[index] !== 42 && source[index] !== 95 && source[index] !== 126) index++;
    if (index === start) index++; push(start, index, 0);
  }
  return spans;
}

function nscCodeHighlight(source: Uint8Array, language: number, state: NscCodeState): NscCodeSpan[] {
  const spans: NscCodeSpan[] = [];
  if (source.length === 0) return spans;
  if (language === 0) { spans.push({ start: 0, end: source.length, color: 0 }); return spans; }
  if (language === 16) return nscCodeMarkdown(source, state);
  let index = 0, full = false;
  while (index < source.length) {
    const start = index, byte = source[index]!; let color = 0;
    if (byte === 10) { state.lineComment = false; state.preprocessor = false; }
    if (state.lineComment || state.preprocessor) {
      const comment = state.lineComment; while (index < source.length && source[index] !== 10) index++;
      if (comment) state.lineComment = index === source.length; else state.preprocessor = index === source.length; color = comment ? 1 : 6;
    } else if (state.htmlComment || state.blockComment) {
      const html = state.htmlComment, close = nscCodeFind(source, index, html ? "-->" : "*/"); index = close >= 0 ? close + (html ? 3 : 2) : source.length;
      if (close >= 0) { if (html) state.htmlComment = false; else state.blockComment = false; } color = 1;
    } else if (state.quote >= 0) {
      const quote = state.quote; let closed = false;
      while (index < source.length) {
        if (source[index] === 92 && nscCodeEscapes(language, state, quote) && index + 1 < source.length) { index += 2; continue; }
        const b = source[index++]!; if (b === quote) { closed = true; break; }
      }
      if (closed) state.quote = -1; color = 3;
    } else if (language === 11 && nscCodeStarts(source, index, "<!--")) {
      const close = nscCodeFind(source, index + 4, "-->"); index = close >= 0 ? close + 3 : source.length; if (close < 0) state.htmlComment = true; color = 1;
    } else if (nscCodeBlocks(language) && nscCodeStarts(source, index, "/*")) {
      const close = nscCodeFind(source, index + 2, "*/"); index = close >= 0 ? close + 2 : source.length; if (close < 0) state.blockComment = true; color = 1;
    } else if (nscCodeComment(language, source, index)) {
      while (index < source.length && source[index] !== 10) index++; state.lineComment = index === source.length; color = 1;
    } else if (language === 9 && byte === 35) {
      while (index < source.length && source[index] !== 10) index++; state.preprocessor = index === source.length; color = 6;
    } else if (nscCodeHtml(language) && byte === 60 && nscCodeTagOpener(source, index, language, state)) {
      index++; const opener = index < source.length ? source[index]! : 0, closing = opener === 47; if (closing) index++;
      nscCodePushTag(state); state.inTag = true; state.expectName = true; state.base = state.depth; state.opened = false;
      if (closing) { if (state.elementCount > 0) state.elementCount--; }
      else if ((nscCodeIdentifier(opener) || opener === 62) && state.elementCount < 32) { state.elementBases[state.elementCount] = state.depth; state.elementCount++; state.opened = true; }
    } else if (nscCodeHtml(language) && state.inTag && nscCodeWordEqual(state.depth, state.base) && byte === 62) {
      if (state.opened && index > 0 && source[index - 1] === 47 && state.elementCount > 0) state.elementCount--;
      index++; if (!nscCodeRestoreTag(state)) { state.inTag = false; state.expectName = false; state.opened = false; }
    } else if (nscCodeHtml(language) && byte === 123) { index++; state.depth = nscCodeWordStep(state.depth, true); }
    else if (nscCodeHtml(language) && nscCodeWordPositive(state.depth) && byte === 125) { index++; state.depth = nscCodeWordStep(state.depth, false); }
    else {
      const rust = language === 8 ? nscCodeRustChar(source, index) : 0, yamlKey = language === 5 ? nscCodeYamlKey(source, index) : -1;
      if (rust > 0) { index += rust; color = 3; }
      else if (yamlKey >= 0) { index = yamlKey; color = 5; }
      else if (language === 5 && (nscCodeStarts(source, index, "---") || nscCodeStarts(source, index, "...")) && (index + 3 === source.length || nscCodeSpace(source[index + 3]!) || source[index + 3] === 35)) { index += 3; color = 2; }
      else if (language === 5 && (byte === 38 || byte === 42 || byte === 33 || byte === 37)) {
        index++; while (index < source.length && !nscCodeSpace(source[index]!) && source[index] !== 44 && source[index] !== 91 && source[index] !== 93 && source[index] !== 123 && source[index] !== 125) index++; color = 6;
      } else if (language === 5 && byte === 126) { index++; color = 3; }
      else if (language === 5 && (byte === 124 || byte === 62)) { index++; color = 2; }
      else if (nscCodeQuote(language, byte) || nscCodeHtml(language) && (state.inTag || nscCodeWordPositive(state.depth)) && (byte === 34 || byte === 39 || byte === 96)) {
        const quote = byte; index++; let closed = false;
        while (index < source.length) {
          if (source[index] === 92 && nscCodeEscapes(language, state, quote) && index + 1 < source.length) { index += 2; continue; }
          const b = source[index++]!; if (b === quote) { closed = true; break; }
        }
        if (!closed) state.quote = quote; color = 3;
      } else if (nscCodeDigit(byte)) {
        index++; while (index < source.length && (nscCodeAlpha(source[index]!) || nscCodeDigit(source[index]!) || source[index] === 95 || source[index] === 46)) index++; color = 3;
      } else if (nscCodeIdentifier(byte)) {
        index++; while (index < source.length && (nscCodeContinue(source[index]!) || (language === 12 || nscCodeHtml(language) && state.inTag) && source[index] === 45)) index++;
        if (nscCodeHtml(language) && state.inTag && state.expectName) { color = 3; state.expectName = false; }
        else if (nscCodeHtml(language) && state.inTag && nscCodeWordEqual(state.depth, state.base)) color = 4;
        else {
          const grammar = nscCodeHtml(language) && (state.inTag || nscCodeWordPositive(state.depth) || language === 14 || language === 15) ? nscCodeScript(language) : language;
          const classified = nscCodeColor(grammar, source, start, index), structural = classified >= 0 ? classified : nscCodeStructural(grammar, source, index); color = structural >= 0 ? structural : 0;
        }
      } else index++;
    }
    if (nscCodeHtml(language)) nscCodePrevious(state, source, start, index);
    if (!full && !nscCodePush(spans, source.length, start, index, color)) full = true;
  }
  return spans;
}

/** Operation 20/0: language ordinal, u64 source length, 608-byte complete
 * carried state and source bytes. Result copies state, count and 24-byte
 * spans (u64 start/end, color ordinal, reserved zero word). Source stays
 * host-owned; no borrowed compiler allocation crosses this boundary.
 */
function nscvCodeContentPolicy(request: Uint8Array): Uint8Array {
  if (request[1] === 1) return nscCodeRecipe(request);
  if (request[1] === 2) return nscCodeChunkPacket(request);
  if (request[1] === 3) return nscCodeSpanBudget(request);
  if (request.length < 624 || request[0] !== 20 || request[1] !== 0 || request[2]! > 16 || request[3] !== 0)
    throw new Error("invalid code content packet");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (wire.getUint32(12, true) !== 0 || !nscCodeWordEqual(nscCodeReadWord(wire, 4), nscCodeSizeWord(request.length - 624)))
    throw new Error("invalid code content length");
  const state = nscCodeReadState(request.subarray(16, 624)), source = request.subarray(624);
  const spans = nscCodeHighlight(source, request[2]!, state), result = new Uint8Array(616 + spans.length * 24), out = new DataView(result.buffer);
  nscCodeWriteState(result.subarray(0, 608), state); out.setUint32(608, spans.length, true);
  for (let i = 0; i < spans.length; i++) {
    const span = spans[i]!, at = 616 + i * 24;
    nscCodeWriteWord(out, at, nscCodeSizeWord(span.start)); nscCodeWriteWord(out, at + 8, nscCodeSizeWord(span.end)); out.setUint32(at + 16, span.color, true);
  }
  return result;
}

function nscCodeLineCount(source: Uint8Array, editable: boolean): number {
  if (source.length === 0) return 1;
  let lines = editable || source[source.length - 1] !== 10 ? 1 : 0;
  for (let i = 0; i < source.length; i++) if (source[i] === 10) lines++;
  return lines;
}
function nscCodeChunkEnd(source: Uint8Array, start: number, wrap: boolean): number {
  let cursor = start, lines = 0, units = 0;
  while (cursor < source.length) {
    if (!wrap) {
      if (source[cursor++] === 10 && ++lines >= 128 && cursor < source.length) return cursor;
    } else {
      const lineStart = cursor;
      while (cursor < source.length && source[cursor] !== 10) cursor++;
      const lineEnd = cursor;
      let scalars = 0, at = lineStart;
      while (at < lineEnd) { at += Math.min(nscCodeScalarLength(source[at]!) || 1, lineEnd - at); scalars++; }
      const lineUnits = Math.max(1, scalars);
      if (units + lineUnits > 128 && lineStart > start) return lineStart;
      units += lineUnits; lines++;
      if (cursor < source.length) cursor++;
      if (lines >= 128 && cursor < source.length) return cursor;
    }
  }
  return source.length;
}
function nscCodeChunkCount(source: Uint8Array, wrap: boolean): number {
  if (source.length === 0) return 1;
  let count = 0, start = 0;
  while (start < source.length) { start = nscCodeChunkEnd(source, start, wrap); count++; }
  return count;
}

/** Recipe request: 48-byte header, source and two u64 line-index arrays.
 * The copied 64-byte result owns numbering/diff admission, content choice,
 * scroll axes and chunk count. Invalid indices mark construction failed;
 * every valid duplicate contributes the same bit as the native reference.
 */
function nscCodeRecipe(request: Uint8Array): Uint8Array {
  if (request.length < 48 || request[0] !== 20 || request[1] !== 1 || request[2]! > 15 || request[3] !== 0)
    throw new Error("invalid code recipe packet");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (wire.getUint32(12, true) !== 0 || wire.getUint32(32, true) !== 0 || wire.getUint32(36, true) !== 0 || wire.getUint32(40, true) !== 0 || wire.getUint32(44, true) !== 0)
    throw new Error("invalid code recipe reserved words");
  // Lengths describe actual memory extents, so they may become exact safe
  // numbers after checking both words against this packet's total capacity.
  const size = (at: number): number => {
    const value = wire.getUint32(at, true) + wire.getUint32(at + 4, true) * 4294967296;
    if (!Number.isSafeInteger(value) || value > request.length) throw new Error("invalid code recipe extent");
    return value;
  };
  const length = size(4), addedCount = size(16), removedCount = size(24);
  if (48 + length + (addedCount + removedCount) * 8 !== request.length) throw new Error("invalid code recipe length");
  const source = request.subarray(48, 48 + length), editable = (request[2]! & 1) !== 0, wrap = (request[2]! & 2) !== 0;
  const lines = nscCodeLineCount(source, editable), terminal = editable && length > 0 && source[length - 1] === 10;
  const numbered = (request[2]! & 4) !== 0 && lines - (terminal ? 1 : 0) <= (editable ? 10000 : 128);
  const result = new Uint8Array(64), out = new DataView(result.buffer);
  let invalid = false;
  for (let lane = 0; lane < 2; lane++) {
    const count = lane === 0 ? addedCount : removedCount, start = 48 + length + (lane === 0 ? 0 : addedCount * 8);
    for (let i = 0; i < count; i++) {
      const line = nscCodeReadWord(wire, start + i * 8);
      if (line.upperBits !== 0 || line.lowerBits === 0 || line.lowerBits > 128) { invalid = true; continue; }
      const bit = line.lowerBits - 1, at = 16 + lane * 16 + Math.floor(bit / 32) * 4;
      out.setUint32(at, out.getUint32(at, true) | (1 << (bit % 32)), true);
    }
  }
  let decorated = false;
  for (let i = 0; i < 4; i++) {
    const added = out.getUint32(16 + i * 4, true), removed = out.getUint32(32 + i * 4, true);
    if ((added & removed) !== 0) invalid = true;
    if (!editable && lines > 128) { out.setUint32(16 + i * 4, 0, true); out.setUint32(32 + i * 4, 0, true); }
    else if (added !== 0 || removed !== 0) decorated = true;
  }
  result[0] = (numbered ? 1 : 0) | (decorated ? 2 : 0) | (invalid ? 4 : 0);
  if (numbered) { let remaining = lines, digits = 1; while (remaining >= 10) { remaining = Math.floor(remaining / 10); digits++; } result[1] = digits; }
  const height = (request[2]! & 8) !== 0;
  result[2] = editable ? 0 : wrap ? height ? 1 : 0 : height ? 3 : 2;
  result[3] = editable ? 2 : numbered || decorated ? 1 : 0;
  nscCodeWriteWord(out, 8, nscCodeSizeWord(lines));
  nscCodeWriteWord(out, 48, nscCodeSizeWord(nscCodeChunkCount(source, wrap)));
  return result;
}

/** Chunk request: 16-byte header (wrap, u64 length), then exact source.
 * Result is a u64 count and its complete, contiguous u64 chunk ends.
 */
function nscCodeChunkPacket(request: Uint8Array): Uint8Array {
  if (request.length < 16 || request[0] !== 20 || request[1] !== 2 || request[2]! > 1 || request[3] !== 0)
    throw new Error("invalid code chunk packet");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (wire.getUint32(12, true) !== 0 || !nscCodeWordEqual(nscCodeReadWord(wire, 4), nscCodeSizeWord(request.length - 16))) throw new Error("invalid code chunk length");
  const source = request.subarray(16), wrap = request[2] === 1, count = nscCodeChunkCount(source, wrap);
  const result = new Uint8Array(8 + count * 8), out = new DataView(result.buffer);
  nscCodeWriteWord(out, 0, nscCodeSizeWord(count));
  let start = 0;
  for (let i = 0; i < count; i++) { start = nscCodeChunkEnd(source, start, wrap); nscCodeWriteWord(out, 8 + i * 8, nscCodeSizeWord(start)); }
  return result;
}
function nscCodeWordAdd(a: NscCodeWord, b: NscCodeWord): NscCodeWord {
  const sum = a.lowerBits + b.lowerBits, upper = a.upperBits + b.upperBits + (sum >= 4294967296 ? 1 : 0);
  if (upper >= 4294967296) throw new Error("code span budget overflow");
  return { lowerBits: sum >>> 0, upperBits: upper };
}
function nscCodeSpanBudget(request: Uint8Array): Uint8Array {
  if (request.length !== 32 || request[0] !== 20 || request[1] !== 3 || request[2] !== 0 || request[3] !== 0)
    throw new Error("invalid code span budget packet");
  const wire = new DataView(request.buffer, request.byteOffset, request.byteLength);
  if (wire.getUint32(4, true) !== 0) throw new Error("invalid code span budget reserved word");
  const used = nscCodeReadWord(wire, 8), remaining = nscCodeWordStep(nscCodeReadWord(wire, 16), false), spans = nscCodeReadWord(wire, 24);
  if (spans.upperBits !== 0 || spans.lowerBits === 0 || spans.lowerBits > 32) throw new Error("invalid code span count");
  const total = nscCodeWordAdd(nscCodeWordAdd(used, spans), remaining), plain = nscCodeWordAbove(total, { lowerBits: 512, upperBits: 0 });
  const result = new Uint8Array(24), out = new DataView(result.buffer);
  nscCodeWriteWord(out, 0, nscCodeWordAdd(used, plain ? { lowerBits: 1, upperBits: 0 } : spans));
  nscCodeWriteWord(out, 8, remaining); result[16] = plain ? 1 : 0;
  return result;
}
