import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...s }) => s);
  if (backend === "zig") writeFileSync(`${reference}.timers.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.timers.json`, "utf8")));
};

test("clocks reconcile keys, exact intervals, routes and order beside reminders, then replay", async () => {
  const app = await NativeApp.start({ width: 760, height: 620, wallMs: 12345 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s];
    const save = () => snapshots.push(s);
    const button = (name: string) => findWidget(s, { role: "button", name });
    const toggle = async (name: string) => { s = await app.click(findWidget(s, { role: "switch", name })); save(); };
    const press = async (name: string) => { s = await app.click(button(name)); save(); };
    const timers = () => s.effects.timers.filter(t => t.mode === "repeating");
    assert.equal(timers().length, 0);
    await toggle("Run clocks");
    assert.equal(timers().length, 1); assert.equal(timers()[0]!.intervalMs, 2000);
    const pulse = timers()[0]!.key;
    s = await app.fireTimer(pulse); assert.equal(s.model.primary, 1); save();
    await toggle("Route pulse to secondary");
    assert.equal(timers()[0]!.key, pulse); assert.equal(timers()[0]!.intervalMs, 2000);
    s = await app.fireTimer(pulse); assert.equal(s.model.primary, 1); assert.equal(s.model.secondary, 1); save();
    await toggle("Fast pulse");
    assert.equal(timers()[0]!.key, pulse); assert.equal(timers()[0]!.intervalMs, 501);
    await toggle("Companion clock"); assert.equal(timers().length, 2);
    const companion = timers().find(t => t.key !== pulse)!.key;
    const before = s.effects.timers;
    await press("Reverse clock order"); assert.deepEqual(s.effects.timers, before);
    s = await app.fireTimer(companion); assert.equal(s.model.secondary, 2); save();
    await press("Read clock");
    assert.equal(s.model.clockReadings, 1); assert.equal(s.effects.recorded, 1);
    await press("Schedule reminder");
    const reminder = s.effects.timers.find(t => t.mode === "one_shot")!.key;
    assert.equal(s.effects.timers.length, 3);
    await press("Cancel reminder"); assert.equal(s.effects.timers.length, 2); assert.equal(s.model.delayed, 0);
    await press("Schedule reminder");
    const second = s.effects.timers.find(t => t.mode === "one_shot")!;
    assert.equal(second.key, reminder); assert.equal(second.intervalMs, 250);
    s = await app.fireTimer(second.key); assert.equal(s.model.delayed, 1); assert.equal(s.effects.timers.length, 2); save();
    await press("Rename pulse key");
    const newPulse = timers().find(t => t.key !== companion)!.key;
    assert.notEqual(newPulse, pulse); assert.equal(timers().length, 2);
    s = await app.fireTimer(newPulse); assert.equal(s.model.secondary, 3); save();
    await toggle("Companion clock"); assert.equal(timers().length, 1); assert.equal(timers()[0]!.key, newPulse);
    await toggle("Run clocks"); assert.equal(timers().length, 0);
    await toggle("Route pulse to secondary"); await toggle("Run clocks");
    assert.equal(timers()[0]!.key, pulse);
    s = await app.fireTimer(pulse); assert.equal(s.model.primary, 2); save();
    await toggle("Run clocks");
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.equal(replay.effects, 1);
    assert.equal(replay.effects, s.effects.recorded);
    assert.deepEqual(replay.snapshot.model, s.model);
    s = replay.snapshot; save(); compare(snapshots);
  } finally { await app.close(); }
});


test("delays debounce routes, allocate independently, reuse retired slots and replay complete effects", async () => {
  const app = await NativeApp.start({ width: 760, height: 620, wallMs: 12345 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    const save = () => snapshots.push(s);
    const press = async (name: string) => { s = await app.click(findWidget(s, { role: "button", name })); save(); };
    const delays = () => s.effects.timers.filter(t => t.mode === "one_shot");
    await press("Schedule reminder"); const reminder = delays()[0]!.key;
    await press("Schedule reminder"); assert.equal(delays().length, 1); assert.equal(delays()[0]!.key, reminder);
    await press("Replace reminder"); assert.equal(delays().length, 1); assert.equal(delays()[0]!.key, reminder);
    assert.equal(delays()[0]!.intervalMs, 701); assert.equal(s.model.clockReadings, 1); assert.equal(s.effects.recorded, 1);
    await press("Pair reminders"); assert.equal(delays().length, 3);
    const left = delays().find(t => t.intervalMs === 1001)!.key, right = delays().find(t => t.intervalMs === 1501)!.key;
    s = await app.fireTimer(reminder); assert.equal(s.model.secondary, 1); assert.equal(s.model.delayed, 0); save();
    await press("Schedule reminder"); assert.equal(delays().find(t => t.intervalMs === 250)!.key, reminder);
    await press("Cancel reminder"); assert.equal(delays().length, 2);
    s = await app.fireTimer(left); assert.equal(s.model.primary, 1); save();
    s = await app.fireTimer(right); assert.equal(s.model.secondary, 2); assert.equal(delays().length, 0); save();
    await press("Anonymous reminders"); assert.equal(delays().length, 2); assert.notEqual(delays()[0]!.key, delays()[1]!.key);
    const anonymous = delays().map(t => t.key);
    await press("Cancel reminder"); assert.deepEqual(delays().map(t => t.key), anonymous);
    for (const key of anonymous) { s = await app.fireTimer(key); save(); }
    assert.equal(s.model.delayed, 2); assert.equal(delays().length, 0);
    await press("Pair reminders"); await press("Cancel pair"); assert.equal(delays().length, 0);
    await press("Schedule reminder"); assert.equal(delays()[0]!.key, reminder);
    s = await app.fireTimer(reminder); assert.equal(s.model.delayed, 3); save();
    const replay = await app.verifyReplay(); assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.equal(replay.effects, 1); assert.deepEqual(replay.snapshot.model, s.model);
    s = replay.snapshot; save();
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const values = snapshots.map(({ viewBackend, ...value }) => value);
      if (backend === "zig") writeFileSync(`${reference}.delays.json`, JSON.stringify(values));
      else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.delays.json`, "utf8")));
    }
  } finally { await app.close(); }
});
