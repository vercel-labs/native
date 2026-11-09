import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const runtime = readFileSync(new URL("../src/runtime_policy.ts", import.meta.url), "utf8");
const source = runtime + readFileSync(new URL("../src/widget_audits.ts", import.meta.url), "utf8");
const { nscvWidgetAudits: audit } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source) + "\nexport { nscvWidgetAudits };").toString("base64")}`);
const missing = 0xffffffff;
const view = (bytes: Uint8Array) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
interface Node { kind?: number; role?: number; parent?: number; flags?: number; id?: bigint; label?: number[]; text?: number[]; placeholder?: number[]; frame?: number[]; opacity?: number; transform?: number[]; size?: number; spans?: number; overflow?: number; measured?: number[]; lines?: number; offset?: number; descendants?: { parent: number; hidden: boolean; label: number[]; text: number[] }[] }
function packet(family: number, nodes: Node[], capacity = 64) {
  const length = 56 + nodes.reduce((n, v) => n + 128 + (v.label?.length ?? 0) + (v.text?.length ?? 0) + (v.placeholder?.length ?? 0) + (v.descendants ?? []).reduce((m, d) => m + 16 + d.label.length + d.text.length, 0), 0);
  const bytes = new Uint8Array(length), w = view(bytes); bytes.set([23, 1, family, 0]); w.setUint32(4, nodes.length, true); w.setUint32(8, capacity, true);
  [0, 0, 400, 300, 18].forEach((v, i) => w.setFloat32(16 + i * 4, v, true)); w.setUint32(52, 1, true);
  let at = 56;
  for (const n of nodes) {
    const p = at; w.setUint32(p, n.parent ?? missing, true); w.setUint32(p + 4, n.kind ?? 31, true); w.setUint32(p + 8, n.role ?? 0, true); w.setUint32(p + 12, n.flags ?? 0, true);
    w.setBigUint64(p + 16, n.id ?? 1n, true); w.setFloat32(p + 24, n.opacity ?? 1, true); w.setFloat32(p + 28, n.offset ?? 0, true);
    (n.transform ?? [1, 0, 0, 1, 0, 0]).forEach((v, i) => w.setFloat32(p + 32 + i * 4, v, true)); (n.frame ?? [0, 0, 30, 30]).forEach((v, i) => w.setFloat32(p + 56 + i * 4, v, true));
    w.setUint32(p + 72, n.size ?? 1, true); w.setUint32(p + 76, n.overflow ?? 0, true); w.setUint32(p + 84, n.spans ?? 0, true);
    w.setUint32(p + 92, n.label?.length ?? 0, true); w.setUint32(p + 96, n.text?.length ?? 0, true); w.setUint32(p + 100, n.placeholder?.length ?? 0, true); w.setUint32(p + 104, n.descendants?.length ?? 0, true);
    (n.measured ?? [0, 0, 0, 0]).forEach((v, i) => w.setFloat32(p + 108 + i * 4, v, true)); w.setUint32(p + 124, n.lines ?? 0, true); at += 128;
    for (const value of [n.label ?? [], n.text ?? [], n.placeholder ?? []]) { bytes.set(value, at); at += value.length; }
    for (const d of n.descendants ?? []) { w.setUint32(at, d.parent, true); w.setUint32(at + 4, Number(d.hidden), true); w.setUint32(at + 8, d.label.length, true); w.setUint32(at + 12, d.text.length, true); at += 16; bytes.set(d.label, at); at += d.label.length; bytes.set(d.text, at); at += d.text.length; }
  }
  return bytes;
}
function findings(bytes: Uint8Array) { const w = view(bytes), result = []; for (let i = 0; i < w.getUint32(4, true); i++) { const p = 16 + i * 24; result.push([w.getUint32(p, true), w.getUint32(p + 4, true), w.getUint32(p + 8, true), w.getFloat32(p + 12, true), w.getFloat32(p + 16, true), w.getUint32(p + 20, true)]); } return result; }
test("raw names preserve NUL, malformed bytes, ASCII-only blankness and first duplicate order", () => {
  const nodes = [{ kind: 1 }, { parent: 0, label: [0, 255] }, { parent: 0, label: [0, 255] }, { parent: 0, label: [0, 255] }, { parent: 0, label: [32, 9, 10, 13] }, { parent: 0, label: [0xc2, 0xa0] }];
  assert.deepEqual(findings(audit(packet(0, nodes))), [[2, 2, 1, 0, 0, 0], [2, 3, 1, 0, 0, 0], [0, 4, missing, 0, 0, 0]]);
});
test("text-entry values cannot name their control, while row content ignores opacity and respects hidden ancestry", () => {
  assert.equal(view(audit(packet(0, [{ kind: 35, text: [97] }]))).getUint32(8, true), 1);
  assert.equal(view(audit(packet(0, [{ kind: 35, text: [97], placeholder: [98] }]))).getUint32(8, true), 0);
  const n: Node = { role: 25, descendants: [{ parent: missing, hidden: true, label: [], text: [] }, { parent: 0, hidden: false, label: [], text: [97] }] };
  assert.equal(view(audit(packet(0, [n]))).getUint32(8, true), 1); n.descendants![0]!.hidden = false;
  assert.equal(view(audit(packet(0, [n]))).getUint32(8, true), 0);
});
test("empty, short and large finding storage retain the full count", () => {
  const nodes: Node[] = [{ kind: 1 }]; for (let i = 0; i < 80; i++) nodes.push({ parent: 0, frame: [i * 35, 0, 30, 30] });
  for (const capacity of [0, 1, 64, 79, 80, 100]) { const out = audit(packet(0, nodes, capacity)); assert.equal(view(out).getUint32(8, true), 80); assert.equal(view(out).getUint32(4, true), Math.min(capacity, 80)); assert.equal(out.length, 16 + Math.min(capacity, 80) * 24); }
});
test("scroll axes forgive only revealable folds, and nested horizontal scopes cannot forgive vertical clipping", () => {
  const nodes: Node[] = [{ kind: 22, flags: 8, frame: [0, 0, 100, 100] }, { kind: 6, parent: 0, flags: 16, frame: [0, 0, 100, 100], offset: 20 }, { parent: 1, text: [97], frame: [-50, 0, 30, 30] }, { parent: 1, text: [98], frame: [200, 0, 30, 30] }, { parent: 1, text: [99], frame: [0, 200, 30, 30] }];
  assert.deepEqual(findings(audit(packet(0, nodes))), [[1, 2, 1, 0, 0, 0], [1, 4, 1, 0, 0, 0]]);
});
test("layout orders overlap before child rules and suppresses duplicate descendant escapes", () => {
  const nodes: Node[] = [{ kind: 1 }, { parent: 0, text: [97], frame: [390, 0, 10, 10] }, { parent: 0, text: [98], frame: [395, 0, 10, 10] }, { parent: 2, kind: 26, text: [99], frame: [405, 0, 10, 10] }];
  assert.deepEqual(findings(audit(packet(1, nodes))), [[1, 2, 1, 5, 10, 0], [3, 1, missing, 8, 8, 0], [3, 2, missing, 8, 8, 0], [2, 2, missing, 5, 0, 0]]);
});
test("text decisions preserve ellipsis, clip, paragraph measurements and half-point thresholds", () => {
  const plain: Node = { kind: 26, text: [97, 10, 98], measured: [31, 60, 0, 0], lines: 2 };
  assert.deepEqual(findings(audit(packet(1, [plain]))), [[0, 0, missing, 0, 30, 2]]);
  plain.overflow = 1; assert.deepEqual(findings(audit(packet(1, [plain]))), [[0, 0, missing, 1, 30, 2]]);
  const span: Node = { kind: 44, spans: 1, measured: [30.5, 30.5, 30, 30], lines: 2 };
  assert.deepEqual(findings(audit(packet(1, [span]))), []); span.measured![0] = Math.fround(30.50001);
  assert.equal(findings(audit(packet(1, [span])))[0]![3], Math.fround(Math.fround(30.50001) - 30));
});
test("portable measurement selection preserves node order and ignores report capacity", () => {
  const nodes: Node[] = [{ kind: 2 }, { kind: 26, parent: 0, text: [97] }, { kind: 26, parent: 0, spans: 1 }, { parent: 0, text: [98], overflow: 1 }, { parent: 0, text: [99] }, { kind: 26, parent: 0, flags: 1, text: [100] }, { kind: 26, parent: 0, transform: [1, 0, 0, 1, 1, 0], text: [101] }];
  const request = packet(1, nodes, 0); request[3] = 2;
  const out = audit(request); assert.deepEqual([...out.subarray(0, 4)], [1, 1, 2, 0]);
  assert.deepEqual(findings(out), [[0, 1, missing, 0, 0, 0], [1, 2, missing, 0, 0, 0], [2, 3, missing, 0, 0, 0]]);
});
test("transforms skip layout audits while accessibility remains live; hidden or transparent ancestry skips both", () => {
  const nodes: Node[] = [{ kind: 1, transform: [1, 0, 0, 1, 2, 0] }, { parent: 0, frame: [0, 0, 1, 1] }];
  assert.equal(view(audit(packet(1, nodes))).getUint32(8, true), 0); assert.equal(view(audit(packet(0, nodes))).getUint32(8, true), 1);
  for (const root of [{ flags: 1 }, { opacity: 0 }]) for (const family of [0, 1]) assert.equal(view(audit(packet(family, [{ kind: 1, ...root }, nodes[1]!]))).getUint32(8, true), 0);
});
test("requests validate complete records, ancestor cycles, byte bounds and trailing data", () => {
  const valid = packet(0, [{ label: [255] }]);
  for (let n = 0; n < valid.length; n++) assert.throws(() => audit(valid.subarray(0, n)));
  const trailing = new Uint8Array(valid.length + 1); trailing.set(valid); assert.throws(() => audit(trailing));
  for (const [at, value] of [[0, 0], [1, 2], [2, 2], [3, 2], [12, 1], [52, 3], [56, 0], [60, 63], [64, 27], [68, 4096], [128, 6], [132, 2], [148, 10000]]) {
    const bad = valid.slice(); if (at < 4) bad[at] = value; else view(bad).setUint32(at, value, true); assert.throws(() => audit(bad), `field ${at}`);
  }
  assert.throws(() => audit(packet(0, [{ parent: 1 }, { parent: 0 }])));
});
