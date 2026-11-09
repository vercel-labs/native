/** Shared runtime markup shape and diagnostic programs (115). Source bytes,
 * tree indices and type classes are copied; native retains borrowed records,
 * exact literal conversion and the bundled font's glyph coverage capability.
 */
interface NscShapeNode {
  readonly kind: number; readonly name: Uint8Array; readonly text: Uint8Array;
  readonly attrs: readonly { name: Uint8Array; value: Uint8Array }[];
  readonly children: readonly number[];
}
function nschEmit(out: number[], action: number, code: number, a: number = 0, b: number = 0,
  c: number = 0, d: number = 0, e: number = 0): void { out.push(action, code, a, b, c, d, e); }
function nschFail(out: number[], code: number, node: number, attr: number = 0,
  offset: number = 0, text: boolean = false): void { nschEmit(out, 255, code, node, attr, offset, text ? 1 : 0); }
function nschAttr(node: NscShapeNode, name: string): number {
  for (let i = 0; i < node.attrs.length; i++) if (nsceNamed(node.attrs[i]!.name, name)) return i;
  return -1;
}
// 0=literal, 1=path/equality, 2=expression, 3=malformed. Attribute braces
// trim only ASCII space, exactly like the original attribute classifier.
function nschExpression(value: Uint8Array): number[] {
  if (value.length === 0 || value[0] !== 123) return [0, 0, value.length];
  if (value[value.length - 1] !== 125) return [3, 0, 0];
  const span = nsccTrim(value, 1, value.length - 1), start = span[0]!, end = span[1]!;
  if (start === end) return [3, 0, 0];
  for (let i = start; i + 1 < end; i++) if (value[i] === 61 && value[i + 1] === 61) {
    const left = nsccTrim(value, start, i), right = nsccTrim(value, i + 2, end);
    if (nsccPath(value, left[0]!, left[1]!) && nsccPath(value, right[0]!, right[1]!)) return [1, start, end];
    break;
  }
  return [nsccPath(value, start, end) ? 1 : 2, start, end];
}
function nschAttrExpression(out: number[], node: number, attr: number, value: Uint8Array,
  fallback: number, atNode: boolean = false): boolean {
  const form = nschExpression(value);
  if (form[0] === 3) { nschFail(out, fallback, node, atNode ? 0 : attr + 1); return false; }
  if (form[0] === 2) nschEmit(out, 1, 0, node, attr + 1, form[1]!, form[2]! - form[1]!, atNode ? 1 : 0);
  return true;
}
function nschMessage(value: Uint8Array): boolean {
  const colon = nsccFind(value, 0, 58);
  if (colon < 0) return nsccPath(value, 0, value.length);
  return nsccPath(value, 0, colon) && value.length - colon - 1 >= 3 && value[colon + 1] === 123 &&
    value[value.length - 1] === 125 && nsccPath(value, colon + 2, value.length - 1);
}
function nschText(out: number[], index: number, text: Uint8Array): boolean {
  let cursor = 0;
  while (true) {
    const open = nsccFind(text, cursor, 123);
    if (open < 0) break;
    const close = nsccFind(text, open, 125);
    if (close < 0) { nschFail(out, 22, index, 0, open, true); return false; }
    const span = nsccTrim(text, open + 1, close);
    if (!nsccPath(text, span[0]!, span[1]!)) nschEmit(out, 4, 0, index, 0, span[0]!, span[1]! - span[0]!, open);
    cursor = close + 1;
  }
  nschEmit(out, 5, 0, index); // literal coverage follows every interpolation
  return true;
}
function nschMenuItem(nodes: readonly NscShapeNode[], index: number, out: number[]): boolean {
  const node = nodes[index]!; let press = false;
  for (let i = 0; i < node.attrs.length; i++) {
    const attr = node.attrs[i]!;
    if (nsceNamed(attr.name, "on-press")) {
      press = true;
      if (!nschMessage(attr.value)) { nschFail(out, 19, index, i + 1); return false; }
    } else if (nsceNamed(attr.name, "disabled")) {
      if (!nschAttrExpression(out, index, i, attr.value, 20)) return false;
    } else { nschFail(out, 16, index, i + 1); return false; }
  }
  if (!press) { nschFail(out, 17, index); return false; }
  let runs = 0;
  for (const child of node.children) {
    const run = nodes[child]!;
    if (run.kind !== 1) { nschFail(out, 18, child); return false; }
    if (++runs > 1) { nschFail(out, 7, child); return false; }
    if (!nschText(out, child, run.text)) return false;
  }
  if (runs === 0) { nschFail(out, 18, index); return false; }
  return true;
}
function nschMenuChildren(nodes: readonly NscShapeNode[], index: number, out: number[]): number {
  let previous = -1, count = 0;
  for (const childIndex of nodes[index]!.children) {
    const child = nodes[childIndex]!;
    if (child.kind === 0) {
      if (nsceNamed(child.name, "menu-item")) {
        count++;
        if (!nschMenuItem(nodes, childIndex, out)) return -1;
      } else if (nsceNamed(child.name, "separator")) {
        if (child.attrs.length !== 0 || child.children.length !== 0) { nschFail(out, 12, childIndex); return -1; }
        count++;
      } else { nschFail(out, 11, childIndex); return -1; }
    } else if (child.kind === 2) {
      if (nschAttr(child, "each") < 0) { nschFail(out, 13, childIndex); return -1; }
      if (nschAttr(child, "as") < 0) { nschFail(out, 14, childIndex); return -1; }
      if (child.children.length === 0) { nschFail(out, 15, childIndex); return -1; }
      const repeated = nschMenuChildren(nodes, childIndex, out);
      if (repeated < 0) return -1;
      if (repeated === 0) { nschFail(out, 11, childIndex); return -1; }
      count += repeated;
    } else if (child.kind === 3) {
      const test = nschAttr(child, "test");
      if (test < 0) { nschFail(out, 23, childIndex); return -1; }
      if (!nschAttrExpression(out, childIndex, test, child.attrs[test]!.value, 24, true)) return -1;
      const nested = nschMenuChildren(nodes, childIndex, out); if (nested < 0) return -1; count += nested;
    } else if (child.kind === 4) {
      if (previous !== 2 && previous !== 3) { nschFail(out, 21, childIndex); return -1; }
      const nested = nschMenuChildren(nodes, childIndex, out); if (nested < 0) return -1; count += nested;
    } else { nschFail(out, 11, childIndex); return -1; }
    previous = child.kind;
  }
  return count;
}
function nschShape(r: NscElementReader, mode: number, out: number[]): void {
  const count = r.word(), nodes: NscShapeNode[] = [], parents = new Uint8Array(count);
  if (count === 0 || count > r.bytes.length - r.at) throw new Error("invalid shape node count");
  for (let i = 0; i < count; i++) {
    const kind = r.word(), name = r.blob(), text = r.blob(), attrs: { name: Uint8Array; value: Uint8Array }[] = [];
    if (kind > 8) throw new Error("invalid shape node kind");
    const ac = r.word(); for (let a = 0; a < ac; a++) attrs.push({ name: r.blob(), value: r.blob() });
    const cc = r.word(), children: number[] = [];
    for (let c = 0; c < cc; c++) {
      const child = r.word();
      if (child <= i || child >= count || parents[child] !== 0) throw new Error("invalid shape tree edge");
      parents[child] = 1; children.push(child);
    }
    nodes.push({ kind, name, text, attrs, children });
  }
  for (let i = 1; i < count; i++) if (parents[i] !== 1) throw new Error("unreachable shape node");
  const weights = r.names(), colors = r.names(), alignments = r.names(), node = nodes[0]!;
  if (mode === 0) {
    if (node.attrs.length !== 0) { nschFail(out, 9, 0, 1); return; }
    const items = nschMenuChildren(nodes, 0, out);
    if (items === 0) nschFail(out, 10, 0);
    return;
  }
  for (let i = 0; i < node.attrs.length; i++) {
    const attr = node.attrs[i]!;
    if (mode === 2) {
      if (!nsceNamed(attr.name, "text-alignment")) { nschFail(out, 25, 0, i + 1); return; }
      if (!nsceIn(attr.value, alignments)) { nschFail(out, 26, 0, i + 1); return; }
      continue;
    }
    const form = nschExpression(attr.value);
    if (nsceNamed(attr.name, "weight")) {
      if (form[0] === 0 && !nsceIn(attr.value, weights)) { nschFail(out, 1, 0, i + 1); return; }
    } else if (nsceNamed(attr.name, "scale")) {
      if (form[0] === 0) nschEmit(out, 2, 0, 0, i + 1);
    } else if (nsceOne(attr.name, ["mono", "italic", "underline"])) {
      // These channels use the same structural expression check.
    } else if (nsceNamed(attr.name, "foreground")) {
      if (!nsceIn(attr.value, colors)) { nschFail(out, form[0] === 0 ? 3 : 4, 0, i + 1); return; }
      continue;
    } else { nschFail(out, 5, 0, i + 1); return; }
    if (!nschAttrExpression(out, 0, i, attr.value, 20)) return;
  }
  let runs = 0;
  for (const child of node.children) {
    if (nodes[child]!.kind !== 1) { nschFail(out, mode === 1 ? 6 : 27, child); return; }
    if (++runs > 1) { nschFail(out, 7, child); return; }
  }
  if (runs === 0) nschFail(out, mode === 1 ? 6 : 27, 0);
}
function nschCoverage(r: NscElementReader, out: number[]): void {
  const text = r.blob(); let at = 0;
  while (at < text.length) {
    const first = text[at]!;
    if (first === 123) { const close = nsccFind(text, at + 1, 125); at = close < 0 ? text.length : close + 1; continue; }
    const size = first < 128 ? 1 : first >= 192 && first < 224 ? 2 : first < 240 && first >= 224 ? 3 : first >= 240 && first < 248 ? 4 : 0;
    if (size === 0) { nschEmit(out, 255, 8, at, 1, 65533); return; }
    if (size > text.length - at) { nschEmit(out, 255, 8, at, text.length - at, 65533); return; }
    let point = first & (size === 1 ? 127 : size === 2 ? 31 : size === 3 ? 15 : 7), valid = true;
    for (let i = 1; i < size; i++) { const b = text[at + i]!; if (b < 128 || b > 191) valid = false; point = point * 64 + (b & 63); }
    if (!valid || size === 2 && point < 128 || size === 3 && point < 2048 || size === 4 && point < 65536 || point > 1114111 || point >= 55296 && point <= 57343) {
      nschEmit(out, 255, 8, at, size, 65533); return;
    }
    if (point >= 32 && point !== 127) nschEmit(out, 3, 0, at, size, point);
    at += size;
  }
}
function nschTypes(r: NscElementReader, out: number[]): void {
  const count = r.word(), root = r.word(), nodes: number[][] = [], kinds: number[] = [];
  if (count === 0 || count > 64 || root >= count) throw new Error("invalid structural expression tree");
  for (let i = 0; i < count; i++) {
    const row: number[] = []; for (let j = 0; j < 11; j++) row.push(r.word());
    const kind = row[0]!, fn = row[1]!, argc = row[2]!;
    if (kind > 20 || fn > 16 || argc > 4 || row[10]! > 4 || row[9]! > 65535) throw new Error("invalid structural expression node");
    if ((kind === 5 || kind === 6) && row[3]! >= i || kind >= 7 && kind <= 19 && (row[3]! >= i || row[4]! >= i)) throw new Error("invalid structural operand");
    if (kind === 20) {
      const min = fn === 0 || fn === 9 || fn === 10 || fn === 16 ? 2 : fn === 15 ? 3 : 1, max = fn === 2 ? 2 : min;
      if (argc < min || argc > max) throw new Error("invalid structural arity");
      for (let j = 0; j < argc; j++) if (row[5 + j]! >= i) throw new Error("invalid structural argument");
    }
    nodes.push(row);
  }
  for (let i = 0; i < count; i++) {
    const n = nodes[i]!, kind = n[0]!, fn = n[1]!, left = kinds[n[3]!] ?? 0, right = kinds[n[4]!] ?? 0;
    let result = 0, error = 0;
    const badNumber = (k: number): boolean => k !== 0 && k !== 2 && k !== 3;
    if (kind < 4) result = kind === 0 ? 2 : kind === 1 ? 3 : kind === 2 ? 1 : 4;
    else if (kind === 4) result = n[10]!;
    else if (kind === 5) { result = left; if (badNumber(left)) error = 1; }
    else if (kind === 6) { result = 4; if (left !== 0 && left !== 4) error = 2; }
    else if (kind >= 7 && kind <= 10) {
      result = kind === 10 ? 3 : left === 0 || right === 0 ? 0 : left === 2 && right === 2 ? 2 : 3;
      if (badNumber(left) || badNumber(right)) error = 3;
    } else if (kind === 11) result = 1;
    else if (kind === 12 || kind === 13) result = 4;
    else if (kind >= 14 && kind <= 17) { result = 4; if (badNumber(left) || badNumber(right)) error = 4; }
    else if (kind === 18 || kind === 19) { result = 4; if (left !== 0 && left !== 4 || right !== 0 && right !== 4) error = 2; }
    else {
      const a = kinds[n[5]!] ?? 0, b = kinds[n[6]!] ?? 0, c = kinds[n[7]!] ?? 0;
      const bad = (k: number, expected: number): boolean => k !== 0 && k !== expected;
      result = fn === 9 || fn === 10 ? a === 0 || b === 0 ? 0 : a === 2 && b === 2 ? 2 : 3 : fn === 11 ? a : fn >= 12 && fn <= 14 ? 2 : 1;
      if (fn === 0) { if (badNumber(a) || bad(b, 2)) error = 32 + fn; }
      else if (fn === 2) { if (badNumber(a) || n[2]! > 1 && bad(b, 2)) error = 32 + fn; }
      else if (fn === 1 || fn >= 3 && fn <= 5) { if (bad(a, 2)) error = 32 + fn; }
      else if (fn >= 6 && fn <= 8) { if (bad(a, 1)) error = 32 + fn; }
      else if (fn === 9 || fn === 10) { if (badNumber(a) || badNumber(b)) error = 32 + fn; }
      else if (fn >= 11 && fn <= 14) { if (badNumber(a)) error = 32 + fn; }
      else if (fn === 15) { if (bad(a, 2) || bad(b, 1) || bad(c, 1)) error = 32 + fn; }
      else if (bad(a, 2) || bad(b, 2)) error = 32 + fn;
    }
    if (error !== 0) { nschEmit(out, 255, error, i, n[9]!); return; }
    kinds.push(result);
  }
  nschEmit(out, 0, 0, kinds[root]!);
}
function nscvMarkupShapes(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 115 || input[1] !== 1 || input[2]! > 4 || input[3]! > 1) throw new Error("invalid markup shape header");
  const r = new NscElementReader(input), out: number[] = [], mode = input[2]!;
  if (mode < 3) nschShape(r, mode, out);
  else if (mode === 3) nschTypes(r, out);
  else nschCoverage(r, out);
  if (r.at !== input.length) throw new Error("trailing markup shape facts");
  const count = out.length / 7, bytes = new Uint8Array(input[3] === 0 ? 16 : 16 + count * 48), wire = new DataView(bytes.buffer);
  bytes[0] = 115; bytes[1] = 1; bytes[2] = input[3]!; wire.setFloat64(8, count, true);
  if (input[3] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, from = i * 7; bytes[at] = out[from]!; bytes[at + 1] = out[from + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, out[from + j + 2]!, true);
  }
  return bytes;
}
