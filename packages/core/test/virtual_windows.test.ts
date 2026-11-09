import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const portableSourceText = ["runtime_policy", "virtual_windows"].map(n => readFileSync(new URL(`../src/${n}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvVirtualWindows: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(portableSourceText) + "\nexport { nscvVirtualWindows }; ").toString("base64")}`);
function layout(ids: readonly bigint[], nodes: readonly [bigint, bigint, number][]): Uint8Array {
 const b = new Uint8Array(16 + (ids.length + nodes.length) * 24), w = new DataView(b.buffer); b[0] = 97;
 w.setUint32(4, ids.length, true); w.setUint32(8, nodes.length, true);
 ids.forEach((id, i) => { const at=16+i*24; w.setBigUint64(at,id,true);w.setBigUint64(at+8,10n,true);w.setUint32(at+16,1,true); });
 nodes.forEach(([id,parent,flags],i)=>{const at=16+(ids.length+i)*24;w.setBigUint64(at,id,true);w.setBigUint64(at+8,parent,true);w.setUint32(at+16,flags,true);});return b;
}
test("virtual windows preserve duplicate list order and distinguish exact identity words",()=>{
 const b=layout([9007199254740993n,9007199254740992n,9007199254740993n],[[9007199254740992n,0n,0],[9007199254740993n,0n,0],[2n,1n,5],[3n,1n,7],[4n,0n,5]]);
 const result=plan(b),v=new DataView(result.buffer);assert.equal(v.getUint32(8,true),3);
 assert.deepEqual([0,1,2].map(i=>v.getUint32(16+i*16,true)),[1,0,1]);
 assert.deepEqual([0,1,2].map(i=>v.getUint32(28+i*16,true)),[1,1,1]);
 assert.deepEqual([...result.subarray(64)],[2,0,0,0,4,0,0,0,2,0,0,0]);
});
test("virtual windows reject truncated or oversized transports and invalid reserved facts",()=>{
 const b=layout([1n],[[1n,0n,0],[2n,0n,5]]);
 for(let n=0;n<b.length;n++)assert.throws(()=>plan(b.subarray(0,n)));
 for(const at of [0,1,2,3,4,8,12,32,36,56,60]){const bad=b.slice();bad[at]=255;assert.throws(()=>plan(bad));}
 assert.throws(()=>plan(layout(Array(9).fill(1n),[])));
 assert.throws(()=>plan(layout([],Array.from({length:1025},()=>[1n,0n,0] as const))));
 assert.equal(plan(layout([],[])).length,16);
});
