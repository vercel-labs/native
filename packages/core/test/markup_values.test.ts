import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["markup_canonical", "markup_elements", "markup_values"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvMarkupValues: run } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupValues };").toString("base64")}`);
interface Attr { name: string; raw?: string; cached?: number }
interface Child { kind?: number; name?: string; text?: string }
class Packet {
  parts: Uint8Array[];
  constructor(mode: number) { this.parts = [Uint8Array.of(113, 1, mode, 1)]; }
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
const attrs = (...names: string[]): Attr[] => names.map(name => ({ name }));
const actions = (packet: Packet) => packet.actions().map(step => step.action);
test("value programs retain resource and dependent anchor failure order", () => {
  assert.equal(new Packet(0).word(0).blob("image").word(0).actions()[0]!.code, 2);
  assert.equal(new Packet(0).word(1).blob("image").word(0).actions()[0]!.code, 3);
  assert.deepEqual(actions(new Packet(1).word(2, 3, 0)), [3]);
  assert.equal(new Packet(1).word(0, 0, 0).actions()[0]!.code, 2);
  assert.equal(new Packet(3).word(2, 0, 0, 0).actions()[0]!.code, 10);
  assert.equal(new Packet(3).word(2, 1, 1, 0).actions()[0]!.code, 13);
  assert.deepEqual(actions(new Packet(2).word(1).blob("tooltip").names(["tooltip"])), [1]);
  for (let type = 0; type <= 5; type++) for (let kind = 0; kind < 4; kind++) for (const within of [0, 1]) {
    const allowed = type === 1 ? kind < 2 : type === 2 ? true : type === 3 || type === 5 ? kind === 3 : type === 4 ? kind === 0 && within === 1 : false;
    assert.equal(new Packet(4).word(type, kind, within).actions()[0]!.action !== 255, allowed);
    assert.equal(new Packet(5).word(type, kind, within).actions()[0]!.action !== 255, allowed);
  }
});
test("message and callback selection keep tag payload and native class distinctions", () => {
  const message = (drag: number, tag: string, payload: number) => new Packet(6).word(drag).blob(tag).word(payload).names(["tick", "number", "drag"]).word(0, 1, 2).actions()[0]!;
  assert.equal(message(0, "missing", 0).code, 30);
  assert.equal(message(0, "tick", 1).code, 28);
  assert.equal(message(0, "number", 0).code, 29);
  assert.equal(message(1, "missing", 0).code, 31);
  assert.equal(message(1, "number", 1).code, 31);
  assert.equal(message(1, "drag", 1).action, 42);
  assert.equal(message(0, "number", 1).action, 41);
  assert.equal(new Packet(7).blob("wide").names(["integer", "wide"]).word(0, 2).actions()[0]!.fields[1], 2);
  assert.deepEqual(actions(new Packet(7).blob("integer").names(["integer", "wide"]).word(0, 2)), [0]);
});
test("binding programs preserve raw byte paths lexical floors and retry effects", () => {
  const scope = (path: Uint8Array | string, floor: number, names: string[], classes: number[]) => new Packet(11).blob(path).word(floor).names(names).word(...classes).actions()[0]!;
  assert.equal(scope("a", 0, ["a", "a"], [2, 0]).action, 62);
  assert.equal(scope("a.b", 1, ["a"], [2]).action, 65);
  assert.equal(scope("a.b", 0, ["a"], [2]).code, 37);
  assert.equal(scope("a", 0, ["a"], [1]).code, 36);
  assert.equal(scope("a", 0, ["a"], [3]).code, 41);
  assert.equal(scope(Uint8Array.of(255, 46, 0), 0, [], []).fields[0], 1);
  assert.deepEqual(actions(new Packet(12).word(0, 0, 0, 0)), [67]);
  assert.equal(new Packet(12).word(0, 1, 1, 0).actions()[0]!.code, 33);
  assert.deepEqual(actions(new Packet(12).word(1, 1, 0, 0)), [75]);
  assert.equal(new Packet(12).word(1, 2, 1, 0).actions()[0]!.code, 38);
  const resolve = (path: string, arena: number, fields: string[], decls: string[], classes: number[]) => new Packet(13).word(1).blob(path).word(arena).names(fields).names(decls).word(...classes).actions()[0]!;
  assert.equal(resolve("same", 1, ["same"], ["same"], [1]).action, 68);
  assert.equal(resolve("same.", 1, ["same"], ["same"], [1]).fields[1], 5);
  assert.equal(resolve("derived", 0, [], ["derived"], [2]).action, 0);
  assert.equal(resolve("derived", 1, [], ["derived"], [2]).action, 69);
  assert.equal(resolve("derived.x", 1, [], ["derived"], [1]).action, 0);
});
test("expression programs keep eager binding order typed literals cached trees and exact enum bytes", () => {
  assert.deepEqual(actions(new Packet(8).word(2, 1)), [53, 54, 55]);
  assert.deepEqual(actions(new Packet(8).word(0, 1)), [50]);
  assert.deepEqual(actions(new Packet(8).word(0, 0)), [51]);
  for (const cached of [0, 1]) assert.deepEqual(actions(new Packet(9).word(cached)), [cached ? 57 : 58]);
  const tree = new Packet(10).word(4, 1, 0, 0, 0, 1, 1, 1, 0).actions();
  assert.deepEqual(tree.map(x => x.action), [59, 59, 59, 60]);
  assert.deepEqual(tree.slice(0, 3).map(x => x.fields.slice(0, 2)), [[0, 1], [2, 0], [3, 1]]);
  assert.equal(new Packet(14).blob("save").names(["save"]).actions()[0]!.action, 72);
  assert.equal(new Packet(15).blob("end").names(["start", "end"]).actions()[0]!.fields[0], 1);
  assert.deepEqual(actions(new Packet(15).blob(Uint8Array.of(255)).names(["�"])), [0]);
});
test("value transport rejects every truncation invalid flag range and trailing bytes", () => {
  const bytes = new Packet(13).word(1).blob("a.b").word(1).names(["a"]).names(["x"]).word(2).bytes();
  for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
  for (const at of [0, 1, 2, 3]) { const bad = bytes.slice(); bad[at] = 255; assert.throws(() => run(bad)); }
  for (const value of [-1, .25, NaN, Infinity, 2 ** 53]) { const bad = bytes.slice(); new DataView(bad.buffer).setFloat64(4, value, true); assert.throws(() => run(bad)); }
  const sizing = bytes.slice(); sizing[3] = 0; assert.equal(new DataView(run(sizing).buffer).getFloat64(8, true), 1);
  assert.throws(() => run(Uint8Array.of(...bytes, 0)));
  assert.throws(() => new Packet(0).word(0).blob("image").word(2).actions());
  assert.throws(() => new Packet(11).blob("a").word(1).names([]).actions());
});
test("icon admission consumes raw expression bytes and explicit built-in names", () => {
  const icon = (raw: string | Uint8Array) => new Packet(14).blob(raw).names(["save", "plus"]).actions()[0]!;
  assert.equal(icon("save").action, 72);
  assert.equal(icon("app:wave-pulse").code, 1);
  assert.equal(icon("app:0").action, 72);
  for (const raw of ["app:", "app:-wave", "app:wave-", "app:wave--pulse", "app:Wave", "app:é", "app:a:b"]) assert.equal(icon(raw).code, 43);
  for (const raw of ["other:save", "save:", ":"]) assert.equal(icon(raw).code, 44);
  for (const raw of ["Save", " save", "missing", "{}", "{ x + y }", "{a == b}", "{"]) assert.equal(icon(raw).code, 42);
  assert.equal(icon("{ icon.name }").action, 73);
  assert.equal(icon(Uint8Array.of(97, 112, 112, 58, 255)).code, 43);
});
test("option admission uses explicit enum names and preserves chart aliases", () => {
  const names = ["band", "bar", "line"];
  for (const [raw, index, fill] of [["line", 2, 0], ["area", 2, 1], ["bar", 1, 0]] as const) {
    const action = new Packet(19).blob(raw).names(names).actions()[0]!;
    assert.equal(action.action, 79); assert.equal(action.fields[0], index); assert.equal(action.code, fill);
  }
  for (const raw of ["band", "Area", " line", "bar ", "", "{kind}", "line\0"]) assert.equal(new Packet(19).blob(raw).names(names).actions()[0]!.code, 47);
  assert.throws(() => new Packet(19).blob("line").names(["bar"]).actions());
  for (const raw of ["bold", "end", "button", "accent"]) {
    assert.equal(new Packet(15).blob(raw).names([raw + " ", raw]).actions()[0]!.fields[0], 1);
    assert.equal(new Packet(15).blob(raw.toUpperCase()).names([raw]).actions()[0]!.action, 0);
  }
});
test("scale admission retains IEEE f32 subnormals signed zeros infinities and NaNs", () => {
  const storage = new DataView(new ArrayBuffer(4));
  for (const bits of [0, 1, 0x7fffff, 0x800000, 0x3f800000, 0x7f7fffff, 0x7f800000, 0x7f800001, 0x7fc00000, 0x7fffffff, 0x80000000, 0x80000001, 0xff7fffff, 0xff800000, 0xffffffff]) {
    storage.setUint32(0, bits, true); const value = storage.getFloat32(0, true);
    assert.equal(new Packet(20).word(bits).actions()[0]!.action === 1, Number.isFinite(value) && value > 0);
  }
  for (const bits of [-1, 0.5, 0x100000000, Infinity, NaN]) assert.throws(() => new Packet(20).word(bits).actions());
  for (const packet of [new Packet(19).blob("area").names(["line", "bar"]), new Packet(20).word(0x7f7fffff)]) {
    const bytes = packet.bytes();
    for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
    assert.throws(() => run(Uint8Array.of(...bytes, 0)));
  }
});
const languages = ["plain", "zig", "javascript", "typescript", "json", "yaml", "shell", "python", "rust", "c_like", "go", "html", "css", "sql", "jsx", "tsx", "markdown"];
test("numeric option admission preserves exact i64 words and distinct failure channels", () => {
  const cases = [-9223372036854775808n, -9007199254740993n, -1n, 0n, 1n, 254n, 255n, 256n, 4294967295n, 4294967296n, 9007199254740991n, 9007199254740992n, 9007199254740993n, 9223372036854775807n];
  for (const value of cases) for (const channel of [0, 1, 2]) {
    const bits = BigInt.asUintN(64, value), low = Number(bits & 0xffffffffn), high = Number(bits >> 32n);
    const result = new Packet(21).word(channel).word(0).word(low).word(high).word(255).actions()[0]!;
    const accepted = channel === 0 ? value >= 0n && value <= 9007199254740991n : channel === 1 || value >= 0n && value <= 255n;
    assert.equal(result.action, accepted ? channel === 1 && value < 0n ? 2 : 1 : 255);
    if (!accepted) assert.equal(result.code, channel === 0 ? 49 : 54);
  }
  for (const channel of [0, 1, 2]) for (const kind of [1, 2, 3]) {
    assert.equal(new Packet(21).word(channel).word(kind).word(0).word(0).word(255).actions()[0]!.code, [50, 52, 53][channel]);
  }
});
test("virtual extent admission preserves signed zero finite values and exact f32 bits", () => {
  const storage = new DataView(new ArrayBuffer(4));
  for (const bits of [0, 1, 0x7fffff, 0x800000, 0x3f800000, 0x7f7fffff, 0x7f800000, 0x7f800001, 0x7fc00000, 0x80000000, 0x80000001, 0xff800000, 0xffffffff]) {
    storage.setUint32(0, bits, true); const value = storage.getFloat32(0, true);
    assert.equal(new Packet(22).word(bits).actions()[0]!.action === 1, Number.isFinite(value) && value >= 0);
    if (Number.isFinite(value) && value >= 0) for (const estimator of [0, 1]) {
      assert.equal(new Packet(25).word(bits).word(estimator).actions()[0]!.action, estimator || value !== 0 ? 0 : 255);
    }
  }
});
test("virtual option defaults anchors and complete safe logical ranges are compiled", () => {
  for (const name of ["item-count", "overscan", "index-base", "item-extent", "gap", "viewport-fallback"]) {
    const channel = ["item-count", "overscan", "index-base"].includes(name) ? 0 : 1;
    const absent = new Packet(26).word(channel).blob(name).word(0).actions()[0]!;
    assert.equal(absent.action, 0); assert.equal(absent.fields[0], name === "overscan" ? 4 : 0);
    assert.equal(new Packet(26).word(channel).blob(name).word(1).actions()[0]!.action, 1);
  }
  for (const raw of ["", "leading", "trailing", "Trailing", "trailing ", "trailing\0", "{anchor}"]) {
    assert.equal(new Packet(23).blob(raw).names(["trailing", "leading"]).actions()[0]!.fields[0], raw === "trailing" ? 0 : 1);
  }
  assert.throws(() => new Packet(23).blob("trailing").names(["leading"]).actions());
  for (const base of [0, 1, 4294967296, 9007199254740990, 9007199254740991]) for (const count of [0, 1, 2, 4294967296, 9007199254740991]) {
    assert.equal(new Packet(24).word(base).word(count).actions()[0]!.action, BigInt(base) + BigInt(count) <= 9007199254740991n ? 0 : 255);
  }
});
test("numeric option packets reject malformed fields truncation and trailing facts", () => {
  const valid = [new Packet(21).word(0).word(0).word(0xffffffff).word(0x1fffff).word(0), new Packet(22).word(0x80000000), new Packet(23).blob("trailing").names(["leading", "trailing"]), new Packet(24).word(9007199254740991).word(0), new Packet(25).word(0).word(1), new Packet(26).word(0).blob("overscan").word(0)];
  for (const packet of valid) {
    const bytes = packet.bytes();
    for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
    assert.throws(() => run(Uint8Array.of(...bytes, 0)));
  }
  for (const packet of [new Packet(21).word(3).word(0).word(0).word(0).word(0), new Packet(21).word(0).word(4).word(0).word(0).word(0), new Packet(21).word(0).word(0).word(0x100000000).word(0).word(0), new Packet(22).word(0x100000000), new Packet(25).word(0).word(2), new Packet(26).word(1).blob("overscan").word(0)]) assert.throws(() => packet.actions());
});
test("code languages retain ASCII aliases trim boundaries and unknown admission", () => {
  const language = (raw: string) => new Packet(16).blob(raw).names(languages).actions()[0]!;
  for (const [alias, expected] of [[" TEXT ", 0], ["\tTsX\r\n", 15], ["C++", 9], ["jsonc", 4], ["mjs", 2], ["golang", 10], ["md", 16]] as const) assert.equal(language(alias).fields[0], expected);
  for (const raw of ["", "unknown", "\vzig", "zig\f", "ſql", "c_like"]) assert.equal(language(raw).code, 45);
});
test("diff grammar stages exact endpoint spans before subsequent errors", () => {
  const spec = " \r\n+1 - 0__2 , 3, ";
  const program = new Packet(17).blob(spec).actions();
  assert.deepEqual(program.map(row => row.action), [77, 77, 255]);
  assert.deepEqual(program.slice(0, 2).map(row => row.fields.slice(0, 4).map((_, i, spans) => i % 2 === 0 ? spec.slice(spans[i]!, spans[i + 1]!) : null).filter(x => x !== null)), [["+1", "0__2"], ["3", "3"]]);
  assert.deepEqual(actions(new Packet(17).blob("\t\r\n")), [200]);
  for (const raw of [",", "1-2-3", "-1", "1-", "1,,2"]) assert.equal(new Packet(17).blob(raw).actions().at(-1)!.code, 46);
  const range = (first: number, last: number, lines: number[] = []) => new Packet(18).word(1, 1, first, 1, 1, last, 128, lines.length, ...lines).actions();
  assert.deepEqual(range(1, 4, [3, 1]).map(row => row.fields.slice(0, 2)), [[2, 2], [3, 4]]);
  assert.equal(range(0, 2)[0]!.code, 46);
  assert.equal(range(3, 2)[0]!.code, 46);
  assert.equal(new Packet(18).word(1, 0, 0, 1, 1, 1, 128, 0).actions()[0]!.code, 46);
});
test("new metadata transports reject truncations trailing bytes and invalid facts", () => {
  const packets = [new Packet(14).blob("app:wave").names(["save"]), new Packet(16).blob("zig").names(languages), new Packet(17).blob("1-3,4"), new Packet(18).word(1, 1, 1, 1, 1, 2, 128, 0)];
  for (const packet of packets) {
    const b = packet.bytes(); for (let i = 0; i < b.length; i++) assert.throws(() => run(b.subarray(0, i)));
    assert.throws(() => run(Uint8Array.of(...b, 0)));
    b[3] = 0; assert.equal(run(b).length, 16);
  }
  assert.throws(() => new Packet(18).word(2, 1, 1, 1, 1, 2, 128, 0).actions());
  assert.throws(() => new Packet(18).word(1, 1, 1, 1, 1, 2, 128, 1, 129).actions());
});
test("specialized admission preserves all forms payload sizes and diagnostic channels", () => {
  const diagnostics = [57, 58, 59, 60, 61, 62, 63, 45, 64, 65, 47, 66, 67, 46];
  for (let channel = 0; channel < 14; channel++) for (let form = 0; form < 6; form++) for (const length of [0, 1, 4096]) {
    const admitted = [1, 2].includes(channel) ? form === 4 && length === 0 : channel === 5 ? ![2, 5].includes(form)
      : [7, 10, 12].includes(channel) ? form === 0 : channel === 8 ? form === 4 : channel === 13 ? form !== 5 : form === 1;
    const row = new Packet(27).word(channel, form, length).actions()[0]!;
    assert.equal(row.action, admitted ? channel === 13 && form !== 0 ? 2 : 1 : 255);
    assert.equal(row.code, admitted ? 0 : diagnostics[channel]);
  }
  assert.throws(() => new Packet(27).word(14, 0, 0).actions());
  assert.throws(() => new Packet(27).word(0, 6, 0).actions());
});
test("specialized evaluated values retain empty publication and native numeric conversion selection", () => {
  for (let channel = 0; channel < 5; channel++) for (let kind = 0; kind < 4; kind++) for (const length of [0, 1, 65536]) {
    const row = new Packet(28).word(channel, kind, length).actions()[0]!;
    assert.equal(row.action, channel === 4 ? kind < 2 ? kind === 0 ? 2 : 1 : 255 : kind === 3 ? channel === 2 && length === 0 ? 0 : 1 : 255);
    assert.equal(row.code, row.action === 255 ? [57, 63, 62, 46, 48][channel] : 0);
  }
  for (const length of [0, 1, 2, 4096]) assert.equal(new Packet(29).word(length).actions()[0]!.action, length === 0 ? 1 : 2);
});
test("stepper requests capture only for one slot and rejects absent capture before allocation", () => {
  for (const count of [0, 1, 2, 100]) for (const kind of ["slot_block", "element", "text", "slot_block\0", ""]) {
    assert.equal(new Packet(30).word(0, count).blob(kind).actions()[0]!.action, count === 1 && kind === "slot_block" ? 2 : 1);
  }
  assert.equal(new Packet(30).word(1, 0).actions()[0]!.code, 68);
  assert.equal(new Packet(30).word(1, 1).actions()[0]!.action, 1);
  assert.throws(() => new Packet(30).word(2).actions());
});
test("literal inference preserves schema text precedence and stages exact native conversion", () => {
  const initial = (raw: string | Uint8Array, aware: number, name: string) => new Packet(31).word(0).blob(raw).word(aware).blob(name).names(["text", "placeholder", "label"]).actions()[0]!;
  for (const raw of ["true", "false", "9223372036854775807", "-9223372036854775808", "9007199254740993", "1e40", "nan", "-0", "", " true", "TRUE", Uint8Array.of(0, 255)]) {
    for (const name of ["text", "placeholder", "label"]) assert.equal(initial(raw, 1, name).action, 81);
    const expected = raw === "true" || raw === "false" ? 82 : 83;
    assert.equal(initial(raw, 0, "text").action, expected);
    assert.equal(initial(raw, 1, "width").action, expected);
    assert.equal(initial(raw, 1, "text\0").action, expected);
  }
  assert.equal(initial("true", 0, "").code, 1);
  assert.equal(initial("false", 0, "").code, 0);
  for (const valid of [0, 1]) {
    assert.equal(new Packet(31).word(1, valid).actions()[0]!.action, valid ? 84 : 85);
    assert.equal(new Packet(31).word(2, valid).actions()[0]!.action, valid ? 86 : 81);
  }
});
test("lexical capture lookup respects every floor and innermost slot independent of contents", () => {
  for (let length = 0; length <= 8; length++) for (let mask = 0; mask < 2 ** length; mask++) for (let floor = 0; floor <= length; floor++) {
    const flags = Array.from({ length }, (_, i) => mask >> i & 1);
    const row = new Packet(32).word(length, floor, ...flags).actions()[0]!;
    let expected = 0;
    for (let i = length - 1; i >= floor; i--) if (flags[i]) { expected = i + 1; break; }
    assert.equal(row.action, 87); assert.equal(row.fields[0], expected);
  }
});
test("literal and capture transport rejects malformed phases flags floors and trailing facts", () => {
  const packets = [new Packet(31).word(0).blob(Uint8Array.of(0, 255)).word(1).blob("text").names(["text"]), new Packet(31).word(1, 1), new Packet(31).word(2, 0), new Packet(32).word(3, 1, 1, 0, 1)];
  for (const packet of packets) {
    const bytes = packet.bytes();
    for (let i = 0; i < bytes.length; i++) assert.throws(() => run(bytes.subarray(0, i)));
    assert.throws(() => run(Uint8Array.of(...bytes, 0)));
    bytes[3] = 0; assert.equal(run(bytes).length, 16);
  }
  assert.throws(() => new Packet(31).word(3).actions());
  assert.throws(() => new Packet(31).word(1, 2).actions());
  assert.throws(() => new Packet(31).word(2, 2).actions());
  assert.throws(() => new Packet(32).word(0, 1).actions());
  assert.throws(() => new Packet(32).word(1, 0, 2).actions());
});

test("element postprocessing orders construction, forwarded press, provenance and publication", () => {
  for (const press of [0, 1]) for (const provenance of [0, 1]) {
    const expected = [88, ...(press ? [89] : []), ...(provenance ? [90] : []), 91];
    assert.deepEqual(new Packet(33).word(press, provenance).actions().map(row => row.action), expected);
  }
});
test("tabs lower only ordinary button children while preserving source indices", () => {
  const kinds = ["button", "toggle_button", "segmented_control", "text", "button", "column", "Button", ""];
  for (let length = 0; length <= kinds.length; length++) {
    const packet = new Packet(34).word(length);
    for (const kind of kinds.slice(0, length)) packet.blob(kind);
    assert.deepEqual(packet.actions().map(row => [row.action, row.fields[0]]),
      kinds.slice(0, length).flatMap((kind, index) => kind === "button" ? [[92, index]] : []));
  }
});
test("binding paths retain byte offsets including empty, trailing and malformed tails", () => {
  const fixed = ["", "a", ".", "a.", ".a", "a.b.c", "a..b", " a.b ", "é.字", "a\0.b"];
  const paths = fixed.map(value => new TextEncoder().encode(value));
  for (let byte = 0; byte < 256; byte++) {
    paths.push(Uint8Array.of(byte, 255, 0));
    paths.push(Uint8Array.of(byte, 46, 255, 0));
  }
  for (const path of paths) {
    const dot = path.indexOf(46), [row] = new Packet(35).blob(path).actions();
    assert.equal(row!.action, 93);
    assert.deepEqual(row!.fields, [dot < 0 ? path.length : dot, dot < 0 ? 0 : dot + 1, 0, 0, 0]);
  }
});

test("timeline forwarding selects use-site handlers and rejects malformed facts", () => {
  assert.deepEqual(actions(new Packet(36).word(0)), [0]);
  assert.deepEqual(actions(new Packet(36).word(1)), [1]);
  const valid = new Packet(36).word(1).bytes();
  for (let end = 0; end < valid.length; end++) assert.throws(() => run(valid.slice(0, end)));
  assert.throws(() => run(new Packet(36).word(2).bytes()));
  assert.throws(() => run(new Packet(36).word(0, 1).bytes()));
});
