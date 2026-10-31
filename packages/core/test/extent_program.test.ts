import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const source = ["runtime_policy", "extent_program"].map(n => readFileSync(new URL(`../src/${n}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvExtentProgram: program } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvExtentProgram };").toString("base64")}`);
function sync(oldId: bigint, id: bigint, oldCount: bigint, count: bigint, oldBase: bigint, base: bigint, dirty = false): Uint8Array {
  const b = new Uint8Array(72), w = new DataView(b.buffer); b[0] = 100; b[2] = dirty ? 1 : 0;
  [oldId,id,oldCount,count,oldBase,base].forEach((v,i) => w.setBigUint64(8 + i * 8, v, true));
  w.setFloat32(56, 1.125, true); return b;
}
function actions(b: Uint8Array): [number, bigint][] {
  const w = new DataView(b.buffer, b.byteOffset, b.byteLength);
  return Array.from({length:w.getUint32(8,true)},(_,i) => [w.getUint32(16+i*16,true),w.getBigUint64(24+i*16,true)]);
}
test("extent programs preserve reset refresh old-total gap and shape ordering", () => {
  const cases: [Uint8Array, number[], number][] = [
    [sync(0n,1n,0n,130n,0n,100n),[0,1,3,4,6,8],1],
    [sync(1n,1n,130n,130n,100n,100n),[1,2,4],0],
    [sync(1n,1n,130n,130n,100n,100n,true),[1,2,4,9],0],
    [sync(1n,1n,130n,193n,100n,100n),[1,2,4,6,8],2],
    [sync(1n,1n,130n,64n,100n,100n),[1,2,4,6,7,8,9],0],
    [sync(1n,1n,130n,140n,100n,93n),[1,2,4,6,7,8,9,5,10],4],
    [sync(1n,1n,130n,120n,100n,109n),[1,2,4,5,6,7,8,9,11],0],
    [sync(9007199254740992n,9007199254740993n,130n,65n,100n,100n),[0,1,3,4,6,8],1],
  ];
  for (const [input, expected, flags] of cases) {
    const result = program(input); assert.deepEqual(actions(result).map(a=>a[0]),expected);
    assert.equal(new DataView(result.buffer).getUint32(0,true),flags);
  }
});
test("extent programs preserve all count words and own their output storage", () => {
  const input=sync(1n,1n,9007199254740993n,9007199254740997n,100n,100n);
  const result=program(input), saved=result.slice();
  assert.equal(actions(result).find(a=>a[0]===8)![1],9007199254740993n/64n);
  input.fill(255);program(sync(0n,2n,0n,0n,0n,0n));assert.deepEqual(result,saved);
  for(const base of [0n,9007199254740993n,18446744073709550000n]) {
    const value=program(sync(1n,1n,130n,65n,base+100n,base));
    assert.equal(actions(value).find(a=>a[0]===5)![1],65n);
  }
});
test("extent correction programs request exactly the required anchor capability", () => {
  for(let mode=0;mode<4;mode++) {
    const b=new Uint8Array(16);b[0]=100;b[1]=1;b[2]=mode;
    assert.deepEqual(actions(program(b)),mode===1?[[13,1n]]:[[12,0n],[13,BigInt(mode)]]);
  }
});
test("extent programs reject malformed facts and preserve gap bit semantics", () => {
  const b=sync(1n,1n,65n,65n,1n,1n),w=new DataView(b.buffer);
  for(let n=0;n<b.length;n++)assert.throws(()=>program(b.subarray(0,n)));
  assert.throws(()=>program(new Uint8Array([...b,0])));
  for(const at of [0,1,2,3,4,60,64,68]) {const bad=b.slice();bad[at]=255;assert.throws(()=>program(bad));}
  for(const value of [-Infinity,-1,NaN,Infinity,-0,0,0.125]) {
    w.setFloat32(56,value,true);const gap=new DataView(program(b).buffer).getFloat32(4,true);
    assert.ok(Object.is(gap,!Number.isFinite(value)||value<0?0:Math.fround(value)));
  }
  const correction=new Uint8Array(16);correction[0]=100;correction[1]=1;
  for(const at of [2,3,4,8,12]) {const bad=correction.slice();bad[at]=255;assert.throws(()=>program(bad));}
  w.setBigUint64(16,0n,true);assert.throws(()=>program(b));
});
