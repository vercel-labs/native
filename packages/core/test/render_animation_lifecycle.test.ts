import assert from "node:assert/strict";
import test from "node:test";
import { stripTypeScriptTypes } from "node:module";
import { readFileSync } from "node:fs";
const source = ["runtime_policy.ts", "render_animation_lifecycle.ts"].map(name => readFileSync(new URL(`../src/${name}`, import.meta.url), "utf8")).join("\n");
const { native_window_policy: plan } = await import(`data:text/javascript;base64,${Buffer.from(stripTypeScriptTypes(source)).toString("base64")}`);
type Animation = { id: bigint; start?: bigint; duration?: number; loop?: number; opacity?: number; from?: number[]; to?: number[]; rotation?: boolean; center?: number[] };
type Override = { id: bigint; opacity?: number; transform?: number[] };
const identity = [1, 0, 0, 1, 0, 0], huge = 9007199254740993n, max = (1n << 64n) - 1n;
function request(mode: number, animations: Animation[] = [], overrides: Override[] = [], commands: (bigint | null)[] = [], now = 0n): Uint8Array {
  const b = new Uint8Array(80 + animations.length * 112 + overrides.length * 40 + commands.length * 16), w = new DataView(b.buffer);
  b.set([72, 1, mode, 0]); w.setUint32(4, animations.length, true); w.setUint32(8, overrides.length, true); w.setUint32(12, commands.length, true); w.setBigUint64(20, now, true);
  animations.forEach((a, i) => {
    const at = 80 + i * 112;
    w.setBigUint64(at, a.id, true); w.setBigUint64(at + 8, a.start ?? 0n, true); w.setUint32(at + 16, a.duration ?? 1, true); w.setUint32(at + 20, a.loop ?? 0, true);
    w.setUint32(at + 24, (a.opacity !== undefined ? 1 : 0) | (a.from ? 2 : 0) | (a.to ? 4 : 0) | (a.rotation ? 8 : 0), true);
    w.setFloat32(at + 28, a.opacity ?? 0, true);
    for (const [off, affine] of [[32, a.from ?? identity], [56, a.to ?? identity]] as const) affine.forEach((v, j) => w.setFloat32(at + off + j * 4, v, true));
    (a.center ?? [0, 0]).forEach((v, j) => w.setFloat32(at + 80 + j * 4, v, true));
  });
  const overrideAt = 80 + animations.length * 112;
  overrides.forEach((a, i) => {
    const at = overrideAt + i * 40; w.setBigUint64(at, a.id, true);
    w.setUint32(at + 8, (a.opacity !== undefined ? 1 : 0) | (a.transform ? 2 : 0), true); w.setFloat32(at + 12, a.opacity ?? 0, true);
    (a.transform ?? identity).forEach((v, j) => w.setFloat32(at + 16 + j * 4, v, true));
  });
  commands.forEach((id, i) => { const at = overrideAt + overrides.length * 40 + i * 16; w.setBigUint64(at, id ?? 0n, true); w.setUint32(at + 8, id !== null ? 1 : 0, true); });
  if (mode === 2) w.setUint32(56, 4294967295, true);
  return b;
}
function checked(bytes: Uint8Array): Uint8Array {
  const before = bytes.slice(), result = plan(bytes); assert.deepEqual(bytes, before); return result;
}
test("animation activity and retirement preserve exact u64 clocks across words and float limits", () => {
  for (const start of [0n, 4294967295n, huge, max - 1000000n, max]) for (const duration of [0, 1, 500, 4294967295]) {
    const animations: Animation[] = [];
    for (const id of [0n, huge, max]) for (const loop of [0, 1, 2]) for (const end of [undefined, 1, 0.5, NaN]) animations.push({ id, start, duration, loop, opacity: end });
    const span = BigInt(duration) * 1000000n;
    for (const now of new Set([0n, start, start > 0n ? start - 1n : 0n, start + 1n, start + span - 1n, start + span, max].filter(n => n >= 0n && n <= max))) {
      const bytes = checked(request(0, animations, [], [], now)), w = new DataView(bytes.buffer);
      const expected = animations.map(a => {
        const active = a.id !== 0n && duration !== 0 && (a.loop !== 0 || now <= start || now - start < span);
        return (active || a.opacity !== undefined && a.opacity !== 1 ? 1 : 0) | (active ? 2 : 0);
      });
      assert.deepEqual(Array.from(bytes.subarray(32)), expected);
      assert.equal(w.getUint32(8, true), expected.some(v => (v & 2) !== 0) ? 1 : 0);
      assert.equal(w.getUint32(12, true), expected.includes(0) ? 1 : 0);
    }
  }
});
test("terminal cleanup preserves optional transforms, rotation semantics, NaN and signed zero", () => {
  const animations: Animation[] = [
    { id: huge, duration: 0, to: identity, rotation: true },
    { id: huge, duration: 0, to: [1, -0, 0, 1, -0, 0], opacity: 1 },
    { id: huge, duration: 0, to: [1, 0, 0, 1, 0.001, 0] },
    { id: max, duration: 0, to: [NaN, 0, 0, 1, 0, 0] },
    { id: huge, duration: 0, opacity: -0 },
    { id: huge, duration: 0, from: [2, 0, 0, 2, 5, 6] },
  ];
  assert.deepEqual(Array.from(checked(request(0, animations)).subarray(32)), [0, 0, 1, 1, 1, 0]);
  const overrides = animations.map(a => ({ id: a.id, opacity: a.opacity, transform: a.to }));
  const bytes = request(1, [], overrides), backing = new Uint8Array(bytes.length + 11); backing.set(bytes, 7);
  const output = checked(backing.subarray(7, 7 + bytes.length)), copy = output.slice();
  assert.deepEqual(Array.from(output.subarray(32)), [0, 0, 1, 1, 1, 0]);
  checked(request(1)); backing.fill(255); assert.deepEqual(output, copy);
});
test("animation replacement admission preserves capacity error precedence and empty-set coordination", () => {
  function admit(ids: bigint[], capacity: number, old = 0, overrides = 0) {
    const bytes = new Uint8Array(80 + (ids.length > capacity ? 0 : ids.length * 8)), w = new DataView(bytes.buffer);
    bytes.set([72, 1, 3, 0]); w.setUint32(4, ids.length, true); w.setUint32(8, overrides, true); w.setUint32(12, old, true); w.setUint32(16, capacity, true);
    if (ids.length <= capacity) ids.forEach((id, i) => w.setBigUint64(80 + i * 8, id, true));
    const r = new DataView(checked(bytes).buffer); return [r.getUint32(4, true), r.getUint32(8, true)];
  }
  assert.deepEqual(admit([], 0), [0, 1]); assert.deepEqual(admit([], 0, 1), [0, 0]); assert.deepEqual(admit([], 0, 0, 1), [0, 0]);
  assert.deepEqual(admit([0n], 0), [1, 0]); assert.deepEqual(admit([0n], 1), [2, 0]); assert.deepEqual(admit([huge, huge, max], 3), [0, 0]);
});
function schedule(animations: Animation[], overrides: Override[], commands: (bigint | null)[], provide: (index: number) => number[] | null) {
  const input = request(2, animations, overrides, commands), w = new DataView(input.buffer), calls: number[] = [];
  for (let step = 0; step <= animations.length + overrides.length; step++) {
    const output = checked(input), r = new DataView(output.buffer);
    if (r.getUint32(4, true) === 0) return { calls, bounds: r.getUint32(16, true) ? Array.from({ length: 4 }, (_, i) => r.getFloat32(20 + i * 4, true)) : null };
    const index = r.getUint32(12, true); calls.push(index);
    w.setUint32(32, r.getUint32(8, true), true); input.set(output.subarray(16, 36), 36); w.setUint32(56, index, true);
    const rect = provide(index); w.setUint32(60, rect ? 1 : 0, true); (rect ?? [0, 0, 0, 0]).forEach((v, i) => w.setFloat32(64 + i * 4, v, true));
  }
  throw new Error("animation bounds continuation did not finish");
}
test("replacement damage requests only the first matching native provider in reference order without memoization", () => {
  let measurement = 0;
  const result = schedule([{ id: huge }, { id: huge }, { id: huge + 1n }, { id: 0n }, { id: max }], [{ id: huge }, { id: huge }],
    [null, huge, huge, max], index => index === 3 ? null : [++measurement, 0, 1, 1]);
  assert.deepEqual(result, { calls: [1, 1, 1, 1, 3], bounds: [1, 0, 4, 1] });
  assert.deepEqual(schedule([{ id: huge }], [], [huge + 1n], () => { throw new Error("unselected provider"); }), { calls: [], bounds: null });
});
test("replacement damage owns exact transform unions and conservative rotation extents", () => {
  assert.deepEqual(schedule([{ id: huge, from: [1, 0, 0, 1, -4, 0], to: [2, 0, 0, 2, 8, 3] }], [{ id: huge, transform: [1, 0, 0, 1, 0, -5] }], [huge], () => [0, 0, 4, 3]).bounds, [-4, -5, 20, 14]);
  assert.deepEqual(schedule([{ id: huge, rotation: true }], [], [huge], () => [0, 0, 4, 3]).bounds, [-5, -5, 10, 10]);
});
test("lifecycle transport rejects malformed extents, tags, reserved words and bounds answers", () => {
  const good = request(0, [{ id: huge }]);
  for (let len = 0; len < good.length; len++) assert.throws(() => plan(good.subarray(0, len)), /invalid|truncated/);
  for (const at of [1, 2, 3, 4, 8, 12, 16, 28, 32, 100, 104, 168]) {
    const bad = good.slice(); bad[at] = 255; assert.throws(() => plan(bad), /invalid/);
  }
  const bad = request(2, [{ id: huge }], [], [huge]); new DataView(bad.buffer).setUint32(56, 1, true);
  assert.throws(() => plan(bad), /invalid/);
  assert.throws(() => plan(new Uint8Array([...good, 0])), /invalid/);
});
