import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "control_appearance", "control_payloads"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvControlPayloads: payload } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvControlPayloads};").toString("base64")}`);
function color(family: number, role: number): Uint8Array {
  const b = new Uint8Array(560), w = new DataView(b.buffer); b.set([46,0,family,role]); b.set([16,2,0,31,0,0,0,0],8);
  for (let i=0;i<8;i++) for (let j=0;j<4;j++) w.setFloat32(280+i*16+j*4,j===3?1:(i+1)/16,true);
  for (let i=0;i<3;i++) for (let j=0;j<4;j++) w.setFloat32(504+i*16+j*4,j===3?1:(i+10)/16,true);
  w.setFloat32(408,0.5,true);return b;
}
function read(b: Uint8Array): number[] { const w=new DataView(b.buffer,b.byteOffset,b.byteLength);return Array.from({length:b.length/4},(_,i)=>w.getFloat32(i*4,true)); }
test("control payloads preserve raw optional color words and own returned bytes",()=>{
  const b=color(16,0),w=new DataView(b.buffer);w.setUint32(172,1,true);
  for(const [i,word] of [0x7fc12345,0x80000000,0x7f800000,0x3f800000].entries())w.setUint32(176+i*4,word,true);
  const saved=b.slice(),out=payload(b),expected=b.slice(176,192);assert.deepEqual(out,expected);assert.deepEqual(b,saved);b.fill(255);assert.deepEqual(out,expected);
});
test("menu admission observes attention separately from authored fill",()=>{
  const b=color(7,7),w=new DataView(b.buffer);w.setUint32(172,1,true);for(let i=0;i<4;i++)w.setFloat32(176+i*4,1,true);
  assert.deepEqual(read(payload(b)),[0,0,0,0]);b[3]=0;assert.deepEqual(read(payload(b)),[1,1,1,1]);b[3]=7;b[4]=2;assert.equal(read(payload(b))[3],1);
});
test("slider disabled replacement keeps independent track and thumb channels",()=>{
  const b=color(15,0),w=new DataView(b.buffer);b[14]=1;assert.equal(read(payload(b))[3],0.5);
  w.setUint32(16,1<<4,true);for(let i=0;i<4;i++)w.setFloat32(84+i*4,0.75,true);
  assert.equal(read(payload(b))[3],1);b[3]=5;assert.deepEqual(read(payload(b)),[0.75,0.75,0.75,0.75]);b[3]=6;assert.deepEqual(read(payload(b)),[1,1,1,1]);
});
test("numeric selection and disabled underline previews preserve distinct ink rules",()=>{
  const b=color(11,2),w=new DataView(b.buffer);b[4]=1|4;b[14]=1;assert.equal(read(payload(b))[3],0.5);
  w.setFloat32(552,0.5,true);assert.equal(read(payload(b))[3],1);w.setFloat32(552,NaN,true);assert.equal(read(payload(b))[3],0.5);
});
test("geometry reserves menu marks and copies raw frame words",()=>{
  const b=new Uint8Array(128),w=new DataView(b.buffer);b.set([46,1,4,0]);for(const [at,value] of [[16,10],[20,-0],[24,100],[28,32],[48,12],[52,8],[56,4]])w.setFloat32(at!,value!,true);
  const saved=b.slice(),out=payload(b);assert.deepEqual(b,saved);assert.deepEqual(read(out).slice(2,14),[10,-0,84,32,18,10,12,12,90,10,12,12]);assert.ok(out.slice(56).every(v=>v===0));b.fill(255);assert.deepEqual(read(out).slice(2,6),[10,-0,84,32]);
  const raw=new Uint8Array(128),r=new DataView(raw.buffer);raw.set([46,1,4,0]);r.setUint32(48,0x7f812345,true);
  const copied=new DataView(payload(raw).buffer);for(const at of [32,36,48,52])assert.equal(copied.getUint32(at,true),0x7f812345);
});
test("payload packets reject malformed versions lengths flags and reserved fields",()=>{
  for(const at of [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,556]) {const b=color(16,0);b[at]=255;assert.throws(()=>payload(b),/invalid/);}
  assert.throws(()=>payload(new Uint8Array(559)),/invalid/);
  const g=new Uint8Array(128);g.set([46,1,0,0]);for(const at of [2,3,4,15,64,127]){const b=g.slice();b[at]=255;assert.throws(()=>payload(b),/invalid/);}
});
