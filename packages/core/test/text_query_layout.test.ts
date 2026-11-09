import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const source = ["runtime_policy", "scalar_text", "text_run_layout", "text_query_layout"].map(name => readFileSync(new URL(`../src/${name}.ts`, import.meta.url), "utf8")).join("\n");
const { nscvTextQueryLayout: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport {nscvTextQueryLayout};").toString("base64")}`);
function packet(text: string, mode: number, capacity = 100, prepared: Uint8Array[] = []): Uint8Array {
  const raw = new TextEncoder().encode(text), end = 1024 + raw.length * 5, count = mode === 1 ? 64 : prepared.length;
  const b = new Uint8Array(end + count * 64), w = new DataView(b.buffer);
  b.set([55, 1, mode, 0, mode === 1 ? 1 : 0, mode >= 5 ? 1 : 0]); b.set([54, 1, 0, 0, 1, 0, 1, 0], 512);
  for (const [at, value] of [[8, mode === 1 ? 64 : capacity], [12, b.length], [40, end], [44, count], [520, end - raw.length], [524, end], [548, raw.length]]) w.setUint32(at!, value!, true);
  w.setFloat32(528, 10, true); w.setFloat32(532, 3, true); w.setFloat32(536, 10, true); w.setFloat32(540, 20, true);
  b.set(raw, end - raw.length); prepared.forEach((line, i) => b.set(line, end + i * 64)); return b;
}
function execute(input: Uint8Array): { bytes: Uint8Array; result: DataView; lines: Uint8Array[]; selections: Uint8Array[]; widths: number[][] } {
  const b = input.slice(), w = new DataView(b.buffer), lines: Uint8Array[] = [], selections: Uint8Array[] = [], widths: number[][] = [];
  for (let i = 0; i < 100000; i++) {
    const before = b.slice(), r = plan(b); assert.deepEqual(b, before); assert.equal(r.length, 1024);
    const q = new DataView(r.buffer); if (r[3] === 2) return { bytes: r, result: q, lines, selections, widths };
    b.set(r); const kind = q.getUint32(80, true), slot = q.getUint32(84, true);
    if (kind === 1) {
      const capability = q.getUint32(612, true), first = q.getUint32(616, true), last = q.getUint32(620, true);
      widths.push([capability, first, last]);
      if (capability === 3 || capability === 4 || capability === 6 || capability === 7) w.setUint32(632, 0, true);
      else w.setFloat32(628, capability === 5 ? 5 : (last - first) * 5, true);
      w.setUint32(624, 1, true);
    } else if (kind === 2) lines[slot] = r.slice(128, 184);
    else if (kind === 3) b.set(r.subarray(128, 184), q.getUint32(40, true) + slot * 64);
    else if (kind === 4) selections[slot] = r.slice(320, 344);
    else throw new Error("unexpected query action");
    w.setUint32(92, 1, true);
  }
  throw new Error("query did not finish");
}
test("whole-run admission preserves exact partial output and copied ownership", () => {
  const full = execute(packet("ab cd ef", 0)); assert.equal(full.lines.length, 3); assert.equal(full.result.getUint32(312, true), 0);
  const short = execute(packet("ab cd ef", 0, 1)); assert.equal(short.lines.length, 1); assert.equal(short.result.getUint32(312, true), 1); assert.deepEqual(short.lines[0], full.lines[0]);
  assert.equal(execute(packet("abc", 0, 0)).result.getUint32(312, true), 1);
  const input = packet("abc", 0), r = execute(input), retained = r.bytes.slice(); input.fill(0); assert.deepEqual(r.bytes, retained);
});
test("streaming and prepared caret neighbors preserve soft-wrap affinities", () => {
  const text = "abcdef", materialized = execute(packet(text, 0)).lines;
  for (const affinity of [0, 1]) {
    const results = [2, 5].map(mode => { const b = packet(text, mode, 0, mode === 5 ? materialized : []), w = new DataView(b.buffer); w.setUint32(16, 4, true); w.setUint32(24, affinity, true); return execute(b); });
    assert.deepEqual(results[0]!.bytes.subarray(256, 276), results[1]!.bytes.subarray(256, 276));
    assert.equal(results[0]!.result.getFloat32(260, true), affinity === 0 ? 0 : 12.5);
  }
  for (const mode of [4, 7]) {
    const b = packet(text, mode, 0, mode === 7 ? materialized : []), w = new DataView(b.buffer); w.setFloat32(28, 3, true); w.setFloat32(32, 13, true);
    const r = execute(b).result; assert.equal(r.getUint32(304, true), 4); assert.equal(r.getUint32(308, true), 1);
  }
});
test("uncapped selection folds every overflow line into the last caller slot", () => {
  const text = "a\n".repeat(260), b = packet(text, 3, 2), w = new DataView(b.buffer); w.setUint32(16, text.length, true);
  const r = execute(b); assert.equal(r.selections.length, 2); assert.equal(r.result.getUint32(124, true), 2);
  const last = new DataView(r.selections[1]!.buffer); assert.equal(last.getUint32(0, true), 2); assert.equal(last.getUint32(4, true), text.length - 1); assert.equal(last.getFloat32(20, true), 259 * 12.5);
  const zero = packet(text, 3, 0); new DataView(zero.buffer).setUint32(20, text.length, true); const z = execute(zero); assert.equal(z.selections.length, 0); assert(z.widths.length > 260);
});
test("bounds retain the native scratch attempt and uncapped restart ordering", () => {
  const text = "a\n".repeat(70), r = execute(packet(text, 1)); assert.equal(r.result.getUint32(272, true), 1);
  // Every first-attempt line asks for its fitted advance and width; the
  // 65th is measured before the reference restarts the complete run.
  const starts = r.widths.filter(([kind, first, last]) => kind === 1 && first !== last).map(([, first]) => first);
  assert.equal(starts[0], 0); assert.equal(starts[128], 128); assert.equal(starts[130], 0);
  assert.equal(r.result.getFloat32(268, true), 879.5);
});
test("query envelopes reject corrupt metadata, reserved state and missing acknowledgments", () => {
  for (const at of [0, 1, 2, 4, 5, 6, 12, 24, 40, 44, 48, 80, 96, 440, 448, 514, 515, 520, 524, 556, 572, 592, 832]) {
    const b = packet("abc", 0); b[at] = 255; assert.throws(() => plan(b), /invalid/, String(at));
  }
  const b = packet("abc", 0); b.set(plan(b)); assert.throws(() => plan(b), /invalid/);
  for (const at of [104, 312, 316, 440]) {
    const resumed = packet("abc", 0); resumed.set(plan(resumed)); const w = new DataView(resumed.buffer); w.setUint32(92, 1, true); w.setUint32(at, 255, true);
    assert.throws(() => plan(resumed), /invalid/, String(at));
  }
});

test("every reserved storage byte remains rejected independently", () => {
  for (let at = 48; at < 80; at++) {
    const input = packet("abc", 0); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
  for (let at = 80; at < 440; at++) {
    const input = packet("abc", 0); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
  for (let at = 440; at < 512; at++) {
    const input = packet("abc", 0); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
  for (let at = 556; at < 576; at++) {
    const input = packet("abc", 0); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
  for (let at = 592; at < 1024; at++) {
    const input = packet("abc", 0); input[at] = 1;
    assert.throws(() => plan(input), /invalid/, String(at));
  }
});
