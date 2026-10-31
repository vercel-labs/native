import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_expressions.ts", import.meta.url), "utf8");
const { nscvMarkupExpressions: program } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupExpressions };").toString("base64")}`);
type Node = [number, number?, number?, number?, number?, number?, number?, number?, number?];
function request(nodes: Node[]): Uint8Array {
  const b = new Uint8Array(8 + nodes.length * 12); b.set([102, 1, nodes.length, nodes.length - 1]);
  for (let i = 0; i < nodes.length; i++) b.set(nodes[i]!.map(n => n ?? 0), 8 + i * 12);
  return b;
}
function instructions(b: Uint8Array): number[][] {
  const p = program(b); const result: number[][] = [];
  for (let i = 8; i < p.length; i += 4) result.push([...p.subarray(i, i + 4)]);
  return result;
}
test("expression programs preserve eager post-order and deferred digits failure priority", () => {
  // fixed(string, integer) must check the integer's dynamic range before
  // failing the value type. Earlier operations remain ahead of that probe.
  assert.deepEqual(instructions(request([[2], [0], [20, 0, 2, 0, 0, 0, 0, 1]])),
    [[0, 0, 0, 1], [1, 0, 0, 2], [2, 17, 0, 0], [2, 35, 16, 0]]);
  assert.deepEqual(instructions(request([[2], [2], [20, 0, 2, 0, 0, 0, 0, 1]])),
    [[0, 0, 0, 1], [1, 0, 0, 1], [2, 35, 5, 0]]);
  const b = request([[3], [0], [0], [10, 0, 0, 0, 1, 2], [18, 0, 0, 0, 0, 3]]);
  assert.deepEqual(instructions(b).slice(-2), [[3, 7, 0, 3], [4, 35, 2, 0]]);
});
test("expression programs retain exact scalar kinds without transporting scalar values", () => {
  for (const [kind, result] of [[0, 2], [1, 3], [2, 1], [3, 4]]) {
    assert.deepEqual(instructions(request([[kind!]])), [[0, 0, 0, result]]);
  }
  assert.deepEqual(instructions(request([[4, 0, 0, 2], [4, 0, 0, 3], [7, 0, 0, 0, 0, 1]])),
    [[0, 1, 0, 2], [1, 1, 0, 3], [2, 4, 0, 3]]);
  for (let kind = 12; kind <= 17; kind++) {
    const result = instructions(request([[0], [1], [kind, 0, 0, 0, 0, 1]]));
    assert.deepEqual(result.at(-1), [2, kind - 3, 0, 4]);
  }
});
test("expression transport validates the entire bounded tree and returns owned programs", () => {
  const b = request([[0]]), p = program(b), copy = p.slice();
  for (let n = 0; n < b.length; n++) assert.throws(() => program(b.subarray(0, n)));
  for (const at of [0, 1, 2, 3, 4, 7, 8, 9, 10, 11, 18, 19]) {
    const bad = b.slice(); bad[at] = 255; assert.throws(() => program(bad));
  }
  assert.throws(() => program(request([[0], [5, 0, 0, 0, 1]])));
  assert.throws(() => program(request([[0], [20, 15, 2, 0, 0, 0, 0, 0]])));
  const afterFailure = request([[2], [5], [21]]); assert.throws(() => program(afterFailure));
  const nodes: Node[] = [[0]]; while (nodes.length < 64) nodes.push([5, 0, 0, 0, nodes.length - 1]);
  assert.equal(program(request(nodes)).length, 8 + 64 * 4);
  nodes.push([0]); assert.throws(() => program(request(nodes)));
  b.fill(255); program(request([[3]])); assert.deepEqual(p, copy);
});
