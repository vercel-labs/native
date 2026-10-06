import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/chart_content.ts", import.meta.url), "utf8");
const { nscvChartContentPolicy: policy, nscChartSummaryValue: format, nscChartIndices: indices } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvChartContentPolicy, nscChartSummaryValue, nscChartIndices };").toString("base64")}`);
const text = (bytes: number[]) => new TextDecoder().decode(new Uint8Array(bytes));
const word = (value: number) => { const b = new ArrayBuffer(4), v = new DataView(b); v.setFloat32(0, value, true); return v.getUint32(0, true); };
function request(values: number[], low: number[] = [], label = new Uint8Array(0), kind = 0) {
  const b = new Uint8Array(24 + label.length + 4 * (values.length + low.length)), v = new DataView(b.buffer);
  b[0] = 21; v.setUint32(4, 1, true); b[8] = kind;
  v.setUint32(12, label.length, true); v.setUint32(16, values.length, true); v.setUint32(20, low.length, true); b.set(label, 24);
  let at = 24 + label.length; for (const w of [...values, ...low]) { v.setUint32(at, w, true); at += 4; } return b;
}
test("chart summaries use native shortest-f32 decimal rounding including special signs", () => {
  const pins = new Map([[0, "0.00"], [0x80000000, "-0.00"], [0x3f80a3d7, "1.01"], [0x402b3333, "2.68"], [0x7f7fffff, "340282350000000000000000000000000000000.00"], [1, "0.00"], [0x6b000000, "154742510000000000000000000.00"], [0x7f800000, "inf"], [0xff800000, "-inf"], [0x7fc00037, "nan"], [0xffc00037, "-nan"]]);
  for (const [bits, expected] of pins) assert.equal(text(format(bits)), expected);
});
test("chart buckets preserve first extrema ties index order and NaN gaps", () => {
  const values = Array(512).fill(word(1)); values[0] = 0x7fc00037; values[1] = word(-200); values[2] = word(200);
  assert.deepEqual(indices(values).slice(0, 4), [1, 2, 4, 4]);
  assert.deepEqual(indices([0x80000000, 0, 0x7fc00037]), [0, 1, 2]);
  assert.deepEqual(indices(Array(257).fill(0x7fc00037)).slice(0, 4), [0, 0, 2, 2]);
});
test("chart preparation reports source counts and only upper-edge rebucketing drops labels", () => {
  const label = new Uint8Array([65, 0, 255]), b = request([word(1.005)], Array(257).fill(0), label, 2), out = policy(b), v = new DataView(out.buffer);
  assert.equal(out[0], 0);
  const len = v.getUint32(4, true); assert.deepEqual([...out.slice(8, 8 + len)], [99,104,97,114,116,58,32,65,0,255,...new TextEncoder().encode(" 1 pts last 1.01")]);
  assert.equal(v.getUint32(8 + len, true), 1); assert.equal(v.getUint32(12 + len, true), 256);
  assert.equal(policy(request(Array(257).fill(word(2))))[0], 1);
  const empty = new Uint8Array(8); empty[0] = 21;
  assert.equal(text([...policy(empty).slice(8)]), "chart:");
});
test("chart packets reject truncated duplicate-tail and invalid headers and own their result", () => {
  const packet = request([word(1), 0x7fc00037], [], new Uint8Array([255]));
  for (let len = 0; len < packet.length; len++) assert.throws(() => policy(packet.subarray(0, len)));
  assert.throws(() => policy(new Uint8Array([...packet, 0])));
  for (const at of [1, 2, 3, 9, 10, 11]) { const b = packet.slice(); b[at] = 1; assert.throws(() => policy(b)); }
  const wrapped = new Uint8Array(packet.length + 13).fill(211), borrowed = wrapped.subarray(7, 7 + packet.length); borrowed.set(packet);
  const before = wrapped.slice(), result = policy(borrowed), owned = result.slice();
  borrowed.fill(0); policy(packet); assert.deepEqual(result, owned);
  assert.deepEqual([...before.slice(0, 7)], Array(7).fill(211));
});
