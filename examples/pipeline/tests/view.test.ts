import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const widget = (snapshot: NativeSnapshot, role: string, name: string) => findWidget(snapshot, { role, name });
const compare = (name: string, snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  const path = `${reference}.${name}.json`;
  if (backend === "zig") writeFileSync(path, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(path, "utf8")), "complete native component snapshots match");
};

test("stepper transitions, bounds, semantics and replay match the native reference", async () => {
  const app = await NativeApp.start({ width: 760, height: 580 });
  try {
    let snapshot = await app.snapshot();
    if (backend) assert.equal(snapshot.viewBackend, backend);
    const snapshots = [snapshot];
    const plan = widget(snapshot, "listitem", "Plan (active)").id;
    const next = widget(snapshot, "button", "Next");
    for (const active of [1, 2, 3, 4]) {
      snapshot = await app.click(next);
      assert.equal(snapshot.model.active, active);
      assert.equal(widget(snapshot, "listitem", "Plan (completed)").id, plan);
      assert.equal(snapshot.widgets.filter(w => w.role === "listitem" && w.name.endsWith("(active)")).length, active < 3 ? 1 : 0);
      snapshots.push(snapshot);
    }
    snapshot = await app.click(widget(snapshot, "button", "Reset"));
    snapshot = await app.click(widget(snapshot, "button", "Previous"));
    assert.equal(snapshot.model.active, -1);
    assert.equal(widget(snapshot, "listitem", "Plan (active)").id, plan); // negative clamps to zero
    snapshots.push(snapshot);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(replay.snapshot);
    compare("stages", snapshots);
  } finally { await app.close(); }
});

test("timeline pointer, keyboard, keyed reordering, empty state and replay match", async () => {
  const app = await NativeApp.start({ width: 760, height: 580 });
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot];
    const review = widget(snapshot, "listitem", "Review café");
    const passive = widget(snapshot, "listitem", "Read-only checkpoint");
    assert.equal(passive.actions.press, false);
    assert.equal(passive.focused, false);
    // Hit the bold title rather than invoking the root's semantic action:
    // native hit testing must route the leaf's pointer to the item handler.
    const title = snapshot.widgets.find(w => w.role === "text" && w.name === "Review café" && w.bounds.y > review.bounds.y)!;
    assert.ok(title);
    const point = { x: title.bounds.x + title.bounds.width / 2, y: title.bounds.y + title.bounds.height / 2 };
    await app.pointer(review, "down", point);
    snapshot = await app.pointer(review, "up", point);
    assert.equal(snapshot.model.selected, 20);
    assert.equal(widget(snapshot, "listitem", "Review café").selected, true);
    snapshots.push(snapshot);
    await app.action(widget(snapshot, "listitem", "Ship"), "focus");
    snapshot = await app.key(review.view, "enter");
    assert.equal(snapshot.model.selected, 30);
    snapshots.push(snapshot);
    await app.action(widget(snapshot, "listitem", "Plan"), "focus");
    snapshot = await app.key(review.view, "space");
    assert.equal(snapshot.model.selected, 10);
    snapshots.push(snapshot);
    snapshot = await app.click(widget(snapshot, "button", "Reverse timeline"));
    assert.equal(widget(snapshot, "listitem", "Review café").id, review.id);
    assert.equal(widget(snapshot, "listitem", "Read-only checkpoint").id, passive.id);
    assert.ok(widget(snapshot, "listitem", "Ship").bounds.y < widget(snapshot, "listitem", "Plan").bounds.y);
    snapshots.push(snapshot);
    snapshot = await app.click(widget(snapshot, "button", "Toggle empty"));
    assert.equal(snapshot.widgets.some(w => w.role === "listitem" && w.name === "Review café"), false);
    snapshots.push(snapshot);
    snapshot = await app.click(widget(snapshot, "button", "Toggle empty"));
    assert.equal(widget(snapshot, "listitem", "Review café").id, review.id);
    snapshots.push(snapshot);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(replay.snapshot);
    compare("timeline", snapshots);
  } finally { await app.close(); }
});
