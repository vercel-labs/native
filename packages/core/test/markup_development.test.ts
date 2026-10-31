import assert from "node:assert/strict";
import { test } from "node:test";
import { markupDevelopmentPolicy } from "../src/markup_development.ts";

class Request {
  bytes: number[];
  constructor(stage: number) { this.bytes = [32, 1, stage, 0]; }
  byte(n: number): this { this.bytes.push(n); return this; }
  word(n: number): this { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); this.bytes.push(...b); return this; }
  wide(lo: number, hi = 0): this { return this.word(lo).word(hi); }
  blob(value: string | Uint8Array): this { const b = typeof value === "string" ? new TextEncoder().encode(value) : value; this.word(b.length); this.bytes.push(...b); return this; }
  run(): Uint8Array { const b = new Uint8Array(this.bytes), saved = b.slice(), out = markupDevelopmentPolicy(b); assert.deepEqual(b, saved); return out; }
}
const words = (b: Uint8Array): number[] => Array.from({ length: b.length / 4 }, (_, i) => new DataView(b.buffer).getUint32(i * 4, true));
test("markup watch keeps the root baseline, complete fragment budget and shared timer admission", () => {
  assert.deepEqual(words(new Request(0).byte(1).byte(1).byte(1).byte(0).word(0).word(16).run()), [1, 1, 0, 0]);
  assert.deepEqual(words(new Request(0).byte(0).byte(0).byte(0).byte(1).word(17).word(16).run()), [0, 1, 16, 1]);
  assert.deepEqual(words(new Request(0).byte(0).byte(1).byte(1).byte(0).word(17).word(16).run()), [0, 0, 0, 0]);
});
test("markup reload preserves failure observation, last-good recovery, arena adoption and compiled reversion order", () => {
  const p = (kind: number, changed: number, failed: number, diagnostic: number, baseline: number, installed: number) => Array.from(new Request(1).byte(kind).byte(changed).byte(failed).byte(diagnostic).byte(baseline).byte(installed).run());
  assert.deepEqual(p(0, 1, 1, 1, 0, 0).slice(0, 3), [2, 0, 0]);
  assert.deepEqual(p(1, 1, 1, 1, 0, 1).slice(0, 3), [1, 2, 0]);
  assert.deepEqual(p(1, 1, 0, 0, 0, 1).slice(0, 5), [3, 4, 5, 6, 0]);
  assert.deepEqual(p(2, 1, 0, 0, 1, 1).slice(0, 6), [1, 7, 9, 10, 11, 0]);
  assert.deepEqual(p(2, 1, 0, 0, 0, 1).slice(0, 7), [1, 3, 8, 9, 10, 11, 0]);
  assert.deepEqual(p(2, 0, 1, 1, 0, 1), Array(12).fill(0));
});
test("markup diagnostics compare complete borrowed bytes and copy bounded retained extents", () => {
  const p = new Request(2).byte(1).byte(1).byte(1).blob("bad").blob("bad").blob("p").blob("p").word(512).word(240);
  assert.deepEqual(words(p.run()), [0, 3, 1]);
  assert.deepEqual(words(new Request(2).byte(1).byte(1).byte(1).blob("bad").blob("bad\0").blob("p").blob("p").word(2).word(0).run()), [1, 2, 0]);
  assert.deepEqual(words(new Request(3).blob("src").blob("src/parts/x.native").run()), [4]);
  assert.deepEqual(words(new Request(3).blob("src").blob("src-other/x.native").run()), [0]);
  assert.deepEqual(words(new Request(3).blob("").blob("/x.native").run()), [0]);
});
test("complete provenance retains exact identity words, clamps spans and sanitizes raw keys", () => {
  const r = new Request(6).word(0).word(2).blob("").blob("parts.native").wide(0xffffffff, 0xffffffff).blob("parts.native");
  r.wide(9, 1).wide(0xffffffff).wide(2).wide(3).word(1).blob("").wide(4).wide(5).wide(6).wide(7).byte(0).word(2).byte(1).blob(new Uint8Array([0, 31, 127, 255])).byte(0).blob("-9223372036854775808");
  const out = r.run(), v = new DataView(out.buffer);
  assert.equal(out.length, 160); assert.equal(out[0], 1); assert.equal(out[1], 1); assert.equal(out[12], 1);
  assert.equal(v.getUint32(4, true), 0xffffffff); assert.equal(v.getUint32(8, true), 0xffffffff);
  assert.equal(v.getUint32(16, true), 0xffffffff); assert.equal(v.getUint32(20, true), 0xffffffff);
  assert.deepEqual(Array.from(out.subarray(112, 117)), [58, 58, 58, 255, 47]);
  assert.equal(new TextDecoder().decode(out.subarray(117, 112 + out[13]!)), "-9223372036854775808");
  const saved = out.slice(); r.run(); assert.deepEqual(out, saved);
});
test("complete provenance response and lookup preserve first-match and saturated-pool behavior", () => {
  assert.deepEqual(words(new Request(8).wide(1, 0x200000).word(3).wide(1).wide(1, 0x200000).wide(1, 0x200000).run()), [1]);
  assert.deepEqual(words(new Request(9).word(2).blob("a").blob("a").blob("a").run()), [0]);
  const r = new Request(7).byte(1).byte(1).byte(1).byte(1).blob("v").blob("18446744073709551615").blob("0").blob("src/app.native").blob("x").word(1).blob("src/app.native").blob("").blob("ffffffffffffffff").word(0).word(5).word(1).word(2);
  assert.equal(new TextDecoder().decode(r.run()), "provenance ok view=v id=18446744073709551615 authored=markup watching=true root=src/app.native\nnode file=src/app.native stamped= hash=ffffffffffffffff span=0..5 line=1 column=2\nchain_truncated=true\nkeys=x keys_truncated=true\n");
  const missing = new Request(7).byte(0).byte(0).byte(0).byte(0).blob("v").blob("1").blob("2").blob("").blob("").word(0).run();
  assert.match(new TextDecoder().decode(missing), /provenance pool saturated \(2 records dropped;/);
});
test("provenance commit paths preserve fixed-buffer join refusal and rebuild admission", () => {
  assert.equal(new TextDecoder().decode(new Request(10).byte(0).byte(1).blob("src").blob("parts.native").run()), "src/parts.native");
  assert.equal(new Request(10).byte(0).byte(1).blob("x".repeat(240)).blob("p").run().length, 0);
  assert.equal(new Request(10).byte(0).byte(0).blob("src").blob("p").run().length, 0);
  assert.deepEqual(words(new Request(11).byte(1).byte(1).run()), [1]);
  assert.deepEqual(words(new Request(11).byte(1).byte(0).run()), [0]);
});
test("markup transport rejects truncation, trailing data, invalid flags and incompatible stages", () => {
  const complete = new Uint8Array([32, 1, 1, 0, 1, 1, 0, 0, 0, 1]);
  for (let n = 0; n < complete.length; n++) assert.throws(() => markupDevelopmentPolicy(complete.subarray(0, n)));
  for (const [at, value] of [[0, 31], [1, 2], [2, 12], [3, 1], [4, 3], [5, 2]]) {
    const bad = complete.slice(); bad[at!] = value!; assert.throws(() => markupDevelopmentPolicy(bad));
  }
  assert.throws(() => markupDevelopmentPolicy(new Uint8Array([...complete, 0])));
});
