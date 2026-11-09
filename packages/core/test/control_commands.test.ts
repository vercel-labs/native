import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/control_commands.ts", import.meta.url), "utf8");
const { nscvControlCommands: program } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvControlCommands};").toString("base64")}`);
function packet(family: number, flags = 0, value = 0, stroke = 0): Uint8Array {
  const b = new Uint8Array(32), w = new DataView(b.buffer); b.set([45, 1, family, 0]);
  w.setUint32(4, flags, true); w.setFloat32(8, value, true); w.setFloat32(12, stroke, true); return b;
}
function commands(b: Uint8Array): number[][] {
  const r = program(b), w = new DataView(r.buffer, r.byteOffset, r.byteLength);
  assert.equal(r.length, 200); assert.equal(w.getUint32(0, true), 1);
  const count = w.getUint32(4, true); assert.ok(count <= 16); assert.ok(r.subarray(8 + count * 12).every(v => v === 0));
  return Array.from({ length: count }, (_, i) => [0, 4, 8].map(j => w.getUint32(8 + i * 12 + j, true)));
}
test("button seams preserve fill clip stroke unclip focus icon and label order", () => {
  assert.deepEqual(commands(packet(0, 1 | 2 | 8 | 131072, 0, 1)), [[0,1,0],[12,0,0],[1,2,0],[13,0,0],[2,3,0],[3,5,0],[4,4,1]]);
  assert.deepEqual(commands(packet(0, 8, 0, 0)), [[0,1,0],[3,5,0]]);
  assert.deepEqual(commands(packet(0)), [[0,1,0],[4,4,0]]);
  assert.deepEqual(commands(packet(1, 1 | 2)), [[0,1,0],[2,15,0],[4,3,0]]);
});
test("editing overlays stay inside content clips while search chrome stays outside", () => {
  const flags = 1 | 2 | 128 | 256 | 512 | 1024 | 2048;
  assert.deepEqual(commands(packet(3, flags)), [[0,1,0],[1,2,0],[2,7,0],[9,16,0],[5,3,1037],[4,4,0],[6,0,4],[7,5,1034],[10,0,0]]);
  assert.deepEqual(commands(packet(5, flags | 16384 | 32768 | 262144 | 524288)), [[0,1,0],[1,2,0],[2,14,0],[3,3,2],[9,7,0],[5,8,256],[4,9,0],[6,0,1],[7,10,256],[10,0,0],[3,12,4],[3,15,6]]);
  assert.deepEqual(commands(packet(3, 1 | 4 | 256)), [[0,1,0],[1,2,0],[2,7,0],[4,4,2],[8,6,0]]);
});
test("menu attention and committed marks remain independent and never add a focus ring", () => {
  const b = packet(7, 1 | 2 | 8 | 16 | 65536); new DataView(b.buffer).setFloat32(16, 0.5, true);
  assert.deepEqual(commands(b), [[0,1,0],[3,4,0],[4,3,1],[3,12,5]]);
  new DataView(b.buffer).setFloat32(16, 0, true);
  assert.deepEqual(commands(b), [[3,4,0],[4,3,1],[3,12,5]]);
});
test("selection numeric thresholds preserve overrides and exceptional float behavior", () => {
  for (const family of [12,13,14]) for (const value of [0,0.49999997,0.5,1,NaN,Infinity,-Infinity]) for (const override of [false,true]) {
    const p = commands(packet(family, 1 | 2 | (override ? 16 : 0), value));
    const selected = override || Math.fround(value) >= 0.5;
    if (family < 14) assert.equal(p.some(c => c[0] === 11), selected);
    else assert.equal(p.find(c => c[0] === 0 && c[1] === 3)?.[2], selected ? 5 : 4);
  }
  assert.deepEqual(commands(packet(15, 0)), [[0,1,0],[0,3,4],[1,4,1]]);
  assert.deepEqual(commands(packet(16, 32 | 8192)), [[0,1,0],[0,2,3]]);
});
test("tab pill and underline registers preserve icon and empty-label contracts", () => {
  assert.deepEqual(commands(packet(11, 16)), [[0,1,1],[1,2,0],[4,3,0]]);
  assert.deepEqual(commands(packet(11, 16 | 4096 | 8192 | 8)), [[0,2,3],[3,5,0]]);
  assert.deepEqual(commands(packet(11, 32 | 4096 | 8 | 2)), [[0,1,0],[3,5,0],[4,3,1]]);
});
test("command packets are bounded and copied across all families and editing observations", () => {
  for (let family = 0; family <= 16; family++) for (let flags = 0; flags < 2048; flags++) {
    if (flags & 512 && !(flags & 256)) continue;
    const b = packet(family, flags, 0.5, 1), saved = b.slice(), r = program(b), copy = r.slice();
    commands(b); assert.deepEqual(b, saved); b.fill(255); assert.deepEqual(r, copy);
  }
  for (const at of [0,1,2,3,6,7]) { const b=packet(3);b[at]=255;assert.throws(()=>program(b),/invalid/); }
  assert.throws(()=>program(packet(3,512)),/editing/);
  assert.throws(()=>program(packet(3,2048)),/editing/);
  assert.throws(()=>program(new Uint8Array(31)),/header/);
});
