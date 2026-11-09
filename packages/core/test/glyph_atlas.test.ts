import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "glyph_atlas.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvGlyphAtlasPlan: plan, nscvGlyphAtlasHash: hash, native_window_policy: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvGlyphAtlasPlan,nscvGlyphAtlasHash};").toString("base64")}`);
type Glyph = { id: number; font?: bigint; x?: number; y?: number };
type Run = { command?: number; font?: bigint; size?: number; x?: number; y?: number; text?: Uint8Array; glyphs?: Glyph[] };
function packet(runs: Run[], capacity = 8192): Uint8Array {
  const out = new Uint8Array(16 + runs.length * 40 + runs.reduce((n, r) => n + (r.glyphs?.length ?? 0) * 24 + (r.text?.length ?? 0), 0)), w = new DataView(out.buffer);
  out.set([61, 1]); w.setUint32(4, runs.length, true); w.setUint32(8, capacity, true); let payload = 16 + runs.length * 40;
  runs.forEach((run, i) => {
    const at = 16 + i * 40; w.setUint32(at, run.command ?? i, true); w.setBigUint64(at + 8, run.font ?? 1n, true); w.setFloat32(at + 16, run.size ?? 13.25, true); w.setFloat32(at + 20, run.x ?? 0, true); w.setFloat32(at + 24, run.y ?? 0, true); w.setUint32(at + 28, run.glyphs?.length ?? 0, true); w.setUint32(at + 32, run.text?.length ?? 0, true);
    for (const glyph of run.glyphs ?? []) { w.setUint32(payload, glyph.id, true); w.setBigUint64(payload + 8, glyph.font ?? 0n, true); w.setFloat32(payload + 16, glyph.x ?? 0, true); w.setFloat32(payload + 20, glyph.y ?? 0, true); payload += 24; }
    if (run.text) { out.set(run.text, payload); payload += run.text.length; }
  }); return out;
}
function checked(input: Uint8Array): Uint8Array { const before = input.slice(), output = plan(input); assert.deepEqual(input, before); assert.equal(output.length, 16 + new DataView(output.buffer).getUint32(0, true) * 32); return output; }
function entries(output: Uint8Array) {
  const w = new DataView(output.buffer); return Array.from({ length: w.getUint32(0, true) }, (_, i) => { const at = 16 + i * 32; return { size: w.getFloat32(at, true), glyph: w.getUint32(at + 4, true), font: w.getBigUint64(at + 8, true), x: w.getUint32(at + 16, true), y: w.getUint32(at + 20, true), command: w.getUint32(at + 24, true), source: w.getUint32(at + 28, true) }; });
}
test("atlas shaping retains full font identities overrides original sources and quarter pixels", () => {
  const input = packet([{ command: 3, font: 0xf123456789abcdefn, x: -0.25, y: -0.5, glyphs: [{ id: 7 }, { id: 7, font: 0x100000001n, x: 0.25, y: 0.5 }, { id: 7 }] }]);
  const output = checked(input); assert.deepEqual(entries(output), [{ size: 13.25, glyph: 7, font: 0xf123456789abcdefn, x: 3, y: 2, command: 3, source: 0 }, { size: 13.25, glyph: 7, font: 0x100000001n, x: 0, y: 0, command: 3, source: 1 }]); input.fill(255); assert.equal(entries(output)[0]!.glyph, 7);
});
test("atlas raw bytes preserve fallback ids and whitespace scalar positions", () => {
  const output = checked(packet([{ size: 1, text: new TextEncoder().encode("A \t🙂A") }]));
  assert.deepEqual(entries(output).map(e => [e.glyph, e.x, e.source]), [[65, 0, 0], [0x1f642, 2, 3]]);
  const raw = checked(packet([{ text: new Uint8Array([0x80, 0x81, 0xc0, 0x80, 65, 0x80, 0xff, 0xe2, 0x80]) }]));
  assert.deepEqual(entries(raw).map(e => e.glyph), [0x80, 0x81, 0, 65, 0x80, 0xff, 0xe2]);
});
test("atlas capacity errors preserve first admission and accept later duplicates at a full limit", () => {
  for (const indexed of [false, true]) {
    const glyphs = Array.from({ length: indexed ? 128 : 4 }, (_, i) => ({ id: i % 2 }));
    const exact = checked(packet([{ glyphs }], 2)); assert.equal(new DataView(exact.buffer).getUint32(4, true), 0); assert.deepEqual(entries(exact).map(e => e.source), [0, 1]);
    const short = checked(packet([{ glyphs }], 1)); assert.equal(new DataView(short.buffer).getUint32(4, true), 1); assert.deepEqual(entries(short).map(e => e.source), [0]);
  }
  assert.deepEqual(entries(checked(packet([{ text: new Uint8Array([32, 10, 9, 13]) }], 0))), []);
});
test("atlas equality folds signed zero and keeps every NaN occurrence distinct", () => {
  const zero = entries(checked(packet([{ size: -0, glyphs: [{ id: 1 }] }, { size: 0, glyphs: [{ id: 1 }] }]))); assert.equal(zero.length, 1); assert.ok(Object.is(zero[0]!.size, -0));
  const nan = entries(checked(packet([{ size: NaN, glyphs: Array.from({ length: 64 }, () => ({ id: 1 })) }]))); assert.equal(nan.length, 64);
});
test("atlas indexed hash collisions preserve complete unique keys and first occurrences", () => {
  const key = new DataView(new ArrayBuffer(24)); key.setFloat32(0, 13.25, true); key.setUint32(4, 7, true);
  const glyphs: Glyph[] = []; for (let font = 1; glyphs.length < 64; font++) { key.setUint32(8, font, true); if ((hash(key, 0) & 16383) === 0) glyphs.push({ id: 7, font: BigInt(font) }); }
  const output = checked(packet([{ glyphs: [...glyphs, ...glyphs] }], 64)); assert.equal(new DataView(output.buffer).getUint32(4, true), 0); assert.deepEqual(entries(output).map(e => e.font), glyphs.map(g => g.font));
});
test("atlas validates all raw storage lengths padding command order and offset views", () => {
  const input = packet([{ glyphs: [{ id: 1 }], text: new Uint8Array([65]) }]);
  for (const length of [0, 15, input.length - 1]) assert.throws(() => checked(input.subarray(0, length)));
  for (const at of [0, 1, 2, 3, 4, 12, 20, 44, 48, 52, 60]) { const invalid = input.slice(); invalid[at] = 255; assert.throws(() => checked(invalid)); }
  assert.throws(() => checked(packet([{ command: 2 }, { command: 2 }])));
  const parent = new Uint8Array(input.length + 7); parent.set(input, 7); assert.deepEqual(checked(parent.subarray(7)), checked(input));
});
test("glyph cache indexing derives keys even when native bucket facts disagree", () => {
  const request = new Uint8Array(48 + 128 * 80), w = new DataView(request.buffer); request.set([11, 1]); w.setUint32(4, 64, true); w.setUint32(8, 64, true); w.setUint32(12, 64, true); w.setUint32(16, 64, true);
  for (let i = 0; i < 128; i++) { const at = 48 + i * 80; w.setFloat32(at, i < 64 ? -0 : 0, true); w.setUint32(at + 4, i % 64, true); w.setBigUint64(at + 8, 0xf123456789abcdefn, true); w.setUint32(at + 72, i * 1234567, true); }
  const output = policy(request), o = new DataView(output.buffer); assert.equal(o.getUint32(0, true), 64); assert.equal(o.getUint32(4, true), 64);
  for (let i = 0; i < 64; i++) { const at = 16 + 64 * 4 + i * 12; assert.equal(o.getUint32(at, true), 1); assert.equal(o.getUint32(at + 8, true), i); }
});
