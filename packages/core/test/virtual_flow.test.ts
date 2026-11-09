import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

const f = Math.fround;
function request(count = 4, op = 0): Uint8Array {
  const bytes = new Uint8Array(128 + count * 64), d = new DataView(bytes.buffer);
  bytes.set([8, op, 2, 0]); d.setUint32(4, count, true);
  [count, count, 0, 0, 0, 10, 20, 200, 100, 2, 30, 0, 0, 0, 0, 0].forEach((v, i) => d.setFloat32(56 + i * 4, v, true));
  for (let i = 0; i < count; i++) { d.setUint32(128 + i * 64, 1, true); d.setFloat32(132 + i * 64, i, true); }
  return bytes;
}
function int(bytes: Uint8Array, at: number, n: bigint): void { new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).setBigUint64(at, n, true); }
function float(bytes: Uint8Array, at: number, n: number): void { new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).setFloat32(at, n, true); }
function decode(bytes: Uint8Array) {
  const d = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { mode: d.getUint32(4, true), count: d.getUint32(8, true), extent: d.getFloat32(12, true), total: d.getFloat32(16, true), offset: d.getFloat32(20, true), items: d.getBigUint64(40, true), content: [24,28,32,36].map(at => d.getFloat32(at, true)),
    children: Array.from({length: d.getUint32(0, true)}, (_,i) => { const at = 48 + i * 32; return { flags: d.getUint32(at, true), index: d.getUint32(at + 4, true), exact: d.getBigUint64(at + 24, true), frame: [8,12,16,20].map(n => d.getFloat32(at + n, true)) }; }) };
}
const run = (b: Uint8Array) => decode(native_window_policy(b));

test("uniform flow culls exact ranges, preserves overscan and elastic displacement", () => {
  const b = request(10); float(b, 108, 70);
  assert.deepEqual(run(b).children.filter(c => c.flags).map(c => c.exact), [2n,3n,4n,5n]);
  int(b,32,1n); assert.deepEqual(run(b).children.filter(c => c.flags).map(c => c.exact), [1n,2n,3n,4n,5n,6n]);
  float(b,108,-1000); assert.equal(run(b).offset,-100); assert.deepEqual(run(b).children[0]!.frame,[10,120,200,30]);
  float(b,108,1000); assert.equal(run(b).offset,318);
  for (const n of [NaN,Infinity,-Infinity]) { float(b,108,n); assert.equal(run(b).offset,0); }
  float(b,88,0); assert.equal(run(b).extent,0); assert.equal(run(b).children.filter(c=>c.flags).length,0);
});
test("windowed flow keeps every uint64 index and saturates semantic counts", () => {
  const b=request(3); const first=9007199254740993n, declared=first+3n;
  int(b,8,first);int(b,16,declared);int(b,32,declared);float(b,60,Number(declared));float(b,64,Number(declared));
  for (let i=0;i<3;i++) float(b,132+i*64,Number(first+BigInt(i)));
  const result=run(b);assert.equal(result.items,declared);assert.equal(result.count,0xffffffff);
  assert.deepEqual(result.children.map(c=>c.exact),[first,first+1n,first+2n]);
  assert.ok(result.children.every(c=>c.index===0xffffffff));
  assert.equal(result.children[0]!.frame[1],f(f(20+f(f(Number(first))*32))-0));
  int(b,8,40n);int(b,16,41n);float(b,60,43);float(b,64,41);assert.equal(run(b).items,43n);
});
test("hoisted children leave source order and absolute flow indices unchanged", () => {
  const b=request();new DataView(b.buffer).setUint32(192,0,true);float(b,56,3);float(b,60,3);
  float(b,260,1);float(b,324,2);
  const r=run(b);assert.equal(r.count,3);assert.deepEqual(r.children.map(c=>c.flags),[1,0,1,1]);assert.deepEqual(r.children.filter(c=>c.flags).map(c=>c.exact),[0n,1n,2n]);
});
test("variable rows stack measured heights before and after the clamped anchor", () => {
  const b=request(3);int(b,8,10n);int(b,16,100n);int(b,24,11n);float(b,60,13);float(b,64,100);float(b,112,120);float(b,116,1000);float(b,108,70);
  [40,60,80].forEach((h,i)=>float(b,168+i*64,h));
  assert.equal(run(b).mode,1);assert.deepEqual(run(b).children.map(c=>c.frame),[[10,28,200,40],[10,70,200,60],[10,132,200,80]]);
  int(b,24,0n);assert.equal(run(b).children[0]!.frame[1],70);
  int(b,24,999n);assert.equal(run(b).children[2]!.frame[1],70);
  float(b,108,-1000);assert.equal(run(b).offset,-100);
  float(b,108,2000);assert.equal(run(b).offset,1000);
});
test("content extent selects declared materialized grid and semantic count contracts", () => {
  const b=request(4,1);assert.equal(run(b).total,126);
  int(b,8,8n);int(b,16,10n);float(b,60,12);float(b,64,10);assert.equal(run(b).items,12n);assert.equal(run(b).total,382);
  float(b,116,999);float(b,88,0);assert.equal(run(b).total,999);assert.equal(run(b).mode,2);
  int(b,8,0xffffffffffffffffn);assert.equal(run(b).total,999);
  const g=request(7,1);g[3]=4;int(g,48,3n);float(g,68,3);assert.equal(run(g).total,94);
  const e=request(0,1);int(e,40,7n);float(e,72,7);assert.equal(run(e).total,222);
  float(e,96,0);assert.equal(run(e).total,0);
});
test("scroll displacement grants each axis and expands only natural horizontal widths", () => {
  const b=request(2,2);float(b,104,25);float(b,108,50);
  [5,6,100,70].forEach((v,i)=>float(b,176+i*4,v));float(b,172,240);
  [7,8,150,90].forEach((v,i)=>float(b,240+i*4,v));float(b,200,80);float(b,236,300);
  b[3]=1;assert.deepEqual(run(b).content,[-15,20,200,100]);assert.deepEqual(run(b).children[0]!.frame,[5,6,240,70]);assert.equal(run(b).children[1]!.frame[2],150);
  b[3]=2;assert.deepEqual(run(b).content,[10,-30,200,100]);assert.equal(run(b).children[0]!.frame[2],100);
  b[3]=3;assert.deepEqual(run(b).content,[-15,-30,200,100]);
  b[3]=0;assert.deepEqual(run(b).content,[10,20,200,100]);
});
test("checked integer overflow rejects while optimized lanes wrap explicitly", () => {
  const b=request(2);int(b,8,0xffffffffffffffffn);int(b,16,1n);assert.throws(()=>run(b),/overflow/);
  b[2]=0;assert.equal(run(b).items,1n);
  const o=request();int(o,32,0xffffffffffffffffn);assert.throws(()=>run(o),/overflow/);o[2]=0;assert.equal(run(o).children.filter(c=>c.flags).length,3);
});
test("flow numeric constraints retain f32 ordering and both native zero-sign capabilities", () => {
  const b=request(2);float(b,92,0.125);float(b,96,24.000002);float(b,108,1.0000001);float(b,136,101.125);float(b,144,150);float(b,148,160);float(b,152,27);float(b,156,29);
  assert.deepEqual(run(b).children[0]!.frame,[10,f(20-f(1.0000001)),150,27]);
  float(b,80,-0);float(b,108,-0);
  b[2]=2;assert.ok(Object.is(run(b).offset,-0));b[2]=3;assert.ok(Object.is(run(b).offset,-0));
  float(b,96,NaN);assert.equal(run(b).extent,0);
});
test("flow wire rejects all truncations surplus reserved flags and invalid child lanes", () => {
  const b=request();for(let n=1;n<b.length;n++) assert.throws(()=>run(b.subarray(0,n)),/virtual flow/);
  assert.throws(()=>run(new Uint8Array([...b,0])),/virtual flow/);
  for(const at of [1,2,3,120,124,128]) { const invalid=b.slice();invalid[at]=255;assert.throws(()=>run(invalid),/virtual flow/); }
});
test("large flow output owns bytes across offset views and recursive policy calls", () => {
  const b=request(256);int(b,32,256n);const padded=new Uint8Array(b.length+19);padded.set(b,7);
  const result=native_window_policy(padded.subarray(7,7+b.length)),saved=result.slice();assert.deepEqual(result,native_window_policy(b));
  padded.fill(0);for(let i=0;i<32;i++)native_window_policy(request(i));assert.deepEqual(result,saved);assert.equal(decode(result).children.filter(c=>c.flags).length,256);
});
