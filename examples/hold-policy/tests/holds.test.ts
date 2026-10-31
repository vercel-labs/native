import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import test from "node:test";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("hold coordination preserves complete state, borrowed handlers, cancellation, effects and replay", async () => {
  const app = await NativeApp.start({ width: 680, height: 620, wallMs: 12345 });
  try {
    let s = await app.snapshot(); const snapshots: NativeSnapshot[] = [s];
    const save = (value: NativeSnapshot) => { s = value; snapshots.push(s); };
    const button = (name: string) => findWidget(s, { role: "button", name });
    const card = () => button("Press or hold this card");
    const center = () => { const b = card().bounds; return { x: b.x + b.width / 2, y: b.y + b.height / 2 }; };
    const text = (value: unknown) => new TextDecoder().decode(new Uint8Array(value as number[]));
    save(await app.click(card())); assert.equal(s.model.presses, 1);
    save(await app.hold(card())); assert.equal(s.model.holds, 1); assert.equal(s.model.presses, 1);
    assert.equal(text(s.model.last), "First note");
    save(await app.contextPress(card())); assert.equal(s.model.holds, 2); assert.equal(s.model.presses, 1);
    const target = card(), point = center();
    save(await app.pointer(target, "down", point));
    // Rebuild while the timer remains armed: firing reads the live handler.
    save(await app.action(button("Change note"), "press"));
    save(await app.fireHoldTimer()); assert.equal(s.model.holds, 3); assert.equal(text(s.model.last), "Updated note");
    save(await app.pointer(target, "up", point)); assert.equal(s.model.presses, 1);
    save(await app.pointer(card(), "down", center()));
    save(await app.pointer(card(), "cancel", center())); assert.equal(s.model.holds, 3);
    save(await app.click(card())); assert.equal(s.model.presses, 2);
    save(await app.action(button("Toggle disabled"), "press"));
    save(await app.pointer(card(), "down", center()));
    save(await app.pointer(card(), "up", center())); assert.equal(s.model.holds, 3); assert.equal(s.model.presses, 2);
    save(await app.action(button("Toggle disabled"), "press"));
    const removed = card(), at = center();
    save(await app.pointer(removed, "down", at));
    save(await app.action(button("Toggle card"), "press"));
    save(await app.fireHoldTimer()); assert.equal(s.model.holds, 3);
    save(await app.pointer(removed, "up", at)); assert.equal(s.model.presses, 2);
    save(await app.action(button("Toggle card"), "press"));
    save(await app.hold(card())); assert.equal(s.model.holds, 4); assert.equal(s.model.presses, 2);
    save(await app.hold(button("Press only"))); assert.equal(s.model.presses, 3); assert.equal(s.model.holds, 4);
    save(await app.click(button("Stamp"))); assert.equal(s.model.stampedMs, 12345);
    const recorded = s;
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0 && replay.effects > 0);
    assert.equal(replay.effects, recorded.effects.recorded); assert.deepEqual(replay.snapshot.model, recorded.model);
    save(replay.snapshot);
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const complete = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.holds.json`, JSON.stringify(complete));
      else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.holds.json`, "utf8")));
    }
  } finally { await app.close(); }
});
