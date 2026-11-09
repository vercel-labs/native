/** Runtime typed-document coordination (109). The copied tree facts produce
 * an allocation-ordered action tape. Native retains source aliases, tree
 * storage and the existing exact expression-parser capability. Records are
 * 48 bytes: action/code/reserved[6], then five exact little-endian f64 words.
 */
class NscCanonicalReader {
  canonical_at: number = 4;
  readonly canonical_bytes: Uint8Array;
  readonly canonical_view: DataView;
  constructor(bytes: Uint8Array) {
    this.canonical_bytes = bytes;
    this.canonical_view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }
  word(): number {
    if (this.canonical_bytes.length - this.canonical_at < 8) throw new Error("short canonical word");
    const value = this.canonical_view.getFloat64(this.canonical_at, true); this.canonical_at += 8;
    if (!Number.isSafeInteger(value) || value < 0) throw new Error("invalid canonical integer");
    return value;
  }
  blob(): Uint8Array {
    const length = this.word();
    if (length > this.canonical_bytes.length - this.canonical_at) throw new Error("short canonical bytes");
    const value = this.canonical_bytes.subarray(this.canonical_at, this.canonical_at + length);
    this.canonical_at += length; return value;
  }
}
function nsccEmit(tape: number[], action: number, code: number = 0,
  a: number = 0, b: number = 0, c: number = 0, d: number = 0, e: number = 0): void {
  tape.push(action, code, a, b, c, d, e);
}
function nsccStart(byte: number): boolean {
  return byte >= 97 && byte <= 122 || byte >= 65 && byte <= 90 || byte === 95;
}
function nsccPath(bytes: Uint8Array, start: number, end: number): boolean {
  if (start === end) return false;
  let first = true;
  for (let i = start; i < end; i++) {
    const byte = bytes[i]!;
    if (first) { if (!nsccStart(byte)) return false; first = false; }
    else if (byte === 46) first = true;
    else if (!nsccStart(byte) && !(byte >= 48 && byte <= 57)) return false;
  }
  return !first;
}
function nsccTrim(bytes: Uint8Array, start: number, end: number): number[] {
  while (start < end && bytes[start] === 32) start++;
  while (end > start && bytes[end - 1] === 32) end--;
  return [start, end];
}
function nsccFind(bytes: Uint8Array, start: number, byte: number): number {
  for (let i = start; i < bytes.length; i++) if (bytes[i] === byte) return i;
  return -1;
}
function nsccAttribute(tape: number[], index: number, name: Uint8Array, value: Uint8Array): void {
  if (name.length >= 3 && name[0] === 111 && name[1] === 110 && name[2] === 45) {
    const colon = nsccFind(value, 0, 58);
    if (colon < 0) {
      nsccEmit(tape, 11, nsccPath(value, 0, value.length) ? 5 : 6, index, 0, value.length, value.length, value.length);
    } else if (nsccPath(value, 0, colon) && value.length - colon - 1 >= 3 && value[colon + 1] === 123 &&
        value[value.length - 1] === 125 && nsccPath(value, colon + 2, value.length - 1)) {
      nsccEmit(tape, 11, 5, index, 0, colon, colon + 2, value.length - 1);
    } else nsccEmit(tape, 11, 6, index);
    return;
  }
  if (value.length === 0 || value[0] !== 123) { nsccEmit(tape, 11, 1, index, 0, value.length); return; }
  if (value[value.length - 1] !== 125) { nsccEmit(tape, 11, 6, index); return; }
  const inner = nsccTrim(value, 1, value.length - 1), start = inner[0]!, end = inner[1]!;
  if (start === end) { nsccEmit(tape, 11, 6, index); return; }
  for (let i = start; i + 1 < end; i++) if (value[i] === 61 && value[i + 1] === 61) {
    const left = nsccTrim(value, start, i), right = nsccTrim(value, i + 2, end);
    if (nsccPath(value, left[0]!, left[1]!) && nsccPath(value, right[0]!, right[1]!)) {
      nsccEmit(tape, 11, 3, index, left[0]!, left[1]!, right[0]!, right[1]!); return;
    }
    break; // Classification considers the first equality token only.
  }
  nsccEmit(tape, 11, nsccPath(value, start, end) ? 2 : 4, index, start, end);
}
function nsccText(tape: number[], text: Uint8Array): void {
  let rest = 0, open = nsccFind(text, 0, 123);
  if (open < 0) return;
  nsccEmit(tape, 12);
  while (open >= 0) {
    if (open > rest) nsccEmit(tape, 13, 1, rest, open);
    const close = nsccFind(text, open, 125);
    if (close < 0) { nsccEmit(tape, 13, 4); nsccEmit(tape, 14); return; }
    const span = nsccTrim(text, open + 1, close);
    nsccEmit(tape, 13, nsccPath(text, span[0]!, span[1]!) ? 2 : 3, span[0]!, span[1]!);
    rest = close + 1; open = nsccFind(text, rest, 123);
  }
  if (rest < text.length) nsccEmit(tape, 13, 1, rest, text.length);
  nsccEmit(tape, 14);
}
function nsccOpen(reader: NscCanonicalReader, tape: number[]): number {
  const kind = reader.word(), attrs = reader.word();
  if (kind > 8) throw new Error("invalid canonical node kind");
  if (attrs > 0) nsccEmit(tape, 10, 0, attrs);
  for (let i = 0; i < attrs; i++) nsccAttribute(tape, i, reader.blob(), reader.blob());
  const text = reader.blob();
  if (kind === 1) nsccText(tape, text);
  const children = reader.word();
  if (children > 0) nsccEmit(tape, 15, 0, children);
  return children;
}
function nsccNode(reader: NscCanonicalReader, tape: number[]): void {
  const frames = [{ canonical_children: nsccOpen(reader, tape), canonical_next: 0 }];
  while (frames.length > 0) {
    const frame = frames[frames.length - 1]!;
    if (frame.canonical_next < frame.canonical_children) {
      nsccEmit(tape, 16, 0, frame.canonical_next++);
      frames.push({ canonical_children: nsccOpen(reader, tape), canonical_next: 0 });
    } else { nsccEmit(tape, 17); frames.pop(); }
  }
}
function nscvMarkupCanonical(request: Uint8Array): Uint8Array {
  if (request.length < 4 || request[0] !== 109 || request[1] !== 1 || request[2]! > 1 || request[3]! > 2)
    throw new Error("invalid canonical request");
  const reader = new NscCanonicalReader(request), tape: number[] = [];
  if (request[3] !== 0) {
    // Standalone raw expressions (1) and name-aware attributes (2) share
    // the document classifier. Native reconstructs borrowed source slices.
    const name = reader.blob(), value = reader.blob();
    nsccAttribute(tape, 0, request[3] === 1 ? new Uint8Array(0) : name, value);
  } else {
    const templates = reader.word(), root = reader.word();
    if (root > 1) throw new Error("invalid canonical root flag");
    if (templates > 0) nsccEmit(tape, 1, 0, templates);
    for (let i = 0; i < templates; i++) { nsccEmit(tape, 2, 0, i); nsccNode(reader, tape); }
    if (root === 1) { nsccEmit(tape, 3); nsccNode(reader, tape); }
    nsccEmit(tape, 4);
  }
  if (reader.canonical_at !== request.length) throw new Error("trailing canonical input");
  const count = tape.length / 7, out = new Uint8Array(request[2] === 0 ? 16 : 16 + count * 48), wire = new DataView(out.buffer);
  out[0] = 109; out[1] = 1; out[2] = request[2]!; wire.setFloat64(8, count, true);
  if (request[2] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, source = i * 7;
    out[at] = tape[source]!; out[at + 1] = tape[source + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, tape[source + 2 + j]!, true);
  }
  return out;
}
