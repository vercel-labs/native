import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["view_components.ts", "input_composition.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n")
  .replace('"@native-sdk/core/text"', JSON.stringify(new URL("../sdk/text.ts", import.meta.url).href));
const { nscvInputComposition: plan, native_text_policy: dispatch } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvInputComposition};").toString("base64")}`);
interface Input {
  mode: number; kind?: number; flags?: number; modifiers?: number; windows?: boolean;
  grace?: number; claim?: number; owner?: bigint; focused?: bigint; routed?: bigint;
  window?: bigint; origin?: bigint; preedit?: bigint; key?: string; text?: Uint8Array;
  label?: Uint8Array; originLabel?: Uint8Array;
  ownerKind?: number; focusedKind?: number;
}
const bytes = (value: string): Uint8Array => new TextEncoder().encode(value);
function request(input: Input): Uint8Array {
  const result = new Uint8Array(256), w = new DataView(result.buffer);
  const key = bytes(input.key ?? ""), text = input.text ?? new Uint8Array();
  const label = input.label ?? bytes("canvas"), originLabel = input.originLabel ?? bytes("canvas");
  result.set([78, 1, input.mode, input.kind ?? 8, input.modifiers ?? 0, input.windows ? 1 : 0, input.grace ?? 0, input.claim ?? 0]);
  w.setUint32(8, input.flags ?? 0, true);
  w.setUint32(12, input.ownerKind ?? ((input.flags ?? 0) & 2 ? 35 : 63), true);
  w.setUint32(240, input.focusedKind ?? 35, true);
  const values = [BigInt(key.length), BigInt(text.length), input.window ?? 1n, input.origin ?? 1n, input.owner ?? 0n, input.focused ?? 0n, input.routed ?? 0n, input.preedit ?? 0n, BigInt(label.length), BigInt(originLabel.length)];
  values.forEach((value, index) => w.setBigUint64(16 + index * 8, value, true));
  result.set(key.subarray(0, 8), 96); result.set(text.subarray(0, 2), 104);
  result.set(label.subarray(0, 64), 112); result.set(originLabel.subarray(0, 64), 176);
  return result;
}
function checked(input: Input): DataView {
  const req = request(input), saved = req.slice(), backing = new Uint8Array(req.length + 19);
  backing.set(req, 7); const result = plan(backing.subarray(7, 7 + req.length));
  assert.deepEqual(req, saved); assert.deepEqual(result, dispatch(req));
  const copy = result.slice(); backing.fill(255); req.fill(255); assert.deepEqual(result, copy);
  assert.equal(result.length, 64); assert.deepEqual(result.slice(56), new Uint8Array(8));
  return new DataView(result.buffer, result.byteOffset, result.byteLength);
}
test("input normalization preserves every OS input kind and modifier including Windows AltGr", () => {
  for (let kind = 0; kind < 15; kind++) for (let modifiers = 0; modifiers < 32; modifiers++) for (const windows of [false, true]) for (const text of [new Uint8Array(), bytes("\0é\ufffd")]) {
    const out = checked({ mode: 0, kind, modifiers, windows, text });
    const command = !(windows && (modifiers & 6) === 6) && (modifiers & 26) !== 0;
    assert.equal(out.getUint32(4, true), kind < 6 ? kind + 1 : 0);
    assert.equal(out.getUint32(8, true), kind === 6 ? 1 : kind === 7 ? 2 : 0);
    const edit = kind === 9 ? 2 : kind === 10 ? 3 : kind === 11 ? 4 : (kind === 6 || kind === 8) && text.length > 0 && !command ? 1 : 0;
    assert.equal(out.getUint32(12, true), edit);
    assert.equal(out.getUint32(16, true), (modifiers & 7) | ((modifiers & 24) !== 0 ? 8 : 0));
    assert.equal(out.getUint32(20, true), command ? 1 : 0);
  }
  for (const key of ["Escape", "ESC", "escape\0", "escapex", "esc", "é", "", "very-long-key-name"]) assert.equal((checked({ mode: 0, key }).getUint32(20, true) & 2) !== 0, ["escape", "esc"].includes(key.toLowerCase()));
});
test("cancel grace and orphaned composition retain exact owner identities and event adjacency", () => {
  const owner = 0xfedcba9876543210n;
  for (let kind = 0; kind < 15; kind++) for (let grace = 0; grace < 3; grace++) for (const alive of [false, true]) for (const present of [false, true]) {
    const out = checked({ mode: 2, kind, grace, owner: present ? owner : 0n, flags: 1 | (alive ? 2 : 0) });
    let retainedOwner = present ? owner : 0n, nextGrace = grace, resolved = 0;
    if (grace !== 0) {
      nextGrace = 0;
      if (kind === 8) {
        resolved = grace;
        if (grace === 1 && (!present || !alive)) { retainedOwner = 0n; resolved = 2; }
      } else if (grace === 1) retainedOwner = 0n;
    }
    const orphan = kind >= 9 && kind <= 11 && retainedOwner !== 0n && !alive;
    if (orphan && kind !== 9) { retainedOwner = 0n; if (kind === 11) nextGrace = 2; }
    const decisions = (orphan ? 16 : 0) | (resolved === 2 ? 32 : 0) | (orphan || resolved === 2 ? 128 : 0);
    assert.equal(out.getBigUint64(24, true), retainedOwner); assert.equal(out.getUint32(32, true), nextGrace); assert.equal(out.getUint32(20, true), decisions);
  }
  const duplicateCancel = checked({ mode: 3, kind: 11 }); assert.equal(duplicateCancel.getUint32(32, true), 0);
  assert.equal(checked({ mode: 3, kind: 9, routed: owner }).getBigUint64(24, true), owner);
  assert.equal(checked({ mode: 8, kind: 8, flags: 2, owner, focused: 3n }).getBigUint64(48, true), owner);
  assert.equal(checked({ mode: 8, kind: 6, flags: 2, owner, focused: 3n }).getBigUint64(48, true), 3n);
});
test("target-less composition and converted commits are scoped to exact surface identity", () => {
  for (const window of [1n, 0x100000000n, 9007199254740993n, 0xffffffffffffffffn]) for (const origin of [window, window ^ 1n]) for (const label of [bytes("canvas"), bytes("Canvas"), bytes("canvas\0"), new Uint8Array(65)]) {
    const same = window === origin && Buffer.from(label).equals(Buffer.from(bytes("canvas")));
    const facts = { window, origin, label, preedit: 1n, flags: 64 };
    const resolve = checked({ ...facts, mode: 2, kind: 8 });
    assert.equal((resolve.getUint32(20, true) & 64) !== 0, same);
    assert.equal((resolve.getUint32(20, true) & 2048) !== 0, true);
    assert.equal((checked({ ...facts, mode: 1, kind: 6 }).getUint32(20, true) & 4) !== 0, same);
    assert.equal(checked({ ...facts, mode: 5, kind: 10 }).getUint32(40, true), same ? 2 : 0);
    assert.equal((checked({ ...facts, mode: 7 }).getUint32(20, true) & 512) !== 0, same);
  }
  assert.equal(checked({ mode: 5, kind: 11, preedit: 9n }).getUint32(20, true), 512 | 16384);
  assert.equal(checked({ mode: 6, flags: 16 }).getUint32(20, true), 1024);
  assert.equal(checked({ mode: 6 }).getUint32(20, true), 512);
});
test("split activation claims only their own literal and paste release retires one physical lifetime", () => {
  for (let claim = 0; claim < 3; claim++) for (const text of [bytes(" "), bytes("\r"), bytes("\n"), bytes("x"), bytes(" \0"), new Uint8Array()]) {
    const out = checked({ mode: 4, kind: 8, claim, text });
    const matches = claim === 1 ? Buffer.from(text).equals(Buffer.from(" ")) : claim === 2 && (Buffer.from(text).equals(Buffer.from("\r")) || Buffer.from(text).equals(Buffer.from("\n")));
    assert.equal(out.getUint32(20, true), matches ? 256 : 0); assert.equal(out.getUint32(36, true), 0);
  }
  for (const key of ["Space", "ENTER", "v", "arrowleft"]) {
    const out = checked({ mode: 4, kind: 6, flags: 16, key });
    assert.equal(out.getUint32(36, true), key === "Space" ? 1 : key === "ENTER" ? 2 : 0);
  }
  assert.equal(checked({ mode: 4, kind: 6, flags: 24, key: "space" }).getUint32(36, true), 0);
  assert.equal(checked({ mode: 9, kind: 7, flags: 64, key: "V" }).getUint32(20, true), 8192 | 2048);
  assert.equal(checked({ mode: 9, kind: 6, flags: 64, key: "V" }).getUint32(20, true), 2048);
});
test("composition delivery uses post-callback focus observations and preserves IME resolution precedence", () => {
  for (let flags = 0; flags < 128; flags++) {
    assert.equal(checked({ mode: 11, flags }).getUint32(20, true), (flags & 33) === 33 && ((flags & 16) === 0 || (flags & 64) !== 0) ? 4096 : 0);
    assert.equal(checked({ mode: 13, flags }).getUint32(20, true), (flags & 33) === 33 && (flags & 8) === 0 ? 4096 : 0);
  }
  const owner = 9007199254740993n;
  assert.equal(checked({ mode: 10, flags: 16, kind: 6, owner, routed: owner }).getBigUint64(24, true), 0n);
  assert.equal(checked({ mode: 10, flags: 16, kind: 6, owner, routed: owner - 1n }).getBigUint64(24, true), owner);
});
test("composition rejects incomplete packets and reserved fields without borrowing request storage", () => {
  for (let mode = 0; mode <= 13; mode++) {
    const req = request({ mode });
    for (let len = 0; len < req.length; len++) assert.throws(() => plan(req.subarray(0, len)));
    for (const at of [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 106, 107, 108, 240, 244, 248, 252]) { const bad = req.slice(); bad[at] = 255; assert.throws(() => plan(bad)); }
    const extra = new Uint8Array(257); extra.set(req); assert.throws(() => plan(extra));
  }
});
