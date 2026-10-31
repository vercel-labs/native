import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_document.ts", import.meta.url), "utf8");
const { nscvMarkupDocument: parse } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupDocument };").toString("base64")}`);
function request(text: string, mode = 1): Uint8Array {
  const bytes = new TextEncoder().encode(text), input = new Uint8Array(32 + bytes.length);
  input.set([107, 1, mode]); input.set(bytes, 32);
  const wire = new DataView(input.buffer); wire.setFloat64(16, 1, true); wire.setFloat64(24, 1, true);
  return input;
}
function tape(text: string): { action: number; code: number; cursor: number; line: number; column: number; fields: number[] }[] {
  const sized: Uint8Array = parse(request(text, 0)), out: Uint8Array = parse(request(text));
  assert.equal(sized.length, 16);
  const count = new DataView(sized.buffer).getFloat64(8, true);
  assert.equal(out.length, 16 + count * 96);
  const wire = new DataView(out.buffer);
  return Array.from({ length: count }, (_, i) => {
    const at = 16 + i * 96;
    return { action: out[at]!, code: out[at + 1]!, cursor: wire.getFloat64(at + 8, true),
      line: wire.getFloat64(at + 16, true), column: wire.getFloat64(at + 24, true),
      fields: Array.from({ length: 8 }, (_, n) => wire.getFloat64(at + 32 + n * 8, true)) };
  });
}
test("runtime document tape keeps allocation boundaries before later syntax failures", () => {
  const actions = tape('<row a="x"><text>yes</text><bad value="unfinished');
  assert.deepEqual(actions.map(a => a.action), [1, 2, 4, 1, 4, 5, 6, 1, 12]);
  assert.equal(actions.at(-1)!.code, 11);
  assert.equal(actions[1]!.cursor, 10);
  assert.deepEqual(actions[1]!.fields.slice(0, 6), [5, 6, 8, 9, 1, 6]);
  assert.equal(tape('<row/> trailing').at(-1)!.code, 2);
  assert.equal(tape('<row></other>').at(-1)!.code, 12);
  assert.equal(tape('<row a="\nx"/>').at(-1)!.code, 10);
});
test("runtime document grammar preserves inline whitespace with transparent comments", () => {
  const spaced = tape('<text>A <span>B</span><!-- ignored --> C<span>D</span>.</text>');
  assert.equal(spaced.filter(a => a.action === 7).length, 2);
  assert.deepEqual(spaced.filter(a => a.action === 7).map(a => a.fields[0]), [1, 2]);
  const abutting = tape('<text><span>A</span><!-- spaces in comment --><span>B</span></text>');
  assert.equal(abutting.filter(a => a.action === 7).length, 0);
  assert.equal(tape('<text>A <!-- comment --> B</text>').filter(a => a.action === 7).length, 0);
  assert.deepEqual(tape('<text>\n  Café </text>').find(a => a.action === 5)!.fields.slice(0, 4), [9, 14, 2, 3]);
});
test("runtime document grammar preserves top-level ordering template bounds and byte positions", () => {
  assert.deepEqual(tape('<import/><template/><row/>').filter(a => a.action >= 8).map(a => a.action), [8, 9, 10]);
  assert.equal(tape('<template/><import/>').at(-1)!.code, 13);
  assert.equal(tape('<template/>'.repeat(256)).at(-1)!.action, 11);
  assert.equal(tape('<template/>'.repeat(257)).at(-1)!.code, 14);
  assert.equal(tape('<!-- unfinished').at(-1)!.code, 1);
  assert.equal(tape('<row><!-- unfinished').at(-1)!.code, 15);
  const input = request('skip<row/>');
  const wire = new DataView(input.buffer);
  wire.setFloat64(8, 4, true); wire.setFloat64(16, 8, true); wire.setFloat64(24, 13, true);
  const result: Uint8Array = parse(input);
  assert.equal(new DataView(result.buffer).getFloat64(16 + 32, true), 4);
});
test("runtime document transport rejects truncated reserved and inexact state", () => {
  const valid = request('<row/>');
  for (let i = 0; i < 32; i++) assert.throws(() => parse(valid.subarray(0, i)));
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7]) {
    const bad = valid.slice(); bad[at] = 255; assert.throws(() => parse(bad));
  }
  for (const at of [8, 16, 24]) for (const value of [-1, NaN, Infinity, 0.5, 2 ** 53]) {
    const bad = valid.slice(); new DataView(bad.buffer).setFloat64(at, value, true);
    assert.throws(() => parse(bad));
  }
});
