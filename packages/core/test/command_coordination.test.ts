import assert from "node:assert/strict";
import test from "node:test";
import { nscvCommandCoordination as policy } from "../src/command_coordination.ts";

function packet(operation: number, words: readonly number[], tail: readonly number[] = []): Uint8Array {
  const input = new Uint8Array(4 + words.length * 4 + tail.length);
  input.set([69, operation, 0, 0]); const wire = new DataView(input.buffer);
  words.forEach((word, i) => wire.setUint32(4 + i * 4, word, true)); input.set(tail, 4 + words.length * 4); return input;
}
function text(operation: number, value: Uint8Array): Uint8Array {
  return packet(operation, [value.length], [...value.subarray(0, operation === 0 ? 128 : 64)]);
}
const bytes = (value: string) => new TextEncoder().encode(value);
function catalog(rows: readonly { id: Uint8Array; title: Uint8Array }[]): Uint8Array {
  const input = new Uint8Array(8 + rows.reduce((size, row) => size + 8 + Math.min(row.id.length, 128) + Math.min(row.title.length, 128), 0));
  input.set([69, 5, 0, 0]); const wire = new DataView(input.buffer); wire.setUint32(4, rows.length, true);
  let at = 8;
  for (const row of rows) {
    wire.setUint32(at, row.id.length, true); wire.setUint32(at + 4, row.title.length, true); at += 8;
    input.set(row.id.subarray(0, 128), at); at += Math.min(row.id.length, 128);
    input.set(row.title.subarray(0, 128), at); at += Math.min(row.title.length, 128);
  }
  return input;
}

test("command catalog admission preserves distinct name errors and duplicate precedence", () => {
  for (let byte = 0; byte < 256; byte++) {
    const id = Uint8Array.of(byte), invalid = [0, 46, 47, 92].includes(byte) ? 2 : [9, 10, 13].includes(byte) ? 1 : 0;
    assert.equal(policy(catalog([{ id, title: bytes("") }]))[0], invalid);
    assert.equal(policy(catalog([{ id: bytes("app.sync"), title: Uint8Array.of(byte) }]))[0], byte === 0 ? 2 : 0);
  }
  for (const [id, error] of [["", 1], ["..", 2], ["x".repeat(129), 1], ["a\n/b", 2], ["a\n\0", 2], ["a\tb", 1], ["a..b", 0]] as const) assert.equal(policy(catalog([{ id: bytes(id), title: bytes("") }]))[0], error);
  const rows = [{ id: bytes("app.sync"), title: bytes("Sync") }, { id: bytes("app.sync"), title: bytes("Duplicate") }];
  assert.equal(policy(catalog(rows))[0], 3);
  rows[1]!.title = bytes("\0"); assert.equal(policy(catalog(rows))[0], 2);
  rows[1]!.title = bytes("x".repeat(129)); assert.equal(policy(catalog(rows))[0], 2);
  rows[0]!.title = bytes("\0"); rows[1]!.id = bytes(""); assert.equal(policy(catalog(rows))[0], 2);
});

test("command catalogs accept complete maximum payloads and reject excess rows first", () => {
  const rows = Array.from({ length: 256 }, (_, slot) => ({ id: bytes(slot.toString(16).padStart(4, "0").padEnd(128, "x")), title: bytes("t".repeat(128)) }));
  assert.deepEqual([...policy(catalog(rows))], [0, 0, 0, 0]);
  assert.deepEqual([...policy(packet(5, [257]))], [1, 0, 0, 0]);
  assert.deepEqual([...policy(packet(5, [0xffffffff]))], [1, 0, 0, 0]);
});

test("command names retain native raw byte validation and exact updater spelling", () => {
  for (let byte = 0; byte < 256; byte++) {
    const input = Uint8Array.of(byte), invalid = [0, 9, 10, 13, 46, 47, 92].includes(byte);
    assert.deepEqual(policy(text(0, input)), Uint8Array.of(invalid ? 1 : 0, 0, 0, 0));
  }
  for (const value of ["", ".", "..", "a/b", "a\\b", "a\tb", "a\nb", "a\rb", "x".repeat(129)]) assert.equal(policy(text(0, bytes(value)))[0], 1);
  for (const value of ["a..b", " ", "x".repeat(128), "app.check-for-updates "]) assert.equal(policy(text(0, bytes(value)))[0], 0);
  assert.equal(policy(text(0, bytes("app.check-for-updates")))[0], 2);
  assert.equal(policy(text(4, bytes("main")))[0], 1);
  for (const value of ["Main", "main\0", "", "x".repeat(65)]) assert.equal(policy(text(4, bytes(value)))[0], 0);
});

test("status admission selects retained identities before the count guard and first free slot", () => {
  for (const admit of [0, 1]) for (const count of [0, 8]) {
    const input = packet(3, [admit, 0xffffffff, count], Array(64).fill(0));
    let result = new DataView(policy(input).buffer);
    assert.equal(result.getUint32(0, true), admit ? count < 8 ? 2 : 3 : 0);
    assert.equal(result.getUint32(4, true), admit && count < 8 ? 0 : 0xffffffff);
    input[16 + 5 * 8] = 1; new DataView(input.buffer).setUint32(20 + 5 * 8, 0xffffffff, true);
    result = new DataView(policy(input).buffer);
    assert.equal(result.getUint32(0, true), 1); assert.equal(result.getUint32(4, true), 5);
  }
});

test("menu lookup preserves independent first-match action and command rules", () => {
  const input = packet(2, [2, 7], [7, 0, 0, 0, 0, 1, 0, 0, 7, 0, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0, 14, 0, 0, 0]);
  const result = policy(input), wire = new DataView(result.buffer);
  assert.deepEqual([...result.subarray(0, 4)], [1, 0, 0, 0]);
  assert.equal(wire.getUint32(4, true), 0); assert.equal(wire.getUint32(8, true), 0); // even an empty segment command wins
  input[16] = 8; // a nonempty row command precedes its same-id segment
  assert.equal(new DataView(policy(input).buffer).getUint32(8, true), 0xffffffff);
  new DataView(input.buffer).setUint32(8, 8, true);
  assert.deepEqual([...policy(input)], [0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0]);
});

test("toolbar ancestry compares opaque window identities without numeric conversion", () => {
  const input = packet(1, [2, 1, 0x200000, 1], [99, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 99, 116, 3, 1, 0, 0, 1, 0, 0, 0, 0, 0, 32, 0, 0, 0, 0, 0, 116]);
  input[21] = 5; // open child with a parent
  assert.equal(policy(input)[0], 3);
  input[25] = 0; // adjacent nonmatching identity above 2^53
  assert.equal(policy(input)[0], 6);
  input[25] = 1; input[38] = 99; // cycle, bounded like the native walk
  assert.equal(policy(input)[0], 6);
});

test("command packets reject every truncation, tail and invalid reserved field", () => {
  const inputs = [text(0, bytes("app.sync")), text(4, bytes("main")), packet(1, [0, 1, 0, 0]), packet(2, [0, 1]), packet(3, [1, 1, 0], Array(64).fill(0)), catalog([{ id: bytes("app.sync"), title: bytes("Sync") }]), packet(5, [0]), packet(5, [257])];
  for (const input of inputs) {
    for (let length = 0; length < input.length; length++) assert.throws(() => policy(input.subarray(0, length)));
    const extra = new Uint8Array(input.length + 1); extra.set(input); assert.throws(() => policy(extra));
    const padded = new Uint8Array(input.length + 8); padded.set(input, 4); assert.deepEqual(policy(padded.subarray(4, 4 + input.length)), policy(input));
    for (const at of [2, 3]) { const bad = input.slice(); bad[at] = 1; assert.throws(() => policy(bad)); }
  }
});
