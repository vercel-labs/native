import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/scalar_text.ts", import.meta.url), "utf8");
const { nscvScalarText: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvScalarText};").toString("base64")}`);
function packet(mode: number, text = new Uint8Array(), font = 1, available = false): Uint8Array {
  const facts = mode === 1 || mode === 2, p = new Uint8Array(64 + (facts ? text.length * 9 : 0)), w = new DataView(p.buffer);
  p.set([60,1,mode,0]); w.setUint32(4, Number(available),true); w.setUint32(8,text.length,true); w.setUint32(12,facts ? text.length : 0,true);
  w.setUint32(16,font,true); w.setFloat32(24,13.25,true); w.setFloat32(28,0.6,true); if(facts)p.set(text,64+text.length*8); return p;
}
function checked(p: Uint8Array): Uint8Array { const before=p.slice(),out=plan(p);assert.deepEqual(p,before);assert.equal(out.length,p.length);return out; }
test("scalar width empty and declined results preserve negative zero and request fallback",()=>{
  assert.equal(checked(packet(0))[3],2);
  const p=packet(0,new Uint8Array([65]),1,true),first=checked(p),w=new DataView(first.buffer); assert.equal(first[3],1);assert.equal(w.getUint32(56,true),2);
  for(const value of [0,-0,0.1,Infinity,-Infinity,-1,NaN]){ const q=first.slice(),v=new DataView(q.buffer);v.setFloat32(32,value,true);const out=checked(q),r=new DataView(out.buffer);assert.equal(out[3],2);assert.equal(r.getUint32(56,true),Number(!(value>=0&&Number.isFinite(value))));assert.equal(r.getFloat32(32,true),Math.fround(value)); }
  assert.equal(new DataView(checked(packet(0,new Uint8Array([65]))).buffer).getUint32(56,true),1);
});
test("scalar font facts are copied and covered advances override fallback classes",()=>{
  const text=new TextEncoder().encode("→界🙂"),first=checked(packet(1,text)),w=new DataView(first.buffer);assert.equal(w.getUint32(36,true),3);assert.deepEqual([0,1,2].map(i=>w.getUint32(64+i*8,true)),[0x2192,0x754c,0x1f642]);
  w.setFloat32(68,0.72,true);const out=checked(first),r=new DataView(out.buffer);let expected=0;for(const em of [Math.fround(0.72),1,1])expected=Math.fround(expected+Math.fround(Math.fround(13.25)*em));assert.equal(r.getFloat32(32,true),expected);
  first.fill(255);assert.deepEqual(out.subarray(64+text.length*8),text);
});
test("scalar UTF8 rejects controls overlong surrogates invalid continuations and truncated clusters",()=>{
  for(const text of [new Uint8Array([0]),new Uint8Array([127]),new Uint8Array([255]),new Uint8Array([0xc0,0x80]),new Uint8Array([0xed,0xa0,0x80]),new Uint8Array([0xf4,0x90,0x80,0x80]),new Uint8Array([0xe2,0x80]),new Uint8Array([0xc2,65])]){ const out=checked(packet(2,text)),w=new DataView(out.buffer);assert.equal(w.getUint32(36,true),1);assert.equal(w.getUint32(64,true),0xffffffff);assert.equal(w.getFloat32(68,true),Math.fround(0.6)); }
});
test("scalar mono accumulation preserves byte cluster order rather than multiplying counts",()=>{
  const text=new Uint8Array(10001).fill(105),out=checked(packet(1,text,2));assert.equal(out[3],2);let width=0;for(const _ of text)width=Math.fround(width+Math.fround(13.25*Math.fround(0.6)));assert.equal(new DataView(out.buffer).getFloat32(32,true),width);
  assert.equal(new DataView(out.buffer).getUint32(36,true),0);assert.ok(out.subarray(64,64+text.length*8).every(byte=>byte===0));
  const p=packet(1,new Uint8Array([105]),2);new DataView(p.buffer).setUint32(20,1,true);assert.equal(checked(p)[3],1);
});
test("scalar ink admission rejects absent empty declined inverted and nonfinite bounds",()=>{
  assert.equal(new DataView(checked(packet(3,new Uint8Array([65]))).buffer).getUint32(56,true),0);assert.equal(checked(packet(3,undefined,1,true))[3],2);
  const first=checked(packet(3,new Uint8Array([65]),1,true));for(const values of [[-1,12,-8,3],[12,-1,-8,3],[-1,12,3,-8],[NaN,12,-8,3],[-1,Infinity,-8,3],[-1,12,-Infinity,3],[-1,12,-8,NaN]])for(const accept of [0,1]){const q=first.slice(),w=new DataView(q.buffer);w.setUint32(32,accept,true);values.forEach((v,i)=>w.setFloat32(40+i*4,v,true));const r=new DataView(checked(q).buffer);assert.equal(r.getUint32(56,true),Number(accept===1&&values.every(Number.isFinite)&&values[1]!>=values[0]!&&values[3]!>=values[2]!));}
});
test("scalar copied ABI rejects malformed lengths padding initial facts and continuation actions",()=>{
  const p=packet(1,new Uint8Array([65,66]));for(const size of [0,63,p.length-1])assert.throws(()=>checked(p.subarray(0,size)));
  for(const at of [0,1,2,3,4,8,12,32,36,40,44,48,52,56,60,64]){const q=p.slice();q[at]=255;assert.throws(()=>checked(q));}
  const first=checked(p);for(const at of [36,56,60]){const q=first.slice();new DataView(q.buffer).setUint32(at,0xffffffff,true);assert.throws(()=>checked(q));}
  const sub=new Uint8Array(p.length+7);sub.set(p,7);assert.deepEqual(checked(sub.subarray(7)),checked(p));
});
