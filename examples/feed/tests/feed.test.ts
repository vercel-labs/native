import assert from "node:assert/strict";
import test from "node:test";
import { NativeApp, findWidget } from "@native-sdk/core/testing";

test("compiled Feed retains complete interaction state across window shifts and replay", async () => {
  await using app = await NativeApp.start({ width: 520, height: 760 });
  let snapshot = await app.snapshot();
  assert.equal(snapshot.model.loaded, 500);
  assert.deepEqual(snapshot.model.liked, Array(12504).fill(0));
  assert.deepEqual(snapshot.model.boosted, Array(12504).fill(0));
  const first = snapshot.widgets.find(widget => widget.role === "listitem" && widget.name.startsWith("Post 0 by "));
  assert.ok(first);
  snapshot = await app.action(findWidget(snapshot, { role: "button", name: "Like post 0" }), "toggle");
  assert.equal((snapshot.model.liked as number[])[0], 1);
  const original = snapshot.model;
  snapshot = await app.wheel(findWidget(snapshot, { role: "group", name: "Timeline" }), -1800);
  snapshot = await app.frame();
  assert.ok(!snapshot.widgets.some(widget => widget.name === first.name));
  assert.deepEqual(snapshot.model, original);
  snapshot = await app.wheel(findWidget(snapshot, { role: "group", name: "Timeline" }), 100000);
  snapshot = await app.frame();
  assert.equal(findWidget(snapshot, { role: "listitem", name: first.name }).id, first.id);
  assert.equal((snapshot.model.liked as number[])[0], 1);
  const replay = await app.verifyReplay();
  assert.ok(replay.events > 0 && replay.checkpoints > 0);
  assert.deepEqual(replay.snapshot.model, snapshot.model);
});
