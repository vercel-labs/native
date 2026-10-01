import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot, type NativeWidget } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...s }) => s);
  if (backend === "zig") writeFileSync(`${reference}.mixer.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.mixer.json`, "utf8")));
};
const point = (widget: NativeWidget, fraction: number) => ({ x: widget.bounds.x + widget.bounds.width * fraction, y: widget.bounds.y + widget.bounds.height / 2 });
const step = (value: number, amount: number) => Math.max(0, Math.min(1, Math.fround(Math.fround(value) + Math.fround(amount))));

test("mixer sliders apply float changes, retain trims, keep keyed identity, and replay", async () => {
  const app = await NativeApp.start({ width: 1040, height: 520 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s];
    const slider = (name: string) => findWidget(s, { role: "slider", name });
    const button = (name: string) => findWidget(s, { role: "button", name });
    const view = slider("Master output").view;
    const acousticId = slider("Acoustic café").id, bassId = slider("Bass").id;
    const save = () => snapshots.push(s);
    const level = (field: string, value: number) => { assert.equal(s.model[field], value, field); save(); };
    const position = (name: string, value: number) => { assert.equal(slider(name).value, Math.fround(value), name); save(); };
    const focused = (name: string) => { assert.equal(slider(name).focused, true, `${name}: focused=${s.widgets.filter(w => w.focused).map(w => w.name)}`); save(); };
    const text = (name: string) => { assert.ok(s.widgets.some(w => w.name === name), name); save(); };
    level("master", 0.35); level("preview", 0.5); text("Master output · 35%");
    position("Master output", 0.35); position("Acoustic café", 0.25); position("Bass", 0.6);
    assert.equal(slider("Managed monitor").enabled, false);
    s = await app.action(slider("Master output"), "focus"); focused("Master output");
    let expected = Math.fround(0.35);
    for (const [key, amount] of [["arrowright", 0.05], ["arrowup", 0.05], ["arrowleft", -0.05], ["arrowdown", -0.05], ["shift+arrowright", 0.1], ["shift+arrowleft", -0.1]] as const) {
      s = await app.key(view, key); expected = step(expected, amount); level("master", expected);
    }
    s = await app.key(view, "home"); level("master", 0);
    s = await app.key(view, "arrowleft"); level("master", 0);
    s = await app.key(view, "end"); level("master", 1);
    s = await app.key(view, "arrowup"); level("master", 1);
    s = await app.action(slider("Master output"), "decrement"); level("master", step(1, -0.05));
    s = await app.action(slider("Master output"), "increment"); level("master", 1);
    const unchanged = s.model.changes;
    for (const key of ["enter", "space", "pageup", "pagedown", "super+arrowleft", "alt+arrowright", "ctrl+arrowdown"]) {
      s = await app.key(view, key); assert.equal(s.model.changes, unchanged); level("master", 1);
    }
    s = await app.key(view, "tab"); focused("Preview level");
    s = await app.key(view, "shift+arrowdown"); level("preview", step(0.5, -0.1));
    s = await app.key(view, "shift+tab"); focused("Master output");
    const master = slider("Master output"), half = point(master, 0.5);
    s = await app.pointer(master, "down", half); level("master", 0.5);
    s = await app.pointer(master, "drag", point(master, 1.2)); level("master", 1);
    s = await app.pointer(master, "drag", point(master, -0.2)); level("master", 0);
    s = await app.pointer(master, "up", point(master, 0.25)); level("master", 0.25);
    text("Master output · 25%");
    const preview = slider("Preview level");
    s = await app.pointer(preview, "down", point(preview, 0.75)); level("preview", 0.75);
    s = await app.pointer(preview, "cancel", point(preview, 0.75)); level("preview", 0.75);
    s = await app.click(button("Refresh")); level("master", 0.25); level("preview", 0.75);
    s = await app.action(slider("Acoustic café"), "focus");
    s = await app.key(view, "end"); save();
    position("Acoustic café", 1);
    const trimChanges = s.model.trimChanges;
    s = await app.click(button("Refresh")); assert.equal(s.model.trimChanges, trimChanges); save();
    position("Acoustic café", 1);
    s = await app.action(slider("Acoustic café"), "focus");
    s = await app.key(view, "tab"); focused("Bass");
    s = await app.key(view, "tab"); assert.equal(slider("Managed monitor").focused, false); save();
    s = await app.click(button("Studio preset")); level("master", 0.8); level("preview", 0.2); save();
    position("Master output", 0.8); position("Acoustic café", 0.65); position("Bass", 0.6);
    s = await app.click(button("Reverse")); assert.equal(slider("Acoustic café").id, acousticId); assert.equal(slider("Bass").id, bassId); save();
    position("Acoustic café", 0.65);
    s = await app.action(slider("Bass"), "focus"); s = await app.key(view, "tab"); focused("Acoustic café");
    s = await app.click(button("Hide acoustic")); assert.ok(!s.widgets.some(w => w.role === "slider" && w.name === "Acoustic café")); save();
    s = await app.click(button("Hide acoustic")); assert.equal(slider("Acoustic café").id, acousticId); save();
    position("Acoustic café", 0.65);
    s = await app.click(button("Empty")); text("No tracks");
    s = await app.click(button("Refresh")); save();
    s = await app.click(button("Empty")); assert.equal(slider("Bass").id, bassId); save();
    position("Bass", 0.6); position("Acoustic café", 0.65);
    s = await app.click(button("Lock mixer"));
    for (const name of ["Master output", "Preview level", "Acoustic café", "Bass", "Managed monitor"]) assert.equal(slider(name).enabled, false);
    const before = s.model; save();
    for (const name of ["Master output", "Preview level", "Acoustic café", "Managed monitor"]) {
      const target = slider(name);
      await app.pointer(target, "down", point(target, 0.1)); s = await app.pointer(target, "up", point(target, 0.1));
      assert.deepEqual(s.model, before); save();
    }
    s = await app.click(button("Lock mixer")); level("master", 0.8); level("preview", 0.2);
    s = await app.click(button("New mixer"));
    assert.equal(s.model.profile, 1); assert.notEqual(slider("Acoustic café").id, acousticId);
    assert.equal(s.model.changes, 0); assert.equal(s.model.trimChanges, 0);
    level("master", 0.35); level("preview", 0.5);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
