import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";
type Fact={key:number,size?:number,last?:bigint,bucket?:number};
function request(current:Fact[],previous:Fact[],capacity=100,actions=100,frame=10n,retention=2n,glyph=false){
 const r=new Uint8Array(48+(current.length+previous.length)*80),w=new DataView(r.buffer);r[0]=11;r[1]=glyph?1:0;
 [current.length,previous.length,capacity,actions].forEach((v,i)=>w.setUint32(4+i*4,v,true));w.setBigUint64(24,frame,true);w.setBigUint64(32,retention,true);
 [...current,...previous].forEach((v,i)=>{const a=48+i*80;w.setFloat32(a,v.size??12,true);w.setUint32(a+(glyph?4:24),v.key,true);w.setBigUint64(a+64,v.last??0n,true);w.setUint32(a+72,v.bucket??v.key,true);});return r;
}
function decode(r:Uint8Array){const w=new DataView(r.buffer),n=w.getUint32(0,true),m=w.getUint32(4,true);return {failed:w.getUint32(8,true),entries:Array.from({length:n},(_,i)=>w.getUint32(16+i*4,true)),actions:Array.from({length:m},(_,i)=>Array.from({length:3},(_,j)=>w.getUint32(16+n*4+i*12+j*4,true)))};}
for(const glyph of [false,true]){
 test(`${glyph?"glyph":"layout"} cache preserves first matches duplicates and retained order`,()=>{
  const out=decode(native_window_policy(request([{key:2},{key:2},{key:3}],[{key:2,last:1n},{key:2,last:1n},{key:4,last:9n},{key:4,last:9n},{key:5,last:1n}],100,100,10n,2n,glyph)));
  assert.deepEqual(out,{failed:0,entries:[0,2,5],actions:[[1,0,0],[0,2,4294967295],[1,5,2],[2,7,4]]});
 });
 test(`${glyph?"glyph":"layout"} cache capacity errors preserve partial writes`,()=>{
  const c=[{key:1},{key:2}];assert.deepEqual(decode(native_window_policy(request(c,[],1,8,10n,2n,glyph))),{failed:1,entries:[0],actions:[[0,0,4294967295]]});
  assert.deepEqual(decode(native_window_policy(request(c,[],8,1,10n,2n,glyph))),{failed:1,entries:[0,1],actions:[[0,0,4294967295]]});
  const old=[{key:3,last:10n},{key:4,last:10n}];assert.deepEqual(decode(native_window_policy(request([],old,1,8,10n,2n,glyph))),{failed:0,entries:[0],actions:[[1,0,0],[2,1,1]]});
 });
 test(`${glyph?"glyph":"layout"} cache retention uses exact uint64 boundaries`,()=>{
  for(const frame of [0n,9007199254740993n,18446744073709551615n])for(const retention of [0n,1n,99n,18446744073709551615n])for(const last of [0n,frame,frame>0n?frame-1n:0n,frame>99n?frame-99n:0n]){
   const warm=retention>0n&&(frame<=last||frame-last<=retention);const out=decode(native_window_policy(request([],[{key:1,last}],1,1,frame,retention,glyph)));assert.equal(out.actions[0]![0],warm?1:2);assert.equal(out.entries.length,warm?1:0);
  }
 });
 test(`${glyph?"glyph":"layout"} cache handles signed zero NaN and hash collisions`,()=>{
  const current=Array.from({length:70},(_,i)=>({key:i%35,size:i%3===0?-0:0,bucket:7})),previous=Array.from({length:35},(_,key)=>({key,size:0,bucket:7,last:10n}));
  const out=decode(native_window_policy(request(current,previous,100,100,10n,2n,glyph)));assert.equal(out.entries.length,35);assert.ok(out.actions.every(v=>v[0]===1));assert.deepEqual(out.actions.map(v=>v[2]),Array.from({length:35},(_,i)=>i));
  const nan=decode(native_window_policy(request([{key:1,size:NaN},{key:1,size:NaN}],[{key:1,size:NaN,last:10n}],10,10,10n,2n,glyph)));assert.deepEqual(nan.entries,[0,1,2]);assert.deepEqual(nan.actions.map(v=>v[0]),[0,0,1]);
 });
 test(`${glyph?"glyph":"layout"} cache copied result survives later calls and oversized linear inputs`,()=>{
  const count=glyph?16385:4097,c=Array.from({length:count},(_,key)=>({key})),out=native_window_policy(request(c,[],count,count,10n,2n,glyph)),saved=out.slice();assert.equal(decode(out).entries.length,count);native_window_policy(request([],[]));assert.deepEqual(out,saved);
 });
}
test("cache wire rejects truncated extended reserved and invalid discriminator requests",()=>{
 const q=request([{key:1}],[]);for(let n=1;n<q.length;n++)assert.throws(()=>native_window_policy(q.subarray(0,n)));
 assert.throws(()=>native_window_policy(new Uint8Array([...q,0])));for(const at of [1,2,3,20,40,44]){const bad=q.slice();bad[at]=3;assert.throws(()=>native_window_policy(bad));}
});
