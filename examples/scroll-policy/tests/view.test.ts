import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  if (backend === "zig") writeFileSync(`${reference}.atlas.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.atlas.json`, "utf8")));
};
const add = (value: number, delta: number) => Math.fround(Math.fround(value) + Math.fround(delta));
const line = (extent: number) => Math.max(24, Math.fround(Math.fround(extent) * Math.fround(0.35)));
const page = (extent: number) => Math.max(line(extent), Math.fround(Math.fround(extent) * Math.fround(0.85)));

test("two-axis offsets, nested wheel routing, retained notes, source changes and replay agree", async () => {
  // The complete history replays every retained state in a fresh runtime.
  const app = await NativeApp.start({ width: 1060, height: 720, timeoutMs: 60000 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], save = () => snapshots.push(s);
    const region = (name: string) => findWidget(s, { role: "group", name });
    const button = (name: string) => findWidget(s, { role: "button", name });
    const scroll = (name: string) => { const state = region(name).scroll; assert.ok(state, name); return state; };
    const offsets = (name: string, x: number, y: number) => {
      assert.equal(scroll(name).offsetX, Math.fround(x), `${name} X`);
      assert.equal(scroll(name).offsetY, Math.fround(y), `${name} Y`); save();
    };
    const max = (name: string) => {
      const state = scroll(name);
      return { x: Math.max(0, Math.fround(state.contentExtentX - state.viewportExtentX)),
        y: Math.max(0, Math.fround(state.contentExtentY - state.viewportExtentY)) };
    };
    const view = region("Project board").view, reading = region("Reading notes").id;
    offsets("Project board", 0.5, 0.5); offsets("Reference shelf", 0.5, 0);
    offsets("Reading notes", 0, 18.5);
    assert.equal(button("Origin").scroll, null);
    s = await app.action(region("Project board"), "focus"); save();
    for (const [key, dx, dy] of [
      ["arrowright", line(scroll("Project board").viewportExtentX), 0],
      ["arrowdown", 0, line(scroll("Project board").viewportExtentY)],
      ["arrowleft", -line(scroll("Project board").viewportExtentX), 0],
      ["arrowup", 0, -line(scroll("Project board").viewportExtentY)],
      ["pagedown", 0, page(scroll("Project board").viewportExtentY)],
      ["pageup", 0, -page(scroll("Project board").viewportExtentY)],
    ] as const) {
      const before = scroll("Project board"), range = max("Project board");
      s = await app.key(view, key);
      offsets("Project board", Math.min(range.x, Math.max(0, add(before.offsetX, dx))), Math.min(range.y, Math.max(0, add(before.offsetY, dy))));
      assert.equal(s.model.boardX, scroll("Project board").offsetX); assert.equal(s.model.boardY, scroll("Project board").offsetY);
    }
    for (const key of ["super+arrowright", "ctrl+pagedown", "alt+home", "space", "enter"]) {
      const before = scroll("Project board"); s = await app.key(view, key); offsets("Project board", before.offsetX, before.offsetY);
    }
    let range = max("Project board"); s = await app.key(view, "end"); offsets("Project board", range.x, range.y);
    s = await app.key(view, "home"); offsets("Project board", 0, 0);
    s = await app.click(button("Middle")); offsets("Project board", 140.5, 180.5); offsets("Reference shelf", 120.5, 0);
    s = await app.click(button("X preset")); offsets("Project board", 75.25, 180.5);
    s = await app.click(button("Y preset")); offsets("Project board", 75.25, 95.75);
    s = await app.click(button("Refresh")); offsets("Project board", 75.25, 95.75);
    s = await app.action(region("Reference shelf"), "focus"); save();
    s = await app.key(view, "arrowdown"); offsets("Reference shelf", add(120.5, line(scroll("Reference shelf").viewportExtentX)), 0);
    s = await app.key(view, "home"); offsets("Reference shelf", 0, 0);
    s = await app.action(region("Reference shelf"), "increment"); offsets("Reference shelf", page(scroll("Reference shelf").viewportExtentX), 0);
    s = await app.action(region("Reference shelf"), "decrement"); offsets("Reference shelf", 0, 0);
    s = await app.action(region("Reading notes"), "focus");
    s = await app.key(view, "arrowdown"); const retained = scroll("Reading notes").offsetY; assert.ok(retained > 18.5); save();
    s = await app.click(button("Refresh")); offsets("Reading notes", 0, retained);
    s = await app.click(button("Reverse")); assert.equal(region("Reading notes").id, reading); offsets("Reading notes", 0, retained);
    s = await app.click(button("Origin")); offsets("Project board", 0, 0);
    s = await app.wheel(region("Activity log"), 55.25, 60.5);
    assert.ok(scroll("Activity log").offsetY > 0); assert.ok(scroll("Project board").offsetX > 0);
    assert.equal(scroll("Project board").offsetY, 0); save();
    const nested = scroll("Activity log").offsetY;
    s = await app.click(button("Refresh")); offsets("Activity log", 0, nested);
    s = await app.action(region("Activity log"), "focus");
    s = await app.key(view, "end"); offsets("Activity log", 0, max("Activity log").y);
    s = await app.wheel(region("Activity log"), 30.5, 0); assert.ok(scroll("Project board").offsetY > 0); save();
    s = await app.click(button("Middle"));
    s = await app.click(button("Change axis")); offsets("Project board", 0, 180.5);
    assert.equal(scroll("Project board").contentExtentX, scroll("Project board").viewportExtentX);
    s = await app.click(button("Change axis")); offsets("Project board", 0, 180.5);
    s = await app.click(button("X preset")); offsets("Project board", 75.25, 180.5);
    s = await app.click(button("Far corner")); range = max("Project board"); offsets("Project board", range.x, range.y); offsets("Reference shelf", max("Reference shelf").x, 0);
    s = await app.click(button("Hide reading")); assert.ok(!s.widgets.some(widget => widget.name === "Reading notes")); save();
    s = await app.click(button("Hide reading")); assert.equal(region("Reading notes").id, reading); offsets("Reading notes", 0, 18.5);
    s = await app.click(button("Empty")); offsets("Project board", 0, 0); offsets("Reference shelf", 0, 0); save();
    s = await app.click(button("Refresh")); save();
    s = await app.click(button("Empty")); save();
    s = await app.click(button("New desk")); assert.notEqual(region("Reading notes").id, reading); offsets("Project board", 0.5, 0.5); offsets("Reading notes", 0, 18.5);
    assert.equal(s.model.desk, 1); assert.equal(s.model.changes, 0);
    const replay = await app.verifyReplay(); assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
