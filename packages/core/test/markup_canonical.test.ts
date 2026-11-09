import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_canonical.ts", import.meta.url), "utf8");
const { nscvMarkupCanonical: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupCanonical };").toString("base64")}`);
interface Node { kind?: number; attrs?: [string, string][]; text?: string; children?: Node[] }
function request(templates: Node[], root?: Node, mode = 1): Uint8Array {
  const parts: Uint8Array[] = [Uint8Array.of(109, 1, mode, 0)];
  const word = (value: number) => { const bytes = new Uint8Array(8); new DataView(bytes.buffer).setFloat64(0, value, true); parts.push(bytes); };
  const blob = (value: string) => { const bytes = new TextEncoder().encode(value); word(bytes.length); parts.push(bytes); };
  function node(n: Node): void {
    word(n.kind ?? 0); word(n.attrs?.length ?? 0);
    for (const [name, value] of n.attrs ?? []) { blob(name); blob(value); }
    blob(n.text ?? ""); word(n.children?.length ?? 0); for (const child of n.children ?? []) node(child);
  }
  word(templates.length); word(root ? 1 : 0); for (const n of templates) node(n); if (root) node(root);
  return Uint8Array.from(Buffer.concat(parts));
}
function actions(root?: Node, templates: Node[] = []) {
  const input = request(templates, root), out: Uint8Array = run(input), wire = new DataView(out.buffer);
  const sized: Uint8Array = run(request(templates, root, 0));
  assert.equal(sized.length, 16);
  const count = new DataView(sized.buffer).getFloat64(8, true);
  assert.equal(out.length, 16 + count * 48);
  return Array.from({ length: count }, (_, i) => {
    const at = 16 + i * 48;
    assert.deepEqual(Array.from(out.subarray(at + 2, at + 8)), [0, 0, 0, 0, 0, 0]);
    return { action: out[at]!, code: out[at + 1]!, fields: Array.from({ length: 5 }, (_, n) => wire.getFloat64(at + 8 + n * 8, true)) };
  });
}
test("typed markup owns attribute classification including first equality and message grammar", () => {
  const values = ["literal", "{ x.y }", "{ a == b }", "{a==b==c}", "{a + 1}", "{}", "{\tx\t}", "{x", "{a_b.C2}"];
  const output = actions({ attrs: values.map(value => ["value", value]) }).filter(a => a.action === 11);
  assert.deepEqual(output.map(a => a.code), [1, 2, 3, 4, 4, 6, 4, 6, 2]);
  assert.deepEqual(output[2]!.fields, [2, 2, 3, 7, 8]);
  const messages = actions({ attrs: ["go", "go:{item.id}", "a.b", "go:{}", "go:{ x }", "go:x", "x:y:{z}", ""].map(value => ["on-press", value]) }).filter(a => a.action === 11);
  assert.deepEqual(messages.map(a => a.code), [5, 5, 5, 6, 6, 6, 6, 6]);
  assert.deepEqual(messages[1]!.fields, [1, 0, 2, 4, 11]);
});
test("typed markup emits interpolation allocation order and keeps unterminated tails", () => {
  const segments = actions({ kind: 1, text: "before {path} { } {1 + 2} tail{bad" }).filter(a => a.action === 13);
  assert.deepEqual(segments.map(a => a.code), [1, 2, 1, 3, 1, 3, 1, 4]);
  assert.equal(actions({ kind: 1, text: "plain" }).filter(a => a.action === 12).length, 0);
  assert.equal(actions({ kind: 0, text: "{path}" }).filter(a => a.action === 12).length, 0);
  assert.deepEqual(actions({ kind: 1, text: "{a}{b}" }).filter(a => a.action === 13).map(a => a.code), [2, 2]);
});
test("typed markup visits templates before root and attributes before text before children", () => {
  const output = actions({ kind: 1, attrs: [["a", "{x}"]], text: "{x}", children: [{}] }, [{}, {}]);
  assert.deepEqual(output.map(a => a.action), [1, 2, 17, 2, 17, 3, 10, 11, 12, 13, 14, 15, 16, 17, 17, 4]);
  assert.deepEqual(actions().map(a => a.action), [4]);
});
test("typed markup rejects malformed copied transport before replay", () => {
  const valid = request([], { attrs: [["a", "{x + 1}"]], children: [{}] });
  for (let i = 0; i < valid.length; i++) assert.throws(() => run(valid.subarray(0, i)));
  for (const at of [0, 1, 2, 3]) { const bad = valid.slice(); bad[at] = 255; assert.throws(() => run(bad)); }
  for (const value of [-1, NaN, Infinity, 0.5, 2 ** 53]) {
    const bad = valid.slice(); new DataView(bad.buffer).setFloat64(4, value, true); assert.throws(() => run(bad));
  }
  assert.throws(() => run(Uint8Array.of(...valid, 0)));
  const bad = valid.slice(); new DataView(bad.buffer).setFloat64(12, 2, true); assert.throws(() => run(bad));
});
