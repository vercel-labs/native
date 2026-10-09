import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["scalar_text.ts", "registered_font.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { nscvRegisteredFont: plan, nscvRegisteredMin: min, nscvRegisteredMax: max } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvRegisteredFont,nscvRegisteredMin,nscvRegisteredMax};").toString("base64")}`);
function packet(mode: number, bytes: Uint8Array, registered = true): Uint8Array {
  const out = new Uint8Array(128), w = new DataView(out.buffer); out.set([62,1,mode,0,Number(registered)]);
  w.setUint32(8,bytes.length,true); w.setUint32(12,64,true); w.setUint32(16,0xf1234567,true);
  w.setFloat32(20,13.25,true); w.setFloat32(24,1000,true); w.setFloat32(28,600,true); return out;
}
function checked(p: Uint8Array): Uint8Array { const saved=p.slice(),out=plan(p); assert.deepEqual(p,saved);assert.equal(out.length,128);return out; }
function run(mode: number, bytes: Uint8Array, failure = false, bounds = (glyph: number): number[] => [-30,-200,600,900]): { out: Uint8Array; actions: number[]; advances: number[] } {
  let p=packet(mode,bytes); const actions: number[]=[],advances=new Array(bytes.length).fill(999);
  for(let steps=0;steps<bytes.length*5+2;steps++) {
    p=checked(p);const w=new DataView(p.buffer),action=w.getUint32(72,true);actions.push(action);
    const first=w.getUint32(112,true),last=w.getUint32(116,true);
    if(last>first){advances[first]=w.getFloat32(120,true);for(let i=first+1;i<last;i++)advances[i]=0;}
    if(action===0)return {out:p,actions,advances};
    if(action===1){const at=w.getUint32(32,true),length=Math.min(4,bytes.length-at);w.setUint32(104,length,true);p.fill(0,108,112);p.set(bytes.subarray(at,at+length),108);}
    if(action===2||action===3){const cp=w.getUint32(40,true);w.setUint32(44,cp<127?cp:0,true);w.setFloat32(48,600,true);}
    if(action===4){w.setUint32(52,failure?2:1,true);bounds(w.getUint32(44,true)).forEach((x,i)=>w.setFloat32(56+i*4,x,true));}
  }
  throw new Error("continuation did not terminate");
}
test("registered font owns complete width accumulation and per-byte advance placements",()=>{
  const bytes=new Uint8Array([...new TextEncoder().encode("Aé界🙂"),255]),result=run(1,bytes),w=new DataView(result.out.buffer);
  const ems=[Math.fround(0.6),Math.fround(0.6),1,1,Math.fround(0.6)];let expected=0;
  for(const em of ems)expected=Math.fround(expected+Math.fround(Math.fround(13.25)*em));
  assert.equal(w.getFloat32(80,true),expected);assert.deepEqual(result.advances,[Math.fround(13.25*ems[0]!),Math.fround(13.25*ems[1]!),0,13.25,0,0,13.25,0,0,0,Math.fround(13.25*ems[4]!)]);
  assert.equal(w.getUint32(124,true),1);assert.equal(result.out[3],2);
});
test("registered font preserves ordered lookups whitespace exclusion and first outline failure",()=>{
  const bytes=new TextEncoder().encode(" AB"),out=run(2,bytes,true);
  assert.deepEqual(out.actions,[1,2,1,2,3,4,0]);assert.equal(new DataView(out.out.buffer).getUint32(124,true),0);
  const all=run(2,bytes);assert.deepEqual(all.actions,[1,2,1,2,3,4,1,2,3,4,0]);
  const w=new DataView(all.out.buffer);assert.equal(w.getUint32(84,true),1);assert.ok(w.getFloat32(92,true)>w.getFloat32(88,true));
});
test("registered font keeps full identity words and avoids reserved mono shortcuts",()=>{
  const bytes=new TextEncoder().encode("A"),p=packet(0,bytes),w=new DataView(p.buffer);w.setUint32(12,2,true);
  let first=checked(p);const v=new DataView(first.buffer);v.setUint32(104,1,true);first[108]=65;
  assert.equal(new DataView(checked(first).buffer).getUint32(72,true),2);
  const low=packet(0,bytes,false),q=new DataView(low.buffer);q.setUint32(12,2,true);q.setUint32(16,0,true);first=checked(low);new DataView(first.buffer).setUint32(104,1,true);first[108]=65;
  const out=checked(first);assert.equal(new DataView(out.buffer).getUint32(72,true),0);assert.equal(new DataView(out.buffer).getFloat32(80,true),Math.fround(13.25*Math.fround(0.6)));
});
test("registered font handles empty results and unavailable ink without capabilities",()=>{
  for(const mode of [0,1,2]){const p=checked(packet(mode,new Uint8Array()));assert.equal(p[3],2);assert.equal(new DataView(p.buffer).getUint32(124,true),1);}
  const absent=checked(packet(2,new Uint8Array([65]),false));assert.equal(absent[3],2);assert.equal(new DataView(absent.buffer).getUint32(124,true),0);
});
test("registered font ink extrema preserve later equal values and minNum maxNum admission",()=>{
  for(const choose of [min,max])for(const a of [0,-0])for(const b of [0,-0])assert.ok(Object.is(choose(a,b),b));
  for(const choose of [min,max]){assert.equal(choose(NaN,1),1);assert.equal(choose(1,NaN),1);assert.ok(Number.isNaN(choose(NaN,NaN)));}
});
test("registered font malformed input follows byte traversal without invalid glyph reads",()=>{
  for(const bytes of [new Uint8Array([0xc0,0x80]),new Uint8Array([0xed,0xa0,0x80]),new Uint8Array([0xf4,0x90,0x80,0x80]),new Uint8Array([0xe2,0x80]),new Uint8Array([0xc2,65])]){
    const out=run(1,bytes);assert.deepEqual(out.actions,[1,0]);assert.equal(out.advances[0],Math.fround(13.25*Math.fround(0.6)));assert.ok(out.advances.slice(1).every(x=>x===0));
  }
});
test("registered font rejects malformed copied headers initial state and text replies",()=>{
  const p=packet(0,new Uint8Array([65]));for(const at of [0,1,2,3,4,5,32,36,72,84,104,124]){const bad=p.slice();bad[at]=255;assert.throws(()=>checked(bad));}
  for(const size of [0,127,129])assert.throws(()=>checked(new Uint8Array(size)));
  const first=checked(p);assert.throws(()=>checked(first));const sub=new Uint8Array(135);sub.set(p,7);assert.deepEqual(checked(sub.subarray(7)),first);
});
