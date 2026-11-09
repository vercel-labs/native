import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = readFileSync(new URL("../src/markup_text.ts", import.meta.url), "utf8");
const { nscvMarkupText: program } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvMarkupText };").toString("base64")}`);
function request(mode: number, bytes: Uint8Array = new Uint8Array(0)): Uint8Array {
  const b = new Uint8Array(32 + bytes.length); b.set([103, 1, mode]);
  new DataView(b.buffer).setUint16(4, bytes.length, true); b.set(bytes, 32); return b;
}
test("markup text preserves every octet and the exact four whitespace bytes", () => {
  const bytes = Uint8Array.from({ length: 256 }, (_, i) => i);
  for (const mode of [0, 1]) {
    const expected = bytes.map(b => mode === 0 && b >= 97 && b <= 122 ? b - 32 : mode === 1 && b >= 65 && b <= 90 ? b + 32 : b);
    assert.deepEqual(program(request(mode, bytes)).subarray(16), expected);
  }
  for (let byte = 0; byte < 256; byte++) {
    const b = request(2, Uint8Array.of(byte, 65, byte)), p = program(b), w = new DataView(p.buffer);
    const whitespace = [32, 9, 10, 13].includes(byte);
    assert.equal(w.getUint16(4, true), whitespace ? 1 : 0);
    assert.equal(w.getUint16(6, true), whitespace ? 2 : 3);
  }
});
test("markup text calendar preserves Gregorian boundaries without a host Date", () => {
  for (const days of [-719163, -719162, -719161, -25509, -1, 0, 1, 11016, 11017, 146156, 2932895, 2932896, 2932897]) {
    for (const seconds of [0, 59, 60, 3599, 3600, 86399]) for (const mode of [5, 6, 7]) {
      const b = request(mode), w = new DataView(b.buffer); w.setFloat64(16, days, true); w.setUint32(24, seconds, true);
      const p = program(b), rejected = days < -719162 || days > 2932896;
      assert.equal(p[3], rejected ? 1 : 0);
      if (!rejected) {
        const iso = new Date((days * 86400 + seconds) * 1000).toISOString();
        const expected = mode === 5 ? iso.slice(0, 10) : mode === 6 ? iso.slice(11, 16) : iso.slice(0, 10) + " " + iso.slice(11, 16);
        assert.equal(new TextDecoder().decode(p.subarray(16)), expected);
      }
    }
  }
});
test("markup text rejects truncated or malformed transports and retains output ownership", () => {
  const b = request(0, Uint8Array.of(97, 255, 0)), p = program(b), copy = p.slice();
  for (let n = 0; n < b.length; n++) assert.throws(() => program(b.subarray(0, n)));
  for (const at of [0, 1, 2, 3, 4, 5, 6, 8, 12, 16, 20, 24, 28]) {
    const bad = b.slice(); bad[at] = 255; assert.throws(() => program(bad));
  }
  assert.throws(() => program(request(0, new Uint8Array(257))));
  for (const text of ["", "-", "a", "1 2", "1.5", "123456789012345678901"]) assert.throws(() => program(request(3, new TextEncoder().encode(text))));
  const invalidDate = request(5); new DataView(invalidDate.buffer).setFloat64(16, NaN, true); assert.throws(() => program(invalidDate));
  new DataView(invalidDate.buffer).setFloat64(16, 0.5, true); assert.throws(() => program(invalidDate));
  new DataView(invalidDate.buffer).setFloat64(16, 0, true); new DataView(invalidDate.buffer).setUint32(24, 86400, true); assert.throws(() => program(invalidDate));
  b.fill(255); program(request(1, Uint8Array.of(65))); assert.deepEqual(p, copy);
});
