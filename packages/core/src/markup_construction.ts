/** Runtime markup construction programs (110). Copied syntax and scope facts
 * select ordered native storage, reflection, evaluation and builder capabilities.
 * No model values, callbacks or borrowed pointers are retained by this owner.
 */
class NscBuildReader {
  build_at: number = 4;
  readonly build_bytes: Uint8Array;
  readonly build_wire: DataView;
  constructor(bytes: Uint8Array) { this.build_bytes = bytes; this.build_wire = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  word(): number {
    if (this.build_bytes.length - this.build_at < 8) throw new Error("short construction word");
    const n = this.build_wire.getFloat64(this.build_at, true); this.build_at += 8;
    if (!Number.isSafeInteger(n) || n < 0) throw new Error("invalid construction integer");
    return n;
  }
  blob(): Uint8Array {
    const n = this.word(); if (n > this.build_bytes.length - this.build_at) throw new Error("short construction bytes");
    const out = this.build_bytes.subarray(this.build_at, this.build_at + n); this.build_at += n; return out;
  }
}
interface NscBuildAttr { readonly name: Uint8Array; readonly value: Uint8Array }
interface NscBuildNode { readonly construction_node_id: number; readonly tag: number; readonly attrs: readonly NscBuildAttr[]; readonly children: readonly NscBuildNode[] }
function nscbEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function nscbNamed(a: Uint8Array, b: string): boolean { return nscbEqual(a, new TextEncoder().encode(b)); }
function nscbEmit(tape: number[], action: number, code: number = 0, a: number = 0, b: number = 0, c: number = 0, d: number = 0, e: number = 0): void {
  tape.push(action, code, a, b, c, d, e);
}
function nscbFail(tape: number[], code: number, node: number = 0): void { nscbEmit(tape, 255, code, node); }
function nscbNode(r: NscBuildReader): NscBuildNode {
  const construction_node_id = r.word(), tag = r.word(), count = r.word(), attrs: NscBuildAttr[] = [];
  if (tag > 8) throw new Error("invalid construction node kind");
  for (let i = 0; i < count; i++) attrs.push({ name: r.blob(), value: r.blob() });
  const length = r.word(), children: NscBuildNode[] = [];
  for (let i = 0; i < length; i++) children.push(nscbNode(r));
  return { construction_node_id, tag, attrs, children };
}
function nscbAttr(node: NscBuildNode, name: string): number {
  for (let i = 0; i < node.attrs.length; i++) if (nscbNamed(node.attrs[i]!.name, name)) return i;
  return -1;
}
function nscbSlots(node: NscBuildNode, found: number[]): void {
  if (node.tag === 8) { found.push(node.construction_node_id); return; }
  if (node.tag === 6) return;
  for (const child of node.children) nscbSlots(child, found);
}
// Tokens are byte spans into the original args attribute. Only ASCII space
// separates tokens, and only the first equals splits the name and default.
function nscbArgs(bytes: Uint8Array): number[] {
  const out: number[] = []; let at = 0;
  while (at < bytes.length) {
    if (bytes[at] === 32) { at++; continue; }
    const first = at; let equals = -1;
    while (at < bytes.length && bytes[at] !== 32) { if (bytes[at] === 61 && equals < 0) equals = at; at++; }
    out.push(first, equals < 0 ? at : equals, equals < 0 ? 0 : equals + 1, at);
  }
  return out;
}
function nscbUse(r: NscBuildReader, tape: number[]): void {
  const scopeLength = r.word(), scopeFloor = r.word(), context = r.word(), depth = r.word(), selected = r.word();
  if (scopeLength > 16 || scopeFloor > scopeLength) throw new Error("invalid construction scope");
  const use = nscbNode(r), definition = nscbNode(r);
  if (context !== 0 && selected >= context - 1 || depth >= 128) throw new Error("unadmitted template body");
  if (definition.children.length !== 1 || definition.children[0]!.tag !== 0) { nscbFail(tape, 14, definition.construction_node_id); return; }
  const slots: number[] = []; nscbSlots(definition.children[0]!, slots);
  if (slots.length > 1) { nscbFail(tape, 15, slots[1]!); return; }
  if (use.children.length !== 0 && slots.length === 0) { nscbFail(tape, 16, use.children[0]!.construction_node_id); return; }
  const argsAttribute = nscbAttr(definition, "args");
  const argsBytes = argsAttribute < 0 ? new Uint8Array(0) : definition.attrs[argsAttribute]!.value;
  const args = nscbArgs(argsBytes);
  for (const attr of use.attrs) {
    if (nscbNamed(attr.name, "template") || nscbNamed(attr.name, "on-press")) continue;
    if (attr.name.length >= 3 && attr.name[0] === 111 && attr.name[1] === 110 && attr.name[2] === 45) { nscbFail(tape, 17, use.construction_node_id); return; }
    let declared = false;
    for (let a = 0; a < args.length; a += 4) if (nscbEqual(attr.name, argsBytes.subarray(args[a]!, args[a + 1]!))) { declared = true; break; }
    if (!declared) { nscbFail(tape, 18, use.construction_node_id); return; }
  }
  nscbEmit(tape, 20, 0, selected, argsAttribute + 1);
  const press = nscbAttr(use, "on-press");
  if (press >= 0) nscbEmit(tape, 21, 0, press);
  let argCount = 0;
  for (let a = 0; a < args.length; a += 4) {
    if (scopeLength + argCount >= 16) { nscbFail(tape, 19, use.construction_node_id); return; }
    const first = args[a]!, last = args[a + 1]!, defaultFirst = args[a + 2]!, end = args[a + 3]!;
    const name = argsBytes.subarray(first, last); let attrIndex = -1;
    for (let i = 0; i < use.attrs.length; i++) if (nscbEqual(use.attrs[i]!.name, name)) { attrIndex = i; break; }
    nscbEmit(tape, 22, 0, scopeLength + argCount, first, last);
    if (attrIndex >= 0) nscbEmit(tape, 23, 0, attrIndex);
    else if (defaultFirst !== 0) {
      for (let i = defaultFirst; i < end; i++) if (argsBytes[i] === 123) { nscbFail(tape, 20, definition.construction_node_id); return; }
      if (defaultFirst < end && (argsBytes[defaultFirst] === 39 || argsBytes[defaultFirst] === 34)) { nscbFail(tape, 21, definition.construction_node_id); return; }
      nscbEmit(tape, 24, 0, defaultFirst, end);
    } else { nscbFail(tape, 22, use.construction_node_id); return; }
    nscbEmit(tape, 25, attrIndex < 0 ? 1 : 0); argCount++;
  }
  if (scopeLength + argCount >= 16) { nscbFail(tape, 19, use.construction_node_id); return; }
  nscbEmit(tape, 26, 0, scopeLength + argCount);
  nscbEmit(tape, 27, 0, scopeLength + argCount + 1, scopeLength, selected + 1, depth + 1);
  nscbEmit(tape, 28); // Provenance allocation precedes installing restoration.
  nscbEmit(tape, 29); // Build body, then restore the saved storage on every exit.
}
function nscvMarkupConstruction(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 110 || input[1] !== 1 || input[2]! > 12 || input[3]! > 1) throw new Error("invalid construction header");
  const mode = input[2]!, r = new NscBuildReader(input), tape: number[] = [];
  if (mode === 0) {
    const imports = r.word(), root = r.word();
    if (root > 1) throw new Error("invalid construction root");
    if (imports > 0) nscbFail(tape, 1); else if (root === 0) nscbFail(tape, 2); else nscbEmit(tape, 0);
  } else if (mode === 1 || mode === 2) {
    const kind = r.word(); if (kind > 8) throw new Error("invalid construction kind");
    const next = mode === 2 ? r.word() : 9, test = mode === 2 ? r.word() : 0;
    if (next > 9 || test > 1) throw new Error("invalid construction child facts");
    if (kind === 0) nscbEmit(tape, 1);
    else if (kind === 6) nscbEmit(tape, 2);
    else if (kind === 5) nscbFail(tape, 3);
    else if (kind === 7) nscbFail(tape, 4);
    else if (kind === 1) nscbFail(tape, 6);
    else if (mode === 1) nscbFail(tape, kind === 8 ? 5 : 7);
    else if (kind === 8) nscbEmit(tape, 3);
    else if (kind === 2) nscbEmit(tape, 4, 0, next === 4 ? 1 : 0);
    else if (kind === 3) { if (test === 0) nscbFail(tape, 8); else nscbEmit(tape, 5); }
    else nscbFail(tape, 9);
  } else if (mode === 3) {
    const kind = r.word(), next = r.word(), result = r.word();
    if ((kind !== 2 && kind !== 3) || next > 1) throw new Error("invalid construction branch");
    nscbEmit(tape, kind === 3 && result !== 0 ? 6 : result === 0 && next === 1 ? 6 : 0, 0, kind === 3 && result !== 0 ? 0 : 1, next);
  } else if (mode === 4) {
    const length = r.word(), floor = r.word(), name = r.blob();
    if (length > 16 || floor > length) throw new Error("invalid lookup scope");
    let found = 0;
    for (let i = 0; i < length; i++) { const entry = r.blob(); if (i >= floor && nscbEqual(entry, name)) found = i + 1; }
    nscbEmit(tape, 7, 0, found);
  } else if (mode === 5) {
    const attrs = r.word(), children = r.word(), context = r.word(), length = r.word(), floor = r.word();
    if (length > 16 || floor > length) throw new Error("invalid slot scope");
    let found = 0, content = 0;
    for (let i = 0; i < length; i++) { const kind = r.word(), children = r.word(); if (kind > 4 || kind !== 4 && children !== 0) throw new Error("invalid scope payload"); if (i >= floor && kind === 4) { found = i + 1; content = children; } }
    if (attrs > 0) nscbFail(tape, 23); else if (children > 0) nscbFail(tape, 24); else if (found === 0 && context === 0) nscbFail(tape, 5); else nscbEmit(tape, 8, 0, content === 0 ? 0 : found);
  } else if (mode === 6) {
    const each = r.word(), as = r.word(), length = r.word(), children = r.word(); let invalid = 0;
    for (let i = 0; i < children; i++) { const tag = r.word(); if (tag > 8) throw new Error("invalid loop child"); if (invalid === 0 && (tag === 1 || tag === 5 || tag === 7)) invalid = i + 1; }
    if (each > 1 || as > 1 || length > 16) throw new Error("invalid loop scope");
    if (each === 0) nscbFail(tape, 25); else if (as === 0) nscbFail(tape, 26); else if (length >= 16) nscbFail(tape, 27); else if (children === 0) nscbFail(tape, 28); else if (invalid !== 0) nscbEmit(tape, 255, 28, invalid); else nscbEmit(tape, 0);
  } else if (mode === 7) {
    const phase = r.word(), cursor = r.word(), length = r.word(), flags = r.word();
    if (phase > 3 || cursor > length) throw new Error("invalid iteration cursor");
    if (phase === 3) nscbEmit(tape, flags === 0 ? 0 : 14);
    else if (cursor === length) { if (phase === 0) nscbFail(tape, 30); else nscbEmit(tape, 0); } else nscbEmit(tape, phase === 2 ? flags === 0 ? 10 : 9 : 9, 0, cursor, cursor + 1, phase === 1 ? flags + 1 : 0, phase === 1 ? flags : 0);
  } else if (mode === 8) {
    const present = r.word(), kind = r.word(), type = r.word(), wanted = r.word();
    if (present > 1 || kind > 4) throw new Error("invalid iterable scope");
    nscbEmit(tape, present === 0 ? 12 : kind === 1 && type === wanted ? 11 : 0);
  } else if (mode === 9) {
    const typed = r.word(), present = r.word(), kind = r.word(), tail = r.word();
    if (typed > 2 || present > 1 || kind > 4 || tail > 1) throw new Error("invalid argument facts");
    if (typed === 0) nscbFail(tape, 29); else nscbEmit(tape, typed === 1 && present === 1 && (kind === 1 || kind === 3) && tail === 0 ? 11 : typed === 1 && present === 0 ? 12 : 13);
  } else if (mode === 10) {
    const length = r.word(), floor = r.word(), context = r.word(), depth = r.word(), present = r.word(), name = r.blob(), count = r.word();
    if (length > 16 || floor > length || present > 1) throw new Error("invalid template lookup scope");
    let selected = -1;
    for (let i = 0; i < count; i++) {
      const named = r.word(), value = r.blob(); if (named > 1) throw new Error("invalid template name fact");
      if (selected < 0 && named === 1 && nscbEqual(value, name)) selected = i;
    }
    if (present === 0) nscbFail(tape, 10);
    else if (selected < 0) nscbFail(tape, 11);
    else if (context !== 0 && selected >= context - 1) nscbFail(tape, 12);
    else if (depth >= 128) nscbFail(tape, 13);
    else nscbEmit(tape, 20, 0, selected);
  } else if (mode === 12) nscbUse(r, tape);
  else {
    const cursor = r.word(), length = r.word(); let found = length;
    if (cursor > length) throw new Error("invalid argument iterable cursor");
    for (let i = 0; i < length; i++) { const byte = r.word(); if (byte > 1) throw new Error("invalid iterable type"); if (i >= cursor && found === length && byte === 0) found = i; }
    nscbEmit(tape, found === length ? 0 : 9, 0, found, found + 1);
  }
  if (r.build_at !== input.length) throw new Error("trailing construction facts");
  const count = tape.length / 7, out = new Uint8Array(input[3] === 0 ? 16 : 16 + count * 48), wire = new DataView(out.buffer);
  out[0] = 110; out[1] = 1; out[2] = input[3]!; wire.setFloat64(8, count, true);
  if (input[3] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, source = i * 7;
    out[at] = tape[source]!; out[at + 1] = tape[source + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, tape[source + 2 + j]!, true);
  }
  return out;
}
