import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["markup_elements", "markup_canonical", "markup_shapes"].map(n => readFileSync(new URL(`../src/${n}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvMarkupShapes: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupShapes };").toString("base64")}`);
interface Node { kind?: number; name?: string; text?: string; attrs?: [string,string][]; children?: number[] }
class Packet {
  parts: Uint8Array[];
  constructor(mode: number) { this.parts = [Uint8Array.of(115,1,mode,1)]; }
  word(...values: number[]): this { for (const n of values) { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0,n,true); this.parts.push(b); } return this; }
  blob(value: string | Uint8Array): this { const b = typeof value === "string" ? new TextEncoder().encode(value) : value; this.word(b.length); this.parts.push(b); return this; }
  names(names: string[]): this { this.word(names.length); for (const n of names) this.blob(n); return this; }
  tree(nodes: Node[]): this {
    this.word(nodes.length);
    for (const n of nodes) {
      this.word(n.kind ?? 0).blob(n.name ?? "context-menu").blob(n.text ?? "").word(n.attrs?.length ?? 0);
      for (const [name,value] of n.attrs ?? []) this.blob(name).blob(value);
      this.word(n.children?.length ?? 0,...n.children ?? []);
    }
    return this.names(["regular","medium","bold"]).names(["accent"]).names(["start","center","end"]);
  }
  bytes(): Uint8Array { return Uint8Array.from(Buffer.concat(this.parts)); }
  actions(): number[][] {
    const b: Uint8Array = run(this.bytes()), v = new DataView(b.buffer), count = v.getFloat64(8,true);
    assert.equal(b.length,16+count*48);
    return Array.from({length:count},(_,i)=>[b[16+i*48]!,b[17+i*48]!,...Array.from({length:5},(_,j)=>v.getFloat64(24+i*48+j*8,true))]);
  }
}
const shape = (mode: number, nodes: Node[]) => new Packet(mode).tree(nodes).actions();
const code = (mode: number, nodes: Node[]) => shape(mode,nodes).find(a=>a[0]===255)?.[1] ?? 0;
test("shared markup shape rules retain ordered capabilities and exact positions",()=>{
  const span: Node[] = [{name:"span",attrs:[["scale","1e-46"],["weight","bad"]],children:[1]},{kind:1,text:"hello"}];
  assert.deepEqual(shape(1,span).map(a=>a.slice(0,4)),[[2,0,0,1],[255,1,0,2]]);
  assert.equal(code(1,[{attrs:[["foreground","{name}"]]}]),4);
  assert.equal(code(1,[{attrs:[["foreground","unknown"]]}]),3);
  assert.equal(code(1,[{attrs:[["italic","{}"]]}]),20);
  assert.deepEqual(shape(1,[{attrs:[["italic","{ 'x' + 1 }"]],children:[1]},{kind:1}])[0],[1,0,0,1,2,7,0]);
  assert.equal(code(2,[{attrs:[["text-alignment","{align}"]]}]),26);
  assert.equal(code(2,[{children:[1,2]},{kind:1},{kind:1}]),7);
  assert.equal(code(2,[{children:[1]},{kind:0,name:"span"}]),27);
});
test("context menu walks structure tags in source order before later failures",()=>{
  const menu: Node[]=[{children:[1,4]},{kind:2,attrs:[["each","rows"],["as","row"]],children:[2]},
    {name:"menu-item",attrs:[["on-press","pick:{row.id}"]],children:[3]},{kind:1,text:"{upper(row.name)}"},
    {kind:4,children:[5]},{name:"separator"}];
  assert.deepEqual(shape(0,menu).map(a=>a.slice(0,4)),[[4,0,3,0],[5,0,3,0]]);
  assert.equal(code(0,[{children:[1]},{kind:4}]),21);
  assert.equal(code(0,[{children:[1]},{kind:3}]),23);
  assert.equal(code(0,[{children:[1]},{kind:2,attrs:[["each","rows"]]}]),14);
  assert.equal(code(0,[{children:[1]},{name:"menu-item",attrs:[["on-press","pick:{ row.id }"]]}]),19);
  const failing:Node[]=[{children:[1]},{name:"menu-item",attrs:[["disabled","{bad()}"],["on-press","pick"]],children:[2]}, {kind:1,text:"unclosed {"}];
  assert.deepEqual(shape(0,failing).map(a=>a.slice(0,4)),[[1,0,1,1],[255,22,2,0]]);
});
test("coverage scans raw UTF-8 spans and skips braces and layout controls",()=>{
  const scan=(b:string|Uint8Array)=>new Packet(4).blob(b).actions();
  assert.deepEqual(scan("\n{ignored}é\x7f").map(a=>a.slice(0,5)),[[3,0,10,2,233]]);
  assert.deepEqual(scan(Uint8Array.of(0xe2,0x28,0xa1))[0],[255,8,0,3,65533,0,0]);
  assert.deepEqual(scan(Uint8Array.of(0xf0,0x90))[0],[255,8,0,2,65533,0,0]);
  for(const b of [0x80,0xff]) assert.deepEqual(scan(Uint8Array.of(b))[0],[255,8,0,1,65533,0,0]);
  for(const b of [Uint8Array.of(0xc0,0x80),Uint8Array.of(0xed,0xa0,0x80),Uint8Array.of(0xf4,0x90,0x80,0x80)]) assert.equal(scan(b)[0]![0],255);
  assert.deepEqual(scan("{unterminated\xff"),[]);
});
test("structural expression types preserve unknown propagation and definite failures",()=>{
  const check=(rows:number[][])=>{const p=new Packet(3).word(rows.length,rows.length-1);for(const row of rows)p.word(...row);return p.actions()[0]!;};
  const node=(kind:number,lhs=0,rhs=0,binding=0,fn=0,argc=0,args=[0,0,0,0])=>[kind,fn,argc,lhs,rhs,...args,17,binding];
  for(let binding=0;binding<5;binding++) {
    const result=check([node(4,0,0,binding),node(0),node(7,0,1)]);
    assert.equal(result[0],binding===1||binding===4?255:0);
    if(result[0]===0)assert.equal(result[2],binding===0?0:binding===2?2:3);
  }
  assert.equal(check([node(2),node(6)])[1],2);
  assert.equal(check([node(0),node(20,0,0,0,6,1)])[1],38);
  assert.equal(check([node(4),node(20,0,0,0,6,1)])[2],1);
  assert.equal(check([node(1),node(0),node(20,0,0,0,16,2,[0,1,0,0])])[1],48);
});
test("shape transport refuses truncation cycles unreachable nodes and trailing bytes",()=>{
  const p=new Packet(0).tree([{children:[1]},{name:"separator"}]).bytes();
  for(let i=0;i<p.length;i++)assert.throws(()=>run(p.subarray(0,i)));
  for(const at of [0,1,2,3]) {const bad=p.slice();bad[at]=255;assert.throws(()=>run(bad));}
  assert.throws(()=>shape(0,[{children:[0]}]));assert.throws(()=>shape(0,[{},{}]));
  assert.throws(()=>shape(0,[{children:[1,1]},{}]));assert.throws(()=>run(Uint8Array.of(...p,0)));
  const sizing=p.slice();sizing[3]=0;assert.equal(run(sizing).length,16);
});
