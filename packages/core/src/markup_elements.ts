/** Runtime element, attribute and event coordination (111). Native supplies
 * schema/reflection facts, exact conversions, borrowed storage and callbacks.
 * Programs preserve capability order, including errors after earlier effects.
 */
class NscElementReader {
  at: number = 4;
  readonly bytes: Uint8Array;
  readonly wire: DataView;
  constructor(bytes: Uint8Array) { this.bytes = bytes; this.wire = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  word(): number {
    if (this.bytes.length - this.at < 8) throw new Error("short element word");
    const n = this.wire.getFloat64(this.at, true); this.at += 8;
    if (!Number.isSafeInteger(n) || n < 0) throw new Error("invalid element integer");
    return n;
  }
  flag(): boolean { const n = this.word(); if (n > 1) throw new Error("invalid element flag"); return n !== 0; }
  blob(): Uint8Array {
    const n = this.word(); if (n > this.bytes.length - this.at) throw new Error("short element bytes");
    const value = this.bytes.subarray(this.at, this.at + n); this.at += n; return value;
  }
  names(): Uint8Array[] { const n = this.word(), out: Uint8Array[] = []; for (let i = 0; i < n; i++) out.push(this.blob()); return out; }
}
interface NscElementAttr { readonly name: Uint8Array; readonly raw: Uint8Array; readonly literal: boolean; readonly typedLiteral: boolean; readonly value: Uint8Array }
interface NscElementChild { readonly kind: number; readonly name: Uint8Array; readonly text: Uint8Array }
interface NscElementNode { readonly name: Uint8Array; readonly attrs: readonly NscElementAttr[]; readonly children: readonly NscElementChild[] }
function nsceEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}
function nsceNamed(a: Uint8Array, b: string): boolean { return nsceEqual(a, new TextEncoder().encode(b)); }
function nsceIn(a: Uint8Array, names: readonly Uint8Array[]): boolean { for (const name of names) if (nsceEqual(a, name)) return true; return false; }
function nsceOne(a: Uint8Array, names: readonly string[]): boolean { for (const name of names) if (nsceNamed(a, name)) return true; return false; }
function nsceStartsEvent(a: Uint8Array): boolean { return a.length >= 3 && a[0] === 111 && a[1] === 110 && a[2] === 45; }
function nsceEmit(out: number[], action: number, code: number = 0, a: number = 0, b: number = 0, c: number = 0): void { out.push(action, code, a, b, c, 0, 0); }
function nsceFail(out: number[], code: number, child: number = 0): void { nsceEmit(out, 255, code, child); }
function nsceAttr(node: NscElementNode, name: string): number { for (let i = 0; i < node.attrs.length; i++) if (nsceNamed(node.attrs[i]!.name, name)) return i; return -1; }
function nsceNode(r: NscElementReader): NscElementNode {
  const name = r.blob(), count = r.word(), attrs: NscElementAttr[] = [];
  for (let i = 0; i < count; i++) {
    const name = r.blob(), raw = r.blob(), cached = r.word();
    if (cached > 6) throw new Error("invalid cached attribute kind");
    const literal = raw.length === 0 || raw[0] !== 123;
    // A cached kind is storage metadata. Without a cache, on-* values use
    // message grammar and cannot be literals, even for a plain byte value.
    const typedLiteral = cached === 0 ? literal && !nsceStartsEvent(name) : cached === 1;
    attrs.push({ name, raw, literal, typedLiteral, value: literal ? raw : new Uint8Array(0) });
  }
  const length = r.word(), children: NscElementChild[] = [];
  for (let i = 0; i < length; i++) { const kind = r.word(); if (kind > 8) throw new Error("invalid element child kind"); children.push({ kind, name: r.blob(), text: r.blob() }); }
  return { name, attrs, children };
}
function nsceBlank(bytes: Uint8Array): boolean { for (const byte of bytes) if (byte !== 32 && byte !== 9 && byte !== 13 && byte !== 10) return false; return true; }
function nsceNonblank(node: NscElementNode, name: string): boolean { const at = nsceAttr(node, name); return at >= 0 && !nsceBlank(node.attrs[at]!.raw); }
function nsceMetadata(child: NscElementChild, name: string): boolean { return child.kind === 0 && nsceNamed(child.name, name); }
function nsceElement(r: NscElementReader, out: number[]): void {
  const node = nsceNode(r), kind = r.blob(), hit = r.flag(), stacks = r.flag(), takesText = r.flag(), takesChildren = r.flag();
  const a11y = r.word(), schemaText = r.flag(), holdsChildren = r.flag(); if (a11y > 4) throw new Error("invalid accessible name rule");
  const nonHit = r.names(), dead = r.names(), overflow = r.names(), textSizes = r.names(), controlSizes = r.names(), roles = r.names(), containerRoles = r.names();
  let menu = -1, reactions = -1;
  for (let i = 0; i < node.children.length; i++) {
    if (!nsceMetadata(node.children[i]!, "context-menu")) continue;
    if (menu >= 0) { nsceFail(out, 10, i + 1); return; }
    let eligible = !nsceIn(node.name, nonHit);
    for (const name of ["on-press", "on-double-press", "on-toggle", "on-hold", "on-drag"]) if (nsceAttr(node, name) >= 0) eligible = true;
    if (!eligible) { nsceFail(out, 11, i + 1); return; }
    nsceEmit(out, 10, 0, i); menu = i;
  }
  for (let i = 0; i < node.children.length; i++) {
    if (!nsceMetadata(node.children[i]!, "reactions")) continue;
    if (!nsceNamed(kind, "bubble")) { nsceFail(out, 8, i + 1); return; }
    if (reactions >= 0) { nsceFail(out, 12, i + 1); return; }
    nsceEmit(out, 11, 0, i); reactions = i;
  }
  if (nsceNamed(kind, "bubble") && nsceAttr(node, "text") >= 0) { nsceFail(out, 13); return; }
  if (menu >= 0 || reactions >= 0) nsceEmit(out, 12, 0, menu + 1, reactions + 1);
  if (!hit) for (const attr of node.attrs) {
    if (nsceStartsEvent(attr.name) && nsceIn(attr.name.subarray(3), dead)) { nsceFail(out, 14); return; }
    if (nsceNamed(attr.name, "autofocus")) { nsceFail(out, 15); return; }
  }
  if (stacks) for (const attr of node.attrs) if (nsceNamed(attr.name, "gap")) { nsceFail(out, 16); return; }
  if (!nsceNamed(kind, "text")) for (const attr of node.attrs) {
    if (nsceNamed(attr.name, "wrap")) { nsceFail(out, 17); return; }
    if (nsceNamed(attr.name, "overflow")) { nsceFail(out, 18); return; }
  }
  if (!nsceNamed(kind, "textarea")) for (const attr of node.attrs) if (nsceNamed(attr.name, "submit-on-enter")) { nsceFail(out, 19); return; }
  for (const attr of node.attrs) if (nsceNamed(attr.name, "overflow") && attr.literal && !nsceIn(attr.value, overflow)) { nsceFail(out, 20); return; }
  for (const attr of node.attrs) if (nsceNamed(attr.name, "size") && attr.literal) {
    if (nsceIn(attr.value, textSizes)) { if (!nsceNamed(kind, "text")) { nsceFail(out, 21); return; } }
    else if (!nsceIn(attr.value, controlSizes)) { nsceFail(out, 22); return; }
  }
  if (nsceNamed(kind, "split")) {
    let panes = 0;
    for (let i = 0; i < node.children.length; i++) if (i !== menu && i !== reactions) {
      if (node.children[i]!.kind === 0 || node.children[i]!.kind === 6) panes++;
      else { nsceFail(out, 23, i + 1); return; }
    }
    if (panes !== 2) { nsceFail(out, 23); return; }
  }
  if (nsceNamed(kind, "image")) {
    if (nsceAttr(node, "image") < 0) { nsceFail(out, 24); return; }
    if (node.children.length > 0) { nsceFail(out, 25); return; }
  }
  if (nsceNamed(kind, "terminal")) {
    if (nsceAttr(node, "pty") < 0) { nsceFail(out, 26); return; }
    if (node.children.length > 0) { nsceFail(out, 27); return; }
  }
  const roleIndex = nsceAttr(node, "role"), role = roleIndex < 0 ? null : node.attrs[roleIndex]!;
  let hasName = nsceNonblank(node, "label") || nsceNonblank(node, "text");
  for (const child of node.children) if (child.kind === 1 && !nsceBlank(child.text)) hasName = true;
  if (role !== null && role.literal && nsceNamed(role.value, "radiogroup") && !nsceNonblank(node, "label")) { nsceFail(out, 28); return; }
  if (a11y === 2 && !hasName) { nsceFail(out, nsceAttr(node, "icon") >= 0 ? 29 : 30); return; }
  if (a11y === 3 && !nsceNonblank(node, "label") && !nsceNonblank(node, "placeholder") && !(schemaText && hasName)) { nsceFail(out, 31); return; }
  if (a11y === 4 && !nsceNonblank(node, "label")) { nsceFail(out, 28); return; }
  if (role !== null && role.literal) {
    if (!nsceIn(role.value, roles)) { nsceFail(out, 32); return; }
    if (nsceIn(role.value, containerRoles) && !holdsChildren) { nsceFail(out, 33); return; }
  }
  nsceEmit(out, 15);
  if (menu >= 0) nsceEmit(out, 16, 0, menu);
  let contentCount = 0, hasSpan = false, hasElements = false;
  for (let i = 0; i < node.children.length; i++) if (i !== menu && i !== reactions) {
    contentCount++; const child = node.children[i]!;
    if (nsceMetadata(child, "span")) hasSpan = true;
    if (child.kind !== 1 && !nsceMetadata(child, "context-menu")) hasElements = true;
  }
  if (nsceNamed(kind, "icon")) {
    const name = nsceAttr(node, "name");
    if (name < 0) { nsceFail(out, 34); return; }
    if (contentCount > 0) { nsceFail(out, 35); return; }
    nsceEmit(out, 20, 0, name); return;
  }
  if (nsceNamed(kind, "text") && hasSpan) { nsceEmit(out, 26); return; }
  const composite = takesChildren && hasElements;
  if (composite) for (let i = 0; i < node.children.length; i++) if (i !== menu && i !== reactions && node.children[i]!.kind === 1) { nsceFail(out, 36, i + 1); return; }
  if (takesText && !composite) { nsceEmit(out, 21, 0, contentCount === 0 ? 0 : 1, nsceNamed(kind, "avatar") ? 1 : 0); return; }
  nsceEmit(out, 22);
  if (nsceNamed(kind, "tabs")) nsceEmit(out, 23);
  nsceEmit(out, 24);
  if (reactions >= 0) nsceEmit(out, 25, 0, reactions);
}
function nsceAttrs(r: NscElementReader, out: number[]): void {
  const node = nsceNode(r), colors = r.names(), options = r.names();
  const sources = ["source-x", "source-y", "source-width", "source-height"];
  let any = false; for (const name of sources) if (nsceAttr(node, name) >= 0) any = true;
  if (any) {
    if (!nsceOne(node.name, ["avatar", "image"])) { nsceFail(out, 40); return; }
    if (nsceAttr(node, "image") < 0) { nsceFail(out, 41); return; }
    for (const name of sources) if (nsceAttr(node, name) < 0) { nsceFail(out, 42); return; }
    nsceEmit(out, 20);
  }
  for (let i = 0; i < node.attrs.length; i++) {
    const name = node.attrs[i]!.name;
    if (nsceNamed(name, "kind")) continue;
    if (nsceStartsEvent(name)) { nsceEmit(out, 1, 0, i); continue; }
    const direct = ["key", "global-key", "focusable", "role", "label", "image"];
    let selected = -1; for (let j = 0; j < direct.length; j++) if (nsceNamed(name, direct[j]!)) selected = j;
    if (selected >= 0) { nsceEmit(out, selected + 2, 0, i); continue; }
    if (nsceOne(name, sources)) continue;
    if (nsceNamed(name, "surface")) { nsceEmit(out, 8, 0, i); continue; }
    if (nsceNamed(name, "pty")) { nsceEmit(out, 9, 0, i); continue; }
    if (nsceNamed(name, "scrollback") && !nsceNamed(node.name, "terminal")) { nsceFail(out, 43); return; }
    if (nsceNamed(name, "text") && nsceNamed(node.name, "terminal")) { nsceFail(out, 44); return; }
    if (nsceOne(name, ["controls", "autoplay", "loop", "muted"])) { nsceFail(out, 45); return; }
    if (nsceNamed(name, "name")) { if (!nsceNamed(node.name, "icon")) { nsceFail(out, 46); return; } continue; }
    const routed = ["icon", "anchor", "anchor-alignment", "anchor-offset", "quiet-hover"];
    selected = -1; for (let j = 0; j < routed.length; j++) if (nsceNamed(name, routed[j]!)) selected = j;
    if (selected >= 0) { nsceEmit(out, selected + 10, 0, i); continue; }
    selected = -1; for (let j = 0; j < colors.length; j++) if (nsceEqual(name, colors[j]!)) { selected = j; break; }
    if (selected >= 0 || nsceNamed(name, "radius")) { if (!node.attrs[i]!.typedLiteral) { nsceFail(out, 48); return; } nsceEmit(out, 15, 0, i, selected < 0 ? colors.length : selected); continue; }
    selected = -1; for (let j = 0; j < options.length; j++) if (nsceEqual(name, options[j]!)) { selected = j; break; }
    if (selected >= 0) nsceEmit(out, 16, 0, i, selected); else { nsceFail(out, 47); return; }
  }
}
function nsceEvents(r: NscElementReader, out: number[]): void {
  const typed = r.flag(), name = r.blob(), element = r.blob(), payload = r.flag(), dismiss = r.names();
  if (!typed) { nsceFail(out, 50); return; }
  if (nsceNamed(name, "input")) { nsceEmit(out, 1); return; }
  if (nsceNamed(name, "scroll")) { if (!nsceNamed(element, "scroll")) { nsceFail(out, 51); return; } nsceEmit(out, 2); return; }
  if (nsceNamed(name, "terminal")) {
    if (!nsceNamed(element, "terminal")) { nsceFail(out, 52); return; }
    if (payload) { nsceFail(out, 53); return; } nsceEmit(out, 3); return;
  }
  if (nsceNamed(name, "resize")) { if (!nsceNamed(element, "split")) { nsceFail(out, 54); return; } nsceEmit(out, 4); return; }
  if (nsceNamed(name, "drag")) { nsceEmit(out, 5); return; }
  if (nsceNamed(name, "change") && nsceNamed(element, "slider") && !payload) nsceEmit(out, 6);
  nsceEmit(out, 7); // Even an unknown event constructs its message first.
  const ordinary = ["press", "double-press", "toggle", "change", "submit", "dismiss", "hold", "hover-enter", "hover-leave", "reach-start", "reach-end"];
  let selected = -1; for (let i = 0; i < ordinary.length; i++) if (nsceNamed(name, ordinary[i]!)) selected = i;
  if (selected === 5 && !nsceIn(element, dismiss)) { nsceFail(out, 55); return; }
  if (selected === 9 && !nsceNamed(element, "scroll")) selected = -1;
  if (selected === 10 && !nsceNamed(element, "scroll")) { nsceFail(out, 56); return; }
  if (selected < 0) { nsceFail(out, 57); return; }
  nsceEmit(out, 8, 0, selected);
}
function nscvMarkupElements(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 111 || input[1] !== 1 || input[2]! > 4 || input[3]! > 1) throw new Error("invalid element header");
  const r = new NscElementReader(input), out: number[] = [], mode = input[2]!;
  if (mode === 0) {
    const name = r.blob(), names = r.names();
    const special = ["virtual-window", "virtual-list", "markdown", "code", "stepper", "timeline", "timeline-item", "chart", "video", "input-group"];
    let selected = -1; for (let i = 0; i < special.length; i++) if (nsceNamed(name, special[i]!)) selected = i;
    if (selected >= 0) nsceEmit(out, 1, 0, selected);
    else {
      const misplaced = ["step", "series", "context-menu", "input-group-actions", "span", "reactions"];
      selected = -1; for (let i = 0; i < misplaced.length; i++) if (nsceNamed(name, misplaced[i]!)) selected = i;
      if (selected >= 0) nsceFail(out, selected + 3);
      else { for (let i = 0; i < names.length; i++) if (nsceEqual(name, names[i]!)) { selected = i; break; } if (selected < 0) nsceFail(out, 9); else nsceEmit(out, 0, 0, selected); }
    }
  } else if (mode === 1) nsceElement(r, out);
  else if (mode === 2) nsceAttrs(r, out);
  else if (mode === 3) nsceEvents(r, out);
  else {
    const binding = r.flag(), defaulted = r.flag(), bare = r.flag(), kind = r.word(), empty = r.flag(); const omitted = binding && defaulted && bare; if (kind > 3) throw new Error("invalid key value kind");
    if (kind === 0) nsceEmit(out, 1); else if (kind === 2) nsceEmit(out, omitted && empty ? 0 : 2); else nsceFail(out, 58);
  }
  if (r.at !== input.length) throw new Error("trailing element facts");
  const count = out.length / 7, bytes = new Uint8Array(input[3] === 0 ? 16 : 16 + count * 48), wire = new DataView(bytes.buffer);
  bytes[0] = 111; bytes[1] = 1; bytes[2] = input[3]!; wire.setFloat64(8, count, true);
  if (input[3] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, from = i * 7; bytes[at] = out[from]!; bytes[at + 1] = out[from + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, out[from + j + 2]!, true);
  }
  return bytes;
}
