import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_parser.ts", import.meta.url), "utf8");
const { nscvMarkupParser: parse } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupParser };").toString("base64")}`);
function request(text: Uint8Array): Uint8Array {
  const out = new Uint8Array(text.length > 256 ? 8 : 9 + text.length * 2);
  out.set([106, 1]); new DataView(out.buffer).setUint16(2, Math.min(257, text.length), true);
  if (text.length <= 256) out.set(text, 8);
  return out;
}
function tree(text: string): Uint8Array {
  const bytes = new TextEncoder().encode(text), input = request(bytes);
  for (let i = 0; i < 66; i++) {
    const out: Uint8Array = parse(input);
    if (out[2] !== 2) return out;
    const wire = new DataView(out.buffer), at = wire.getUint16(8, true), size = wire.getUint16(10, true);
    assert.equal(input[8 + bytes.length + at], 0, "each capability is requested once");
    const literal = new TextDecoder().decode(bytes.subarray(at, at + size));
    const accepted = literal.includes(".") ? Number.isFinite(Math.fround(Number(literal))) : BigInt(literal) <= (1n << 63n) - 1n;
    input[8 + bytes.length + at] = accepted ? 1 : 2;
  }
  throw new Error("parser did not converge");
}
function kinds(out: Uint8Array): number[] {
  return Array.from({ length: out[4]! }, (_, i) => out[16 + i * 20]!);
}
test("runtime parser preserves precedence, eager post-order and direct comparison flags", () => {
  const result = tree("not a == b and 1 + 2 * 3 > 0 or false");
  assert.equal(result[2], 0);
  assert.deepEqual(kinds(result), [4, 4, 12, 6, 0, 0, 0, 9, 7, 0, 16, 18, 3, 19]);
  assert.equal(result[26], 1); assert.equal(result[46], 1);
  const indirect = tree("a + b == c");
  assert.equal(indirect[26], 0); assert.equal(indirect[46], 0); assert.equal(indirect[86], 1);
  assert.equal(tree("a == b < c")[3], 6);
});
test("runtime parser retains numeric admission and syntax failure order", () => {
  assert.equal(tree("9223372036854775807")[2], 0);
  assert.equal(tree("9223372036854775808")[3], 8);
  assert.equal(tree("-9223372036854775808")[3], 8);
  assert.equal(tree("max(9223372036854775808, unknown())")[3], 8);
  assert.equal(tree("max(unknown(), 9223372036854775808)")[3], 10);
  assert.equal(tree("now()")[3], 15);
  assert.equal(tree("max(1,2,3,4,9223372036854775808)")[3], 5);
  assert.equal(tree("max(1,2,3)")[3], 42);
  assert.equal(tree("99999999999999999999999999999999999999999999.0")[3], 9);
});
test("runtime parser enforces byte, node, depth and protocol bounds", () => {
  assert.equal(tree("1" + " ".repeat(255))[2], 0);
  assert.equal(tree("1" + " ".repeat(256))[3], 2);
  assert.equal(tree("-1" + "+1".repeat(31))[4], 64);
  assert.equal(tree("1" + "+1".repeat(32))[3], 3);
  assert.equal(tree("(".repeat(15) + "1" + ")".repeat(15))[2], 0);
  assert.equal(tree("(".repeat(16) + "1" + ")".repeat(16))[3], 4);
  assert.equal(tree(" ")[3], 11); assert.equal(tree("")[3], 1);
  const valid = request(new Uint8Array());
  for (let i = 0; i < valid.length; i++) assert.throws(() => parse(valid.subarray(0, i)));
  for (const at of [0, 1, 4, 5, 6, 7, 8]) {
    const bad = valid.slice(); bad[at] = 255; assert.throws(() => parse(bad));
  }
});
