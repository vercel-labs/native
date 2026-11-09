import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "control_primitives", "effect_plans"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvEffectPlans: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvEffectPlans};").toString("base64")}`);
function packet(mode: number, facts = 0, kind = 0): Uint8Array {
  const b = new Uint8Array(128), w = new DataView(b.buffer);
  b.set([52, mode, 1, 0]); w.setUint32(8, facts, true); w.setBigUint64(12, 0xfedcba9876543210n, true);
  [1.5, 2.25, 120.5, 40.75].forEach((x, i) => w.setFloat32(20 + i * 4, x, true));
  [0.1, 0.2, 0.3, 0.5].forEach((x, i) => w.setFloat32(36 + i * 4, x, true)); w.setFloat32(52, -3, true);
  w.setFloat32(56, 0, true); w.setFloat32(60, 6, true); [0, 0, 0, 0.4].forEach((x, i) => w.setFloat32(64 + i * 4, x, true));
  w.setFloat32(80, 12, true); w.setUint32(100, kind, true); return b;
}
const view = (b: Uint8Array): DataView => new DataView(plan(b).buffer);
test("containers paint authored rest fills and ask appearance for actionable feedback", () => {
  const rest = view(packet(0, (1 << 5) | (1 << 10)));
  assert.equal(rest.getUint32(8, true), 1); assert.equal(rest.getBigUint64(16, true), (0xfedcba9876543210n * 16n + 1n) & 0xffffffffffffffffn);
  assert.equal(rest.getFloat32(44, true), 0); assert.equal(rest.getFloat32(60, true), 0.5);
  assert.equal(view(packet(0, 1 << 2)).getUint32(8, true), 0);
  const hovered = packet(0, (1 << 2) | (1 << 8)), query = view(hovered); assert.equal(query.getUint32(4, true), 1);
  hovered[9]! |= 0x80; new DataView(hovered.buffer).setFloat32(116, 0.25, true);
  const fill = view(hovered); assert.equal(fill.getUint32(4, true), 0); assert.equal(fill.getFloat32(60, true), 0.25);
  assert.equal(view(packet(0, (1 << 2) | (1 << 8) | (1 << 9))).getUint32(8, true), 0);
});
test("backdrop and modal scrim plans preserve token fallbacks verdicts and identities", () => {
  const blur = view(packet(1, 1 << 12)); assert.equal(blur.getFloat32(12, true), 6); assert.equal(blur.getUint32(24, true), 1);
  assert.equal(view(packet(1)).getUint32(8, true), 0);
  for (const kind of [19, 20, 21]) { const r = view(packet(2, 1 << 11, kind)); assert.equal(r.getUint32(12, true), 1); assert.equal(r.getUint32(8, true), 2); }
  assert.equal(view(packet(2, 1 << 11, 23)).getUint32(12, true), 0); assert.equal(view(packet(2, 0, 19)).getUint32(12, true), 0);
});
test("child clip radius sources follow their surface chrome", () => {
  const expected = new Map([[15, 1], [17, 2], [18, 2], [16, 2], [22, 2], [24, 2], [25, 2], [21, 2], [19, 3], [20, 3], [23, 3], [40, 4], [14, 0], [0, 0]]);
  for (const [kind, source] of expected) { assert.equal(view(packet(3, 1 << 13, kind)).getUint32(12, true), source); assert.equal(view(packet(3, 0, kind)).getUint32(12, true), 0); }
});
test("effect packets reject invalid tags facts kinds and reserved storage", () => {
  assert.throws(() => plan(new Uint8Array(127)), /invalid/);
  for (const [at, x] of [[0, 51], [1, 4], [2, 2], [3, 16], [4, 32], [5, 1], [7, 1], [8, 1], [11, 1], [100, 63], [120, 1], [127, 1]]) { const b = packet(0); b[at!] = x!; assert.throws(() => plan(b), /invalid/); }
});
