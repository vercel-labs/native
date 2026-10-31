import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["markup_elements", "markup_specialized"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvMarkupSpecialized: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupSpecialized };").toString("base64")}`);
interface Attr { name: string; raw?: string; cached?: number }
interface Child { kind?: number; name?: string; text?: string }
class Packet {
  parts: Uint8Array[];
  constructor(mode: number) { this.parts = [Uint8Array.of(112, 1, mode, 1)]; }
  word(...values: number[]): this { for (const n of values) { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, n, true); this.parts.push(b); } return this; }
  blob(value: string | Uint8Array): this { const b = typeof value === "string" ? new TextEncoder().encode(value) : value; this.word(b.length); this.parts.push(b); return this; }
  names(values: string[]): this { this.word(values.length); for (const value of values) this.blob(value); return this; }
  node(name: string, attrs: Attr[] = [], children: Child[] = []): this {
    this.blob(name).word(attrs.length);
    for (const attr of attrs) this.blob(attr.name).blob(attr.raw ?? "").word(attr.cached ?? 0);
    this.word(children.length); for (const child of children) this.word(child.kind ?? 0).blob(child.name ?? "column").blob(child.text ?? ""); return this;
  }
  bytes(): Uint8Array { return Uint8Array.from(Buffer.concat(this.parts)); }
  actions() {
    const b: Uint8Array = run(this.bytes()), v = new DataView(b.buffer), count = v.getFloat64(8, true);
    assert.equal(b.length, 16 + count * 48);
    return Array.from({ length: count }, (_, i) => ({ action: b[16 + i * 48]!, code: b[17 + i * 48]!, fields: Array.from({ length: 5 }, (_, j) => v.getFloat64(24 + i * 48 + j * 8, true)) }));
  }
}
const attrs = (...names: string[]): Attr[] => names.map(name => ({ name }));
const actions = (packet: Packet) => packet.actions().map(step => step.action);
test("specialized policy preserves leaf admission before evaluation and missing fields after attributes", () => {
  for (const [mode, name, required] of [[2, "markdown", "source"], [3, "code", "source"], [8, "timeline-item", "title"]] as const) {
    assert.deepEqual(actions(new Packet(mode).node(name, attrs(required), [{ kind: 1, text: "bad" }])), [255]);
    assert.equal(new Packet(mode).node(name, attrs(required)).actions().at(-1)!.action, 200);
  }
  assert.deepEqual(actions(new Packet(3).node("code", attrs("width", "height"))), [9, 10, 255]);
  assert.deepEqual(actions(new Packet(3).node("code", attrs("source", "width", "width", "bad"))), [1, 9, 9, 255]);
  assert.deepEqual(actions(new Packet(4).node("stepper", attrs("label"))), [4, 255]);
});
test("specialized child plans retain partial input groups allocation before chart admission and span ordering", () => {
  const late = new Packet(5).node("input-group", [], [{ name: "textarea" }, { name: "column" }]).actions();
  assert.deepEqual(late.map(step => step.action), [100, 255]); assert.equal(late[1]!.fields[0], 2);
  assert.deepEqual(actions(new Packet(5).node("input-group", [], [{ name: "input-group-actions" }])), [255]);
  assert.deepEqual(actions(new Packet(9).node("chart", [], [{ name: "series" }, { name: "text" }])), [100, 101, 255]);
  assert.deepEqual(actions(new Packet(6).node("input-group-actions", [], [{ name: "button" }, { kind: 1 }])), [255]);
  assert.deepEqual(actions(new Packet(12).node("text", [], [{ kind: 1 }, { name: "span" }, { name: "button" }])), [100, 101, 102, 255]);
  assert.deepEqual(actions(new Packet(13).node("span", attrs("scale", "weight", "scale"))), [100, 2, 1, 2, 101, 200]);
  assert.deepEqual(actions(new Packet(14).node("step", attrs("bad")).word(0)), [255]);
});
test("virtual plans preserve consumed publication before shape checks query counts rows and proxy filtering", () => {
  assert.deepEqual(actions(new Packet(1).node("virtual-list", attrs("window")).word(0)), [100, 255]);
  assert.deepEqual(actions(new Packet(15).word(2, 2)), [1, 1, 100, 200]);
  assert.deepEqual(actions(new Packet(15).word(2, 3)), [255]);
  assert.deepEqual(actions(new Packet(16).node("virtual-list", attrs("window", "label", "each", "label", "as"))), [1, 1, 100, 200]);
  const window = () => new Packet(0).node("virtual-window", attrs("id", "as", "extent-estimate"), [{ name: "column" }]);
  assert.deepEqual(actions(window().word(0, 0, 0, 0)), [1, 2, 3, 4, 5, 6, 100, 7, 101, 102, 103, 200]);
  assert.deepEqual(actions(window().word(1, 0, 0, 0)), [255]);
  for (const mode of [17, 18, 19]) {
    const packet = new Packet(mode).word(...(mode === 19 ? [1] : mode === 18 ? [1, 0] : [0, 1]));
    assert.deepEqual(actions(packet), [0]);
  }
});
test("specialized transport validates truncation reserved modes numeric facts and sizing", () => {
  const packet = new Packet(0).node("virtual-window", attrs("id", "as"), [{ name: "column" }]).word(0, 0, 0, 0);
  const bytes = packet.bytes();
  for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
  for (const at of [0, 1, 2, 3]) { const bad = bytes.slice(); bad[at] = 255; assert.throws(() => run(bad)); }
  for (const value of [-1, .25, NaN, Infinity, 2 ** 53]) { const bad = bytes.slice(); new DataView(bad.buffer).setFloat64(4, value, true); assert.throws(() => run(bad)); }
  const sizing = bytes.slice(); sizing[3] = 0; assert.equal(new DataView(run(sizing).buffer).getFloat64(8, true), packet.actions().length);
  assert.throws(() => run(Uint8Array.of(...bytes, 0)));
});

test("static window admission preserves capacity before duplicate identity", () => {
  assert.deepEqual(new Packet(20).word(0, 64, 0).actions().map(step => [step.action, step.code]), [[0, 0]]);
  assert.deepEqual(new Packet(20).word(1, 64, 1).actions().map(step => [step.action, step.code]), [[255, 35]]);
  assert.deepEqual(new Packet(20).word(64, 64, 1).actions().map(step => [step.action, step.code]), [[255, 34]]);
  assert.deepEqual(new Packet(20).word(65, 64, 0).actions().map(step => [step.action, step.code]), [[255, 34]]);
  const bytes = new Packet(20).word(1, 64, 0).bytes();
  for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
  assert.throws(() => run(new Packet(20).word(1, 64, 2).bytes()));
});

test("static spans retain first-match channels in fixed evaluation order", () => {
  const names = ["weight", "scale", "mono", "italic", "underline", "foreground"];
  for (let mask = 0; mask < 64; mask++) {
    const selected = names.filter((_, i) => (mask & (1 << i)) !== 0).reverse();
    const packet = new Packet(21).node("span", attrs(...selected, ...selected));
    const rows = packet.actions();
    assert.deepEqual(rows.map(row => row.action), [100, ...names.flatMap((_, i) => (mask & (1 << i)) !== 0 ? [i + 1] : []), 101, 200]);
    for (const row of rows.slice(1, -2)) assert.equal(row.fields[0], selected.indexOf(names[row.action - 1]!));
  }
  // The runtime engine retains source order and repeated occurrences.
  assert.deepEqual(actions(new Packet(13).node("span", attrs("scale", "weight", "scale"))), [100, 2, 1, 2, 101, 200]);
  const packet = new Packet(21).node("span", attrs(...names)).bytes();
  for (let end = 0; end < packet.length; end++) assert.throws(() => run(packet.slice(0, end)));
  assert.throws(() => run(new Packet(21).node("span").word(1).bytes()));
  const sizing = packet.slice(); sizing[3] = 0;
  assert.equal(new DataView(run(sizing).buffer).getFloat64(8, true), 9);
});


test("static builders sequence first occurrences before children and publication", () => {
  const specs = [
    [22, "input-group", ["label", "width", "height", "min-width", "grow", "key", "global-key"], [{ name: "textarea" }, { name: "input-group-actions" }], [100, 101, 200]],
    [23, "input-group-actions", ["gap", "key", "global-key"], [{ name: "button" }], [100, 200]],
    [24, "timeline", ["gap", "grow", "key", "global-key", "label"], [{ name: "timeline-item" }], [100, 200]],
    [25, "timeline-item", ["title", "description", "meta", "indicator", "icon", "variant", "connector", "selected", "on-press", "key", "global-key"], [], [200]],
    [26, "chart", ["y-min", "y-max", "grid-lines", "baseline", "x-labels", "y-labels", "hover-details", "stroke-width", "width", "height", "grow", "padding", "key", "global-key", "label"], [{ name: "series" }, { name: "series" }, { name: "series" }], [100, 101, 101, 101, 200]],
    [27, "series", ["kind", "values", "color", "label"], [], [200]],
    [28, "video", ["src", "controls", "autoplay", "loop", "muted", "width", "height", "grow", "label", "key", "global-key"], [], [200]],
  ] as const;
  for (const [mode, name, names, children, tail] of specs) {
    const all = (1 << names.length) - 1;
    const masks = [0, all, all & 0x5555, all & 0x2aaa, ...names.flatMap((_, i) => [1 << i, all ^ (1 << i)])];
    for (const mask of masks) {
      const selected = names.filter((_, i) => (mask & (1 << i)) !== 0).reverse();
      const rows = new Packet(mode).node(name, attrs(...selected, ...selected), [...children]).actions();
      const channels = names.flatMap((_, i) => (mask & (1 << i)) !== 0 ? [i + 1] : []);
      assert.deepEqual(rows.map(row => row.action), [...channels, ...tail]);
      for (const row of rows.slice(0, channels.length)) assert.equal(row.fields[0], selected.indexOf(names[row.action - 1]!));
      if (mode === 22) assert.equal(rows.at(-2)!.fields[0], 1);
      if (mode === 26) assert.deepEqual(rows.filter(row => row.action === 101).map(row => row.fields[0]), [0, 1, 2]);
    }
    const bytes = new Packet(mode).node(name, attrs(...names), [...children]).bytes();
    for (let end = 0; end < bytes.length; end++) assert.throws(() => run(bytes.subarray(0, end)));
    assert.throws(() => run(Uint8Array.of(...bytes, 0)));
    const sizing = bytes.slice(); sizing[3] = 0;
    assert.equal(new DataView(run(sizing).buffer).getFloat64(8, true), names.length + tail.length);
  }
  assert.deepEqual(actions(new Packet(22).node("input-group", [], [{ name: "textarea" }])), [100, 200]);
  assert.deepEqual(actions(new Packet(23).node("input-group-actions")), [100, 200]);
  assert.deepEqual(actions(new Packet(24).node("timeline")), [100, 200]);
});

test("runtime specialized builders retain source order and repeated attributes", () => {
  for (const [mode, name, names, children, expected] of [
    [5, "input-group", ["width", "label", "width"], [{ name: "textarea" }], [2, 1, 2, 100, 200]],
    [6, "input-group-actions", ["key", "gap", "key"], [], [2, 1, 2, 100, 200]],
    [7, "timeline", ["label", "gap", "label"], [], [5, 1, 5, 100, 200]],
    [8, "timeline-item", ["selected", "title", "selected"], [], [8, 1, 8, 200]],
    [9, "chart", ["width", "y-min", "width"], [{ name: "series" }], [10, 2, 10, 100, 101, 200]],
    [10, "video", ["muted", "src", "muted"], [], [5, 1, 5, 200]],
    [11, "series", ["label", "values", "label"], [], [4, 2, 4, 200]],
  ] as const) assert.deepEqual(actions(new Packet(mode).node(name, attrs(...names), [...children])), expected);
});

test("static markdown code and stepper programs fix source and active before first-occurrence channels", () => {
  const specs = [
    [29, "markdown", ["source", "on-link", "on-details", "details-expanded", "images", "issue-link-base"], [], [200]],
    [30, "code", ["source", "language", "line-numbers", "added-lines", "removed-lines", "editable", "on-input", "wrap", "width", "height", "min-width", "grow", "label", "key", "global-key"], [], [200]],
    [31, "stepper", ["active", "key", "global-key", "label"], [{ name: "step" }, { name: "step" }], [100, 101, 101, 200]],
  ] as const;
  for (const [mode, name, names, children, tail] of specs) {
    const facts = mode === 31 ? [children.length, 0] : [];
    const all = (1 << names.length) - 1;
    const masks = [1, all, (all & 0x5555) | 1, all & 0x2aaa | 1, ...names.flatMap((_, i) => [1 | (1 << i), all ^ (i === 0 ? 0 : 1 << i)])];
    for (const mask of masks) {
      const selected = names.filter((_, i) => (mask & (1 << i)) !== 0).reverse();
      const rows = new Packet(mode).node(name, attrs("kind", ...selected, ...selected), [...children]).word(...facts).actions();
      const channels = names.flatMap((_, i) => (mask & (1 << i)) !== 0 ? [i + 1] : []);
      assert.deepEqual(rows.map(row => row.action), [...channels, ...tail]);
      for (const row of rows.slice(0, channels.length)) assert.equal(row.fields[0], selected.indexOf(names[row.action - 1]!) + 1);
      if (mode === 31) assert.deepEqual(rows.filter(row => row.action === 101).map(row => row.fields[0]), [0, 1]);
    }
    const bytes = new Packet(mode).node(name, attrs(...names), [...children]).word(...facts).bytes();
    for (let end = 0; end < bytes.length; end++) assert.throws(() => run(bytes.subarray(0, end)));
    assert.throws(() => run(Uint8Array.of(...bytes, 0)));
    const sizing = bytes.slice(); sizing[3] = 0;
    assert.equal(new DataView(run(sizing).buffer).getFloat64(8, true), names.length + tail.length);
  }
  const slot = new Packet(31).node("stepper", attrs("label", "active"), [{ kind: 6 }]).word(3, 1).actions();
  assert.deepEqual(slot.map(row => [row.action, row.fields[0]]), [[1, 1], [4, 0], [100, 0], [102, 0], [102, 1], [102, 2], [200, 0]]);
  assert.deepEqual(actions(new Packet(31).node("stepper", attrs("active"), [{ kind: 6 }]).word(0, 1)), [1, 100, 200]);
  assert.deepEqual(actions(new Packet(31).node("stepper", attrs("active")).word(0, 0)), [1, 100, 200]);
  for (const facts of [[1, 0], [0, 1], [2, 1], [0, 2]]) assert.throws(() => run(new Packet(31).node("stepper", attrs("active")).word(...facts).bytes()));
  assert.throws(() => run(new Packet(32).node("markdown", attrs("source")).bytes()));
});

test("runtime markdown code and stepper programs retain source order and repeated attributes", () => {
  assert.deepEqual(actions(new Packet(2).node("markdown", attrs("images", "source", "images"))), [5, 1, 5, 200]);
  assert.deepEqual(actions(new Packet(3).node("code", attrs("label", "source", "label"))), [15, 1, 15, 200]);
  assert.deepEqual(actions(new Packet(4).node("stepper", attrs("label", "active", "label"))), [4, 1, 4, 100]);
});
