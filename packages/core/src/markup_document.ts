/** Runtime document grammar (107). A copied action tape preserves every
 * native tree-storage allocation boundary, including failures before a later
 * syntax error. Source spans are borrowed again only by the native consumer.
 * The sizing pass returns a 16-byte header; the delivery pass appends 96-byte
 * records: action/code/reserved[6], cursor/line/column, eight payload words.
 * Positions are exact nonnegative integers carried as little-endian f64.
 */
type NscMarkupDocumentFrame = {
  doc_start: number; doc_line: number; doc_column: number;
  doc_name_start: number; doc_name_end: number; doc_kind: number;
  doc_is_text: boolean; doc_is_span: boolean; doc_has_span: boolean;
  doc_children: number[];
};
type NscMarkupDocument = {
  doc_source: Uint8Array; doc_cursor: number; doc_line: number; doc_column: number;
  doc_actions: number[]; doc_frames: NscMarkupDocumentFrame[];
  doc_imports: number; doc_templates: number; doc_finished: boolean;
};
function nscdocEmit(s: NscMarkupDocument, action: number, code: number, fields: readonly number[]): void {
  s.doc_actions.push(action, code, s.doc_cursor, s.doc_line, s.doc_column);
  for (let i = 0; i < 8; i++) s.doc_actions.push(i < fields.length ? fields[i]! : 0);
}
function nscdocFail(s: NscMarkupDocument, code: number, line: number, column: number): void {
  nscdocEmit(s, 12, code, [line, column]); s.doc_finished = true;
}
function nscdocAdvance(s: NscMarkupDocument): void {
  if (s.doc_source[s.doc_cursor] === 10) { s.doc_line++; s.doc_column = 1; }
  else s.doc_column++;
  s.doc_cursor++;
}
function nscdocConsume(s: NscMarkupDocument, byte: number): boolean {
  if (s.doc_cursor >= s.doc_source.length || s.doc_source[s.doc_cursor] !== byte) return false;
  nscdocAdvance(s); return true;
}
function nscdocSpace(byte: number): boolean { return byte === 32 || byte === 9 || byte === 13 || byte === 10; }
function nscdocSkipSpace(s: NscMarkupDocument): void {
  while (s.doc_cursor < s.doc_source.length && nscdocSpace(s.doc_source[s.doc_cursor]!)) nscdocAdvance(s);
}
function nscdocMatch(source: Uint8Array, at: number, token: string): boolean {
  if (at + token.length > source.length) return false;
  for (let i = 0; i < token.length; i++) if (source[at + i] !== token.charCodeAt(i)) return false;
  return true;
}
function nscdocCommentEnd(source: Uint8Array, at: number): number {
  for (let i = at + 4; i + 3 <= source.length; i++) if (nscdocMatch(source, i, "-->")) return i + 3;
  return source.length;
}
function nscdocSkipComments(s: NscMarkupDocument): void {
  while (nscdocMatch(s.doc_source, s.doc_cursor, "<!--")) {
    const end = nscdocCommentEnd(s.doc_source, s.doc_cursor);
    while (s.doc_cursor < end) nscdocAdvance(s);
  }
}
function nscdocSkipOuter(s: NscMarkupDocument): void {
  while (true) {
    const before = s.doc_cursor; nscdocSkipSpace(s); nscdocSkipComments(s);
    if (s.doc_cursor === before) return;
  }
}
function nscdocName(s: NscMarkupDocument): boolean {
  const start = s.doc_cursor;
  while (s.doc_cursor < s.doc_source.length) {
    const b = s.doc_source[s.doc_cursor]!;
    if (!(b >= 97 && b <= 122 || b >= 48 && b <= 57 || b === 45 || b === 95)) break;
    nscdocAdvance(s);
  }
  if (start !== s.doc_cursor) return true;
  nscdocFail(s, 8, s.doc_line, s.doc_column); return false;
}
function nscdocNamed(s: NscMarkupDocument, start: number, end: number, name: string): boolean {
  return end - start === name.length && nscdocMatch(s.doc_source, start, name);
}
function nscdocKind(s: NscMarkupDocument, start: number, end: number): number {
  const names = ["for", "if", "else", "template", "use", "import", "slot"];
  for (let i = 0; i < names.length; i++) if (nscdocNamed(s, start, end, names[i]!)) return i + 2;
  return 0;
}
function nscdocComplete(s: NscMarkupDocument, f: NscMarkupDocumentFrame): void {
  if (s.doc_frames.length > 0) {
    const parent = s.doc_frames[s.doc_frames.length - 1]!;
    if (parent.doc_is_text) {
      parent.doc_children.push(f.doc_start, s.doc_cursor);
      if (f.doc_is_span) parent.doc_has_span = true;
    }
  } else if (f.doc_kind === 7) {
    if (s.doc_templates > 0) nscdocFail(s, 13, f.doc_line, f.doc_column);
    else { s.doc_imports++; nscdocEmit(s, 8, 0, []); }
  } else if (f.doc_kind === 5) {
    if (s.doc_templates >= 256) nscdocFail(s, 14, f.doc_line, f.doc_column);
    else { s.doc_templates++; nscdocEmit(s, 9, 0, []); }
  } else {
    nscdocSkipOuter(s);
    if (s.doc_cursor < s.doc_source.length) nscdocFail(s, 2, s.doc_line, s.doc_column);
    else { nscdocEmit(s, 10, 0, []); s.doc_finished = true; }
  }
}
function nscdocOpen(s: NscMarkupDocument): void {
  const start = s.doc_cursor, line = s.doc_line, column = s.doc_column;
  if (!nscdocConsume(s, 60)) { nscdocFail(s, 3, s.doc_line, s.doc_column); return; }
  const nameStart = s.doc_cursor;
  if (!nscdocName(s)) return;
  const nameEnd = s.doc_cursor, kind = nscdocKind(s, nameStart, nameEnd);
  const f: NscMarkupDocumentFrame = { doc_start: start, doc_line: line, doc_column: column,
    doc_name_start: nameStart, doc_name_end: nameEnd, doc_kind: kind,
    doc_is_text: nscdocNamed(s, nameStart, nameEnd, "text"),
    doc_is_span: nscdocNamed(s, nameStart, nameEnd, "span"), doc_has_span: false, doc_children: [] };
  nscdocEmit(s, 1, kind, [start, line, column, nameStart, nameEnd]);
  while (!s.doc_finished) {
    nscdocSkipSpace(s);
    if (s.doc_cursor >= s.doc_source.length) { nscdocFail(s, 4, s.doc_line, s.doc_column); return; }
    const b = s.doc_source[s.doc_cursor]!;
    if (b === 47 || b === 62) break;
    const attrLine = s.doc_line, attrColumn = s.doc_column, attrStart = s.doc_cursor;
    if (!nscdocName(s)) return;
    const attrEnd = s.doc_cursor;
    let valueStart = attrEnd, valueEnd = attrEnd, hasValue = 0;
    nscdocSkipSpace(s);
    if (nscdocConsume(s, 61)) {
      nscdocSkipSpace(s);
      if (!nscdocConsume(s, 34)) { nscdocFail(s, 9, s.doc_line, s.doc_column); return; }
      hasValue = 1; valueStart = s.doc_cursor;
      while (s.doc_cursor < s.doc_source.length && s.doc_source[s.doc_cursor] !== 34) {
        if (s.doc_source[s.doc_cursor] === 10) { nscdocFail(s, 10, s.doc_line, s.doc_column); return; }
        nscdocAdvance(s);
      }
      valueEnd = s.doc_cursor;
      if (!nscdocConsume(s, 34)) { nscdocFail(s, 11, s.doc_line, s.doc_column); return; }
    }
    nscdocEmit(s, 2, hasValue, [attrStart, attrEnd, valueStart, valueEnd, attrLine, attrColumn]);
  }
  if (nscdocConsume(s, 47)) {
    if (!nscdocConsume(s, 62)) { nscdocFail(s, 5, s.doc_line, s.doc_column); return; }
    nscdocEmit(s, 3, 0, []); nscdocComplete(s, f); return;
  }
  if (!nscdocConsume(s, 62)) { nscdocFail(s, 6, s.doc_line, s.doc_column); return; }
  nscdocEmit(s, 4, 0, []); s.doc_frames.push(f);
}
function nscdocGap(s: NscMarkupDocument, start: number, end: number): boolean {
  let at = start;
  while (at < end) {
    if (nscdocMatch(s.doc_source, at, "<!--")) at = nscdocCommentEnd(s.doc_source, at);
    else if (nscdocSpace(s.doc_source[at]!)) return true;
    else at++;
  }
  return false;
}
function nscdocClose(s: NscMarkupDocument, f: NscMarkupDocumentFrame): void {
  const line = s.doc_line, column = s.doc_column;
  nscdocAdvance(s); nscdocAdvance(s);
  const nameStart = s.doc_cursor;
  if (!nscdocName(s)) return;
  const nameEnd = s.doc_cursor;
  nscdocSkipSpace(s);
  if (!nscdocConsume(s, 62)) { nscdocFail(s, 7, s.doc_line, s.doc_column); return; }
  let equal = nameEnd - nameStart === f.doc_name_end - f.doc_name_start;
  if (equal) for (let i = 0; i < nameEnd - nameStart; i++) {
    if (s.doc_source[nameStart + i] !== s.doc_source[f.doc_name_start + i]) { equal = false; break; }
  }
  if (!equal) { nscdocFail(s, 12, line, column); return; }
  const separators: number[] = [];
  if (f.doc_has_span) for (let i = 2; i < f.doc_children.length; i += 2) {
    const start = f.doc_children[i - 1]!, end = f.doc_children[i]!;
    if (nscdocGap(s, start, end)) {
      let gapLine = 1, gapColumn = 1;
      for (let j = 0; j < start; j++) {
        if (s.doc_source[j] === 10) { gapLine++; gapColumn = 1; } else gapColumn++;
      }
      separators.push(i / 2, start, end, gapLine, gapColumn);
    }
  }
  nscdocEmit(s, 6, 0, [separators.length / 5]);
  for (let i = 0; i < separators.length; i += 5) nscdocEmit(s, 7, 0, separators.slice(i, i + 5));
  s.doc_frames.pop(); nscdocComplete(s, f);
}
function nscdocText(s: NscMarkupDocument, f: NscMarkupDocumentFrame): void {
  const at = s.doc_cursor;
  let line = s.doc_line, column = s.doc_column;
  while (s.doc_cursor < s.doc_source.length && s.doc_source[s.doc_cursor] !== 60) nscdocAdvance(s);
  let start = at, end = s.doc_cursor;
  while (start < end && nscdocSpace(s.doc_source[start]!)) {
    if (s.doc_source[start] === 10) { line++; column = 1; } else column++;
    start++;
  }
  while (end > start && nscdocSpace(s.doc_source[end - 1]!)) end--;
  if (end > start) {
    nscdocEmit(s, 5, 0, [start, end, line, column]);
    if (f.doc_is_text) f.doc_children.push(start, end);
  }
}
function nscvMarkupDocument(request: Uint8Array): Uint8Array {
  if (request.length < 32 || request[0] !== 107 || request[1] !== 1 || request[2]! > 1 ||
      request[3] !== 0 || request[4] !== 0 || request[5] !== 0 || request[6] !== 0 || request[7] !== 0)
    throw new Error("invalid markup document request");
  const input = new DataView(request.buffer, request.byteOffset, request.byteLength);
  const cursor = input.getFloat64(8, true), line = input.getFloat64(16, true), column = input.getFloat64(24, true);
  if (!Number.isSafeInteger(cursor) || cursor < 0 || cursor > request.length - 32 ||
      !Number.isSafeInteger(line) || line < 1 || !Number.isSafeInteger(column) || column < 1)
    throw new Error("invalid markup document position");
  const s: NscMarkupDocument = { doc_source: request.subarray(32), doc_cursor: cursor, doc_line: line, doc_column: column,
    doc_actions: [], doc_frames: [], doc_imports: 0, doc_templates: 0, doc_finished: false };
  while (!s.doc_finished) {
    if (s.doc_frames.length === 0) {
      nscdocSkipOuter(s);
      if (s.doc_cursor >= s.doc_source.length) {
        if (s.doc_imports === 0 && s.doc_templates === 0) nscdocFail(s, 1, s.doc_line, s.doc_column);
        else { nscdocEmit(s, 11, 0, []); s.doc_finished = true; }
      } else nscdocOpen(s);
    } else {
      const f = s.doc_frames[s.doc_frames.length - 1]!;
      nscdocSkipComments(s);
      if (s.doc_cursor >= s.doc_source.length) nscdocFail(s, 15, f.doc_line, f.doc_column);
      else if (s.doc_source[s.doc_cursor] === 60) {
        if (s.doc_source[s.doc_cursor + 1] === 47) nscdocClose(s, f); else nscdocOpen(s);
      } else nscdocText(s, f);
    }
  }
  const count = s.doc_actions.length / 13, out = new Uint8Array(request[2] === 0 ? 16 : 16 + count * 96);
  out[0] = 107; out[1] = 1; out[2] = request[2]!;
  const wire = new DataView(out.buffer); wire.setFloat64(8, count, true);
  if (request[2] === 1) for (let i = 0; i < count; i++) {
    const record = 16 + i * 96, index = i * 13;
    out[record] = s.doc_actions[index]!; out[record + 1] = s.doc_actions[index + 1]!;
    for (let j = 0; j < 11; j++) wire.setFloat64(record + 8 + j * 8, s.doc_actions[index + 2 + j]!, true);
  }
  return out;
}
