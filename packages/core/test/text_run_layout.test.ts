import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "text_run_layout"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvTextRunLayout: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvTextRunLayout};").toString("base64")}`);
function packet(text: string, width = 20, wrap = 1, mode = 0): Uint8Array {
  const raw = new TextEncoder().encode(text), at = 512 + raw.length * 4;
  const bytes = new Uint8Array(at + raw.length), w = new DataView(bytes.buffer);
  bytes.set([54, 1, mode, 0, wrap, 0, 0, 0]);
  for (const [p, value] of [[8, at], [12, bytes.length], [36, raw.length]]) w.setUint32(p!, value!, true);
  w.setFloat32(16, 10, true); w.setFloat32(20, 3, true); w.setFloat32(24, 10, true); w.setFloat32(28, width, true);
  bytes.set(raw, at); return bytes;
}
function execute(input: Uint8Array, batch = false): { result: DataView; calls: number[][]; bytes: Uint8Array } {
  const calls: number[][] = [];
  let bytes = input;
  for (let i = 0; i < 10000; i++) {
    const before = bytes.slice(), result = plan(bytes); assert.deepEqual(bytes, before);
    assert.equal(result.length, 512);
    const w = new DataView(result.buffer);
    if (result[3] === 2) return { result: w, calls, bytes: result };
    assert.equal(result[3], 1);
    const kind = w.getUint32(100, true), start = w.getUint32(104, true), end = w.getUint32(108, true);
    calls.push([kind, start, end]);
    const continuation = bytes.slice(); continuation.set(result);
    const state = new DataView(continuation.buffer);
    if (kind === 3 || kind === 4) {
      state.setUint32(120, batch ? 1 : 0, true);
      if (batch) for (let p = 0; p < state.getUint32(36, true); p++) state.setFloat32(512 + p * 4, 5, true);
    } else state.setFloat32(116, kind === 5 ? 5 : (end - start) * 5, true);
    state.setUint32(112, 1, true); bytes = continuation;
  }
  throw new Error("text continuation did not finish");
}
test("ordinary text retains hard-line whitespace and exact soft-wrap cursors", () => {
  const { result: r } = execute(packet("abc de"));
  assert.equal(r.getUint32(320, true), 0); assert.equal(r.getUint32(324, true), 3);
  assert.equal(r.getUint32(288, true), 4); assert.equal(r.getUint32(292, true), 1); assert.equal(r.getUint32(296, true), 0);
  assert.equal(r.getFloat32(344, true), 15);
  const next = packet("a\n  b", 50); new DataView(next.buffer).setUint32(44, 2, true);
  const last = execute(next).result;
  assert.equal(last.getUint32(320, true), 2); assert.equal(last.getUint32(324, true), 3);
  assert.equal(last.getUint32(288, true), 2); assert.equal(last.getUint32(296, true), 1);
});
test("elision preserves hidden logical ranges and trims only soft break bytes", () => {
  const b = packet("ab cd", 20, 0); b[5] = 1;
  const { result: r } = execute(b);
  assert.equal(r.getUint32(324, true), 5); assert.equal(r.getUint32(356, true), 1); assert.equal(r.getUint32(360, true), 2);
  assert.equal(r.getFloat32(372, true), 5); assert.equal(r.getFloat32(344, true), 15); assert.equal(r.getFloat32(336, true), 5.5);
  const cr = execute(packet("ab\rcd", 20, 0)).result;
  assert.equal(cr.getUint32(360, true), 3);
  const tiny = execute(packet("abc", 2, 0)).result;
  assert.equal(tiny.getUint32(360, true), 0); assert.equal(tiny.getFloat32(372, true), 0); assert.equal(tiny.getFloat32(344, true), 0);
});
test("batched line decisions use owned copied advances", () => {
  const b = packet("abc de"); b[7] = 3;
  const { result: r, calls } = execute(b, true);
  assert.equal(r.getUint32(324, true), 3);
  assert.deepEqual(calls, [[3, 0, 6], [4, 0, 6]]);
  assert.equal(r.getFloat32(344, true), 15);
});
test("standalone line ends and empty runs retain iterator state", () => {
  const r = execute(packet("abc de", 20, 1, 1)).result;
  assert.equal(r.getUint32(308, true), 3);
  const empty = execute(packet("")).result;
  assert.equal(empty.getUint32(300, true), 1); assert.equal(empty.getUint32(296, true), 1); assert.equal(empty.getUint32(288, true), 0);
});
test("long text continuations retain caller facts and return fixed owned state", () => {
  const b = packet("abcdef ".repeat(400), 25); b[7] = 3;
  const before = b.slice(), { result: r, bytes } = execute(b, true);
  assert.deepEqual(b, before); assert.equal(bytes.length, 512);
  assert.equal(r.getUint32(324, true), 5);
  const saved = bytes.slice(); b.fill(0);
  assert.deepEqual(bytes, saved);
});
test("text packets reject malformed headers, mutable initial state and missing replies", () => {
  assert.throws(() => plan(new Uint8Array(511)), /invalid/);
  for (const [at, value] of [[0, 53], [1, 2], [2, 9], [3, 2], [4, 3], [5, 3], [6, 2], [7, 4], [8, 0], [12, 0], [52, 2], [80, 1], [96, 1], [356, 2], [376, 1]]) {
    const b = packet("abc"); b[at!] = value!; assert.throws(() => plan(b), /invalid/, String(at));
  }
  const q = packet("abc"); q.set(plan(q)); assert.throws(() => plan(q), /reply/);
  for (const [at, value] of [[96, 40], [100, 0], [100, 2], [104, 99], [108, 99], [120, 2]]) {
    const b = q.slice(), w = new DataView(b.buffer); w.setUint32(112, 1, true); w.setUint32(at!, value!, true);
    assert.throws(() => plan(b), /invalid/, String(at));
  }
});

test("every reserved storage byte remains rejected independently", () => {
  for (let at = 80; at < 320; at++) {
    const input = packet("abc", 20); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
  for (let at = 320; at < 376; at++) {
    const input = packet("abc", 20); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
  for (let at = 376; at < 512; at++) {
    const input = packet("abc", 20); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
});
