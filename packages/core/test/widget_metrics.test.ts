import assert from "node:assert/strict";
import test from "node:test";
import {readFileSync} from "node:fs";
import {stripTypeScriptTypes} from "node:module";
const source = ["runtime_policy.ts", "widget_metrics.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const {nscvWidgetMetrics:derive} = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvWidgetMetrics};").toString("base64")}`);
function packet(op: number, kind = 31) {
  const b = new Uint8Array(224), w = new DataView(b.buffer); b.set([32,1,op,0,0,1,0,kind]);
  for (const [at,v] of [[20,14],[24,13],[28,14],[32,28],[36,48],[44,28],[48,32],[52,36],[56,10],[60,10],[64,10],[68,1.2],[76,6],[80,2],[84,28],[88,2],[96,40],[108,8],[112,12],[116,16],[120,4],[124,2]]) w.setFloat32(at!,v!,true);
  return b;
}
const word = (b: Uint8Array, at: number) => new DataView(b.buffer).getUint32(at,true);
const value = (b: Uint8Array, at: number) => new DataView(b.buffer).getFloat32(at,true);
test("icon-only buttons admit no measurement and labels request their selected font", () => {
  const b=packet(32),w=new DataView(b.buffer);w.setUint32(12,2,true);let out=derive(b);assert.equal(word(out,4),2);assert.equal(value(out,12),32);
  w.setUint32(12,3,true);out=derive(b);assert.equal(word(out,4),3);assert.equal(word(out,20),1);assert.equal(value(out,24),14);
  w.setUint32(12,35,true);w.setFloat32(144,41.125,true);out=derive(b);assert.equal(value(out,12),83.125);assert.equal(value(out,16),32);
});
test("typography heading and density registers keep their separate ladders", () => {
  const b=packet(1,26);b[4]=4;b[5]=0;assert.equal(value(derive(b),8),28);
  b[2]=10;assert.equal(value(derive(b),8),28);b[4]=1;assert.equal(value(derive(b),8),24.5);
});
test("raw unmodified scalar words and copied results retain ownership", () => {
  const b=packet(0),w=new DataView(b.buffer);w.setUint32(28,0xff812345,true);const out=derive(b);b.fill(0);assert.equal(word(out,8),0xff812345);assert.ok(out.subarray(12).every((x:number)=>x===0));
});
test("code gutters and table span alignment use ordered measurement continuations", () => {
  const b=packet(9,44),w=new DataView(b.buffer);w.setUint32(12,20,true);w.setFloat32(136,100,true);w.setFloat32(140,40,true);w.setFloat32(152,3,true);w.setFloat32(156,7,true);
  let out=derive(b);assert.equal(word(out,20),4);assert.equal(word(out,28),1);
  w.setUint32(12,52,true);w.setFloat32(144,8,true);out=derive(b);assert.equal(word(out,20),3);assert.equal(value(out,12),70);
  w.setUint32(12,116,true);w.setFloat32(148,20,true);out=derive(b);assert.equal(word(out,4),5);assert.equal(value(out,8),23);assert.equal(value(out,12),10);assert.equal(value(out,16),70);
});
test("invalid enums reserved fields and incomplete packets reject", () => {
  for (const at of [0,1,2,3,4,5,6,7,8,9,11,13,200,223]) {const b=packet(0);b[at]=255;assert.throws(()=>derive(b),/invalid widget metric/);}
  assert.throws(()=>derive(new Uint8Array(223)),/shape/);assert.throws(()=>derive(new Uint8Array(225)),/shape/);
});
