import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import test from "node:test";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("theme changes retain complete app state, effects and replay", async () => {
  const app = await NativeApp.start({ width: 680, height: 600, wallMs: 12345 });
  try {
    let snapshot = await app.snapshot();
    const snapshots: NativeSnapshot[] = [snapshot];
    const ids = snapshot.widgets.map(w => w.id);
    const press = async (name: string) => {
      snapshot = await app.click(findWidget(snapshot, { role: "button", name }));
      snapshots.push(snapshot);
      assert.deepEqual(snapshot.widgets.map(w => w.id), ids);
    };
    for (const name of ["Light", "Pink", "House", "Dark", "Teal", "Geist", "Inherit accent", "System", "Inherit palette", "Pink", "Add sample", "Stamp", "Light", "Inherit accent", "House", "System"]) await press(name);
    assert.equal(snapshot.model.count, 1);
    assert.equal(snapshot.model.stampedMs, 12345);
    assert.equal(snapshot.model.pack, "house");
    assert.equal(snapshot.model.inheritPack, false);
    assert.equal(snapshot.model.scheme, "system");
    assert.equal(snapshot.model.accent, "inherit");
    assert.ok(snapshot.effects.recorded > 0);
    const final = snapshot;
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.equal(replay.effects, final.effects.recorded);
    assert.deepEqual(replay.snapshot.model, final.model);
    snapshots.push(replay.snapshot);
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const complete = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.theme.json`, JSON.stringify(complete));
      else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.theme.json`, "utf8")));
    }
  } finally { await app.close(); }
});
