import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markdown_content.ts", import.meta.url), "utf8");
const { nscvMarkdownContentPolicy: policy, nscMdFloat: parse, nscMdDecode: decode } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkdownContentPolicy, nscMdFloat, nscMdDecode };\n").toString("base64")}`);
const utf8 = (text: string) => new TextEncoder().encode(text);
function request(bytes: Uint8Array, collect = false, capacity = 16) {
  const r = new Uint8Array(24 + bytes.length), w = new DataView(r.buffer);
  r.set([22, collect ? 1 : 0, 1, 0]); w.setUint32(4, bytes.length, true); w.setUint32(20, collect ? capacity : 0, true); r.set(bytes, 24); return r;
}
function sources(result: Uint8Array) {
  const w = new DataView(result.buffer, result.byteOffset, result.byteLength), values: Uint8Array[] = []; assert.equal(w.getUint32(0, true), 1); let at = 8;
  for (let i = 0; i < w.getUint32(4, true); i++) { const length = w.getUint32(at, true); at += 4; assert.ok(length <= 2048 && length <= result.length - at); values.push(result.slice(at, at + length)); at += length; }
  assert.equal(at, result.length); return values;
}
test("Markdown discovery keeps opaque HTML and code inert and canonicalizes complete raw sources", () => {
  const bytes = new Uint8Array([...utf8("<!--\n<img src='hidden'>\n-->\n<script>\n![x](hidden)\n</script>\n<code>\n<img src='hidden'>\n</code>\n```\n![x](hidden)\n```\n\n<img src='a&amp;b'>\n\n![x](a&b)\n\n| ![x](first) | ![x](second) |\n|---|---|\n\n![raw]("), 0, 255, ...utf8(")")]);
  const expected = [utf8("a&b"), utf8("first"), utf8("second"), new Uint8Array([0, 255])];
  for (let capacity = 0; capacity <= 20; capacity++) assert.deepEqual(sources(policy(request(bytes, true, capacity))), expected.slice(0, capacity));
  assert.deepEqual(sources(policy(request(utf8(`![x](${"a".repeat(2049)})\n\n![y](next)`), true))), [utf8("next")]);
});
test("Markdown recipes own every byte and retain bounded complete span tails", () => {
  const bytes = new Uint8Array([...utf8("**b** *i* ".repeat(50)), 0, 255, 192, 175]), r = request(bytes), result = policy(r), saved = result.slice();
  r.fill(0); bytes.fill(0); assert.deepEqual(result, saved);
  const w = new DataView(result.buffer); assert.equal(w.getUint32(0, true), 1); const count = w.getUint32(4, true); assert.ok(count > 1); assert.equal(w.getUint32(8, true), count - 1);
  assert.ok(result.includes(255)); assert.ok(result.includes(192));
});
test("Markdown dimensions round at exact f32 decimal and hexadecimal midpoints", () => {
  assert.equal(parse(utf8("1.000000059604644775390625")), 1);
  assert.equal(parse(utf8("1.000000059604644775390626")), 1 + 2 ** -23);
  assert.equal(parse(utf8("1.000000059604644775390624")), 1);
  assert.equal(parse(utf8("0x1.000001p0")), 1);
  assert.equal(parse(utf8("0x1.00000100000001p0")), 1 + 2 ** -23);
  assert.equal(parse(utf8("0x1p-149")), 2 ** -149);
  assert.equal(parse(utf8("0x1p-150")), 0);
  assert.equal(parse(utf8("0x1.000001p-150")), 2 ** -149);
  assert.equal(parse(utf8("1_024")), 1024);
  for (const spelling of ["", "_1", "1_", "1__2", "1_.2", "1e_2", "0b100", "64px", "64\r", "0x_1"]) assert.ok(Number.isNaN(parse(utf8(spelling))), spelling);
});
test("Markdown entity grammar retains malformed input and every raw byte", () => {
  assert.deepEqual(decode(utf8("&#6__5; &#_65; &#65_; &#+65; &#0; &#xD800; &#x1f600;")), utf8("A &#_65; &#65_; &#+65; &#0; &#xD800; 😀"));
  assert.deepEqual(decode(new Uint8Array([255, 0, ...utf8("&amp;"), 192])), new Uint8Array([255, 0, 38, 192]));
});
test("Markdown rejects malformed request framing before parsing", () => {
  const r = request(utf8("document"));
  for (let length = 0; length < r.length; length++) assert.throws(() => policy(r.slice(0, length)));
  assert.throws(() => policy(new Uint8Array([...r, 0])));
  for (const [at, value] of [[0, 21], [1, 2], [2, 0], [3, 2], [8, 1], [12, 10], [16, 17], [20, 1]]) { const bad = r.slice(); bad[at] = value; assert.throws(() => policy(bad)); }
});
