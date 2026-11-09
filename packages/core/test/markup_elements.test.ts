import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_elements.ts", import.meta.url), "utf8");
const { nscvMarkupElements: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupElements };").toString("base64")}`);
interface Attr { name: string; raw?: string; cached?: number }
interface Child { kind?: number; name?: string; text?: string }
class Packet {
  parts: Uint8Array[];
  constructor(mode: number) { this.parts = [Uint8Array.of(111, 1, mode, 1)]; }
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
function element(name = "column", attrs: Attr[] = [], children: Child[] = [], kind = name, a11y = 0, flags = [0, 0, 0, 0, 0, 1]) {
  return new Packet(1).node(name, attrs, children).blob(kind).word(...flags.slice(0, 4), a11y, ...flags.slice(4)).names(["column"]).names(["change", "submit", "input"]).names(["clip", "ellipsis"]).names(["heading", "display"]).names(["sm", "md", "lg"]).names(["button", "radiogroup", "tree"]).names(["radiogroup", "tree"]);
}
function attrs(values: Attr[], name = "column") { return new Packet(2).node(name, values).names(["background", "color"]).names(["width", "text", "scrollback"]); }
function event(name: string, element = "column", payload = false, typed = true) { return new Packet(3).word(typed ? 1 : 0).blob(name).blob(element).word(payload ? 1 : 0).names(["dropdown-menu", "popover"]); }
test("element owner dispatches schema entries and specialized builders without accepting misplaced children", () => {
  assert.equal(new Packet(0).blob("button").names(["column", "button"]).actions()[0]!.fields[0], 1);
  assert.equal(new Packet(0).blob("code").names([]).actions()[0]!.action, 1);
  assert.equal(new Packet(0).blob("span").names(["span"]).actions()[0]!.code, 7);
  assert.equal(new Packet(0).blob("not-an-element").names([]).actions()[0]!.code, 9);
});
test("element owner retains metadata checks, filtering, allocation boundaries and diagnostic witnesses", () => {
  const menu = { name: "context-menu" }, pill = { name: "reactions" };
  assert.equal(element("column", [], [menu]).actions()[0]!.code, 11);
  const duplicate = element("column", [{ name: "on-drag" }], [menu, menu]).actions();
  assert.deepEqual(duplicate.map(a => a.action), [10, 255]); assert.equal(duplicate[1]!.fields[0], 2);
  const bubble = element("bubble", [], [menu, pill, { kind: 1, text: "bad" }], "bubble").actions();
  assert.deepEqual(bubble.map(a => a.action), [10, 11, 12, 15, 16, 22, 24, 25]);
  assert.deepEqual(bubble[2]!.fields.slice(0, 2), [1, 2]);
  const lateError = element("image", [{ name: "image" }], [menu]).actions();
  assert.deepEqual(lateError.map(a => a.action), [10, 12, 255]); assert.equal(lateError[2]!.code, 25);
  assert.equal(element("column", [{ name: "wrap" }, { name: "on-change" }]).actions()[0]!.code, 14);
});
test("element owner preserves accessible-name admission, text content and post-attribute failures", () => {
  assert.equal(element("button", [{ name: "icon", raw: "save" }], [], "button", 2, [1, 0, 1, 1, 1, 0]).actions()[0]!.code, 29);
  assert.equal(element("button", [{ name: "role", raw: "radiogroup" }], [{ kind: 1, text: "name" }], "button", 2).actions()[0]!.code, 28);
  assert.equal(element("input", [{ name: "text", raw: "value" }], [], "text_field", 3).actions()[0]!.code, 31);
  assert.equal(element("text", [], [{ kind: 1, text: "name" }], "text", 0, [0, 0, 1, 0, 1, 0]).actions().at(-1)!.action, 21);
  assert.deepEqual(element("icon").actions().map(a => a.action), [15, 255]);
  assert.deepEqual(element("text", [], [{ name: "span" }], "text").actions().map(a => a.action), [15, 26]);
  const composite = element("list-row", [], [{ kind: 1, text: "mixed" }, { name: "text" }], "list_row", 0, [1, 0, 1, 1, 1, 1]).actions();
  assert.deepEqual(composite.map(a => a.action), [15, 255]); assert.equal(composite[1]!.fields[0], 1);
});
test("attribute owner emits source rectangles first, keeps duplicates ordered and preserves late errors", () => {
  const rectangle = ["source-height", "width", "image", "source-y", "source-width", "source-x"].map(name => ({ name }));
  assert.deepEqual(attrs(rectangle, "image").actions().map(a => a.action), [20, 16, 7]);
  assert.equal(attrs([{ name: "source-x" }], "image").actions()[0]!.code, 41);
  assert.deepEqual(attrs([{ name: "width" }, { name: "width" }, { name: "oops" }]).actions().map(a => a.action), [16, 16, 255]);
  assert.deepEqual(attrs([{ name: "on-press" }, { name: "background", cached: 6 }]).actions().map(a => a.action), [1, 255]);
  assert.equal(attrs([{ name: "background", cached: 6 }]).actions()[0]!.code, 48);
  assert.equal(attrs([{ name: "text" }], "terminal").actions()[0]!.code, 44);
});
test("event owner requests constructors before late failures and retains slider fallback", () => {
  assert.deepEqual(event("change", "slider").actions().map(a => a.action), [6, 7, 8]);
  assert.deepEqual(event("change", "slider", true).actions().map(a => a.action), [7, 8]);
  assert.deepEqual(event("unknown").actions().map(a => a.action), [7, 255]);
  assert.deepEqual(event("dismiss").actions().map(a => a.action), [7, 255]);
  assert.equal(event("terminal", "terminal", true).actions()[0]!.code, 53);
  assert.equal(event("input", "input", true).actions()[0]!.action, 1);
  assert.equal(event("scroll", "column").actions()[0]!.code, 51);
  assert.equal(event("reach-start", "column").actions()[1]!.code, 57);
});
test("key owner keeps negative integer identities and distinguishes omitted defaults from explicit empty text", () => {
  assert.equal(new Packet(4).word(0, 0, 0, 0, 0).actions()[0]!.action, 1);
  assert.equal(new Packet(4).word(1, 1, 1, 2, 1).actions()[0]!.action, 0);
  for (const flags of [[0, 1, 1], [1, 0, 1], [1, 1, 0]]) assert.equal(new Packet(4).word(...flags, 2, 1).actions()[0]!.action, 2);
  assert.equal(new Packet(4).word(0, 0, 0, 1, 0).actions()[0]!.code, 58);
});
test("element transport rejects malformed lengths, modes, booleans, numbers and trailing bytes", () => {
  const packet = element("text", [{ name: "size", raw: "heading" }], [{ kind: 1, text: "owned" }], "text");
  const bytes = packet.bytes(), actions = packet.actions();
  for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
  for (const at of [0, 1, 2, 3]) { const bad = bytes.slice(); bad[at] = 255; assert.throws(() => run(bad)); }
  for (const number of [-1, .25, NaN, Infinity, 2 ** 53]) { const bad = bytes.slice(); new DataView(bad.buffer).setFloat64(4, number, true); assert.throws(() => run(bad)); }
  const sizing = bytes.slice(); sizing[3] = 0; assert.equal(new DataView(run(sizing).buffer).getFloat64(8, true), actions.length);
  assert.throws(() => run(Uint8Array.of(...bytes, 0)));
});

test("element facts derive raw literal admission while preserving explicit cached kinds", () => {
  assert.equal(element("text", [{ name: "overflow", raw: "bad" }]).actions()[0]!.code, 20);
  assert.notEqual(element("text", [{ name: "overflow", raw: "{bad" }]).actions()[0]!.code, 20);
  assert.equal(attrs([{ name: "background", raw: "accent" }]).actions()[0]!.action, 15);
  assert.equal(attrs([{ name: "background", raw: "{bad", cached: 1 }]).actions()[0]!.action, 15);
  assert.equal(attrs([{ name: "background", raw: "accent", cached: 2 }]).actions()[0]!.code, 48);
  assert.throws(() => attrs([{ name: "background", cached: 7 }]).actions());
});
