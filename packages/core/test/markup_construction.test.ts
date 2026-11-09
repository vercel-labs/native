import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_construction.ts", import.meta.url), "utf8");
const { nscvMarkupConstruction: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupConstruction };").toString("base64")}`);
interface Node { kind?: number; attrs?: [string, string][]; children?: Node[] }
class Packet {
  parts: Uint8Array[];
  constructor(mode: number) { this.parts = [Uint8Array.of(110, 1, mode, 1)]; }
  word(...values: number[]): this { for (const value of values) { const raw = new Uint8Array(8); new DataView(raw.buffer).setFloat64(0, value, true); this.parts.push(raw); } return this; }
  blob(value: string | Uint8Array): this { const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value; this.word(bytes.length); this.parts.push(bytes); return this; }
  node(node: Node, id = { next: 0 }): this {
    this.word(id.next++, node.kind ?? 0, node.attrs?.length ?? 0);
    for (const [name, value] of node.attrs ?? []) this.blob(name).blob(value);
    this.word(node.children?.length ?? 0); for (const child of node.children ?? []) this.node(child, id); return this;
  }
  bytes(): Uint8Array { return Uint8Array.from(Buffer.concat(this.parts)); }
  actions() { return actions(this.bytes()); }
}
function actions(bytes: Uint8Array) {
  const out: Uint8Array = run(bytes), wire = new DataView(out.buffer), count = wire.getFloat64(8, true);
  assert.equal(out.length, 16 + count * 48);
  return Array.from({ length: count }, (_, i) => ({ action: out[16 + i * 48]!, code: out[17 + i * 48]!, fields: Array.from({ length: 5 }, (_, j) => wire.getFloat64(24 + i * 48 + j * 8, true)) }));
}
function use(node: Node, definitions: Node[], length = 0, floor = 0, context = 0, depth = 0) {
  const named = node.attrs?.find(a => a[0] === "template");
  const selection = new Packet(10).word(length, floor, context, depth, named ? 1 : 0).blob(named?.[1] ?? "").word(definitions.length);
  for (const definition of definitions) { const name = definition.attrs?.find(a => a[0] === "name"); selection.word(name ? 1 : 0).blob(name?.[1] ?? ""); }
  const first = selection.actions()[0]!;
  const packet = new Packet(12).word(length, floor, context, depth, first.fields[0]), id = { next: 0 };
  packet.node(node, id).node(definitions[first.fields[0]] ?? {}, id);
  return { bytes: () => packet.bytes(), actions: () => first.action === 255 ? [first] : packet.actions() };
}
const useNode = (attrs: [string, string][] = []): Node => ({ kind: 6, attrs: [["template", "t"], ...attrs] });
const template = (args = "", children: Node[] = [{}]): Node => ({ kind: 5, attrs: [["name", "t"], ["args", args]], children });
test("markup construction preserves root admission, branch sequencing and shadowed lookup", () => {
  assert.equal(new Packet(0).word(1, 0).actions()[0]!.code, 1);
  assert.equal(new Packet(0).word(0, 0).actions()[0]!.code, 2);
  assert.equal(new Packet(2).word(2, 4, 0).actions()[0]!.fields[0], 1);
  assert.equal(new Packet(2).word(3, 4, 0).actions()[0]!.code, 8);
  assert.equal(new Packet(3).word(3, 1, 0).actions()[0]!.fields[0], 1);
  assert.equal(new Packet(3).word(3, 1, 1).actions()[0]!.fields[0], 0);
  assert.equal(new Packet(4).word(3, 1).blob("x").blob("x").blob("x").blob("x").actions()[0]!.fields[0], 3);
  assert.equal(new Packet(8).word(1, 2, 0, 0).actions()[0]!.action, 0);
  assert.equal(new Packet(8).word(0, 0, 0, 0).actions()[0]!.action, 12);
});
test("markup construction template failures retain exact priority and witness identities", () => {
  assert.equal(use({ kind: 6 }, []).actions()[0]!.code, 10);
  assert.equal(use(useNode(), []).actions()[0]!.code, 11);
  assert.equal(use(useNode(), [template()], 0, 0, 1, 128).actions()[0]!.code, 12);
  assert.equal(use(useNode(), [template()], 0, 0, 0, 128).actions()[0]!.code, 13);
  const badBody = use(useNode(), [template("", [{ kind: 1 }])]).actions()[0]!;
  assert.equal(badBody.code, 14); assert.equal(badBody.fields[0], 1);
  const secondSlot = use(useNode(), [template("", [{ children: [{ kind: 8 }, { kind: 8 }] }])]).actions()[0]!;
  assert.equal(secondSlot.code, 15); assert.equal(secondSlot.fields[0], 4);
  assert.equal(use({ ...useNode([["bad", "x"]]), children: [{}] }, [template()]).actions()[0]!.code, 16);
  assert.equal(use(useNode([["on-click", "x"]]), [template()]).actions()[0]!.code, 17);
  assert.equal(use(useNode([["unknown", "x"]]), [template()]).actions()[0]!.code, 18);
});
test("markup construction reserves the capture slot and evaluates arguments before activation", () => {
  const packet = use(useNode([["a", "{x}"]]), [template("a b=flat c=")]);
  const out = packet.actions();
  assert.deepEqual(out.map(a => a.action), [20, 22, 23, 25, 22, 24, 25, 22, 24, 25, 26, 27, 28, 29]);
  assert.deepEqual(out.filter(a => a.action === 25).map(a => a.code), [0, 1, 1]);
  assert.deepEqual(out.find(a => a.action === 27)!.fields, [4, 0, 1, 1, 0]);
  for (let length = 0; length <= 16; length++) {
    const tokens = Array.from({ length: 16 - length }, (_, i) => `a${i}=x`).join(" ");
    const boundary = use(useNode(), [template(tokens)], length).actions();
    assert.equal(boundary.at(-1)!.code, 19);
    if (length < 16) assert.equal(use(useNode(), [template(tokens.split(" ").slice(1).join(" "))], length).actions().at(-1)!.action, 29);
  }
  assert.equal(use(useNode(), [template("x='{")]).actions().at(-1)!.code, 20);
  assert.equal(use(useNode(), [template("x='a")]).actions().at(-1)!.code, 21);
  assert.equal(use(useNode(), [template("x")]).actions().at(-1)!.code, 22);
  const sized = packet.bytes(); sized[3] = 0;
  assert.equal(new DataView(run(sized).buffer).getFloat64(8, true), out.length);
});
test("markup construction admits slots, scalar strings, loop types and post-body key publication", () => {
  assert.equal(new Packet(5).word(0, 0, 1, 2, 1, 4, 1, 4, 1).actions()[0]!.fields[0], 2);
  assert.equal(new Packet(5).word(0, 0, 1, 1, 0, 4, 0).actions()[0]!.fields[0], 0);
  assert.equal(new Packet(5).word(1, 1, 0, 0, 0).actions()[0]!.code, 23);
  assert.equal(new Packet(6).word(1, 1, 0, 3, 0, 5, 1).actions()[0]!.fields[0], 2);
  assert.equal(new Packet(9).word(1, 1, 1, 0).actions()[0]!.action, 11);
  assert.equal(new Packet(9).word(1, 1, 1, 1).actions()[0]!.action, 13);
  assert.equal(new Packet(11).word(0, 3, 1, 0, 0).actions()[0]!.fields[0], 1);
  assert.equal(new Packet(7).word(3, 0, 0, 1).actions()[0]!.action, 14);
  assert.equal(new Packet(7).word(2, 1, 3, 0).actions()[0]!.action, 10);
  assert.equal(new Packet(7).word(2, 1, 3, 1).actions()[0]!.action, 9);
});
test("markup construction rejects truncated, nonintegral and trailing transport facts", () => {
  const valid = use(useNode(), [template("a=x")]).bytes();
  for (let i = 0; i < valid.length; i++) assert.throws(() => run(valid.subarray(0, i)));
  for (const offset of [0, 1, 2, 3]) { const bad = valid.slice(); bad[offset] = 255; assert.throws(() => run(bad)); }
  for (const n of [-1, 0.5, NaN, Infinity, 2 ** 53]) { const bad = valid.slice(); new DataView(bad.buffer).setFloat64(4, n, true); assert.throws(() => run(bad)); }
  assert.throws(() => run(Uint8Array.of(...valid, 0)));
});
