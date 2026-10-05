import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";
const run=(r:Uint8Array)=>native_window_policy(r);
function fixed(op:number,len:number){const b=new Uint8Array(len);b[0]=10;b[1]=op;return b;}
function shape(oldId:bigint,id:bigint,oldCount:bigint,count:bigint,oldBase:bigint,base:bigint,gap=1,oldTotal=90){const b=fixed(0,72),w=new DataView(b.buffer);[oldId,id,oldCount,count,oldBase,base].forEach((n,i)=>w.setBigUint64(8+i*8,n,true));w.setFloat32(56,gap,true);w.setFloat32(60,oldTotal,true);return b;}
function correction(mode:number,measured:readonly {index:bigint;delta:number;prefix:number}[]=[],rows:readonly {physical:bigint;estimate:number;extent:number}[]=[],base=9007199254740993n,count=6000n,anchor=2000n){
 const b=fixed(1,64+measured.length*16+rows.length*16),w=new DataView(b.buffer);b[3]=mode;w.setUint32(4,measured.length,true);w.setUint32(8,rows.length,true);w.setBigUint64(16,base,true);w.setBigUint64(24,count,true);w.setBigUint64(32,anchor,true);w.setFloat32(48,measured.reduce((sum,row)=>Math.fround(sum+row.delta),0),true);w.setFloat32(52,10,true);w.setFloat32(56,5,true);
 measured.forEach((row,i)=>{const at=64+i*16;w.setBigUint64(at,row.index,true);w.setFloat32(at+8,row.delta,true);w.setFloat32(at+12,row.prefix,true);});
 rows.forEach((row,i)=>{const at=64+measured.length*16+i*16;w.setBigUint64(at,row.physical,true);w.setFloat32(at+8,row.estimate,true);w.setFloat32(at+12,row.extent,true);});return b;
}
function decode(b:Uint8Array){const w=new DataView(b.buffer,b.byteOffset,b.byteLength);return {anchor:w.getBigUint64(0,true),before:w.getFloat32(8,true),pending:w.getFloat32(12,true),total:w.getFloat32(16,true),dirty:w.getUint32(20,true),rows:Array.from({length:w.getUint32(24,true)},(_,i)=>({index:w.getBigUint64(32+i*16,true),delta:w.getFloat32(40+i*16,true),prefix:w.getFloat32(44+i*16,true)}))};}
test("extent sync classifies every shape with exact uint64 identities and chunk ordinals",()=>{
 const id=9007199254740993n,base=0xffffffffffff0000n;
 const cases=[[0n,id,0n,65n,0n,base,1],[id,id,65n,65n,base,base,0],[id,id,65n,99n,base,base,4],[id,id,65n,1n,base,base,5],[id,id,65n,99n,base,base-3n,2],[id,id,65n,99n,base,base+3n,3],[id,id+1n,65n,99n,base,base,1]] as const;
 for(const [old,id,count,next,from,to,mode]of cases){const r=run(shape(old,id,count,next,from,to));assert.equal(r[0],mode);assert.equal(new DataView(r.buffer).getBigUint64(16,true),mode===4?count/64n:mode===5?next/64n:0n);}
 const b=shape(id,id,0xffffffffffffffffn,0xfffffffffffffffen,base,base,NaN);const r=run(b),w=new DataView(r.buffer);assert.equal(w.getBigUint64(16,true),0xfffffffffffffffen/64n);assert.equal(w.getFloat32(4,true),0);
});
test("extent corrections apply ordered epsilon patches and complete exclusive prefixes atomically",()=>{
 const b=correction(3,[],[{physical:3n,estimate:10,extent:12},{physical:0n,estimate:10,extent:10.25},{physical:2n,estimate:10,extent:13},{physical:2n,estimate:10,extent:13.25},{physical:6000n,estimate:0,extent:99}]);const r=decode(run(b));
 assert.deepEqual(r.rows,[{index:9007199254740995n,delta:3,prefix:0},{index:9007199254740996n,delta:2,prefix:3}]);assert.equal(r.total,5);assert.equal(r.before,15);assert.equal(r.pending,5);assert.equal(r.dirty,0);
 const begin=correction(0);begin[2]=1;new DataView(begin.buffer).setFloat32(40,-7.125,true);assert.equal(decode(run(begin)).before,-7.125);
});
test("extent eviction keeps closest endpoints with stable tie and incoming drop rules",()=>{
 const base=9007199254740993n,measured=Array.from({length:2048},(_,i)=>({index:base+BigInt(i),delta:1,prefix:i}));
 const dropped=decode(run(correction(3,measured,[{physical:2048n,estimate:1,extent:20}],base,6000n,1024n)));assert.equal(dropped.rows.length,2048);assert.equal(dropped.rows[0]!.index,base);
 const admitted=decode(run(correction(3,measured,[{physical:2050n,estimate:1,extent:20}],base,6000n,2047n)));assert.equal(admitted.rows[0]!.index,base+1n);assert.equal(admitted.rows.at(-1)!.index,base+2050n);
});
test("extent window pins initial and retained bottom while preserving scrolled-away offsets",()=>{
 for(const [flags,offset,expected]of [[5,10,200],[7,99,200],[7,98.9,105.9],[6,99,106]] as const){const b=fixed(2,32),w=new DataView(b.buffer);b[3]=flags;[offset,7,300,100,200,100].forEach((v,i)=>w.setFloat32(4+i*4,v,true));assert.equal(new DataView(run(b).buffer).getFloat32(0,true),Math.fround(expected));}
});
test("extent protocol rejects truncation padding flags invalid ordering and dirty queries",()=>{
 const examples=[shape(0n,1n,0n,10n,0n,0n),correction(3),fixed(2,32),fixed(3,32),fixed(4,48),fixed(5,32),fixed(6,24),fixed(7,64),fixed(8,16)];
 for(const b of examples){for(let n=1;n<b.length;n++)assert.throws(()=>run(b.subarray(0,n)),/extent/);assert.throws(()=>run(new Uint8Array([...b,0])),/extent/);const bad=b.slice();bad[2]=2;assert.throws(()=>run(bad),/extent/);}
 const dirty=correction(0);new DataView(dirty.buffer).setUint32(12,1,true);assert.throws(()=>run(dirty),/dirty/);
 const unordered=correction(3,[{index:2n,delta:1,prefix:0},{index:1n,delta:2,prefix:1}],[],0n);assert.throws(()=>run(unordered),/ordering/);
});
test("extent output owns bytes across offset views repeated policies and later mutation",()=>{
 const b=correction(3,[],[{physical:1n,estimate:1,extent:10}]);const padded=new Uint8Array(b.length+10);padded.set(b,7);const out=run(padded.subarray(7,7+b.length)),saved=out.slice();padded.fill(0);for(let i=0;i<12;i++)run(correction(3));assert.deepEqual(out,saved);
});
function estimates(op:number,values:readonly number[],prefix=0,total=0,extra=0,covered=0){const b=fixed(op,32+values.length*4),w=new DataView(b.buffer);w.setUint32(4,values.length,true);[prefix,total,extra,covered].forEach((v,i)=>w.setFloat32(8+i*4,v,true));values.forEach((v,i)=>w.setFloat32(32+i*4,v,true));return b;}
const float=(b:Uint8Array,at=0)=>new DataView(b.buffer,b.byteOffset,b.byteLength).getFloat32(at,true);
test("estimate batches preserve chunk grouping and partial-prefix rounding",()=>{
 const values=Array.from({length:1024},(_,i)=>Math.fround(i%5===0?16777216:i%3===0?0.125:1));let prefix=123.125;
 const result=run(estimates(9,values,prefix));for(let c=0;c<16;c++){let sum=0;for(const value of values.slice(c*64,c*64+64))sum=Math.fround(sum+value);prefix=Math.fround(prefix+sum);assert.equal(float(result,c*4),prefix);}
 assert.equal(float(run(estimates(10,[1,1],16777216))),16777216);
 assert.equal(float(run(estimates(10,[],262144,262144,17,262144))),262161);
 assert.equal(run(estimates(9,[],0)).length,0);
 assert.throws(()=>run(estimates(9,new Array(1025).fill(1))),/batch/);
 assert.throws(()=>run(estimates(10,new Array(64).fill(1))),/batch/);
 const bad=estimates(10,[]);new DataView(bad.buffer).setUint32(28,1,true);assert.throws(()=>run(bad),/batch/);
});
function search(count:bigint,low=0n,high=0n,flags=1,target=10,probe=0){const b=fixed(12,40),w=new DataView(b.buffer);b[3]=flags;[count,low,high].forEach((v,i)=>w.setBigUint64(8+i*8,v,true));w.setFloat32(32,target,true);w.setFloat32(36,probe,true);return b;}
test("query continuation owns exact uint64 midpoints ties zero and overflow modes",()=>{
 const count=9007199254740997n;let out=run(search(count)),w=new DataView(out.buffer);assert.equal(w.getBigUint64(16,true),(count)/2n);
 let low=w.getBigUint64(0,true),high=w.getBigUint64(8,true),steps=0;const wanted=9007199254740987n;
 while(w.getUint32(24,true)){const mid=w.getBigUint64(16,true);out=run(search(count,low,high,3,10,mid<=wanted?10:11));w=new DataView(out.buffer);low=w.getBigUint64(0,true);high=w.getBigUint64(8,true);steps++;assert.ok(steps<=54);}
 assert.equal(low,wanted);assert.equal(w.getBigUint64(16,true),wanted);
 assert.equal(new DataView(run(search(0n)).buffer).getUint32(24,true),0);
 assert.equal(new DataView(run(search(1n)).buffer).getBigUint64(0,true),0n);
 assert.throws(()=>run(search(0xffffffffffffffffn,0xfffffffffffffffdn,0xfffffffffffffffen,3)),/overflow/);
 assert.throws(()=>run(search(4n,2n,1n,3)),/bounds/);
 const wrapped=run(search(0xffffffffffffffffn,0xfffffffffffffffdn,0xfffffffffffffffen,2));assert.ok(wrapped.length===32);
 const nan=run(search(2n,0n,0n,1,NaN));assert.equal(float(nan,28),0);
});
test("extent scalar queries preserve f32 grouping and copied result ownership",()=>{
 const b=fixed(11,24),w=new DataView(b.buffer);[16777216,1,1,1].forEach((v,i)=>w.setFloat32(4+i*4,v,true));const out=run(b);assert.equal(float(out),16777216);const saved=out.slice();b.fill(0);run(search(99n));assert.deepEqual(out,saved);
 const negative=fixed(11,24);negative[3]=1;new DataView(negative.buffer).setFloat32(4,-10,true);assert.equal(float(run(negative)),0);
 for(const example of [estimates(9,[1]),estimates(10,[1]),fixed(11,24),search(2n)]){for(let n=1;n<example.length;n++)assert.throws(()=>run(example.subarray(0,n)));assert.throws(()=>run(new Uint8Array([...example,0])));}
});
