import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/render_coordination.ts", import.meta.url), "utf8");
const { nscvRenderRecipe: recipe, nscvRenderChildren: children } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvRenderRecipe,nscvRenderChildren};").toString("base64")}`);
const wire = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
function packet(kind: number, retained = false, flags = 0, disclosure = 0): Uint8Array {
  const b = new Uint8Array(32); b.set([43,1,retained ? 1 : 0,disclosure]);
  wire(b).setUint32(4,flags,true);wire(b).setUint32(20,kind,true);return b;
}
function commands(b: Uint8Array): number[][] {
  const r = recipe(b), w = wire(r);
  assert.equal(r.length,64);assert.equal(w.getUint32(0,true),1);assert.ok(r.subarray(16+w.getUint32(8,true)*8).every(v=>v===0));
  return Array.from({length:w.getUint32(8,true)},(_,i)=>[w.getUint32(16+i*8,true),w.getUint32(20+i*8,true)]);
}
test("bubble recipes preserve the palette cascade and page-token reactions after children",()=>{
  for(const retained of [false,true])assert.deepEqual(commands(packet(15,retained,1)),[[0,0],[1,9],[3,257],[6,0]]);
});
test("table and virtual scrolling order clips children bars and separators correctly",()=>{
  assert.deepEqual(commands(packet(5,false,2)),[[0,0],[3,0],[4,0]]);
  assert.deepEqual(commands(packet(5,true,2)),[[0,0],[3,2],[5,0],[4,1]]);
  assert.deepEqual(commands(packet(5,true,3|32)),[[0,0],[3,1],[4,1]]);
  assert.deepEqual(commands(packet(6,true,32)),[[0,0],[3,2]]);
  assert.deepEqual(commands(packet(6,false)),[[0,0],[3,2],[5,1]]);
});
test("disclosure recipes preserve discrete tree and three-state retained emission",()=>{
  assert.deepEqual(commands(packet(14,false,0,1)),[[0,0],[1,8]]);
  assert.deepEqual(commands(packet(14,false,64|1)),[[0,0],[1,8],[3,1]]);
  for(const [pose,clip]of [[0,-1],[1,3],[2,1]])assert.deepEqual(commands(packet(14,true,1,pose!)),[[0,0],[1,8],...(clip!<0?[]:[[3,clip!]])]);
});
test("retained leaves and direct cells retain their different child contracts",()=>{
  assert.deepEqual(commands(packet(31,false)),[[0,0],[1,22]]);
  assert.deepEqual(commands(packet(31,true)),[[0,0],[1,22],[3,0]]);
  assert.deepEqual(commands(packet(44,false,128)),[[0,0],[1,31],[3,0]]);
  assert.deepEqual(commands(packet(44,false,128|4)),[[0,0],[1,31]]);
  assert.deepEqual(commands(packet(26,false,8|4)),[[0,0],[1,14]]);
  assert.deepEqual(commands(packet(39,true,16)),[[0,0],[1,26],[3,0]]);
});
test("modal scrims precede chrome and segment stamps honor style and exceptional gaps",()=>{
  assert.deepEqual(commands(packet(19,true,1024|1)),[[0,0],[2,0],[1,5],[3,1]]);
  for(const [gap,detached,stamp]of [[0,false,true],[2,false,false],[-1,false,true],[NaN,false,false],[Infinity,true,true]] as const){
    const b=packet(9,false,detached?512:0);wire(b).setFloat32(16,gap,true);
    assert.deepEqual(commands(b),[[0,0],[3,stamp?512:0]]);
  }
});
test("depth errors precede hidden suppression and retain complete empty command tails",()=>{
  const b=packet(31,false,256);assert.equal(wire(recipe(b)).getUint32(4,true),1);
  for(const depth of [32n,9007199254740993n,0xffffffffffffffffn]){
    wire(b).setBigUint64(8,depth,true);const r=recipe(b);assert.equal(wire(r).getUint32(4,true),2);assert.ok(r.subarray(8).every(v=>v===0));
  }
});
function childPacket(rows: [number,boolean,number|null][], stamp=true):Uint8Array{
  const b=new Uint8Array(32+rows.length*12),w=wire(b);b.set([44,1,stamp?1:0,0]);w.setUint32(4,rows.length,true);
  for(const [i,value]of [7,20,-5,30].entries())w.setInt32(8+i*4,value,true);
  rows.forEach(([kind,hidden,layer],i)=>{const at=32+i*12;w.setUint32(at,kind,true);w.setUint32(at+4,(hidden?1:0)|(layer===null?0:2),true);if(layer!==null)w.setInt32(at+8,layer,true);});return b;
}
function entries(b:Uint8Array):number[][]{const r=children(b),w=wire(r);return Array.from({length:w.getUint32(4,true)},(_,i)=>[w.getUint32(8+i*8,true),w.getUint32(12+i*8,true)]);}
test("direct paint ordering retains hidden visits, exact signed layers and visible source segments",()=>{
  const b=childPacket([[31,false,2147483647],[23,false,null],[31,true,-2147483648],[31,false,null],[40,false,null],[19,false,null],[31,false,null]]);
  assert.deepEqual(entries(b),[[2,1],[1,2],[3,2],[6,3],[5,2],[4,2],[0,1]]);
  b[2]=0;assert.deepEqual(entries(b).map(e=>e[1]),[0,0,0,0,0,0,0]);
  assert.deepEqual(entries(childPacket([])),[]);assert.deepEqual(entries(childPacket([[31,true,null],[31,true,null]])),[[0,0],[1,0]]);
});
test("all kind and flag recipes are bounded, owned and reject malformed packets",()=>{
  for(let kind=0;kind<63;kind++)for(const retained of [false,true])for(let flags=0;flags<2048;flags++){
    const b=packet(kind,retained,flags,flags%3),saved=b.slice(),r=recipe(b),copy=r.slice();assert.deepEqual(b,saved);b.fill(255);assert.deepEqual(r,copy);assert.ok(wire(r).getUint32(8,true)<=6);
  }
  for(const at of [0,1,2,3,5,12,20,24,31]){const b=packet(31,true);b[at]=255;assert.throws(()=>recipe(b),/invalid/);}
  for(const at of [0,1,2,3,4,24,32,36,40]){const b=childPacket([[31,false,null]]);b[at]=255;assert.throws(()=>children(b),/invalid/);}
  const b=childPacket([[31,false,null],[31,false,null]]),saved=b.slice(),r=children(b),copy=r.slice();assert.deepEqual(b,saved);b.fill(255);assert.deepEqual(r,copy);
});
