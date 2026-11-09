import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const source = readFileSync(new URL("../src/context_menus.ts", import.meta.url), "utf8");
const { nscvContextMenus: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvContextMenus };").toString("base64")}`);
function request(mode: number, bytes: number): [Uint8Array, DataView] {
  const b = new Uint8Array(bytes); b[0] = 98; b[1] = mode; return [b, new DataView(b.buffer)];
}
test("context-menu transport rejects malformed headers lengths flags and capacities", () => {
  const sizes = [16, 56, 16, 16, 32, 48, 16];
  for (let mode = 0; mode < sizes.length; mode++) {
    const [b, w] = request(mode, sizes[mode]!); if (mode === 6) w.setUint32(4, 1, true);
    assert.doesNotThrow(() => plan(b));
    for (let length = 0; length < b.length; length++) assert.throws(() => plan(b.subarray(0, length)));
    assert.throws(() => plan(new Uint8Array([...b, 0])));
    for (const at of [0, 1, 2, 3]) { const bad = b.slice(); bad[at] = 255; assert.throws(() => plan(bad)); }
  }
  for (const [mode, at, value] of [[0,4,1025],[0,8,1025],[0,12,1],[1,4,2048],[1,8,1],[1,12,1],[1,48,1],[1,52,1],
    [2,4,1],[3,4,5],[3,8,1],[3,12,1],[4,4,4],[4,24,1],[4,28,1],[5,4,5],[5,44,1],[6,4,0],[6,4,5],[6,12,1]]) {
    const [b,w] = request(mode!, sizes[mode!]!); w.setUint32(at!,value!,true); assert.throws(() => plan(b));
  }
});
test("context menus choose later equal-depth routes and preserve exact depth words", () => {
  const [b,w] = request(0,16+4*16+7*8); w.setUint32(4,4,true); w.setUint32(8,7,true);
  [9007199254740992n,9007199254740993n,9007199254740993n,18446744073709551615n].forEach((depth,i)=>{
    w.setBigUint64(16+i*16,depth,true);w.setUint32(24+i*16,1,true);w.setUint32(28+i*16,i===3?1:0,true);
  });
  [99n,0n,1n,3n,2n,4294967296n,0n].forEach((slot,i)=>w.setBigUint64(80+i*8,slot,true));
  assert.equal(new DataView(plan(b).buffer).getUint32(0,true),2);
  const invalid=b.slice();new DataView(invalid.buffer).setUint32(28,2,true);assert.throws(()=>plan(invalid));
});
test("context-menu default precedence and item enablement match the native rules", () => {
  for (let flags=0;flags<2048;flags++) {
    const [b,w]=request(1,56);w.setUint32(4,flags,true);
    w.setBigUint64(16,9007199254740993n,true);w.setBigUint64(24,9007199254740992n,true);
    w.setBigUint64(32,18446744073709551615n,true);w.setBigUint64(40,18446744073709551615n,true);
    const r=plan(b);
    const group=(flags&1024)!==0;
    const kind=(flags&1)===0?1:(flags&6)===2?((flags&16)!==0?2:0):(flags&12)===8?((flags&16)!==0?3:0):group?((flags&16)!==0?4:0):1;
    assert.equal(r[0],kind);assert.equal(r[1],kind===2?5:kind===3?2:kind===4?1:0);
    if(kind===2){assert.equal(r[10],(flags&32)!==0?1:0);assert.equal(r[14],r[10]);assert.equal(r[26],(flags&64)!==0?1:0);assert.equal(r[23],1);}
    if(kind===3){assert.equal(r[10],(flags&128)!==0?1:0);assert.equal(r[14],(flags&256)!==0?1:0);}
  }
});
test("context-menu admission preserves stale requests and exact token wrap", () => {
  for(const token of [0n,1n,4294967295n,9007199254740992n,9007199254740993n,18446744073709551615n]){
    const [b,w]=request(2,16);w.setBigUint64(8,token,true);
    assert.equal(new DataView(plan(b).buffer).getBigUint64(0,true),token===18446744073709551615n?1n:token+1n);
    for(let kind=0;kind<=4;kind++)for(const item of [0,1,4294967295])for(const mismatch of [0,1,2]){
      const [a,v]=request(5,48);v.setUint32(4,kind,true);v.setBigUint64(8,9007199254740993n,true);
      v.setBigUint64(16,9007199254740993n-BigInt(mismatch===1),true);v.setBigUint64(24,token,true);
      v.setBigUint64(32,token^BigInt(mismatch===2),true);v.setUint32(40,item,true);
      assert.equal(new DataView(plan(a).buffer).getUint32(0,true),kind===0||mismatch!==0?0:item!==0?3:kind===1?1:2);
    }
  }
});
