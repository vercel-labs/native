import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "flow_measurement.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvGridMeasure: grid, nscvFlowMeasure: flow } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvGridMeasure,nscvFlowMeasure};").toString("base64")}`);
const wire = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
const word = (b: Uint8Array, at: number) => wire(b).getUint32(at, true);
const value = (b: Uint8Array, at: number) => wire(b).getFloat32(at, true);
function gridPacket(virtual = true): Uint8Array {
  const b = new Uint8Array(384), w = wire(b); b.set([38, 1, 0, virtual ? 1 : 0]); w.setUint32(4, 4, true);
  b.set([4, 0, virtual ? 1 : 0], 16); w.setBigUint64(20, 3n, true); w.setBigUint64(28, 2n, true);
  for (const [at, v] of [[44,3.25],[48,5.125],[52,160],[56,100],[60,2],[76,3],[80,2],[84,2],[88,1]]) w.setFloat32(at!, v!, true);
  for (const i of [0,2,3]) w.setUint32(128 + i * 64, 1, true);
  w.setFloat32(148, 20, true); w.setFloat32(284, 10, true); w.setFloat32(292, 25, true);
  return b;
}
function flowPacket(op = 0, count = 3): Uint8Array {
  const b = new Uint8Array(144 + count * 72), w = wire(b); b.set([39,1,op,0]); w.setUint32(4, count, true);
  b.set([8,op,0,3], 16); w.setUint32(20, count, true);
  for (const [at,v] of [[72,count],[76,count],[92,3.25],[96,5.125],[100,160],[104,100],[108,2]]) w.setFloat32(at!, v!, true);
  for (let i = 0; i < count; i++) { w.setUint32(144 + i * 64, 1, true); w.setFloat32(148 + i * 64, i, true); }
  return b;
}
function reply(b: Uint8Array, index: number, at: number, result: number): void {
  wire(b).setUint32(144 + word(b, 4) * 64 + index * 8, 1, true);
  wire(b).setFloat32(144 + index * 64 + at, result, true);
}
test("virtual grid measures only missing heights in the first flow row and preserves complete child records", () => {
  const b = gridPacket(), w = wire(b);
  let r = grid(b); assert.equal(word(r,4),1); assert.equal(word(r,8),2);
  w.setUint32(260,1,true); w.setFloat32(296,50,true); r = grid(b);
  assert.equal(word(r,4),0); assert.equal(word(r,12),2); assert.equal(value(r,16),25);
  assert.equal(word(r,64),0); assert.equal(word(r,96),1); assert.equal(word(r,100),1); assert.equal(word(r,104),3);
  assert.equal(value(r,112),84.25); assert.equal(value(r,124),25); assert.equal(word(r,128),1); assert.equal(value(r,148),32.125);
});
test("authored grid extents suppress measurements; nonvirtual cells preserve authored semantic ownership", () => {
  const b = gridPacket(); wire(b).setFloat32(64,40,true); assert.equal(word(grid(b),4),0); assert.equal(value(grid(b),16),40);
  const plain = gridPacket(false); const r = grid(plain); assert.equal(word(r,4),0); assert.equal(value(r,16),0); assert.equal(value(r,124),25); assert.equal(value(r,156),49);
});
test("grid preserves wide column words and copied results without modifying the borrowed request", () => {
  const b = gridPacket(false), w = wire(b); w.setBigUint64(28,0xffffffffffffffffn,true); w.setFloat32(80,Math.fround(2 ** 64),true); w.setFloat32(88,Math.fround(2 ** 64),true);
  const before = b.slice(), r = grid(b), saved = r.slice(); assert.equal(word(r,12),1); assert.deepEqual(b,before); b.fill(255); assert.deepEqual(r,saved);
});
test("uniform rows measure only the first flow child and clamp its reply before allocation", () => {
  const b = flowPacket(), w = wire(b); w.setUint32(144,0,true); w.setFloat32(212,0,true); w.setFloat32(276,1,true); w.setFloat32(232,12,true); w.setFloat32(236,30,true);
  let r = flow(b); assert.equal(word(r,4),1); assert.equal(word(r,8),1);
  w.setUint32(8,1,true); w.setFloat32(116,50,true); r = flow(b);
  assert.equal(word(r,4),0); assert.equal(word(r,40),2); assert.equal(value(r,44),30); assert.equal(word(r,80),0);
  assert.equal(value(r,124),5.125); assert.equal(value(r,156),37.125);
});
test("variable rows query every missing window height in order and retain the anchor layout", () => {
  const b = flowPacket(), w = wire(b); w.setBigUint64(32,100n,true); w.setBigUint64(40,1n,true); w.setFloat32(132,1000,true); w.setFloat32(128,80,true); w.setFloat32(220,40,true);
  let r = flow(b); assert.equal(word(r,4),2); assert.equal(word(r,8),0); assert.equal(value(r,16),160);
  reply(b,0,40,20); r = flow(b); assert.equal(word(r,4),2); assert.equal(word(r,8),2);
  reply(b,2,40,60); r = flow(b); assert.equal(word(r,4),0); assert.equal(word(r,36),1);
  assert.equal(value(r,92),63.125); assert.equal(value(r,124),85.125); assert.equal(value(r,156),127.125);
});
test("scroll shelves measure only horizontal missing widths and preserve stack frames and stale-axis filtering", () => {
  const b = flowPacket(2), w = wire(b); w.setUint32(208,0,true); w.setFloat32(280,200,true); w.setFloat32(120,7,true); w.setFloat32(124,9,true);
  let r = flow(b); assert.equal(word(r,4),3); assert.equal(word(r,8),0);
  reply(b,0,44,300); r = flow(b); assert.equal(word(r,4),0); assert.equal(word(r,36),4);
  assert.equal(value(r,88),-3.75); assert.equal(value(r,92),-3.875); assert.equal(value(r,96),300); assert.equal(value(r,160),200);
  b[19] = 2; const vertical = flow(b); assert.equal(value(vertical,88),3.25); assert.equal(value(vertical,96),160);
});
test("empty flow parents retain inactive admission instead of replacing declared metadata", () => {
  const b = gridPacket(); const w = wire(b); w.setBigUint64(20,0n,true);
  for (let i=0;i<4;i++) w.setUint32(128+i*64,0,true);
  assert.equal(word(grid(b),24),0);
  const f = flowPacket(0,0); assert.equal(word(flow(f),24),0); assert.equal(word(flow(f),4),0);
});
test("complete packets reject malformed states, lengths and reserved data before issuing a query", () => {
  for (const at of [0,1,2,3,4,8,12,16,17,18,19,20,92,127,128,132,172,191]) {
    const b=gridPacket(); b[at]=255; assert.throws(()=>grid(b),/invalid/);
  }
  for (const at of [0,1,2,3,4,8,12,16,17,18,19,20,136,140,144,336,340]) {
    const b=flowPacket(); b[at]=255; assert.throws(()=>flow(b),/invalid/);
  }
  for (const derive of [grid,flow]) assert.throws(()=>derive(new Uint8Array(143)),/invalid/);
  const b=flowPacket(), before=b.slice(), r=flow(b), saved=r.slice(); assert.deepEqual(b,before); b.fill(255); assert.deepEqual(r,saved);
});
