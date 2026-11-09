import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "control_appearance.ts", "widget_paint.ts"].map(p => readFileSync(new URL(`../src/${p}`, import.meta.url), "utf8")).join("\n");
const { nscvWidgetPaint: paint } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetPaint };").toString("base64")}`);
const missing = 0xffffffff;
interface Node { kind?: number; parent?: number; depth?: number; flags?: number; size?: number; frame?: number[]; transform?: number[]; textWidth?: number; }
function packet(nodes: Node[], entries: number[][], options: { mode?: number; numeric?: number; tokens?: Record<number, number>; before?: number } = {}) {
  const mode = options.mode ?? 1, before = options.before ?? 0, payload = 16 + entries.length * 16;
  const b = new Uint8Array(544 + nodes.length * 128 + payload), w = new DataView(b.buffer);
  b.set([26, mode, 2, options.numeric ?? 0]); w.setUint32(4, before, true); w.setUint32(8, nodes.length - before, true); w.setUint32(12, payload, true); w.setUint32(16, 1, true);
  const tokens = { 0: 2, 1: 2, 2: 1, 3: 1, 4: 1, 6: 1, 7: 14, 10: 2, 11: 2, 12: 4, 13: 2, 14: 12, 15: 12, ...options.tokens };
  for (const [slot, value] of Object.entries(tokens)) w.setFloat32(64 + Number(slot) * 4, value, true);
  nodes.forEach((n, i) => { const at = 544 + i * 128;
    w.setUint32(at, n.kind ?? 26, true); w.setUint32(at + 4, n.size ?? 1, true); w.setUint32(at + 12, n.parent ?? missing, true); w.setUint32(at + 16, n.depth ?? i, true); w.setUint32(at + 20, (n.flags ?? 0) | (n.parent !== undefined && n.parent !== missing ? 2048 : 0), true); w.setUint32(at + 28, missing, true);
    (n.frame ?? [0, 0, 100, 100]).forEach((v, j) => { w.setFloat32(at + 32 + j * 4, v, true); w.setFloat32(at + 48 + j * 4, v, true); });
    (n.transform ?? [1, 0, 0, 1, 0, 0]).forEach((v, j) => w.setFloat32(at + 64 + j * 4, v, true)); w.setFloat32(at + 116, n.textWidth ?? 0, true);
  });
  const at = 544 + nodes.length * 128; b[at] = 1; w.setUint32(at + 4, entries.length, true); entries.forEach((e, i) => e.forEach((v, j) => w.setUint32(at + 16 + i * 16 + j * 4, v, true)));
  return b;
}
function bounds(result: Uint8Array) { const w = new DataView(result.buffer, result.byteOffset, result.byteLength); return Array.from({ length: w.getUint32(4, true) }, (_, i) => w.getUint32(8 + i * 20, true) === 0 ? null : Array.from({ length: 4 }, (_, j) => w.getFloat32(12 + i * 20 + j * 4, true))); }
test("damage obeys ancestor clipping, hoisted surfaces, and hidden ancestry", () => {
  const nodes = [{ frame: [0, 0, 50, 50], flags: 2 }, { parent: 0, frame: [40, 40, 30, 30] }], entry = [[2, missing, 1, 7]];
  assert.deepEqual(bounds(paint(packet(nodes, entry))), [[40, 40, 10, 10]]);
  nodes[1]!.flags = 4; assert.deepEqual(bounds(paint(packet(nodes, entry))), [[40, 40, 30, 30]]);
  nodes[0]!.flags |= 1; assert.deepEqual(bounds(paint(packet(nodes, entry))), [null]);
});
test("bubble reactions reserve the complete out-of-frame ring", () => {
  assert.deepEqual(bounds(paint(packet([{ kind: 15, flags: 16 | (2 << 9), textWidth: 10 }], [[2, missing, 0, 7]]))), [[-0.5, -0.5, 101, 119.625]]);
});
test("measurement requests follow plan encounter order and skip unchanged paint", () => {
  const nodes = [{ kind: 15, flags: 16, size: 0 }, { kind: 15, flags: 16, size: 2 }, { kind: 15, flags: 16 }, { kind: 15, flags: 16 }];
  const request = packet(nodes, [[1, 0, 0, 7], [1, 1, 1, 7]], { before: 2, mode: 0 }), result = paint(request), w = new DataView(result.buffer, result.byteOffset, result.byteLength);
  assert.equal(w.getUint32(4, true), 4);
  assert.deepEqual(Array.from({ length: 4 }, (_, i) => [w.getUint32(8 + i * 8, true), w.getFloat32(12 + i * 8, true)]), [[0, 13], [2, 14], [1, 15], [3, 14]]);
  assert.equal(new DataView(paint(packet(nodes, [[1, 0, 0, 2]], { before: 2, mode: 0 })).buffer).getUint32(4, true), 0);
});
test("malformed geometry wires fail before yielding partial output", () => {
  const valid = packet([{}], [[2, missing, 0, 7]]);
  for (const at of [2, 20, 536, 544 + 124]) { const bad = valid.slice(); bad[at] = 255; assert.throws(() => paint(bad), /invalid/); }
  assert.throws(() => paint(valid.subarray(0, valid.length - 1)), /invalid/);
  assert.throws(() => paint(packet([{ parent: 0 }], [[2, missing, 0, 7]])), /cyclic/);
});
