import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_canonical.ts", import.meta.url), "utf8");
const { nscvMarkupCanonical: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupCanonical };").toString("base64")}`);
function request(channel: number, name: string, value: string, phase = 1): Uint8Array {
  const parts = [Uint8Array.of(109, 1, phase, channel)];
  for (const text of [name, value]) {
    const bytes = new TextEncoder().encode(text), size = new Uint8Array(8);
    new DataView(size.buffer).setFloat64(0, bytes.length, true); parts.push(size, bytes);
  }
  return Uint8Array.from(Buffer.concat(parts));
}
function classify(channel: number, name: string, value: string): number[] {
  const bytes: Uint8Array = run(request(channel, name, value)), view = new DataView(bytes.buffer);
  assert.equal(bytes.length, 64); assert.equal(view.getFloat64(8, true), 1); assert.equal(bytes[16], 11);
  return [bytes[17]!, ...Array.from({ length: 4 }, (_, i) => view.getFloat64(32 + i * 8, true))];
}
test("standalone classification reuses canonical spans and keeps raw expressions distinct from messages", () => {
  assert.deepEqual(classify(1, "on-press", "pick:{row.id}"), [1, 0, 13, 0, 0]);
  assert.deepEqual(classify(2, "on-press", "pick:{row.id}"), [5, 0, 4, 6, 12]);
  assert.deepEqual(classify(2, "on-press", "tick"), [5, 0, 4, 4, 4]);
  assert.deepEqual(classify(2, "on-press", "pick:{ row.id }"), [6, 0, 0, 0, 0]);
  assert.deepEqual(classify(1, "", "{ a  ==  b.c }"), [3, 2, 3, 9, 12]);
  assert.deepEqual(classify(2, "text", "{a == b == c}"), [4, 1, 12, 0, 0]);
  assert.deepEqual(classify(2, "text", "{\t}"), [4, 1, 2, 0, 0]);
  assert.deepEqual(classify(2, "text", "{ }"), [6, 0, 0, 0, 0]);
  assert.deepEqual(classify(2, "text", "{ row.id }"), [2, 2, 8, 0, 0]);
});
test("standalone classification checks framing bounds phases and trailing bytes", () => {
  const input = request(2, "on-press", "tick");
  for (let i = 0; i < input.length; i++) assert.throws(() => run(input.subarray(0, i)));
  for (const offset of [0, 1, 2, 3]) { const bad = input.slice(); bad[offset] = 255; assert.throws(() => run(bad)); }
  assert.throws(() => run(Uint8Array.of(...input, 0)));
  assert.equal(run(request(1, "", "{x}", 0)).length, 16);
});
