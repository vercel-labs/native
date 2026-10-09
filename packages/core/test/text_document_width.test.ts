import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "text_run_layout", "text_document_width"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvTextDocumentWidth: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvTextDocumentWidth};").toString("base64")}`);
function packet(mode: number, text = new Uint8Array(), flags = 3): Uint8Array {
  const slots = mode === 2 ? Math.min(text.length, 65536) : 0, bytes = new Uint8Array(128 + slots * 4 + text.length), w = new DataView(bytes.buffer);
  bytes.set([59, 1, mode, 0]); w.setUint32(4, flags, true); w.setUint32(8, text.length, true); w.setUint32(12, 128 + slots * 4, true); w.setUint32(16, slots, true); bytes.set(text, 128 + slots * 4); return bytes;
}
function checked(bytes: Uint8Array): Uint8Array {
  const before = bytes.slice(), out = plan(bytes); assert.deepEqual(bytes, before); assert.equal(out.length, 128); return out;
}
function drive(text: Uint8Array, flags: number, declineAt = -1): { width: number; calls: number[][] } {
  const bytes = packet(2, text, flags), w = new DataView(bytes.buffer), calls: number[][] = [];
  for (let n = 0; n <= text.length * 2 + 3; n++) {
    const result = checked(bytes), v = new DataView(result.buffer); bytes.set(result);
    if (result[3] === 2) return { width: v.getFloat32(104, true), calls };
    const action = v.getUint32(80, true), first = v.getUint32(84, true), last = v.getUint32(88, true); calls.push([action, first, last]);
    if (action === 1) {
      w.setUint32(92, calls.length === declineAt ? 0 : 1, true);
      for (let i = first; i < last; i++) w.setFloat32(128 + (i - first) * 4, 0.1, true);
    } else w.setFloat32(108, (last - first) * Math.fround(0.1), true);
  }
  throw new Error("document walk failed to finish");
}
test("document width restarts full scalar traversal after a later batch decline", () => {
  const text = new Uint8Array(131076).fill(120); text[65535] = 10; text[131071] = 10;
  const out = drive(text, 3, 2);
  assert.deepEqual(out.calls, [[1, 0, 65536], [1, 65536, 131072], [2, 0, 65535], [2, 65536, 131071], [2, 131072, 131076]]);
  assert.equal(out.width, Math.fround(65535 * Math.fround(0.1)));
});
test("document width distinguishes bounded runs oversized lines empty and trailing lines", () => {
  for (const length of [65535, 65536, 65537]) {
    const text = new Uint8Array(length).fill(120), out = drive(text, 3);
    assert.deepEqual(out.calls, [[length > 65536 ? 2 : 1, 0, length]]);
  }
  assert.deepEqual(drive(new Uint8Array(), 3), { width: 0, calls: [] });
  for (const flags of [0, 1]) assert.deepEqual(drive(new Uint8Array(), flags), { width: 0, calls: [[2,0,0]] });
  assert.deepEqual(drive(new Uint8Array([10]), 1).calls, [[2, 0, 0], [2, 1, 1]]);
  assert.deepEqual(drive(new Uint8Array([10]), 3, 1).calls, [[1,0,1],[2,0,0],[2,1,1]]);
  assert.deepEqual(drive(new Uint8Array([120, 10]), 3).calls, [[1, 0, 2]]);
  let expected = 0; for (let i = 0; i < 65536; i++) expected = Math.fround(expected + Math.fround(0.1));
  assert.equal(drive(new Uint8Array(65536).fill(120), 3).width, expected);
});
test("document cache admission and exact words preserve diff metadata and float bit identity", () => {
  for (let flags = 0; flags < 16; flags++) assert.equal(new DataView(checked(packet(1, undefined, flags)).buffer).getUint32(80, true), flags === 7 ? 1 : 0);
  const p = packet(0, undefined, 7), w = new DataView(p.buffer);
  w.setBigUint64(32, 0xf000000000000001n, true); w.setBigUint64(56, 0xf000000000000001n, true); w.setBigUint64(40, 0x8000000000000001n, true); w.setBigUint64(64, 0x8000000000000001n, true);
  for (const width of [0, -0, 0.1, -1, Infinity, -Infinity, NaN]) {
    w.setFloat32(76, width, true); assert.equal(new DataView(checked(p).buffer).getUint32(80, true), width >= 0 && Number.isFinite(width) ? 1 : 0);
  }
  w.setFloat32(76, 1, true);
  for (const at of [32, 36, 40, 44, 48]) { const q = p.slice(); new DataView(q.buffer).setUint32(at, 17, true); assert.equal(new DataView(checked(q).buffer).getUint32(80, true), 0); }
  w.setFloat32(48, -0, true); assert.equal(new DataView(checked(p).buffer).getUint32(80, true), 0);
});
test("document width rejects malformed copies and reply ranges without touching source", () => {
  const p = packet(2, new Uint8Array([120, 10]));
  for (const size of [0, 127, p.length - 1]) assert.throws(() => plan(p.subarray(0, size)));
  for (const at of [0, 1, 2, 3, 4, 8, 12, 16, 20, 28, 80, 124]) { const q = p.slice(); q[at] = 255; assert.throws(() => checked(q)); }
  const out = checked(p); p.set(out);
  for (const at of [84, 88, 92, 96, 100, 112, 116, 124]) { const q = p.slice(); new DataView(q.buffer).setUint32(at, 0xffffffff, true); assert.throws(() => checked(q)); }
});
