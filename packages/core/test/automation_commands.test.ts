import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { test } from "node:test";
const source = ["runtime_policy.ts", "automation_commands.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`);
function request(mode: number, text: string | Uint8Array, capacity = 0) {
  const bytes = typeof text === "string" ? Buffer.from(text) : text;
  const out = new Uint8Array(16 + bytes.length); out.set([90, 1, mode, 0]);
  const view = new DataView(out.buffer); view.setUint32(4, bytes.length, true); view.setUint32(8, capacity, true); out.set(bytes, 16); return out;
}
function plan(mode: number, text: string | Uint8Array, capacity = 0) { return dispatch(request(mode, text, capacity)) as Uint8Array; }
function words(plan: Uint8Array) { const view = new DataView(plan.buffer); return Array.from({length: plan.length / 4}, (_, i) => view.getUint32(i * 4, true)); }
function spans(mode: number, text: string | Uint8Array) {
  const bytes = typeof text === "string" ? Buffer.from(text) : text;
  const value = plan(mode, text); const w = words(value);
  return Array.from({length: w[5]}, (_, i) => ({kind: w[6+i*6], text: Buffer.from(bytes.subarray(w[7+i*6], w[7+i*6]+w[8+i*6])).toString("hex")}));
}
test("automation grammar covers every shipped parser and its complete field order", () => {
  const cases = [[0,"command ignored",1],[1,"1",1],[2,"1 2",2],[3,"label with spaces",1],[4,"command label with spaces",2],[5,"main 1 set-text value",3],[6,"main 1",2],[7,"main at 1 2",3],[8,"main 1 2 3",4],[9,"main 1 2",3],[10,"main cmd+a text",3],[11,"main 2 1 2",4],[12,"main 1 0 1",6],[13,"main 2",2],[14,"a b c",3],[15,"1 2",2],[16,"",2],[17,"900 640",3]] as const;
  for (const [mode,text,count] of cases) { const w=words(plan(mode,text,3)); assert.deepEqual(w.slice(0,3),[1,mode,1]); assert.equal(w[5],count); assert.equal(w.length,6+6*count); }
});
test("automation grammar preserves opaque bytes and trims only four ASCII separators", () => {
  const input = new Uint8Array([32,255,0,32,49,32,115,101,116,95,116,101,120,116,32,194,160,9]);
  assert.deepEqual(spans(5,input).filter(x=>x.kind===0).map(x=>x.text),["ff00","c2a0"]);
  assert.deepEqual(spans(3,"  label with spaces\n").map(x=>x.text),[Buffer.from("label with spaces").toString("hex")]);
  assert.equal(words(plan(0,"\u00a0"))[2],1);
});
test("automation action aliases and value rules retain the full native surface", () => {
  const names=["focus","press","toggle","increment","decrement","set_text","set_selection","set_composition","commit_composition","cancel_composition","select","drag","drop_files","dismiss"];
  for(let i=0;i<names.length;i++) {
    const needsValue=i===6||i===12; const acceptsValue=[5,6,7,11,12].includes(i);
    for(const name of [names[i],names[i].replaceAll("_","-").toUpperCase()]) {
      const empty=words(plan(5,`main 1 ${name}`)); assert.equal(empty[2],needsValue?0:1);
      const value=words(plan(5,`main 1 ${name} x`)); assert.equal(value[2],acceptsValue?1:0); if(acceptsValue) assert.equal(value[3],i);
    }
  }
  assert.equal(words(plan(5,"main 1 unknown"))[2],0);
});
test("automation key chords preserve aliases and reset unknown prefixes", () => {
  for(const [key,flags,returned] of [["cmd+c",24,"c"],["ctrl+shift+ArrowLeft",3,"ArrowLeft"],["option+super+a",28,"a"],["cmd+unknown+a",0,"cmd+unknown+a"],["cmd++",24,"+"],["cmd+",0,"cmd+"],["+",0,"+"]] as const) {
    const text=`main ${key} words`; assert.equal(words(plan(10,text))[4],flags); assert.equal(spans(10,text)[1].text,Buffer.from(returned).toString("hex"));
  }
});
test("automation optional arguments keep defaults and reject partial or excess tails", () => {
  for(const [mode,text] of [[6,"main 1 extra"],[7,"main at 1"],[8,"main 1 2 3 extra"],[11,"main 1 2"],[12,"main 1 0 1 0"],[13,"main 1 extra"],[15,"1 2 3"],[16,"1"],[17,"900 640 1 extra"]] as const) assert.equal(words(plan(mode,text))[2],0);
  const drag=plan(12,"main 1 0 1"); assert.equal(new DataView(drag.buffer).getFloat32(24+4*24+16,true),0.5);
  assert.equal(words(plan(2,"1"))[10],1);
  assert.equal(words(plan(14,"a b c",2))[2],0); assert.equal(words(plan(14,"",3))[2],0);
});
function complete(mode: number, text: string, numbers: readonly (bigint | number | null)[]) {
  const first=request(mode,text); const recipe=words(dispatch(first)); const next=new Uint8Array(first.length+recipe[5]*12); next.set(first); next[3]=1;
  const data=new DataView(next.buffer);
  for(let i=0;i<recipe[5];i++) {
    const kind=recipe[6+i*6]; if(kind===0||kind>=6) continue;
    const at=first.length+i*12; const number=numbers[i]; if(number===null) continue;
    data.setUint32(at,1,true);
    if(typeof number==="bigint") data.setBigUint64(at+4,number,true); else data.setFloat32(at+4,number,true);
  }
  return dispatch(next) as Uint8Array;
}
test("automation numeric admission preserves exact u64 identities and native float32 facts", () => {
  const max=(1n<<64n)-1n; const value=complete(6,"main id",[null,max]); assert.equal(words(value)[2],2); assert.equal(new DataView(value.buffer).getBigUint64(24+24+16,true),max);
  assert.equal(words(complete(6,"main id",[null,0n]))[2],0);
  assert.equal(words(complete(6,"main id",[null,null]))[2],0);
  for(const value of [NaN,Infinity,-Infinity,0,-0,-1]) assert.equal(words(complete(13,"main scale",[null,value]))[2],0);
  const wheel=complete(8,"main id dy dx",[null,1n,-0,0.5]); assert.equal(words(wheel)[2],2); assert.equal(new DataView(wheel.buffer).getUint32(24+2*24+16,true),0x80000000);
});
test("automation rejects malformed framing and conversion facts", () => {
  for(const index of [0,1,2,3,4,7,12]) { const bad=request(6,"main 1"); bad[index]=255; assert.throws(()=>dispatch(bad)); }
  const missing=request(6,"main 1"); missing[3]=1; assert.throws(()=>dispatch(missing));
  const extra=new Uint8Array(request(6,"main 1").length+1); extra.set(request(6,"main 1")); assert.throws(()=>dispatch(extra));
  const original=request(6,"main 1"); const bad=new Uint8Array(original.length+24); bad.set(original); bad[3]=1; bad[original.length+12]=2; assert.throws(()=>dispatch(bad));
});
