import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const source = readFileSync(new URL("../src/web_panes.ts", import.meta.url), "utf8");
const { nscvWebPanes: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWebPanes };").toString("base64")}`);
function request(mode: number, bytes: number): [Uint8Array, DataView] {
  const b = new Uint8Array(bytes); b[0] = 99; b[1] = mode; return [b, new DataView(b.buffer)];
}
test("web panes reject malformed lengths flags matches counts and reserved bytes", () => {
  const sizes = [32, 32, 64, 32];
  for (let mode = 0; mode < 4; mode++) {
    const [b] = request(mode, sizes[mode]!);
    assert.doesNotThrow(() => plan(b));
    for (let length = 0; length < b.length; length++) assert.throws(() => plan(b.subarray(0, length)));
    assert.throws(() => plan(new Uint8Array([...b, 0])));
    for (const at of [0, 1, 2, 3]) { const bad = b.slice(); bad[at] = 255; assert.throws(() => plan(bad)); }
  }
  for (const [mode, at, value] of [[0,4,1025],[0,8,2],[0,12,1],[1,4,5],[1,16,65],[1,20,2],[1,24,1],[1,28,1],[2,4,8],[2,56,1],[2,60,1],[3,4,2],[3,16,4097],[3,20,1],[3,24,1],[3,28,1]]) {
    const [b,w]=request(mode!,sizes[mode!]!); w.setUint32(at!,value!,true);assert.throws(()=>plan(b));
  }
  const [b,w]=request(0,52);w.setUint32(4,1,true);assert.throws(()=>plan(b));
  w.setUint32(8,1,true);w.setUint32(32,2,true);assert.throws(()=>plan(b));
});
test("web pane anchors select the first match before testing its size", () => {
  const [b,w]=request(0,32+1024*20);w.setUint32(4,1024,true);w.setUint32(8,1,true);
  w.setUint32(32+400*20,1,true);w.setUint32(32+1023*20,1,true);
  for(const row of [400,1023]) {w.setFloat32(44+row*20,120,true);w.setFloat32(48+row*20,80,true);}
  let r=new DataView(plan(b).buffer);assert.equal(r.getUint32(0,true),2);assert.equal(r.getUint32(4,true),400);
  w.setFloat32(44+400*20,0.999,true);r=new DataView(plan(b).buffer);assert.equal(r.getUint32(0,true),1);assert.equal(r.getUint32(4,true),400);
  w.setUint32(32+400*20,0,true);w.setUint32(32+1023*20,0,true);r=new DataView(plan(b).buffer);assert.equal(r.getUint32(0,true),0);
});
test("web pane frame admission preserves numeric capability and payload bits", () => {
  const [b,w]=request(0,32);w.setFloat32(24,1,true);w.setUint32(28,0x7fc12345,true);
  for(let flags=0;flags<16;flags++) {
    b[2]=flags;w.setFloat32(16,-0,true);w.setFloat32(20,-10,true);
    const r=new DataView(plan(b).buffer);assert.equal(r.getUint32(0,true),2);assert.equal(r.getUint32(8,true),(flags&4)!==0?0x80000000:0);assert.equal(r.getFloat32(12,true),0);assert.equal(r.getUint32(20,true),0x7fc12345);
  }
});
test("web pane slots preserve first matching labels and exact bounded lengths", () => {
  for(let count=0;count<=4;count++)for(let matches=0;matches<16;matches++) {
    if(matches>=(1<<count))continue;
    const [b,w]=request(1,32);w.setUint32(4,count,true);w.setUint32(16,64,true);w.setBigUint64(8,18446744073709551615n,true);
    for(let i=0;i<count;i++)b[20+i]=(matches>>i)&1;
    const r=new DataView(plan(b).buffer);const first=[0,1,2,3].find(i=>(matches&(1<<i))!==0);
    assert.equal(r.getUint32(0,true),first!==undefined?1:count===4?0:2);assert.equal(r.getUint32(4,true),first??(count===4?4294967295:count));assert.equal(r.getUint32(8,true),first===undefined&&count<4?64:0);
  }
});
test("web pane patches preserve exact reload tokens and strict f32 thresholds", () => {
  for(const previous of [0n,4294967295n,9007199254740992n,9007199254740993n,18446744073709551615n])
    for(const token of [previous,previous^1n])for(let flags=0;flags<8;flags++)for(const delta of [0,0.2499999850988388,0.25,0.2500000298023224,NaN,Infinity]) {
      const [b,w]=request(2,64);w.setUint32(4,flags,true);w.setBigUint64(40,previous,true);w.setBigUint64(48,token,true);w.setFloat32(24,delta,true);
      assert.equal(plan(b)[0],(Math.abs(Math.fround(delta))<0.25?0:1)|((flags&4)!==0&&((flags&1)!==0||(flags&2)===0||token!==previous)?2:0));
    }
});
test("web pane commits retain failed updates and bound successful copies", () => {
  for(const success of [0,1])for(const capacity of [0,1,4096])for(const length of [0n,1n,4095n,4096n,4097n,9007199254740993n,18446744073709551615n]) {
    const [b,w]=request(3,32);w.setUint32(4,success,true);w.setBigUint64(8,length,true);w.setUint32(16,capacity,true);
    const r=new DataView(plan(b).buffer);assert.equal(r.getUint32(0,true),success);assert.equal(r.getUint32(4,true),success?Number(length<BigInt(capacity)?length:BigInt(capacity)):0);
  }
});
