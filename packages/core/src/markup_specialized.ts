/** Specialized runtime markup programs (112). The policy sequences admission,
 * evaluation, scope changes, child construction and publication; native supplies
 * typed reflection, exact conversion, borrowed storage and builder capabilities.
 */
function nscsAttrs(node: NscElementNode, out: number[], names: readonly string[], error: number, skipKind: boolean): boolean {
  for (let i = 0; i < node.attrs.length; i++) {
    const name = node.attrs[i]!.name;
    if (skipKind && nsceNamed(name, "kind")) continue;
    let selected = -1;
    for (let j = 0; j < names.length; j++) if (names[j] === "on-*" ? nsceStartsEvent(name) : nsceNamed(name, names[j]!)) { selected = j; break; }
    if (selected < 0) { nsceFail(out, error); return false; }
    nsceEmit(out, selected + 1, 0, i);
  }
  return true;
}
// Source-known shapes are admitted by static lowering. These programs retain
// first-occurrence channels in the static engine's fixed evaluation order.
function nscsStaticAttrs(node: NscElementNode, out: number[], names: readonly string[]): void {
  for (let i = 0; i < names.length; i++) {
    const index = nsceAttr(node, names[i]!);
    if (index >= 0) nsceEmit(out, i + 1, 0, index);
  }
}
function nscsNode(r: NscElementReader, out: number[], mode: number): void {
  const node = nsceNode(r);
  const kind = mode === 14 ? r.word() : 0;
  const windowFacts = mode === 0 ? [r.flag(), r.flag(), r.flag(), r.flag()] : [];
  const full = mode === 1 ? r.flag() : false;
  if (mode === 22) {
    nscsStaticAttrs(node, out, ["label", "width", "height", "min-width", "grow", "key", "global-key"]);
    nsceEmit(out, 100);
    if (node.children.length > 1) nsceEmit(out, 101, 0, 1);
    nsceEmit(out, 200); return;
  }
  if (mode === 23) {
    nscsStaticAttrs(node, out, ["gap", "key", "global-key"]);
    nsceEmit(out, 100);
    nsceEmit(out, 200); return;
  }
  if (mode === 24) {
    nscsStaticAttrs(node, out, ["gap", "grow", "key", "global-key", "label"]);
    nsceEmit(out, 100);
    nsceEmit(out, 200); return;
  }
  if (mode === 25) {
    nscsStaticAttrs(node, out, ["title", "description", "meta", "indicator", "icon", "variant", "connector", "selected", "on-press", "key", "global-key"]);
    nsceEmit(out, 200); return;
  }
  if (mode === 26) {
    nscsStaticAttrs(node, out, ["y-min", "y-max", "grid-lines", "baseline", "x-labels", "y-labels", "hover-details", "stroke-width", "width", "height", "grow", "padding", "key", "global-key", "label"]);
    nsceEmit(out, 100);
    for (let i = 0; i < node.children.length; i++) nsceEmit(out, 101, 0, i);
    nsceEmit(out, 200); return;
  }
  if (mode === 27) {
    nscsStaticAttrs(node, out, ["kind", "values", "color", "label"]);
    nsceEmit(out, 200); return;
  }
  if (mode === 28) {
    nscsStaticAttrs(node, out, ["src", "controls", "autoplay", "loop", "muted", "width", "height", "grow", "label", "key", "global-key"]);
    nsceEmit(out, 200); return;
  }
  if (mode === 29) {
    nscsStaticAttrs(node, out, ["source", "on-link", "on-details", "details-expanded", "images", "issue-link-base"]);
    nsceEmit(out, 200); return;
  }
  if (mode === 30) {
    nscsStaticAttrs(node, out, ["source", "language", "line-numbers", "added-lines", "removed-lines", "editable", "on-input", "wrap", "width", "height", "min-width", "grow", "label", "key", "global-key"]);
    nsceEmit(out, 200); return;
  }
  if (mode === 31) {
    // Inherited slot steps interpolate in their lexical site scope; ordinary
    // steps use the stepper's scope. The step array precedes every label.
    const steps = r.word(), slot = r.flag();
    if (slot ? node.children.length !== 1 : steps !== node.children.length) throw new Error("invalid static stepper facts");
    nscsStaticAttrs(node, out, ["active", "key", "global-key", "label"]);
    nsceEmit(out, 100);
    for (let i = 0; i < steps; i++) nsceEmit(out, slot ? 102 : 101, 0, i);
    nsceEmit(out, 200); return;
  }
  if (mode === 2) {
    if (node.children.length !== 0) { nsceFail(out, 1, 1); return; }
    if (!nscsAttrs(node, out, ["source", "on-link", "on-details", "details-expanded", "images", "issue-link-base"], 2, true)) return;
    if (nsceAttr(node, "source") < 0) { nsceFail(out, 3, 0); return; }
    nsceEmit(out, 200); return;
  }
  if (mode === 3) {
    if (node.children.length !== 0) { nsceFail(out, 4, 1); return; }
    if (!nscsAttrs(node, out, ["source", "language", "line-numbers", "added-lines", "removed-lines", "editable", "on-input", "wrap", "width", "height", "min-width", "grow", "key", "global-key", "label"], 5, true)) return;
    if (nsceAttr(node, "source") < 0) { nsceFail(out, 6, 0); return; }
    nsceEmit(out, 200); return;
  }
  if (mode === 4) {
    if (!nscsAttrs(node, out, ["active", "key", "global-key", "label"], 7, true)) return;
    if (nsceAttr(node, "active") < 0) { nsceFail(out, 8, 0); return; }
    nsceEmit(out, 100); return;
  }
  if (mode === 5) {
    if (!nscsAttrs(node, out, ["label", "width", "height", "min-width", "grow", "key", "global-key"], 9, true)) return;
    let entry = false, actions = false;
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i]!;
      if (child.kind !== 0) { nsceFail(out, 10, i + 1); return; }
      if (nsceNamed(child.name, "textarea")) {
        if (entry || actions) { nsceFail(out, 10, i + 1); return; }
        nsceEmit(out, 100, 0, i); entry = true;
      } else if (nsceNamed(child.name, "input-group-actions")) {
        if (!entry) { nsceFail(out, 11, i + 1); return; }
        if (actions) { nsceFail(out, 10, i + 1); return; }
        nsceEmit(out, 101, 0, i); actions = true;
      } else { nsceFail(out, 10, i + 1); return; }
    }
    if (!entry) { nsceFail(out, 11, 0); return; }
    nsceEmit(out, 200); return;
  }
  if (mode === 6) {
    if (!nscsAttrs(node, out, ["gap", "key", "global-key"], 12, true)) return;
    for (let i = 0; i < node.children.length; i++) if (node.children[i]!.kind === 1) { nsceFail(out, 13, i + 1); return; }
    nsceEmit(out, 100); nsceEmit(out, 200); return;
  }
  if (mode === 7) {
    if (!nscsAttrs(node, out, ["gap", "grow", "key", "global-key", "label"], 14, true)) return;
    nsceEmit(out, 100); nsceEmit(out, 200); return;
  }
  if (mode === 8) {
    if (node.children.length !== 0) { nsceFail(out, 15, 1); return; }
    if (!nscsAttrs(node, out, ["title", "description", "meta", "indicator", "icon", "variant", "connector", "selected", "on-press", "on-*", "key", "global-key"], 16, true)) return;
    if (nsceAttr(node, "title") < 0) { nsceFail(out, 17, 0); return; }
    nsceEmit(out, 200); return;
  }
  if (mode === 9) {
    if (!nscsAttrs(node, out, ["on-*", "y-min", "y-max", "grid-lines", "baseline", "x-labels", "y-labels", "hover-details", "stroke-width", "width", "height", "grow", "padding", "key", "global-key", "label"], 18, true)) return;
    if (node.children.length === 0) { nsceFail(out, 19, 0); return; }
    nsceEmit(out, 100);
    for (let i = 0; i < node.children.length; i++) {
      if (!nsceMetadata(node.children[i]!, "series")) { nsceFail(out, 20, i + 1); return; }
      nsceEmit(out, 101, 0, i);
    }
    nsceEmit(out, 200); return;
  }
  if (mode === 10) {
    if (node.children.length !== 0) { nsceFail(out, 21, 1); return; }
    if (!nscsAttrs(node, out, ["src", "controls", "autoplay", "loop", "muted", "width", "height", "grow", "label", "key", "global-key"], 22, true)) return;
    nsceEmit(out, 200); return;
  }
  if (mode === 11) {
    if (node.children.length !== 0) { nsceFail(out, 23, 1); return; }
    if (!nscsAttrs(node, out, ["kind", "values", "color", "label"], 24, false)) return;
    if (nsceAttr(node, "values") < 0) { nsceFail(out, 25, 0); return; }
    nsceEmit(out, 200); return;
  }
  if (mode === 12) {
    for (const attr of node.attrs) if (nsceOne(attr.name, ["wrap", "overflow"])) { nsceFail(out, 26, 0); return; }
    nsceEmit(out, 100);
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i]!;
      if (child.kind === 1) nsceEmit(out, 101, 0, i);
      else if (nsceMetadata(child, "span")) nsceEmit(out, 102, 0, i);
      else { nsceFail(out, 27, i + 1); return; }
    }
    nsceEmit(out, 200); return;
  }
  if (mode === 13 || mode === 21) {
    nsceEmit(out, 100); // shared span-shape capability precedes every evaluation
    const names = ["weight", "scale", "mono", "italic", "underline", "foreground"];
    if (mode === 21) {
      // Static views evaluate the first occurrence of each channel in this
      // order, independently of the source attribute order.
      for (let j = 0; j < names.length; j++) {
        const index = nsceAttr(node, names[j]!);
        if (index >= 0) nsceEmit(out, j + 1, 0, index);
      }
    } else {
      for (let i = 0; i < node.attrs.length; i++) {
        for (let j = 0; j < names.length; j++) if (nsceNamed(node.attrs[i]!.name, names[j]!)) nsceEmit(out, j + 1, 0, i);
      }
    }
    nsceEmit(out, 101); nsceEmit(out, 200); return;
  }
  if (mode === 14) {
    if (!nsceNamed(node.name, "step") || kind !== 0) { nsceFail(out, 28, 0); return; }
    for (const attr of node.attrs) if (!nsceNamed(attr.name, "kind")) { nsceFail(out, 29, 0); return; }
    nsceEmit(out, 101); return;
  }
  if (mode === 16) {
    for (let i = 0; i < node.attrs.length; i++) if (!nsceOne(node.attrs[i]!.name, ["window", "each", "as"])) nsceEmit(out, 1, 0, i);
    nsceEmit(out, 100); nsceEmit(out, 200); return;
  }
  if (mode === 0) {
    const nested = windowFacts[0]!, full = windowFacts[1]!, windowsFull = windowFacts[2]!, duplicate = windowFacts[3]!;
    if (nested) { nsceFail(out, 30, 0); return; }
    if (full || node.children.length !== 1 || (node.children[0]!.kind !== 0 && node.children[0]!.kind !== 6)) { nsceFail(out, 31, 0); return; }
    if (nsceAttr(node, "id") < 0) { nsceFail(out, 32, 0); return; }
    if (nsceAttr(node, "as") < 0) { nsceFail(out, 33, 0); return; }
    if (windowsFull) { nsceFail(out, 34, 0); return; }
    if (duplicate) { nsceFail(out, 35, 0); return; }
    for (let i = 1; i <= 6; i++) nsceEmit(out, i);
    nsceEmit(out, 100); // exact logical range fact, before estimator lookup
    if (nsceAttr(node, "extent-estimate") >= 0) nsceEmit(out, 7);
    nsceEmit(out, 101); nsceEmit(out, 102); nsceEmit(out, 103); nsceEmit(out, 200); return;
  }
  if (mode === 1) {
    if (nsceAttr(node, "window") < 0) { nsceFail(out, 36, 0); return; }
    nsceEmit(out, 100); // lookup, admission, then consumed publication
    if (nsceAttr(node, "each") < 0) { nsceFail(out, 37, 0); return; }
    if (nsceAttr(node, "as") < 0) { nsceFail(out, 38, 0); return; }
    if (full || node.children.length !== 1) { nsceFail(out, 39, 0); return; }
    nsceEmit(out, 101); return;
  }
  throw new Error("invalid specialized node mode");
}
function nscvMarkupSpecialized(input: Uint8Array): Uint8Array {
  if (input.length < 4 || input[0] !== 112 || input[1] !== 1 || input[2]! > 31 || input[3]! > 1) throw new Error("invalid specialized header");
  const r = new NscElementReader(input), out: number[] = [], mode = input[2]!;
  if (mode === 15) {
    const count = r.word(), expected = r.word();
    if (count !== expected) { nsceFail(out, 40); }
    else { for (let i = 0; i < count; i++) nsceEmit(out, 1, 0, i); nsceEmit(out, 100); nsceEmit(out, 200); }
  } else if (mode === 17) {
    const phase = r.word(), admitted = r.flag();
    if (phase > 2) throw new Error("invalid virtual window phase");
    if (!admitted) nsceFail(out, phase === 0 ? 41 : phase === 1 ? 42 : 43); else nsceEmit(out, 0);
  } else if (mode === 18) {
    const virtual = r.flag(), consumed = r.flag();
    if (!virtual) nsceFail(out, 44); else if (consumed) nsceFail(out, 45); else nsceEmit(out, 0);
  } else if (mode === 19) {
    if (!r.flag()) nsceFail(out, 39); else nsceEmit(out, 0);
  } else if (mode === 20) {
    const count = r.word(), capacity = r.word(), duplicate = r.flag();
    if (count >= capacity) nsceFail(out, 34);
    else if (duplicate) nsceFail(out, 35);
    else nsceEmit(out, 0);
  } else nscsNode(r, out, mode);
  if (r.at !== input.length) throw new Error("trailing specialized facts");
  const count = out.length / 7, bytes = new Uint8Array(input[3] === 0 ? 16 : 16 + count * 48), wire = new DataView(bytes.buffer);
  bytes[0] = 112; bytes[1] = 1; bytes[2] = input[3]!; wire.setFloat64(8, count, true);
  if (input[3] === 1) for (let i = 0; i < count; i++) {
    const at = 16 + i * 48, from = i * 7; bytes[at] = out[from]!; bytes[at + 1] = out[from + 1]!;
    for (let j = 0; j < 5; j++) wire.setFloat64(at + 8 + j * 8, out[from + j + 2]!, true);
  }
  return bytes;
}
