import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("workspace windows retain identities, compact slots, route closes and replay complete state", async () => {
  const app = await NativeApp.start({ width: 780, height: 500, wallMs: 12345 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    const save = () => snapshots.push(s);
    const press = async (name: string, view = "main-canvas") => {
      s = await app.click(findWidget(s, { role: "button", name, view })); save();
    };
    const ids = () => Object.fromEntries(s.windows.map(w => [w.label, w.id]));
    const labels = () => s.windows.map(w => w.label).sort();
    assert.deepEqual(labels(), ["main"]);
    await press("Open workspace");
    assert.deepEqual(labels(), ["activity", "main", "notes", "overview"]);
    const first = ids();
    await press("Add one", "notes-canvas"); assert.equal(s.model.count, 1);
    await press("Reverse order"); assert.deepEqual(ids(), first);
    await press("Open workspace"); assert.deepEqual(ids(), first);
    await press("Switch panel set");
    assert.deepEqual(labels(), ["inspector", "main", "overview"]);
    assert.equal(ids().overview, first.overview);
    const compact = ids();
    await press("Add one", "inspector-canvas"); assert.equal(s.model.count, 2);
    await press("Reverse order"); assert.deepEqual(ids(), compact);
    await press("Switch close action"); assert.deepEqual(ids(), compact);
    s = await app.closeWindow(s.windows.find(w => w.label === "overview")!); save();
    assert.deepEqual(labels(), ["main"]); assert.equal(s.model.closes, 1);
    assert.equal(new TextDecoder().decode(new Uint8Array(s.model.lastClose as number[])), "Alternate close received.");
    await press("Open workspace");
    assert.notEqual(ids().overview, compact.overview); assert.equal(s.model.count, 2);
    await press("Switch close action");
    s = await app.closeWindow(s.windows.find(w => w.label === "inspector")!); save();
    assert.deepEqual(labels(), ["main"]); assert.equal(s.model.closes, 2);
    await press("Open workspace"); await press("Switch panel set");
    assert.deepEqual(labels(), ["activity", "main", "notes", "overview"]);
    await press("Close panels", "activity-canvas"); assert.deepEqual(labels(), ["main"]);
    assert.equal(s.model.closes, 2); // Model-initiated closes do not dispatch onClose.
    await press("Open workspace"); await press("Add one", "overview-canvas");
    assert.equal(s.model.count, 3);
    await press("Close panels");
    const replay = await app.verifyReplay(); assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.equal(replay.effects, s.effects.recorded); assert.deepEqual(replay.snapshot.model, s.model);
    s = replay.snapshot; save();
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const complete = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.windows.json`, JSON.stringify(complete));
      else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.windows.json`, "utf8")));
    }
  } finally { await app.close(); }
});
