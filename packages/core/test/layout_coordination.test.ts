import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "layout_coordination.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvLayoutAdmission: admission, nscvLayoutChildren: children, nscvLayoutRetained: retained } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvLayoutAdmission,nscvLayoutChildren,nscvLayoutRetained};").toString("base64")}`);
const wire = (b: Uint8Array) => new DataView(b.buffer, b.byteOffset, b.byteLength);
const word = (b: Uint8Array, at: number) => wire(b).getUint32(at, true);
const value = (b: Uint8Array, at: number) => wire(b).getFloat32(at, true);
function packet(mode: number, kinds: number[], spans = 0): Uint8Array {
  const b = new Uint8Array(64 + kinds.length * 64 + spans * 24), w = wire(b); b.set([41,1,mode,0]);
  w.setUint32(4,kinds.length,true); w.setUint32(8,spans,true);
  for (const [at,v] of [[16,3.25],[20,5.125],[24,200],[28,100]]) w.setFloat32(at!,v!,true);
  for (let i=0;i<kinds.length;i++) w.setUint32(64+i*64,kinds[i]!,true);
  return b;
}
function records(b: Uint8Array) { return Array.from({length:word(b,8)},(_,i)=>({source:word(b,32+i*32),flags:word(b,36+i*32),value:value(b,40+i*32),frame:[0,4,8,12].map(j=>value(b,48+i*32+j))})); }
test("admission preserves depth-before-capacity precedence and exact wide counts",()=>{
  const b=new Uint8Array(32),w=wire(b);b.set([40,1,0,0]);w.setBigUint64(24,1n,true);
  assert.deepEqual([...admission(b)],[0,12,0,0]);w.setBigUint64(8,32n,true);w.setBigUint64(16,1n,true);
  assert.deepEqual([...admission(b)],[1,0,0,0]);w.setBigUint64(8,0n,true);
  for(const [len,cap,full] of [[9007199254740992n,9007199254740993n,false],[0xfffffffffffffffen,0xffffffffffffffffn,false],[0xffffffffffffffffn,0xffffffffffffffffn,true]] as const){
    w.setBigUint64(16,len,true);w.setBigUint64(24,cap,true);assert.equal(admission(b)[0],full?2:0);
  }
  w.setBigUint64(8,0xffffffffffffffffn,true);assert.equal(admission(b)[0],1);
});
test("stack, modal and anchor stages preserve authored order and modal priority",()=>{
  const b=packet(0,[31,19,23,26,20]),w=wire(b);w.setUint32(196,1,true);w.setUint32(324,1,true);
  assert.deepEqual(records(children(b)).map(r=>r.source),[0,3]);
  b[2]=1;assert.deepEqual(records(children(b)),[1,4].map(source=>({source,flags:2,value:0,frame:[3.25,5.125,200,100]})));
  b[2]=2;assert.deepEqual(records(children(b)),[{source:2,flags:4,value:0,frame:[3.25,5.125,200,100]}]);
});
test("split chooses the first two panes and first divider, mirrors the capability reply, and collapses extras",()=>{
  const b=packet(3,[58,31,58,23,26,31]),w=wire(b);w.setUint32(260,1,true);w.setFloat32(152,20,true);w.setFloat32(344,30,true);
  let r=children(b);assert.equal(word(r,4),2);assert.deepEqual([value(r,16),value(r,20),value(r,24)],[191,20,30]);
  w.setUint32(12,1,true);w.setFloat32(40,0.25,true);r=children(b);
  assert.deepEqual(records(r),[
    {source:1,flags:2,value:0,frame:[3.25,5.125,47.75,100]},
    {source:0,flags:3,value:0.25,frame:[51,5.125,9,100]},
    {source:4,flags:2,value:0,frame:[60,5.125,143.25,100]},
    {source:5,flags:2,value:0,frame:[203.25,5.125,0,0]},
  ]);
  assert.ok(r.subarray(32+4*32).every(v=>v===0));
});
test("link spans consume excluded children and surplus flow hotspots collapse",()=>{
  const b=packet(4,[23,31,19,26],4),w=wire(b),base=64+4*64;w.setUint32(68,1,true);
  for(const i of [0,2,3])w.setUint32(base+i*24,1,true);
  let r=children(b);assert.equal(word(r,4),1);assert.equal(word(r,8),1);assert.equal(word(r,12),2);
  w.setUint32(base+2*24+4,2,true);for(const [offset,v]of [[8,7],[12,9],[16,30],[20,12]])w.setFloat32(base+2*24+offset!,v!,true);
  r=children(b);assert.deepEqual(records(r),[
    {source:1,flags:2,value:0,frame:[10.25,14.125,30,12]},
    {source:3,flags:2,value:0,frame:[3.25,5.125,0,0]},
  ]);
});
function retainedPacket(parents: bigint[], anchors: number[]): Uint8Array {
  const b=new Uint8Array(32+parents.length*24),w=wire(b);b.set([42,1,0,0]);w.setUint32(4,parents.length,true);
  for(let i=0;i<parents.length;i++){w.setUint32(32+i*24,anchors[i]!,true);w.setBigUint64(48+i*24,parents[i]!,true);}return b;
}
test("retained passes select anchor strata, bound malformed chains and guarantee exact cursor progress",()=>{
  const b=retainedPacket([0xffffffffffffffffn,0n,1n,2n,0n],[0,0,1,1,1]),w=wire(b);
  w.setBigUint64(8,3n,true);assert.equal(word(retained(b),8),2);b[2]=1;assert.equal(word(retained(b),8),2);
  b[2]=2;w.setBigUint64(8,1n,true);w.setBigUint64(16,0n,true);assert.deepEqual([word(retained(b),4),word(retained(b),8),word(retained(b),12)],[1,2,1]);
  w.setBigUint64(16,1n,true);assert.equal(word(retained(b),8),3);
  b[2]=3;w.setBigUint64(8,0xffffffffn,true);w.setBigUint64(16,0n,true);assert.equal(wire(retained(b)).getBigUint64(8,true),0x100000000n);
  w.setBigUint64(16,9007199254740993n,true);assert.equal(wire(retained(b)).getBigUint64(8,true),9007199254740993n);
  const cycle=retainedPacket([1n,0n],[1,1]);assert.equal(word(retained(cycle),8),2);
  const invalid=retainedPacket([0xffffffffffffffffn,9007199254740993n],[0,1]);invalid[2]=2;assert.equal(word(retained(invalid),4),0);
});
test("plans reject malformed tables and keep requests and copied continuations independent",()=>{
  const b=packet(3,[31,58,26]),saved=b.slice(),r=children(b),copy=r.slice();assert.deepEqual(b,saved);b.fill(255);assert.deepEqual(r,copy);
  for(const at of [0,1,2,3,4,8,12,44,48,63,64,68,104,120,127]){const bad=packet(0,[31]);bad[at]=255;assert.throws(()=>children(bad),/invalid/);}
  const span=packet(4,[31],1);wire(span).setUint32(128,1,true);wire(span).setUint32(132,1,true);span[136]=1;assert.throws(()=>children(span),/invalid/);
  assert.throws(()=>admission(new Uint8Array(31)),/invalid/);assert.throws(()=>retained(new Uint8Array(31)),/invalid/);
});
test("modal and anchor proposals preserve untouched signaling NaNs and negative zero as raw words",()=>{
  for(const mode of [1,2])for(const raw of [0x80000000,1,0x7f800000,0x7fc12345,0x7f812345,0xff812345]){
    const b=packet(mode,[mode===1?19:23]),w=wire(b);if(mode===2)w.setUint32(68,1,true);
    for(const at of [16,20,24,28])w.setUint32(at,raw,true);
    const r=children(b);assert.deepEqual(r.slice(48,64),b.slice(16,32));
  }
});
test("split slides mutate only selected frames and translate the second subtree without changing wraps",()=>{
  const b=packet(5,[57,2,26,58,2,26,31]),w=wire(b);
  for(let i=0;i<7;i++){
    const at=64+i*64;w.setBigUint64(at+40,i===0?0n:i===2||i===5?2n:1n,true);
    w.setBigUint64(at+48,i===0?0xffffffffffffffffn:i===2?1n:i===5?4n:0n,true);
    for(const [offset,v]of [[8,3.25],[12,5.125],[16,i===3?9:95.5],[20,100]])w.setFloat32(at+offset!,v!,true);
  }
  w.setFloat32(64+3*64+8,98.75,true);w.setFloat32(64+4*64+8,107.75,true);w.setFloat32(64+5*64+8,110,true);
  assert.equal(word(children(b),4),2);w.setUint32(12,1,true);w.setFloat32(40,0.25,true);
  const r=children(b),rows=records(r);assert.deepEqual(rows.map(row=>row.source),[0,1,3,4,5]);
  assert.equal(rows[1]!.frame[2],47.75);assert.equal(rows[3]!.frame[0],60);assert.equal(rows[4]!.frame[0],62.25);
  assert.equal(rows[4]!.frame[2],95.5);
  const raw=0x7f812345;w.setUint32(64+5*64+12,raw,true);w.setUint32(64+5*64+16,0x80000000,true);
  const preserve=children(b);assert.equal(word(preserve,32+4*32+20),raw);assert.equal(word(preserve,32+4*32+24),0x80000000);
  w.setUint32(64+3*64,26,true);assert.equal(word(children(b),8),0);
});
