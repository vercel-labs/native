import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_display.ts", import.meta.url), "utf8");
const { nscvMarkupDisplay: program } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupDisplay };").toString("base64")}`);
function request(mode: number, kind: number, digits = 0, truth = false): Uint8Array {
  return Uint8Array.of(104, 1, mode, kind, digits, truth ? 1 : 0, 0, 0);
}
function decode(b: Uint8Array): { actions: number[][]; literal: string } {
  assert.equal(b.length, 8 + b[3]! * 4 + b[4]!);
  const actions: number[][] = [];
  for (let i = 0; i < b[3]!; i++) actions.push(Array.from(b.subarray(8 + i * 4, 12 + i * 4)));
  return { actions, literal: new TextDecoder().decode(b.subarray(8 + b[3]! * 4)) };
}
test("markup display preserves exact rendering capabilities and individual append boundaries", () => {
  assert.deepEqual(decode(program(request(0, 1))), { actions: [[4, 0, 0, 0]], literal: "" });
  assert.deepEqual(decode(program(request(0, 2))), { actions: [[0, 0, 0, 0], [5, 0, 0, 0]], literal: "" });
  assert.deepEqual(decode(program(request(0, 3))), { actions: [[1, 0, 0, 0], [5, 0, 0, 0]], literal: "" });
  for (const truth of [false, true]) assert.deepEqual(decode(program(request(0, 4, 0, truth))), {
    actions: [[6, 0, truth ? 4 : 5, 0]], literal: truth ? "true" : "false",
  });
  for (let digits = 0; digits <= 6; digits++) {
    const integer = [[0, digits, 0, 0], [5, 0, 0, 0]];
    if (digits > 0) integer.push([6, 0, 1, 0], [7, 48, digits, 0]);
    integer.push([6, digits > 0 ? 1 : 0, 0, 0]);
    assert.deepEqual(decode(program(request(1, 2, digits))), { actions: integer, literal: digits > 0 ? "." : "" });
    assert.deepEqual(decode(program(request(1, 3, digits))), { actions: [[3, digits, 0, 0], [5, 0, 0, 0], [6, 0, 0, 0]], literal: "" });
    for (const kind of [2, 3]) assert.deepEqual(decode(program(request(2, kind, digits))), {
      actions: [[2, 0, 0, 0], [3, digits, 0, 0], [5, 0, 0, 0], [6, 0, 1, 0]], literal: "%",
    });
  }
});
test("markup display validates complete metadata and returns independently owned plans", () => {
  const b = request(0, 4, 0, true), result = program(b), copy = result.slice();
  for (let i = 0; i < 8; i++) assert.throws(() => program(b.subarray(0, i)));
  assert.throws(() => program(new Uint8Array(9)));
  for (let i = 0; i < 8; i++) { const bad = b.slice(); bad[i] = 255; assert.throws(() => program(bad)); }
  for (const mode of [1, 2]) for (const kind of [1, 4]) assert.throws(() => program(request(mode, kind)));
  assert.throws(() => program(request(0, 2, 1)));
  assert.throws(() => program(request(0, 2, 0, true)));
  b.fill(0); program(request(2, 3, 6)); assert.deepEqual(result, copy);
});
