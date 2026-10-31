import assert from "node:assert/strict";
import test from "node:test";
import { native_effect_policy } from "../src/runtime_policy.ts";
const words=[0n,1n,4096n,4294967295n,4294967296n,9007199254740993n,18446744073709551615n];
function input(mode:number,flags=0,w:bigint[]=[],a=new Uint8Array(),b=new Uint8Array()):Uint8Array {
 const r=new Uint8Array(64+a.length+b.length);r.set([28,1,mode,flags]);const d=new DataView(r.buffer);w.forEach((v,i)=>d.setBigUint64(8+i*8,v,true));d.setUint32(56,a.length,true);d.setUint32(60,b.length,true);r.set(a,64);r.set(b,64+a.length);return r;
}
function plan(mode:number,flags=0,w:bigint[]=[],a=new Uint8Array(),b=new Uint8Array()):Uint8Array {
 const r=input(mode,flags,w,a,b),before=r.slice(),out=native_effect_policy(r);assert.deepEqual(r,before);assert.deepEqual(out.slice(1,4),new Uint8Array(3));assert.equal(out.length,32+new DataView(out.buffer).getUint32(4,true));return out;
}
function value(r:Uint8Array,i:number):bigint{return new DataView(r.buffer).getBigUint64(8+i*8,true);}
test("blob admission preserves exact budgets and memory capacity refusal precedence",()=>{
 for(const a of words)for(const b of words){assert.equal(plan(0,0,[a,b])[0],a===0n||a>b?5:0);assert.equal(plan(1,0,[a,b])[0],a>b?1:0);for(let flags=0;flags<4;flags++){
 const r=plan(6,flags,[a,b,32n,32n,7n]);assert.equal(r[0],a>b?1:flags&1?flags&2?9:10:2);if(r[0]===9)assert.equal(value(r,1),8n);
 assert.equal(plan(7,flags&1,[a,b])[0],!(flags&1)?3:a>b?1:0);
 }}
 assert.equal(plan(6,0,[0n,1n,31n,32n])[0],11);assert.equal(value(plan(6,0,[0n,1n,31n,32n]),0),32n);
});
test("blob probes compare complete bounded chunks and preserve short-read termination",()=>{
 const a=new Uint8Array(4096).fill(90);for(const len of [0,1,4095,4096])for(const mismatch of [false,true]){
 const chunk=a.slice(0,len),other=chunk.slice();if(mismatch&&len)other[len-1]^=1;
 const r=plan(3,1,[BigInt(len),0n,BigInt(len),4096n],chunk,other);assert.equal(r[0],mismatch&&len?7:len===4096?8:6);if(len)assert.equal(value(r,0),BigInt(len));
 assert.equal(plan(3,1,[BigInt(len+1),0n,BigInt(len),4096n],chunk,other)[0],len===4096&&!mismatch?8:7);
 }
 assert.equal(plan(3,0)[0],7);assert.equal(plan(3,1,[0n,0n,1n,4096n],a.slice(0,1),new Uint8Array())[0],7);
 for(const start of words.filter(n=>n<18446744073709547519n)){const r=plan(3,1,[start+4096n,start,4096n,4096n],a,a);assert.equal(r[0],8);assert.equal(value(r,0),start+4096n);}
});
test("blob equality and address search preserve byte identity and first-match positions",()=>{
 for(const len of [0,1,4095,4096]){
 const a=new Uint8Array(len).fill(13),b=a.slice();assert.equal(plan(4,1,[BigInt(len),BigInt(len)])[0],len?8:6);assert.equal(plan(4,0,[0n,BigInt(len)],a,b)[0],6);if(len){b[len-1]=14;assert.equal(plan(4,0,[0n,BigInt(len)],a,b)[0],7);}
 }
 const hash=Uint8Array.from({length:16},(_,i)=>i);for(const index of words.filter(n=>n<18446744073709551615n)){const r=plan(5,0,[index,index+1n],hash,hash);assert.equal(r[0],13);assert.equal(value(r,0),index);}
});
test("blob read keeps exact-fit spare-byte and hash refusal order",()=>{
 for(const len of words)for(const capacity of words){assert.equal(plan(8,0,[len,capacity])[0],2);assert.equal(plan(8,1,[len,capacity])[0],len===capacity?12:0);assert.equal(plan(8,3,[len,capacity,0n])[0],0);assert.equal(plan(8,3,[len,capacity,1n])[0],1);}
 const hash=new Uint8Array(16);assert.equal(plan(9,0,[],hash,hash)[0],0);const bad=hash.slice();bad[15]=1;assert.equal(plan(9,0,[],hash,bad)[0],4);assert.equal(plan(10,1)[0],0);assert.equal(plan(10,0)[0],2);
});
test("blob names and writer-unique paths retain all token bits and capacity failures",()=>{
 const hash=Uint8Array.from({length:16},(_,i)=>i*17),encode=new TextEncoder(),decode=new TextDecoder();assert.equal(decode.decode(plan(12,0,[],hash).slice(32)),"00112233445566778899aabbccddeeff");
 for(const token of words)for(const dir of ["", ".", "a".repeat(1024)]){
 const text=dir+"/address."+token.toString(16).padStart(16,"0")+".partial";
 assert.equal(decode.decode(plan(11,1,[token,1104n],encode.encode(dir),encode.encode("address")).slice(32)),text);
 assert.equal(plan(11,1,[token,BigInt(text.length-1)],encode.encode(dir),encode.encode("address"))[0],2);
 }
});
test("blob transport refuses malformed headers extents flags and address lengths",()=>{
 for(const mode of [0,13,255]){const r=input(mode);r[1]=2;assert.throws(()=>native_effect_policy(r));}
 for(const byte of [0,1,2,3,4,7]){const r=input(1);r[byte]=255;assert.throws(()=>native_effect_policy(r));}
 for(const len of [0,1,63,65,8257])assert.throws(()=>native_effect_policy(new Uint8Array(len).fill(28)));
 assert.throws(()=>plan(9));assert.throws(()=>plan(5,0,[0n,0n],new Uint8Array(16),new Uint8Array(16)));
 assert.throws(()=>plan(3,1,[1n,0n,1n,4096n],new Uint8Array(),new Uint8Array()));
});
