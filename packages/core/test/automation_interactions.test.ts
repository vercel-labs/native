import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
const source = ["runtime_policy.ts", "automation_interactions.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`);
function input(mode: number, facts = 35, values: number[] = [0, 0, 100, 80], phase = 0) {
  const bytes = new Uint8Array(128), w = new DataView(bytes.buffer);
  bytes.set([91, 1, mode, phase]); w.setUint32(4, facts, true);
  values.forEach((n, i) => w.setFloat32(8 + i * 4, n, true)); return bytes;
}
function plan(bytes: Uint8Array) {
  const out = dispatch(bytes) as Uint8Array, w = new DataView(out.buffer), count = w.getUint32(16, true);
  assert.equal(out.length, 40 + count * 36);
  assert.equal(w.getUint32(0, true), 1); assert.equal(w.getUint32(4, true), bytes[2]); assert.equal(w.getUint32(36, true), 0);
  return { status: w.getUint32(8, true), flags: w.getUint32(12, true), origin: [w.getFloat32(20, true), w.getFloat32(24, true)],
    steps: Array.from({ length: count }, (_, i) => { const at = 40 + i * 36; return [0,4,8,12].map(n=>w.getUint32(at+n,true)).concat([16,20,24,28,32].map(n=>w.getFloat32(at+n,true))); }) };
}
test("click, hold and secondary click preserve complete event order and flags", () => {
  const values = [0,0,100,80,7,9];
  assert.deepEqual(plan(input(0,35,values)), { status:0,flags:5,origin:[0,0],steps:[[0,0,0,0,7,9,0,0,0],[1,0,0,0,7,9,0,0,0]] });
  assert.deepEqual(plan(input(1,35,values)).steps.map(s=>s[0]),[0,9,1]); assert.equal(plan(input(1,35,values)).flags,20);
  assert.deepEqual(plan(input(2,35,values)).steps.map(s=>[s[0],s[1]]),[[0,1],[1,1]]);
  for (let mode=0;mode<3;mode++) { assert.equal(plan(input(mode,33,values)).status,1); assert.equal(plan(input(mode,35,values,1)).steps.length,0); }
});
test("wheel refusal order precedes geometry and preserves both axes", () => {
  assert.equal(plan(input(3,0)).status,2); assert.equal(plan(input(3,1)).status,3);
  assert.equal(plan(input(3,3,[1,2,0,5])).status,4);
  assert.deepEqual(plan(input(3,3,[10,20,-8,-6,0,0,-3,5])).steps,[[3,0,0,0,6,17,-3,5,0]]);
});
test("pinch rejects the exact f32 wire minimum before emitting any event", () => {
  const atMinimum=plan(input(5,0,[0,0,100,80,0,0,2**-25])); assert.equal(atMinimum.status,5); assert.deepEqual(atMinimum.steps,[]);
  const bits=new DataView(new ArrayBuffer(4));bits.setFloat32(0,2**-25,true);bits.setUint32(0,bits.getUint32(0,true)+1,true);
  const accepted=plan(input(5,0,[0,0,100,80,0,0,bits.getFloat32(0,true)]));assert.deepEqual(accepted.steps.map(s=>s[0]),[6,7,8]); assert.equal(accepted.steps[1]![8],-1+2**-24);
  assert.deepEqual(accepted.steps.map(s=>s.slice(4,6)),[[50,40],[50,40],[50,40]]);
  assert.deepEqual(plan(input(5,8,[0,0,100,80,7,9,1.5])).steps[1], [7,0,0,0,7,9,0,0,.5]);
});
test("pointer drag uses native f32 rounding at every operation", () => {
  const f=Math.fround, x=f(16777215), width=f(3), start=f(x+f(width*f(.25))),end=f(x+f(width*f(.75)));
  const p=plan(input(6,35,[x,2,width,8,0,0,0,0,.25,.25,.75,.75])); assert.equal(p.flags,6);
  assert.deepEqual(p.steps,[[0,0,0,0,start,4,0,0,0],[2,0,0,0,end,8,f(end-start),4,0],[1,0,0,0,end,8,0,0,0]]);
});
test("text replacement selects all then types or deletes, with editability admission", () => {
  assert.deepEqual(plan(input(7,20)).steps.map(s=>s.slice(0,4)),[[4,0,1,0],[5,0,0,1]]);
  assert.deepEqual(plan(input(7,4)).steps.map(s=>s.slice(0,4)),[[4,0,1,0],[4,0,2,0]]);
  assert.equal(plan(input(7,16)).status,1);assert.equal(plan(input(8,0)).status,1);
  assert.deepEqual(plan(input(8,4)).steps.map(s=>s.slice(0,4)),[[10,0,0,1]]);
  assert.deepEqual(plan(input(4,0)).steps.map(s=>s.slice(0,4)),[[4,0,0,1]]);
});
test("accessibility drag retains untimestamped press seed, release and delta", () => {
  const p=plan(input(9,35,[10,20,8,6,0,0,-3,4]));assert.equal(p.flags,8); assert.deepEqual(p.origin,[14,23]);
  assert.deepEqual(p.steps,[[2,0,0,0,11,27,-3,4,0],[1,0,0,0,11,27,0,0,0]]);
});
test("drop admission checks interaction before path parsing and bounds afterwards", () => {
  assert.equal(plan(input(10,0,[],1)).status,7);assert.equal(plan(input(10,32,[],1)).status,1);
  assert.equal(plan(input(10,34,[],1)).status,0);assert.equal(plan(input(10,35,[0,0,0,4])).status,1);
  assert.deepEqual(plan(input(10,35,[10,20,8,6])).steps,[[11,0,0,0,14,23,0,0,0]]);
});
test("menu admission preserves the entire refusal ladder", () => {
  const stages=[0,2048,2080,2081,2145,2273,2529,2785];
  assert.deepEqual(stages.map(f=>plan(input(11,f)).status),[8,7,1,9,10,12,11,0]);
});
test("menu completion compares every token byte without number conversion", () => {
  const bytes=input(12,1056), w=new DataView(bytes.buffer);w.setBigUint64(64,2n**64n-1n,true);w.setBigUint64(72,2n**64n-1n,true);
  assert.equal(plan(bytes).status,0);
  for(let i=0;i<8;i++){bytes[72+i]^=1;assert.equal(plan(bytes).status,13);bytes[72+i]^=1;}
  w.setUint32(4,1024,true);const closed=plan(bytes);assert.equal(closed.status,14);assert.equal(closed.flags,32);
  w.setUint32(4,0,true);assert.equal(plan(bytes).status,13);
});
test("malformed interaction headers refuse instead of selecting a fallback", () => {
  assert.throws(()=>dispatch(input(0).subarray(0,127)),/invalid automation interaction request/);
  for(const [at,value] of [[1,2],[2,13],[3,2]] as const){const b=input(0);b[at]=value;assert.throws(()=>dispatch(b),/invalid/);}
  const b=input(3,4096);assert.throws(()=>dispatch(b),/observations/);assert.throws(()=>dispatch(input(5,0,[],1)),/phase/);
});
