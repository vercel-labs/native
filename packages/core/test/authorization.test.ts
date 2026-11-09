import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy.ts", "authorization.ts"].map(n => readFileSync(new URL(`../src/${n}`, import.meta.url), "utf8")).join("\n");
const { nscvAuthorization: derive, native_window_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvAuthorization };").toString("base64")}`);
type Bytes = string | Uint8Array;
type Command = { name: Bytes; grants?: Bytes[]; origins?: Bytes[] };
class Packet {
  parts: Uint8Array[];
  constructor(mode: number, flags = [0, 0, 0, 0]) { this.parts = [new Uint8Array([88, 1, mode, ...flags, 0])]; }
  integer(value: bigint | number): this { const bytes = new Uint8Array(8); new DataView(bytes.buffer).setBigUint64(0, BigInt(value), true); this.parts.push(bytes); return this; }
  field(value: Bytes): this { const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value; this.integer(bytes.length); this.parts.push(bytes); return this; }
  list(values: Bytes[]): this { this.integer(values.length); for (const value of values) this.field(value); return this; }
  commands(values: Command[]): this { this.integer(values.length); for (const value of values) this.field(value.name).list(value.grants ?? []).list(value.origins ?? []); return this; }
  bytes(): Uint8Array { const bytes = new Uint8Array(this.parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const part of this.parts) { bytes.set(part, at); at += part.length; } return bytes; }
  result(): [boolean, number] { const bytes = this.bytes(), actual = derive(bytes); assert.deepEqual(actual, dispatch(bytes)); const out = new DataView(actual.buffer); assert.equal(actual.length, 16); assert.equal(out.getUint32(0, true), 1); assert.equal(out.getUint32(4, true), bytes[2]); return [out.getUint32(8, true) === 1, out.getUint32(12, true)]; }
}
test("authorization preserves exact raw permission bytes and requires every grant", () => {
  for (const value of ["", "window", "Window", "window\0", "*", new Uint8Array([255, 0, 254]), "x".repeat(8192)]) {
    assert.deepEqual(new Packet(0).list([value]).field(value).result(), [true, 0]);
    assert.deepEqual(new Packet(0).list(["*"]).field(value).result(), [value === "*", 0]);
    assert.deepEqual(new Packet(1).list([value]).list([value, value]).result(), [true, 0]);
    assert.deepEqual(new Packet(1).list([]).list([]).result(), [true, 0]);
    assert.deepEqual(new Packet(1).list([value]).list([value, "missing"]).result(), [false, 0]);
  }
});
test("origin authorization preserves wildcard scope and performs no normalization", () => {
  for (const value of ["", "zero://inline", "https://A", new Uint8Array([255, 0]), "x".repeat(16384)]) {
    assert.deepEqual(new Packet(2).list([value]).field(value).result(), [true, 0]);
    assert.deepEqual(new Packet(2).list(["*"]).field(value).result(), [true, 0]);
    assert.deepEqual(new Packet(2).list([]).field(value).result(), [false, 0]);
  }
  assert.deepEqual(new Packet(2).list(["https://a"]).field("https://A").result(), [false, 0]);
});
test("external-link patterns require an explicit action and preserve host/path boundaries", () => {
  for (const [pattern, url, expected] of [["https://example.com/*", "https://example.com/docs", true], ["https://example.com/*", "https://example.com.evil/docs", false], ["https://example.com*", "https://example.com.evil/docs", false], ["https:///*", "https:///docs", false], ["HTTPS://a/*", "HTTPS://a/path", false], ["http://a/one*", "http://a/one/two", true], ["http://a/*/two*", "http://a/one/two", false], ["odd://a/*", "odd://a/x", false], ["odd://a/*", "odd://a/*", true], ["*", "", true]] as const) {
    assert.deepEqual(new Packet(3, [1, 0, 0, 0]).list([pattern]).field(url).result(), [expected, 0]);
    assert.deepEqual(new Packet(3).list([pattern]).field(url).result(), [false, 0]);
  }
});
test("bridge admission uses the first duplicate command and does not widen permission wildcards", () => {
  const commands = [{ name: "one", grants: ["window"], origins: ["zero://inline"] }, { name: "one" }];
  for (const enabled of [0, 1]) for (const grants of [[], ["*"], ["window"]]) for (const origin of ["zero://inline", "elsewhere"]) {
    assert.deepEqual(new Packet(4, [enabled, 0, 0, 0]).list(grants).commands(commands).field("one").field(origin).result(), [enabled === 1 && grants[0] === "window" && origin === "zero://inline", 0]);
  }
  assert.deepEqual(new Packet(4, [1, 0, 0, 0]).list([]).commands([{ name: "two" }]).field("two").field("").result(), [true, 0]);
});
test("builtin fallback preserves explicit policy precedence and the window compatibility grant", () => {
  const commands = [{ name: "one", grants: ["clipboard"], origins: ["allowed"] }];
  for (const explicit of [0, 1]) for (const js of [0, 1]) for (const present of [0, 1]) for (const grants of [[], ["window"], ["clipboard"], ["missing"]]) for (const origin of ["allowed", "denied"]) {
    const expected = explicit === 1 ? (grants.length === 0 || grants[0] === "clipboard") && origin === "allowed" : js === 1 && present === 1 && origin === "allowed" && (grants.length === 0 || grants[0] === "window" || grants[0] === "clipboard");
    assert.deepEqual(new Packet(5, [explicit, js, present, 0]).list(grants).list(["clipboard"]).commands(commands).list(["allowed"]).field("one").field(origin).field("clipboard").result(), [expected, 0]);
  }
});
test("external URL admission preserves ordered errors and the complete byte limit", () => {
  for (const [url, expected] of [["", 1], [" ".repeat(33), 2], ["HTTPS://a/x", 1], ["http://a/\0", 1], ["http://a/\x7f", 1], ["https://a/x", 3]] as const) assert.deepEqual(new Packet(6).list(["*"]).field(url).integer(32).result(), [false, expected]);
  assert.deepEqual(new Packet(6, [1, 0, 0, 0]).list(["*"]).field("http://").integer(32).result(), [true, 0]);
  assert.deepEqual(new Packet(6, [1, 0, 0, 0]).list(["*"]).field(new Uint8Array([104,116,116,112,58,47,47,255])).integer(32).result(), [true, 0]);
});
test("authorization refuses every truncated table and unsafe extent before reading bytes", () => {
  const bytes = new Packet(5, [1, 1, 1, 0]).list(["window"]).list(["clipboard"]).commands([{ name: "one", origins: ["*"] }]).list(["zero://inline"]).field("one").field("zero://inline").field("clipboard").bytes();
  for (let end = 0; end < bytes.length; end++) assert.throws(() => derive(bytes.slice(0, end)));
  const extra = new Uint8Array(bytes.length + 1); extra.set(bytes); assert.throws(() => derive(extra));
  for (const count of [4294967296n, 9007199254740992n, (1n << 64n) - 1n]) assert.throws(() => derive(new Packet(0).integer(count).field("").bytes()));
  for (const [at, value] of [[0, 87], [1, 2], [2, 7], [3, 2], [7, 1]]) { const bad = bytes.slice(); bad[at!] = value!; assert.throws(() => derive(bad)); }
});
