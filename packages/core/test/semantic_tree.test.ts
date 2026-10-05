import assert from "node:assert/strict";
import test from "node:test";
import { native_window_policy } from "../src/runtime_policy.ts";

function tree(count: number, query = false, target = 0, capacity = count): Uint8Array {
  const bytes = new Uint8Array(16 + count * 128), wire = new DataView(bytes.buffer);
  bytes.set([9, query ? 1 : 0, 0, 0]); wire.setUint32(4, count, true); wire.setUint32(8, target, true); wire.setUint32(12, capacity, true);
  for (let i = 0; i < count; i++) { word(bytes, i, 0, 26); word(bytes, i, 12, 0xffffffff); word(bytes, i, 16, 64); floats(bytes, i, 52, [0, 0, 100, 100, 0, 0, 100, 100]); }
  return bytes;
}
function word(bytes: Uint8Array, node: number, at: number, value: number): void { new DataView(bytes.buffer).setUint32(16 + node * 128 + at, value, true); }
function integer(bytes: Uint8Array, node: number, at: number, value: bigint): void { new DataView(bytes.buffer).setBigUint64(16 + node * 128 + at, value, true); }
function floats(bytes: Uint8Array, node: number, at: number, values: readonly number[]): void { const d = new DataView(bytes.buffer); values.forEach((value, i) => d.setFloat32(16 + node * 128 + at + i * 4, value, true)); }
function node(bytes: Uint8Array, i: number, kind: number, depth = 0, parent = 0xffffffff): void { word(bytes, i, 0, kind); word(bytes, i, 8, depth); word(bytes, i, 12, parent); }
function run(bytes: Uint8Array) {
  const output = native_window_policy(bytes), d = new DataView(output.buffer);
  const metric = (at: number) => ({ present: d.getUint32(at, true) === 1, offset: d.getFloat32(at + 4, true), viewport: d.getFloat32(at + 8, true), content: d.getFloat32(at + 12, true) });
  return { error: d.getUint32(4, true), output, records: Array.from({ length: d.getUint32(0, true) }, (_, i) => {
    const at = 16 + i * 144;
    return { source: d.getUint32(at, true), parent: d.getUint32(at + 4, true), role: d.getUint32(at + 8, true), fields: d.getUint32(at + 12, true), state: d.getUint32(at + 16, true), actions: d.getUint32(at + 20, true), value: d.getFloat32(at + 24, true),
      list: [28,32,36].map(n => d.getUint32(at + n, true)), gridMask: d.getUint32(at + 40, true), grid: [44,52,60,68].map(n => d.getBigUint64(at + n, true)),
      primary: metric(at + 76), vertical: metric(at + 100), horizontal: metric(at + 116), scrollValue: d.getFloat32(at + 92, true), scrollable: d.getUint32(at + 96, true) === 1 };
  }) };
}

test("semantic reduction preserves hidden and concealed subtrees, grouping and partial errors", () => {
  const b = tree(8); node(b,0,2); node(b,1,2,1,0); word(b,1,16,65); node(b,2,31,2,1);
  node(b,3,14,1,0); node(b,4,31,2,3); node(b,5,53,1,0); node(b,6,31,2,5); node(b,7,26,1,0);
  // Skipped semantic siblings retain the reference's depth-stack entry.
  assert.deepEqual(run(b).records.map(r => [r.source,r.parent]), [[0,0xffffffff],[3,0],[6,1],[7,0]]);
  word(b,3,16,192); assert.deepEqual(run(b).records.map(r=>r.source),[0,3,4,6,7]);
  new DataView(b.buffer).setUint32(12,2,true); const full=run(b);assert.equal(full.error,2);assert.deepEqual(full.records.map(r=>r.source),[0,3]);
  new DataView(b.buffer).setUint32(12,8,true);word(b,2,8,32);const deep=run(b);assert.equal(deep.error,1);assert.deepEqual(deep.records.map(r=>r.source),[0]);
});
test("semantic fields preserve authored overrides, selected state, text selectors and chart values", () => {
  const b=tree(7);[14,38,23,62,56,51,42].forEach((kind,i)=>node(b,i,kind));
  floats(b,0,84,[0.5]);word(b,1,16,64|256|512);floats(b,1,92,[-0]);word(b,2,20,256);word(b,4,16,64|1024);floats(b,4,96,[37.25]);floats(b,5,84,[2]);word(b,6,20,16);
  const r=run(b).records;assert.equal(r[0]!.state,768);assert.equal(r[0]!.value,1);assert.equal(r[1]!.fields&7,7);assert.ok(Object.is(r[1]!.value,-0));
  assert.equal(r[2]!.state,256);assert.equal(r[3]!.fields&6,2);assert.equal(r[4]!.value,37.25);assert.equal(r[5]!.value,1);assert.equal(r[6]!.value,1);
});
test("semantic grids divide every uint64 child count and preserve exact authored columns", () => {
  for(const count of [0n,3n,9007199254740993n,0xffffffffffffffffn]) for(const columns of [0n,1n,3n,9007199254740993n,0xffffffffffffffffn]) {
    const b=tree(2);node(b,0,3);word(b,0,4,14);integer(b,0,44,count);integer(b,0,36,columns);node(b,1,44,1,0);word(b,1,16,64|2048);word(b,1,32,0xffffffff);
    const chosen=count===0n?0n:columns===0n?count:columns, rows=chosen===0n?0n:1n+(count-1n)/chosen;
    const r=run(b).records;assert.deepEqual(r[0]!.grid.slice(2),[rows,chosen]);
    if(chosen>0n){assert.equal(r[1]!.gridMask,15);assert.deepEqual(r[1]!.grid,[0xffffffffn/chosen,0xffffffffn%chosen,rows,chosen]);}
  }
});
test("table reduction infers uneven rows and columns while preserving authored row ordinals", () => {
  const b=tree(7);node(b,0,5);node(b,1,43,1,0);node(b,2,44,2,1);node(b,3,26,2,1);node(b,4,43,1,0);node(b,5,44,2,4);node(b,6,44,2,4);word(b,4,16,64|2048);word(b,4,32,0xffffffff);
  const r=run(b).records;assert.deepEqual(r[0]!.grid.slice(2),[2n,2n]);assert.equal(r[1]!.gridMask,13);assert.deepEqual(r[2]!.grid,[0n,0n,2n,1n]);assert.deepEqual(r[6]!.grid,[0xffffffffn,1n,2n,2n]);
});
test("list metrics preserve maximum authored indices and present zero counts", () => {
  const b=tree(4);node(b,0,7);node(b,1,42,1,0);node(b,2,26,1,0);node(b,3,42,1,0);word(b,2,16,64|2048|4096);word(b,2,32,0xffffffff);
  assert.deepEqual(run(b).records.map(r=>r.list),[[0,0,0],[1,0,2],[1,0xffffffff,0],[1,1,2]]);
});
test("scroll observation selects the overflowing primary axis and augments enabled actions", () => {
  const b=tree(2,true);node(b,0,6);word(b,0,16,96);node(b,1,26,1,0);floats(b,0,84,[25,50]);floats(b,1,52,[-50,-25,250,100]);
  let r=run(b).records[0]!;assert.deepEqual(r.primary,{present:true,offset:50,viewport:100,content:250});assert.equal(r.scrollValue,Math.fround(1/3));assert.equal(r.actions,25);assert.ok(r.fields&8);
  floats(b,1,64,[20]);r=run(b).records[0]!;assert.equal(r.primary.content,250);assert.equal(r.primary.offset,50);assert.equal(r.horizontal.content,250);
  word(b,0,20,8);assert.equal(run(b).records[0]!.actions,0);assert.equal(run(b).records[0]!.fields&8,0);
});
test("scroll reach excludes floating, direct anchored, clipped and concealed descendants by axis", () => {
  const b=tree(7,true);node(b,0,6);word(b,0,16,96);node(b,1,19,1,0);node(b,2,26,2,1);floats(b,2,52,[0,0,1000,1000]);
  node(b,3,26,1,0);word(b,3,16,64|8);floats(b,3,52,[0,0,900,900]);node(b,4,14,1,0);floats(b,4,52,[0,0,120,120]);node(b,5,26,2,4);floats(b,5,52,[0,0,800,800]);node(b,6,26,1,0);floats(b,6,52,[0,0,130,140]);
  let r=run(b).records[0]!;assert.equal(r.vertical.content,140);assert.equal(r.horizontal.content,130);
  word(b,4,16,64|128);r=run(b).records[0]!;assert.equal(r.vertical.content,140);assert.equal(r.horizontal.content,800);
  word(b,4,16,64|128|16);assert.equal(run(b).records[0]!.horizontal.content,130);
});
test("virtual observations use declared content and ignore horizontal grants", () => {
  const b=tree(1,true);node(b,0,6);word(b,0,16,32|4);floats(b,0,84,[150]);floats(b,0,100,[1000]);const r=run(b).records[0]!;
  assert.equal(r.vertical.content,1000);assert.equal(r.horizontal.present,false);assert.equal(r.scrollValue,Math.fround(1/6));
  floats(b,0,76,[0]);assert.equal(run(b).records[0]!.primary.present,false);
});
test("semantic numeric facts retain f32 clamp ordering and nonfinite behavior", () => {
  const b=tree(1);node(b,0,51);
  for(const value of [-Infinity,-1,-0,0,0.5,1,Infinity,NaN]) {floats(b,0,84,[value]);const actual=run(b).records[0]!.value;assert.equal(actual,Number.isNaN(value)?1:Math.max(0,Math.min(1,value)));}
  node(b,0,6);floats(b,0,84,[NaN]);assert.equal(run(b).records[0]!.primary.offset,0);
});
test("semantic protocol refuses all truncated, surplus, reserved and invalid tree facts", () => {
  const b=tree(1);for(let n=1;n<b.length;n++)assert.throws(()=>run(b.subarray(0,n)),/semantic/);
  assert.throws(()=>run(new Uint8Array([...b,0])),/semantic/);
  for(const at of [1,2,3,8,16,20,120]){const bad=b.slice();bad[at]=255;assert.throws(()=>run(bad),/semantic/);}
  for(const [at,value] of [[28,0xfffffffe],[32,0xffffffff],[36,1024],[40,2048]]){const bad=b.slice();new DataView(bad.buffer).setUint32(at!,value!,true);assert.throws(()=>run(bad),/semantic/);}
});
test("large semantic records own output across offset views and repeated policies", () => {
  const b=tree(256),padded=new Uint8Array(b.length+11);padded.set(b,7);const output=native_window_policy(padded.subarray(7,7+b.length)),saved=output.slice();padded.fill(0);
  for(let i=0;i<12;i++)native_window_policy(tree(i));assert.deepEqual(output,saved);assert.equal(run(b).records.length,256);
});
