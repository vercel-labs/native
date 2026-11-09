import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["markup_elements", "markup_canonical", "markup_runtime"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvMarkupRuntime: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupRuntime };").toString("base64")}`);
interface Attr { name: string; raw?: string; cached?: number }
interface Child { kind?: number; name?: string; text?: string }
class Packet {
  parts: Uint8Array[];
  constructor(mode: number) { this.parts = [Uint8Array.of(114, 1, mode, 1)]; }
  word(...values: number[]): this { for (const n of values) { const b = new Uint8Array(8); new DataView(b.buffer).setFloat64(0, n, true); this.parts.push(b); } return this; }
  blob(value: string | Uint8Array): this { const b = typeof value === "string" ? new TextEncoder().encode(value) : value; this.word(b.length); this.parts.push(b); return this; }
  names(values: string[]): this { this.word(values.length); for (const value of values) this.blob(value); return this; }
  node(name: string, attrs: Attr[] = [], children: Child[] = []): this {
    this.blob(name).word(attrs.length);
    for (const attr of attrs) this.blob(attr.name).blob(attr.raw ?? "").word(attr.cached ?? 0);
    this.word(children.length); for (const child of children) this.word(child.kind ?? 0).blob(child.name ?? "column").blob(child.text ?? ""); return this;
  }
  bytes(): Uint8Array { return Uint8Array.from(Buffer.concat(this.parts)); }
  actions() {
    const b: Uint8Array = run(this.bytes()), v = new DataView(b.buffer), count = v.getFloat64(8, true);
    assert.equal(b.length, 16 + count * 48);
    return Array.from({ length: count }, (_, i) => ({ action: b[16 + i * 48]!, code: b[17 + i * 48]!, fields: Array.from({ length: 5 }, (_, j) => v.getFloat64(24 + i * 48 + j * 8, true)) }));
  }
}
const actions = (p: Packet) => p.actions().map(a => [a.action, a.code, ...a.fields.slice(0, 2)]);
test("runtime collection selection preserves field priority exact bytes and callback classes", () => {
 const select = (name: string | Uint8Array, fields: string[], flags: number[], decls: string[], classes: number[]) => actions(new Packet(0).blob(name).names(fields).word(...flags).names(decls).word(...classes));
 assert.deepEqual(select("same", ["same"], [1], ["same"], [3]), [[1, 0, 0, 0]]);
 assert.deepEqual(select("same", ["same"], [0], ["same"], [3]), [[2, 0, 0, 3]]);
 assert.deepEqual(select(Uint8Array.of(255), ["�"], [1], [], []), [[0, 0, 0, 0]]);
 assert.deepEqual(actions(new Packet(7).word(0, 5, 0, 2, 1, 3, 2)), [[30, 0, 1, 2], [30, 0, 2, 1], [30, 0, 4, 2], [31, 0, 0, 0]]);
 for (let channel=1;channel<=3;channel++) assert.deepEqual(actions(new Packet(7).word(channel, 6, 0, 1, 2, 3, 4, 5)), [[30, 0, channel+2, channel+2], [31, 0, 0, 0]]);
});
test("runtime image admission orders all four evaluations before publishing", () => {
 const source = ["source-height", "source-width", "source-y", "image", "source-x"].map(name=>({name}));
 assert.deepEqual(actions(new Packet(2).node("image", source)), [[20,0,0,0],[21,0,4,0],[21,0,2,1],[21,0,1,2],[21,0,0,3],[22,0,0,0]]);
 assert.deepEqual(actions(new Packet(2).node("button", source)), [[255,3,0,0]]);
 assert.deepEqual(actions(new Packet(2).node("image", source.filter(a=>a.name!=="image"))), [[255,4,0,0]]);
 assert.deepEqual(actions(new Packet(2).node("image", source.filter(a=>a.name!=="source-x"))), [[255,5,0,0]]);
 assert.deepEqual(actions(new Packet(2).node("button")), []);
});
test("runtime keys scalar admission constructors keep exact classes", () => {
 for(let present=0;present<=1;present++) for(let kind=0;kind<4;kind++) assert.equal(new Packet(1).word(present,kind).actions()[0]!.action, present && (kind===0 || kind===3) ? kind===0 ? 1 : 2 : 255);
 for(let channel=0;channel<2;channel++) for(let kind=0;kind<4;kind++) assert.equal(new Packet(3).word(channel,kind).actions()[0]!.action!==255, channel===0 ? kind===3 : kind<2);
 assert.deepEqual(actions(new Packet(4).blob("link").names(["link","link"]).word(0,1)), [[1,0,1,0]]);
});
test("runtime text keeps cached identity admission raw slices and failure ordering", () => {
 assert.deepEqual(actions(new Packet(5).node("text",[],[{kind:0,name:"span"}])), [[255,9,1,0]]);
 assert.deepEqual(actions(new Packet(5).node("text",[],[{kind:1},{kind:0,name:"span"}])), [[255,8,0,0]]);
 assert.deepEqual(actions(new Packet(6).blob(Uint8Array.of(255,0,125)).word(1,1,3)), [[40,0,0,0]]);
 assert.deepEqual(actions(new Packet(6).blob("{x}").word(1,4,0,1,2,3)), [[41,0,0,0],[42,0,1,0],[43,0,2,0],[255,11,0,0]]);
 assert.deepEqual(actions(new Packet(6).blob("a{ x }{x+1}z{").word(0,0)), [[44,0,0,1],[45,0,3,4],[44,0,6,6],[46,0,7,10],[44,0,11,12],[255,11,0,0]]);
 assert.deepEqual(actions(new Packet(6).blob("{}{}").word(0,0)), [[44,0,0,0],[46,0,1,1],[44,0,2,2],[46,0,3,3],[44,0,4,4]]);
});
test("runtime transport rejects truncation invalid flags counts and trailing facts", () => {
 const packet=new Packet(6).blob("{x}").word(1,3,0,1,2).bytes();
 for(let i=0;i<packet.length;i++) assert.throws(()=>run(packet.subarray(0,i)));
 for(const at of [0,1,2,3]) {const bad=packet.slice();bad[at]=255;assert.throws(()=>run(bad));}
 assert.throws(()=>new Packet(6).blob("x").word(0,1,0).actions());
 assert.throws(()=>new Packet(4).blob("x").names(["x"]).word(2).actions());
 assert.throws(()=>new Packet(7).word(0,1,6).actions());
 assert.throws(()=>run(Uint8Array.of(...packet,0)));
 const sizing=packet.slice();sizing[3]=0;assert.equal(run(sizing).length,16);
});
