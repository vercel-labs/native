import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const components = readFileSync(new URL("../src/view_components.ts", import.meta.url), "utf8");
const split = components.slice(components.indexOf("function nscvSplitPolicy("), components.indexOf("/** Resizable wire:"));
const source = split + "\n" + readFileSync(new URL("../src/staged_rebuild.ts", import.meta.url), "utf8");
const { nscvStagedRebuild: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvStagedRebuild };").toString("base64")}`);
function program(nodes: readonly (readonly [number, number])[], maximum: number): Uint8Array {
 const b = new Uint8Array(32 + nodes.length * 8), w = new DataView(b.buffer);b[0] = 96; w.setUint32(4,nodes.length,true);w.setUint32(16,maximum,true);
 nodes.forEach(([admit,depth],i) => { w.setUint32(32+i*8,admit,true);w.setUint32(36+i*8,depth,true); });return b;
}
test("staged program orders outer split mutations before scroll, reveal and nested anchors", () => {
 const b = program([[1,0],[0,0],[1,1],[1,0],[1,2]],2), w=new DataView(b.buffer), seen: string[]=[];
 for(let i=0;i<30;i++) { const reply=plan(b), out=new DataView(reply.buffer), kind=reply[2];
  if(kind===0)break;seen.push(`${w.getUint32(12,true)}:${kind}:${out.getUint32(4,true)}`);
  w.setUint32(8,out.getUint32(8,true),true);w.setUint32(12,out.getUint32(16,true),true);w.setUint32(20,out.getUint32(12,true),true);
 }
 assert.deepEqual(seen,["0:1:0","0:1:3","0:2:0","0:3:0","0:4:0","0:5:0","1:1:2","1:2:0","1:3:0","1:4:0","1:5:0","2:1:4","2:2:0","2:3:0","2:4:0"]);
});
test("staged split plans distinguish mount, source drive, retained tween and active drag", () => {
 const b = new Uint8Array(32),w=new DataView(b.buffer);b[0]=96;b[1]=1;
 const cases: readonly (readonly [number,number,number])[] = [[0,0,.75],[28,1,.125],[5,0,.75],[7,0,.75],[15,3,.25],[79,4,.25],[39,3,.25],[71,0,.75],[43,2,.25]];
 for(const [flags,kind,value] of cases){b[2]=flags;w.setFloat32(4,.75,true);w.setFloat32(8,.125,true);w.setFloat32(12,.5,true);w.setFloat32(16,.25,true);
  const out=plan(b);assert.equal(out[2],kind);assert.equal(new DataView(out.buffer).getFloat32(4,true),value);
 }
 b[2]=7;w.setFloat32(12,.75,true);assert.equal(plan(b)[2],4);
});
test("staged programs validate full boundaries and own output bytes", () => {
 const b=program([[1,0]],0), result=plan(b);b.fill(255);assert.equal(result[2],1);
 const good=program([[1,0]],0);for(let i=0;i<good.length;i++)assert.throws(()=>plan(good.subarray(0,i)));
 for(const at of [0,1,2,3,4,8,12,20,24,28,32,36]){const bad=good.slice();bad[at]=255;assert.throws(()=>plan(bad));}
 assert.equal(plan(program([],0))[2],2);assert.equal(plan(program(Array.from({length:1024},()=>[1,0] as const),0))[2],1);
 assert.throws(()=>plan(program(Array.from({length:1025},()=>[1,0] as const),0)));
 const split=new Uint8Array(32);split[0]=96;split[1]=1;
 for(const at of [2,3,20,24,28]){const bad=split.slice();bad[at]=255;assert.throws(()=>plan(bad));}
});
