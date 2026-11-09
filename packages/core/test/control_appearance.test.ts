import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/control_appearance.ts", import.meta.url), "utf8");
const { nscvControlAppearance: policy } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvControlAppearance };").toString("base64")}`);
function context(op: number, variant = 0, flags = 0): Uint8Array {
  const request = new Uint8Array(496); request.set([16, op, 0, 31, variant, 0, flags, 0]);
  const w = new DataView(request.buffer);
  for (let i = 0; i < 8; i++) for (let j = 0; j < 4; j++) w.setFloat32(272 + i * 16 + j * 4, j === 3 ? 1 : i / 8, true);
  w.setFloat32(400, 0.5, true); w.setFloat32(404, 0.9, true); w.setFloat32(408, 0.8, true); w.setFloat32(412, 0.9, true);
  w.setFloat32(416, 0.1, true); w.setFloat32(420, 0.15, true); w.setFloat32(424, 0.2, true); w.setFloat32(428, 0.1, true); w.setFloat32(432, 0.2, true);
  return request;
}
const float = (bytes: Uint8Array, at = 0) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getFloat32(at, true);
test("control feedback distinguishes primary identity from pointer feedback", () => {
  assert.equal(float(policy(context(2, 1, 4)), 12), 1);
  assert.equal(float(policy(context(2, 1, 8)), 12), Math.fround(0.9));
  assert.equal(float(policy(context(2, 1, 2)), 12), Math.fround(0.8));
  assert.equal(float(policy(context(2, 1, 24)), 12), 1);
});
test("authored transparent colors retain exact channel bytes", () => {
  const request = context(28), w = new DataView(request.buffer); w.setUint32(164, 1, true);
  const bits = [0x80000000, 0x7fc00037, 0x3eaaaaab, 0]; bits.forEach((v, i) => w.setUint32(168 + i * 4, v, true));
  assert.deepEqual(policy(request), request.slice(168, 184));
  const saved = request.slice(), owned = policy(request); request.fill(255); assert.deepEqual(owned, saved.slice(168, 184));
});
test("control fallback keeps native omitted active foreground and optional zero geometry", () => {
  const request = new Uint8Array(320); request.set([16, 1]); const w = new DataView(request.buffer);
  w.setUint32(8, 128 | 512, true); w.setUint32(164, 1 | 128 | 1024, true); w.setFloat32(164 + 152, 3, true);
  const result = policy(request), out = new DataView(result.buffer);
  assert.equal(out.getUint32(0, true), 1 | 512 | 1024); assert.equal(float(result, 148), 0); assert.equal(float(result, 152), 3);
});
test("detached button groups require both membership and theme register", () => {
  for (let flags = 0; flags < 4; flags++) { const request = context(31); request[7] = flags; assert.equal(policy(request)[0], flags === 3 ? 1 : 0); }
});
test("quiet navigation selection and toggle selection use distinct background ladders", () => {
  const request = context(2, 4, 4); assert.equal(float(policy(request), 12), 0);
  request[3] = 32; assert.equal(float(policy(request), 12), 1); assert.equal(float(policy(request)), Math.fround(1 / 8));
});
test("radius resolution retains authored zero and size stepping", () => {
  const request = context(19), w = new DataView(request.buffer); request[5] = 2; w.setFloat32(488, 8, true);
  assert.equal(float(policy(request)), 10); w.setUint32(164, 64, true); assert.equal(float(policy(request)), 0);
  request[1] = 22; request[5] = 1; w.setFloat32(488, -3, true); assert.equal(float(policy(request)), 0);
});
test("appearance refuses truncated packets, illegal enums and presence masks", () => {
  for (let length = 0; length < 496; length++) if (length !== 8 && length !== 320) assert.throws(() => policy(context(2).slice(0, length)));
  for (const [at, value] of [[0, 17], [1, 39], [3, 63], [4, 6], [5, 6], [6, 32], [7, 4]]) { const request = context(2); request[at!] = value!; assert.throws(() => policy(request)); }
  const request = context(2); new DataView(request.buffer).setUint32(8, 2048, true); assert.throws(() => policy(request));
});
