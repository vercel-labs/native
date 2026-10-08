import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "control_primitives", "chart_content", "chart_plans"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvChartPlans: plan, nscChartLabel: label, nscChartLog10: log, nscChartPower10: pow } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvChartPlans,nscChartLabel,nscChartLog10,nscChartPower10};").toString("base64")}`);
const f = Math.fround;
const bits = (x: number): number => { const w = new DataView(new ArrayBuffer(4)); w.setFloat32(0, x, true); return w.getUint32(0, true); };
const value = (x: number): number => { const w = new DataView(new ArrayBuffer(4)); w.setUint32(0, x, true); return w.getFloat32(0, true); };
function packet(mode = 0, kind = 0, samples = [1, 3, 2]): Uint8Array {
  const b = new Uint8Array(520 + samples.length * 4), w = new DataView(b.buffer);
  b.set([50, 1, mode, 0, 0, 0]); w.setUint32(8, 1, true); w.setBigUint64(16, 0xfedcba9876543210n, true);
  [1.25, 2.5, 160.25, 90.5].forEach((x, i) => w.setFloat32(24 + i * 4, x, true));
  w.setFloat32(72, 13, true); w.setFloat32(76, 1, true); w.setFloat32(100, 1.25, true); w.setUint32(104, 68, true);
  w.setUint32(480, kind, true); w.setUint32(488, samples.length, true);
  [0.125, 0.25, 0.5, 0.625].forEach((x, i) => w.setFloat32(504 + i * 4, x, true));
  samples.forEach((x, i) => w.setFloat32(520 + i * 4, x, true)); return b;
}
function sequence(b: Uint8Array): Uint8Array[] {
  const input = b.slice(), w = new DataView(input.buffer), out: Uint8Array[] = [];
  for (let i = 0; i < 1000; i++) {
    const r: Uint8Array = plan(input), v = new DataView(r.buffer); out.push(r);
    if (v.getUint32(4, true) === 0) return out;
    input.set(r.subarray(16, 192), 240);
    if (v.getUint32(4, true) === 1) w.setFloat32(416, v.getUint32(252, true) * v.getFloat32(224, true) * 0.45, true);
  }
  throw new Error("chart plan did not terminate");
}
test("chart plans preserve complete line and area verbs alpha and caller ownership", () => {
  const b = packet(), w = new DataView(b.buffer); w.setUint32(484, 1, true); const saved = b.slice();
  const results = sequence(b); assert.deepEqual(results.map(r => new DataView(r.buffer).getUint32(4, true)), [5, 6, 0]);
  assert.deepEqual(b, saved);
  for (const [i, expected] of [[0, [0, 1, 1, 1, 1, 2]], [1, [0, 1, 1]]] as const) {
    const r = results[i]!, v = new DataView(r.buffer);
    assert.equal(v.getUint32(252, true), expected.length); assert.deepEqual(expected.map((_, n) => v.getUint32(288 + n * 28, true)), expected);
    assert.equal(v.getUint32(248, true), bits(i === 0 ? f(0.18) : 0.625));
    const copy = r.slice(); b.fill(255); assert.deepEqual(r, copy);
  }
});
test("chart hover carries exact indices above the float32 integer precision boundary", () => {
  const b = packet(4), w = new DataView(b.buffer), index = 16777217;
  w.setUint32(120, index, true); [0, 0, 160, 90].forEach((x, i) => w.setFloat32(124 + i * 4, x, true));
  [10, 10, 120, 80].forEach((x, i) => w.setFloat32(144 + i * 4, x, true));
  for (const r of sequence(b)) assert.equal(new DataView(r.buffer).getUint32(28, true), index);
});
test("chart logarithm and power preserve native software boundary rounding", () => {
  const boundaries = [[507307245, -20], [702623235, -13], [869711757, -7], [1287568409, 8], [2067830679, 36], [2123789934, 38]];
  for (const [word, expected] of boundaries) assert.equal(Math.floor(log(value(word!))), expected);
  for (const exponent of [-45, -30, -10, -1, 0, 1, 10, 30, 38]) assert.ok(pow(exponent) > 0);
});
test("chart labels preserve fixed precision signed zero extremes and special values", () => {
  const text = (x: number, places: number): string => Buffer.from(label(bits(x), places)).toString();
  assert.equal(text(-0, 3), "0"); assert.equal(text(0.125, 2), "0.13"); assert.equal(text(-0.125, 2), "-0.13");
  assert.equal(text(1.005, 2), "1.01"); assert.equal(text(Infinity, 3), "inf"); assert.equal(text(-Infinity, 0), "-inf"); assert.equal(text(NaN, 1), "nan");
  assert.equal(text(value(0x7f7fffff), 0), "340282350000000000000000000000000000000");
});
test("chart modes preserve plot and hover admission without mutating input", () => {
  for (const mode of [1, 2, 3]) {
    const b = packet(mode), w = new DataView(b.buffer); w.setFloat32(420, 81.375, true); [0, 0, 300, 180].forEach((x, i) => w.setFloat32(56 + i * 4, x, true));
    const r = sequence(b).at(-1)!, v = new DataView(r.buffer); assert.equal(v.getUint32(8, true), 1);
    if (mode !== 1) assert.equal(v.getUint32(28, true), 1);
    if (mode === 3) assert.ok(v.getFloat32(120, true) > 0);
    if (mode !== 1) { w.setUint32(104, 64, true); assert.equal(new DataView(plan(b).buffer).getUint32(8, true), 0); }
  }
});
test("chart packets reject truncated sources invalid tags flags and reserved storage", () => {
  assert.throws(() => plan(new Uint8Array(479)), /invalid/);
  for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 428, 479]) { const b = packet(); b[at] = 255; assert.throws(() => plan(b), /invalid/); }
  for (const [at, x] of [[8, 2], [12, 1], [480, 3], [484, 2], [488, 100], [492, 1], [496, 1], [500, 1]]) { const b = packet(); new DataView(b.buffer).setUint32(at!, x!, true); assert.throws(() => plan(b), /invalid|truncated/); }
  const b = packet(), tail = new Uint8Array(b.length + 1); tail.set(b); assert.throws(() => plan(tail), /trailing/);
});
