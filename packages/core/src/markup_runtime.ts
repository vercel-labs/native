/** Residual runtime markup coordination (114). Programs order native typed
 * collection access, exact key conversion, interpolation and borrowed storage.
 * Names and text are raw bytes; integer identities never enter numeric fields.
 */
function nscrProgram(r: NscElementReader, out: number[], mode: number): void {
  if (mode === 0) {
    const each = r.blob(), fields = r.names(), eligible: boolean[] = [];
    for (let i = 0; i < fields.length; i++) eligible.push(r.flag());
    const declarations = r.names(), classes: number[] = [];
    for (let i = 0; i < declarations.length; i++) { const kind = r.word(); if (kind > 3) throw new Error("invalid collection class"); classes.push(kind); }
    for (let i = 0; i < fields.length; i++) if (eligible[i] && nsceEqual(each, fields[i]!)) { nsceEmit(out, 1, 0, i); return; }
    for (let i = 0; i < declarations.length; i++) if (classes[i] !== 0 && nsceEqual(each, declarations[i]!)) { nsceEmit(out, 2, 0, i, classes[i]!); return; }
    nsceEmit(out, 0);
  } else if (mode === 1) {
    const present = r.flag(), kind = r.word();
    if (kind > 3) throw new Error("invalid key value kind");
    if (!present) nsceFail(out, 1);
    else if (kind === 0 || kind === 3) nsceEmit(out, kind === 0 ? 1 : 2);
    else nsceFail(out, 2);
  } else if (mode === 2) {
    const node = nsceNode(r), names = ["source-x", "source-y", "source-width", "source-height"];
    let any = false; for (const name of names) if (nsceAttr(node, name) >= 0) any = true;
    if (!any) return;
    if (!nsceOne(node.name, ["avatar", "image"])) { nsceFail(out, 3); return; }
    if (nsceAttr(node, "image") < 0) { nsceFail(out, 4); return; }
    for (const name of names) if (nsceAttr(node, name) < 0) { nsceFail(out, 5); return; }
    nsceEmit(out, 20);
    for (let i = 0; i < names.length; i++) nsceEmit(out, 21, 0, nsceAttr(node, names[i]!), i);
    nsceEmit(out, 22);
  } else if (mode === 3) {
    const channel = r.word(), kind = r.word();
    if (channel > 1 || kind > 3) throw new Error("invalid scalar admission");
    if (channel === 0 && kind === 3) nsceEmit(out, 1);
    else if (channel === 1 && kind < 2) nsceEmit(out, kind === 1 ? 2 : 3);
    else nsceFail(out, channel === 0 ? 6 : 7);
  } else if (mode === 4) {
    const tag = r.blob(), names = r.names(), eligible: boolean[] = [];
    for (let i = 0; i < names.length; i++) eligible.push(r.flag());
    for (let i = 0; i < names.length; i++) if (eligible[i] && nsceEqual(tag, names[i]!)) { nsceEmit(out, 1, 0, i); return; }
    nsceEmit(out, 0);
  } else if (mode === 5) {
    const node = nsceNode(r);
    if (node.children.length > 1) nsceFail(out, 8);
    else if (node.children.length === 0) nsceEmit(out, 10);
    else if (node.children[0]!.kind === 1) nsceEmit(out, 11);
    else if (nsceMetadata(node.children[0]!, "span")) nsceFail(out, 9, 1);
    else nsceFail(out, 10);
  } else if (mode === 6) {
    const source = r.blob(), cached = r.flag(), count = r.word(), kinds: number[] = [];
    for (let i = 0; i < count; i++) { const kind = r.word(); if (kind > 3) throw new Error("invalid text segment"); kinds.push(kind); }
    if (!cached && count !== 0) throw new Error("raw text has cached segments");
    if (nsccFind(source, 0, 123) < 0) { nsceEmit(out, 40); return; }
    if (cached) {
      for (let i = 0; i < count; i++) {
        if (kinds[i] === 3) { nsceFail(out, 11); return; }
        nsceEmit(out, 41 + kinds[i]!, 0, i);
      }
      return;
    }
    let cursor = 0;
    while (true) {
      const open = nsccFind(source, cursor, 123);
      if (open < 0) { nsceEmit(out, 44, 0, cursor, source.length); return; }
      nsceEmit(out, 44, 0, cursor, open);
      const close = nsccFind(source, open, 125);
      if (close < 0) { nsceFail(out, 11); return; }
      const inner = nsccTrim(source, open + 1, close);
      nsceEmit(out, nsccPath(source, inner[0]!, inner[1]!) ? 45 : 46, 0, inner[0]!, inner[1]!);
      cursor = close + 1;
    }
  } else if (mode === 7) {
    const channel = r.word(), count = r.word();
    if (channel > 3) throw new Error("invalid collection channel");
    for (let i = 0; i < count; i++) {
      const kind = r.word(); if (kind > 5) throw new Error("invalid collection item kind");
      if (channel === 0 ? kind === 1 || kind === 2 : kind === channel + 2) nsceEmit(out, 30, 0, i, kind);
    }
    nsceEmit(out, 31);
  } else throw new Error("invalid runtime markup mode");
}
function nscvMarkupRuntime(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 114 || input[1] !== 1 || input[2]! > 7 || input[3]! > 1) throw new Error("invalid runtime markup header");
  const r = new NscElementReader(input), out: number[] = [];
  nscrProgram(r, out, input[2]!);
  if (r.at !== input.length) throw new Error("trailing runtime markup facts");
  const count = out.length / 7, bytes = new Uint8Array(input[3] === 0 ? 16 : 16 + count * 48), wire = new DataView(bytes.buffer);
  bytes[0] = 114; bytes[1] = 1; bytes[2] = input[3]!; wire.setFloat64(8, count, true);
  if (input[3] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, from = i * 7; bytes[at] = out[from]!; bytes[at + 1] = out[from + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, out[from + j + 2]!, true);
  }
  return bytes;
}
