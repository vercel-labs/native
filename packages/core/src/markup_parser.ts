/** Runtime expression grammar (106). The parser owns byte spans, post-order
 * trees, limits and diagnostics. Exact i64/f32 literal conversion is a pure
 * native capability: an unknown admission requests one span, then parsing
 * resumes with its result. No numeric value or borrowed pointer crosses the
 * copied protocol. The compile-time frontend remains separately callable.
 * Node records: kind/function/argc/bool, lhs/rhs/args[4], comparison/reserved,
 * offset:u16, text-start:u16, text-length:u16, reserved:u16.
 */
type NscMarkupParser = {
  parse_source: Uint8Array; parse_admissions: Uint8Array; parse_nodes: Uint8Array;
  parse_cursor: number; parse_depth: number; parse_count: number;
  parse_status: number; parse_error: number; parse_offset: number;
  parse_number_start: number; parse_number_length: number;
};
function nscmpFail(s: NscMarkupParser, offset: number, code: number): number {
  if (s.parse_status === 0) { s.parse_status = 1; s.parse_error = code; s.parse_offset = offset; }
  return 0;
}
function nscmpStart(byte: number): boolean {
  return byte >= 97 && byte <= 122 || byte >= 65 && byte <= 90 || byte === 95;
}
function nscmpIdentifier(byte: number): boolean { return nscmpStart(byte) || byte >= 48 && byte <= 57; }
function nscmpDigit(byte: number): boolean { return byte >= 48 && byte <= 57; }
function nscmpSpace(s: NscMarkupParser): void {
  while (s.parse_cursor < s.parse_source.length) {
    const b = s.parse_source[s.parse_cursor]!;
    if (b !== 32 && b !== 9 && b !== 13 && b !== 10) break;
    s.parse_cursor++;
  }
}
function nscmpMatch(s: NscMarkupParser, token: string, keyword: boolean): boolean {
  if (s.parse_cursor + token.length > s.parse_source.length) return false;
  for (let i = 0; i < token.length; i++) if (s.parse_source[s.parse_cursor + i] !== token.charCodeAt(i)) return false;
  const end = s.parse_cursor + token.length;
  if (keyword && end < s.parse_source.length && nscmpIdentifier(s.parse_source[end]!)) return false;
  s.parse_cursor = end; return true;
}
function nscmpEnter(s: NscMarkupParser, at: number): boolean {
  s.parse_depth++;
  if (s.parse_depth <= 16) return true;
  nscmpFail(s, at, 4); return false;
}
function nscmpNode(s: NscMarkupParser, kind: number, offset: number, lhs: number, rhs: number,
  start: number, length: number, fn: number, args: readonly number[], boolean: boolean): number {
  if (s.parse_status !== 0) return 0;
  if (s.parse_count >= 64) return nscmpFail(s, offset, 3);
  const index = s.parse_count++, at = index * 20, out = s.parse_nodes;
  out[at] = kind; out[at + 1] = fn; out[at + 2] = args.length; out[at + 3] = boolean ? 1 : 0;
  out[at + 4] = lhs; out[at + 5] = rhs;
  for (let i = 0; i < args.length; i++) out[at + 6 + i] = args[i]!;
  const wire = new DataView(out.buffer);
  wire.setUint16(at + 12, offset, true); wire.setUint16(at + 14, start, true); wire.setUint16(at + 16, length, true);
  return index;
}
function nscmpBinary(s: NscMarkupParser, level: number): number {
  const entered = level === 0;
  if (entered && !nscmpEnter(s, s.parse_cursor)) return 0;
  let left = level === 2 ? nscmpNot(s) : level === 5 ? nscmpUnary(s) : nscmpBinary(s, level + 1);
  // Level 2 delegates not/comparison. Other levels are left associative.
  if (level !== 2) while (s.parse_status === 0) {
    nscmpSpace(s); const offset = s.parse_cursor;
    let kind = -1;
    if (level === 0) { if (nscmpMatch(s, "or", true)) kind = 19; }
    else if (level === 1) { if (nscmpMatch(s, "and", true)) kind = 18; }
    else if (level === 3) {
      if (nscmpMatch(s, "++", false)) kind = 11;
      else if (nscmpMatch(s, "+", false)) kind = 7;
      else if (nscmpMatch(s, "-", false)) kind = 8;
    } else if (level === 4) {
      if (nscmpMatch(s, "*", false)) kind = 9;
      else if (nscmpMatch(s, "/", false)) kind = 10;
    }
    if (kind < 0) break;
    const right = nscmpBinary(s, level + 1);
    left = nscmpNode(s, kind, offset, left, right, 0, 0, 0, [], false);
  }
  if (entered) s.parse_depth--;
  return left;
}
function nscmpNot(s: NscMarkupParser): number {
  nscmpSpace(s); const at = s.parse_cursor;
  if (nscmpMatch(s, "not", true)) {
    if (!nscmpEnter(s, at)) return 0;
    const operand = nscmpNot(s); s.parse_depth--;
    return nscmpNode(s, 6, at, operand, 0, 0, 0, 0, [], false);
  }
  const left = nscmpBinary(s, 3);
  if (s.parse_status !== 0) return 0;
  nscmpSpace(s); const offset = s.parse_cursor;
  let kind = -1;
  if (nscmpMatch(s, "==", false)) kind = 12;
  else if (nscmpMatch(s, "!=", false)) kind = 13;
  else if (nscmpMatch(s, "<=", false)) kind = 15;
  else if (nscmpMatch(s, ">=", false)) kind = 17;
  else if (nscmpMatch(s, "<", false)) kind = 14;
  else if (nscmpMatch(s, ">", false)) kind = 16;
  if (kind < 0) return left;
  const right = nscmpBinary(s, 3);
  if (s.parse_status !== 0) return 0;
  if (s.parse_nodes[left * 20] === 4) s.parse_nodes[left * 20 + 10] = 1;
  if (s.parse_nodes[right * 20] === 4) s.parse_nodes[right * 20 + 10] = 1;
  nscmpSpace(s);
  const cursor = s.parse_cursor, byte = cursor < s.parse_source.length ? s.parse_source[cursor]! : -1;
  if (byte === 60 || byte === 62 || (byte === 61 || byte === 33) && cursor + 1 < s.parse_source.length && s.parse_source[cursor + 1] === 61)
    return nscmpFail(s, cursor, 6);
  return nscmpNode(s, kind, offset, left, right, 0, 0, 0, [], false);
}
function nscmpUnary(s: NscMarkupParser): number {
  nscmpSpace(s); const at = s.parse_cursor;
  if (nscmpMatch(s, "-", false)) {
    if (!nscmpEnter(s, at)) return 0;
    const operand = nscmpUnary(s); s.parse_depth--;
    return nscmpNode(s, 5, at, operand, 0, 0, 0, 0, [], false);
  }
  return nscmpPrimary(s);
}
function nscmpName(s: NscMarkupParser, start: number, end: number, name: string): boolean {
  if (end - start !== name.length) return false;
  for (let i = 0; i < name.length; i++) if (s.parse_source[start + i] !== name.charCodeAt(i)) return false;
  return true;
}
function nscmpPrimary(s: NscMarkupParser): number {
  nscmpSpace(s); const offset = s.parse_cursor, source = s.parse_source;
  if (offset >= source.length) return nscmpFail(s, offset, offset === 0 ? 1 : 11);
  const byte = source[offset]!;
  if (byte === 40) {
    s.parse_cursor++;
    const inner = nscmpBinary(s, 0);
    if (s.parse_status !== 0) return 0;
    nscmpSpace(s);
    if (!nscmpMatch(s, ")", false)) return nscmpFail(s, s.parse_cursor, 13);
    return inner;
  }
  if (byte === 39) {
    s.parse_cursor++;
    const start = s.parse_cursor;
    while (s.parse_cursor < source.length) {
      if (source[s.parse_cursor++] === 39)
        return nscmpNode(s, 2, offset, 0, 0, start, s.parse_cursor - start - 1, 0, [], false);
    }
    return nscmpFail(s, offset, 7);
  }
  if (nscmpDigit(byte)) {
    while (s.parse_cursor < source.length && nscmpDigit(source[s.parse_cursor]!)) s.parse_cursor++;
    let floating = false;
    if (s.parse_cursor + 1 < source.length && source[s.parse_cursor] === 46 && nscmpDigit(source[s.parse_cursor + 1]!)) {
      floating = true; s.parse_cursor++;
      while (s.parse_cursor < source.length && nscmpDigit(source[s.parse_cursor]!)) s.parse_cursor++;
    }
    const admission = s.parse_admissions[offset]!;
    if (admission === 0) {
      s.parse_status = 2; s.parse_number_start = offset; s.parse_number_length = s.parse_cursor - offset;
      return 0;
    }
    if (admission === 2) return nscmpFail(s, offset, floating ? 9 : 8);
    return nscmpNode(s, floating ? 1 : 0, offset, 0, 0, offset, s.parse_cursor - offset, 0, [], false);
  }
  if (!nscmpStart(byte)) return nscmpFail(s, offset, 11);
  s.parse_cursor++;
  while (s.parse_cursor < source.length && (nscmpIdentifier(source[s.parse_cursor]!) || source[s.parse_cursor] === 46)) s.parse_cursor++;
  const end = s.parse_cursor;
  if (nscmpName(s, offset, end, "true")) return nscmpNode(s, 3, offset, 0, 0, 0, 0, 0, [], true);
  if (nscmpName(s, offset, end, "false")) return nscmpNode(s, 3, offset, 0, 0, 0, 0, 0, [], false);
  nscmpSpace(s);
  if (s.parse_cursor < source.length && source[s.parse_cursor] === 40) {
    for (let i = offset; i < end; i++) if (source[i] === 46) return nscmpFail(s, offset, 10);
    return nscmpCall(s, offset, end);
  }
  let segment = true;
  for (let i = offset; i < end; i++) {
    const b = source[i]!;
    if (segment) { if (!nscmpStart(b)) return nscmpFail(s, offset, 11); segment = false; }
    else if (b === 46) segment = true;
    else if (!nscmpIdentifier(b)) return nscmpFail(s, offset, 11);
  }
  if (segment) return nscmpFail(s, offset, 11);
  return nscmpNode(s, 4, offset, 0, 0, offset, end - offset, 0, [], false);
}
function nscmpCall(s: NscMarkupParser, offset: number, end: number): number {
  const names = ["fixed", "thousands", "percent", "date", "time", "datetime", "upper", "lower", "trim",
    "min", "max", "abs", "round", "floor", "ceil", "plural", "pad"];
  let fn = -1;
  for (let i = 0; i < names.length; i++) if (nscmpName(s, offset, end, names[i]!)) { fn = i; break; }
  if (fn < 0) return nscmpFail(s, offset,
    nscmpName(s, offset, end, "now") || nscmpName(s, offset, end, "today") ? 15 : 10);
  s.parse_cursor++;
  if (!nscmpEnter(s, offset)) return 0;
  const args: number[] = [];
  nscmpSpace(s);
  if (!nscmpMatch(s, ")", false)) while (s.parse_status === 0) {
    if (args.length >= 4) { nscmpFail(s, s.parse_cursor, 5); break; }
    const arg = nscmpBinary(s, 0);
    if (s.parse_status !== 0) break;
    args.push(arg); nscmpSpace(s);
    if (nscmpMatch(s, ",", false)) continue;
    if (nscmpMatch(s, ")", false)) break;
    nscmpFail(s, s.parse_cursor, 14);
  }
  s.parse_depth--;
  if (s.parse_status !== 0) return 0;
  const minimum = fn === 0 || fn === 9 || fn === 10 || fn === 16 ? 2 : fn === 15 ? 3 : 1;
  const maximum = fn === 2 ? 2 : minimum;
  if (args.length < minimum || args.length > maximum) return nscmpFail(s, offset, 32 + fn);
  return nscmpNode(s, 20, offset, 0, 0, 0, 0, fn, args, false);
}
function nscvMarkupParser(request: Uint8Array): Uint8Array {
  if (request.length < 8 || request[0] !== 106 || request[1] !== 1 ||
      request[4] !== 0 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid expression parser header");
  const length = new DataView(request.buffer, request.byteOffset, request.byteLength).getUint16(2, true);
  if (length > 256) {
    if (request.length !== 8) throw new Error("invalid oversized expression request");
    const out = new Uint8Array(16); out.set([106, 1, 1, 2]); return out;
  }
  if (request.length !== 9 + length * 2) throw new Error("invalid expression parser length");
  const admissions = request.subarray(8 + length);
  for (let i = 0; i < admissions.length; i++) if (admissions[i]! > 2) throw new Error("invalid literal admission");
  const s: NscMarkupParser = { parse_source: request.subarray(8, 8 + length), parse_admissions: admissions,
    parse_nodes: new Uint8Array(1280), parse_cursor: 0, parse_depth: 0, parse_count: 0,
    parse_status: 0, parse_error: 0, parse_offset: 0, parse_number_start: 0, parse_number_length: 0 };
  const root = nscmpBinary(s, 0);
  if (s.parse_status === 0) { nscmpSpace(s); if (s.parse_cursor < length) nscmpFail(s, s.parse_cursor, 12); }
  const out = new Uint8Array(16 + s.parse_count * 20), wire = new DataView(out.buffer);
  out.set([106, 1, s.parse_status, s.parse_error, s.parse_count, s.parse_status === 0 ? root : 0]);
  wire.setUint16(6, s.parse_offset, true); wire.setUint16(8, s.parse_number_start, true);
  wire.setUint16(10, s.parse_number_length, true); out.set(s.parse_nodes.subarray(0, s.parse_count * 20), 16);
  return out;
}
