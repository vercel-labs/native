import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/scroll_tree.ts", import.meta.url), "utf8");
const { nscvScrollTree: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvScrollTree };").toString("base64")}`);
function packet(mode: number, nodes: readonly (readonly number[])[], target = 0): Uint8Array {
  const b = new Uint8Array(48 + nodes.length * 56), w = new DataView(b.buffer);
  b[0] = 94; b[1] = mode; w.setUint32(4, nodes.length, true); w.setUint32(8, target, true); w.setUint32(12, 0xffffffff, true);
  w.setFloat32(24, 100, true); w.setFloat32(28, 100, true);
  nodes.forEach((n, i) => { const at = 48 + i * 56;
    for (let j = 0; j < 3; j++) w.setUint32(at + j * 4, n[j]!, true);
    for (let j = 3; j < n.length; j++) w.setFloat32(at + j * 4, n[j]!, true);
  }); return b;
}
const root = [0, 0xffffffff, 64 | 8, 10, 20, 0, 0, 100, 100, 0, 0, 100, 100] as const;
test("extent and translation walks have distinct stationary and clipping exclusions", () => {
  const nodes = [root, [1,0,8,0,0,10,10,20,20], [2,1,0,0,0,500,500,50,50], [1,0,1|4,0,0,900,900,50,50], [2,3,0,0,0,1000,1000,1,1], [1,0,2|4,0,0,800,800,50,50], [2,5,0,0,0,1000,1000,1,1]];
  const b = packet(0, nodes), out = new DataView(plan(b).buffer);
  assert.equal(out.getFloat32(12, true), 100); assert.equal(out.getFloat32(16, true), 560);
  b[1] = 1; assert.deepEqual([...plan(b).subarray(24)], [0,1,1,0,0,0,0]);
});
test("tab reveals run in order against refreshed geometry and preserve prior selections", () => {
  const b = packet(2, [root, [1,0,128,0,0,180,0,30,20], [1,0,128|256,0,0,-80,0,30,20]]);
  const out = new DataView(plan(b).buffer);
  assert.equal(out.getUint32(8,true), 0); assert.equal(out.getUint32(20,true), 2);
  assert.equal(out.getFloat32(12,true), -110); assert.equal(out.getFloat32(16,true), 130);
  new DataView(b.buffer).setUint32(8,2,true);
  assert.equal(new DataView(plan(b).buffer).getUint32(8,true), 0xffffffff);
});
test("owned results, bounded parents, empty walks and all truncations", () => {
  const b = packet(1, [root]), before = b.slice(), out = plan(b); b.fill(0);
  assert.equal(out[0],94); assert.deepEqual([...out.subarray(24)],[0]);
  for (let n=0;n<before.length;n++) assert.throws(()=>plan(before.subarray(0,n)));
  for (const at of [2,3,36,47]) { const changed=before.slice(); changed[at]=1; assert.throws(()=>plan(changed)); }
  const changed=before.slice(); new DataView(changed.buffer).setUint32(52,0,true); assert.throws(()=>plan(changed));
  assert.equal(plan(packet(2,[])).length,24);
  assert.equal(plan(packet(1,Array.from({length:1024},(_,i)=>i===0?root:[1,0,0,0,0,0,0,1,1]))).length,1048);
});
