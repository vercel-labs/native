import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/code_content.ts", import.meta.url), "utf8");
const { nscvCodeContentPolicy: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvCodeContentPolicy };\n").toString("base64")}`);
const utf8 = (text: string) => new TextEncoder().encode(text);
function request(language: number, bytes: Uint8Array, state?: Uint8Array) {
  const r = new Uint8Array(624 + bytes.length), wire = new DataView(r.buffer); r.set([20, 0, language]);
  wire.setBigUint64(4, BigInt(bytes.length), true); r[16] = 128;
  if (state !== undefined) r.set(state, 16); r.set(bytes, 624); return r;
}
function spans(result: Uint8Array, bytes: Uint8Array) {
  const wire = new DataView(result.buffer, result.byteOffset, result.byteLength), count = wire.getUint32(608, true);
  assert.equal(result.length, 616 + count * 24); assert.ok(count <= 32); let end = 0;
  const out: { text: Uint8Array; color: number }[] = [];
  for (let i = 0; i < count; i++) {
    const at = 616 + i * 24, start = Number(wire.getBigUint64(at, true)), next = Number(wire.getBigUint64(at + 8, true)), color = wire.getUint32(at + 16, true);
    assert.equal(start, end); assert.ok(next > start && next <= bytes.length); assert.ok(color <= 6); assert.equal(wire.getUint32(at + 20, true), 0);
    out.push({ text: bytes.slice(start, next), color }); end = next;
  }
  assert.equal(end, bytes.length); return out;
}
test("code content retains every raw byte through coalescing and span overflow in all grammars", () => {
  const bytes = new Uint8Array([...utf8("const café = 1; /* 日本 */ ".repeat(200)), 0, 255, 192, 175]);
  for (let language = 0; language < 17; language++) {
    const result = policy(request(language, bytes)), runs = spans(result, bytes);
    assert.deepEqual(new Uint8Array(runs.flatMap(r => [...r.text])), bytes);
    if (language === 1) { assert.equal(runs.length, 32); assert.equal(runs.at(-1)!.color, 0); }
  }
});
test("code content preserves exact 64-bit context words and copies inactive slots", () => {
  const r = request(0, utf8("unchanged")), wire = new DataView(r.buffer);
  wire.setBigUint64(20, 9007199254740993n, true); wire.setBigUint64(28, 9007199254740995n, true);
  for (let i = 0; i < 32; i++) { wire.setBigUint64(48 + i * 8, 18446744073709551615n - BigInt(i), true); wire.setBigUint64(368 + i * 8, 9007199254740993n + BigInt(i), true); }
  const result = policy(r); assert.deepEqual(result.subarray(0, 608), r.subarray(16, 624));
  const html = request(15, utf8("{}"), r.subarray(16, 624)), after = policy(html);
  assert.equal(new DataView(after.buffer).getBigUint64(4, true), 9007199254740993n);
  r.fill(0); assert.equal(new DataView(result.buffer).getBigUint64(4, true), 9007199254740993n);
});
test("code content keeps scanning after overflow so the next chunk resumes multiline state", () => {
  for (const language of [1, 2, 3, 8, 9, 10, 12, 13, 14, 15]) {
    const first = utf8("const x = 1; ".repeat(80) + "/* open"), result = policy(request(language, first));
    assert.ok(new DataView(result.buffer).getUint32(0, true) & 16);
    const next = utf8("still comment */ const done = true;"), resumed = spans(policy(request(language, next, result.subarray(0, 608))), next);
    assert.equal(resumed[0]!.color, 1); assert.ok(resumed.some(s => s.color === 3));
  }
});
test("code content carries nested JSX tags and Markdown fence state across chunks", () => {
  for (const [language, chunks] of [[15, ['return <Outer icon={<Inner ', 'a={true} />} data="x">', 'text</Outer>']], [16, ['# Title\n```ts\nconst x', ' = 1;\n```\n[text](url)']]] as const) {
    let state: Uint8Array | undefined;
    for (const chunk of chunks) { const bytes = utf8(chunk), result = policy(request(language, bytes, state)); spans(result, bytes); state = result.slice(0, 608); }
    const wire = new DataView(state!.buffer); assert.equal(wire.getUint32(0, true) & 1, 0);
    if (language === 16) { assert.equal(state![25], 0); assert.equal(state![26], 0); }
    else { assert.equal(state![20], 0); assert.equal(state![21], 0); }
  }
});
test("code content refuses incomplete packets and invalid copied state", () => {
  const r = request(1, utf8("const x = 1;"));
  for (let size = 0; size < r.length; size++) assert.throws(() => policy(r.slice(0, size)));
  assert.throws(() => policy(new Uint8Array([...r, 0])));
  for (const [offset, value] of [[0, 19], [1, 1], [2, 17], [3, 1], [8, 1], [12, 1], [17, 1], [36, 33], [37, 33], [39, 2], [40, 1], [44, 1], [304, 2], [336, 2]]) {
    const bad = r.slice(); bad[offset] = value; assert.throws(() => policy(bad), `offset ${offset}`);
  }
});

function recipe(bytes: Uint8Array, facts: number, added: bigint[] = [], removed: bigint[] = []) {
  const r = new Uint8Array(48 + bytes.length + 8 * (added.length + removed.length)), wire = new DataView(r.buffer);
  r.set([20, 1, facts]); wire.setBigUint64(4, BigInt(bytes.length), true);
  wire.setBigUint64(16, BigInt(added.length), true); wire.setBigUint64(24, BigInt(removed.length), true); r.set(bytes, 48);
  [...added, ...removed].forEach((line, i) => wire.setBigUint64(48 + bytes.length + i * 8, line, true));
  return policy(r);
}
test("code recipes preserve terminal lines decoration bounds axes and every diff mask word", () => {
  for (const editable of [false, true]) for (const wrap of [false, true]) for (const height of [false, true]) {
    const result = recipe(utf8("x\n".repeat(128)), (editable ? 1 : 0) | (wrap ? 2 : 0) | 4 | (height ? 8 : 0), [1n, 32n, 33n, 64n, 65n, 96n, 97n, 128n, 128n], [2n, 127n]);
    assert.equal(result[0], 3); assert.equal(result[1], 3);
    assert.equal(result[2], editable ? 0 : wrap ? height ? 1 : 0 : height ? 3 : 2);
    assert.equal(result[3], editable ? 2 : 1);
    const wire = new DataView(result.buffer); assert.equal(wire.getBigUint64(8, true), editable ? 129n : 128n);
    for (let i = 0; i < 4; i++) assert.equal(wire.getUint32(16 + i * 4, true), 0x80000001);
    const over = recipe(utf8("x\n".repeat(129)), (editable ? 1 : 0) | 4, [1n], [2n]);
    assert.equal(over[0], editable ? 3 : 0);
    if (!editable) assert.ok(over.slice(16, 48).every(b => b === 0));
  }
  for (const line of [0n, 129n, 9007199254740993n, 18446744073709551615n]) assert.equal(recipe(utf8("x"), 0, [line])[0]! & 4, 4);
  assert.equal(recipe(utf8("x"), 0, [1n], [1n])[0]! & 4, 4);
});
test("code chunks retain whole source lines and every byte through malformed UTF-8", () => {
  for (const wrap of [false, true]) {
    const bytes = new Uint8Array([...utf8("x\n".repeat(200)), ...Array(200).fill(255), 10, ...utf8("tail\n")]);
    const r = new Uint8Array(16 + bytes.length), wire = new DataView(r.buffer); r.set([20, 2, wrap ? 1 : 0]); wire.setBigUint64(4, BigInt(bytes.length), true); r.set(bytes, 16);
    const result = policy(r), out = new DataView(result.buffer), count = Number(out.getBigUint64(0, true));
    assert.equal(count, Number(new DataView(recipe(bytes, wrap ? 2 : 0).buffer).getBigUint64(48, true)));
    let previous = 0;
    for (let i = 0; i < count; i++) {
      const end = Number(out.getBigUint64(8 + i * 8, true)); assert.ok(end > previous); assert.equal(bytes[end - 1], 10); previous = end;
    }
    assert.equal(previous, bytes.length);
  }
});
test("code span budgets preserve exact u64 usage and reserve every remaining chunk", () => {
  for (const used of [0n, 480n, 511n, 512n, 9007199254740993n, 18446744073709551551n]) {
    const r = new Uint8Array(32), wire = new DataView(r.buffer); r.set([20, 3]);
    wire.setBigUint64(8, used, true); wire.setBigUint64(16, 2n, true); wire.setBigUint64(24, 32n, true);
    const result = policy(r), out = new DataView(result.buffer), plain = used + 33n > 512n;
    assert.equal(out.getBigUint64(0, true), used + (plain ? 1n : 32n)); assert.equal(out.getBigUint64(8, true), 1n); assert.equal(result[16], plain ? 1 : 0);
    assert.ok(result.slice(17).every(b => b === 0));
  }
});
