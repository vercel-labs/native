import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const item = (s: NativeSnapshot, name: string) => findWidget(s, { role: "menuitem", name });
const button = (s: NativeSnapshot, name: string) => findWidget(s, { role: "button", name });
const menu = (s: NativeSnapshot, name: string) => findWidget(s, { role: "menu", name });
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...s }) => s);
  if (backend === "zig") writeFileSync(`${reference}.navigation.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.navigation.json`, "utf8")));
};

test("menu entry, traversal, committed choice, dismissal, identities and replay match", async () => {
  const app = await NativeApp.start({ width: 800, height: 420 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], view = button(s, "Choose queue").view;
    const save = () => snapshots.push(s);
    const focused = (name: string) => { assert.equal(item(s, name).focused, true); save(); };
    s = await app.action(button(s, "Reset"), "focus"); save();
    for (const name of ["Choose queue", "Open actions", "Choose environment", "Reverse", "Hide review", "Empty", "Reset"]) {
      s = await app.key(view, "tab"); assert.equal(button(s, name).focused, true); save();
    }
    for (const name of ["Empty", "Hide review", "Reverse", "Choose environment", "Open actions", "Choose queue", "Reset"]) {
      s = await app.key(view, "shift+tab"); assert.equal(button(s, name).focused, true); save();
    }
    const closed = (field: string, trigger: string) => {
      assert.equal(s.model[field], false);
      assert.equal(s.widgets.some(w => w.role === "menuitem"), false);
      assert.equal(button(s, trigger).focused, true); save();
    };
    s = await app.click(button(s, "Choose queue")); assert.equal(s.model.pickerOpen, true); save();
    const reviewId = item(s, "Review café").id, archiveId = item(s, "Archive").id;
    const popup = menu(s, "Queues"), trigger = button(s, "Choose queue");
    assert.equal(popup.bounds.x, trigger.bounds.x);
    assert.ok(popup.bounds.y >= trigger.bounds.y + trigger.bounds.height);
    assert.ok(popup.bounds.width >= trigger.bounds.width);
    s = await app.key(view, "arrowdown"); focused("Review café");
    assert.equal(item(s, "Review café").selected, true);
    s = await app.key(view, "arrowdown"); focused("Release"); assert.equal(s.model.selected, 2);
    s = await app.key(view, "arrowdown"); focused("Archive");
    s = await app.key(view, "arrowdown"); focused("Archive");
    s = await app.key(view, "home"); focused("Inbox");
    s = await app.key(view, "arrowup"); focused("Inbox");
    s = await app.key(view, "end"); focused("Archive");
    s = await app.key(view, "tab"); closed("pickerOpen", "Choose queue");
    s = await app.key(view, "tab"); assert.equal(button(s, "Open actions").focused, true); save();
    s = await app.key(view, "shift+tab"); assert.equal(button(s, "Choose queue").focused, true); save();
    s = await app.key(view, "enter"); assert.equal(s.model.pickerOpen, true); save();
    s = await app.key(view, "arrowdown"); focused("Review café");
    s = await app.key(view, "arrowdown"); focused("Release");
    s = await app.key(view, "enter"); assert.equal(s.model.selected, 4); closed("pickerOpen", "Choose queue");
    s = await app.key(view, "enter"); assert.equal(s.model.pickerOpen, true); save();
    s = await app.key(view, "arrowup"); focused("Release");
    s = await app.key(view, "shift+tab"); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Choose queue")); save();
    s = await app.click(button(s, "Choose queue")); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Choose queue")); save();
    const unavailable = item(s, "Unavailable"); assert.equal(unavailable.enabled, false);
    const point = { x: unavailable.bounds.x + 10, y: unavailable.bounds.y + 10 };
    await app.pointer(unavailable, "down", point);
    s = await app.pointer(unavailable, "up", point); assert.equal(s.model.selected, 4); assert.equal(s.model.pickerOpen, true); save();
    const outside = { x: 790, y: 410 };
    await app.pointer(trigger, "down", outside);
    s = await app.pointer(trigger, "up", outside); assert.equal(s.model.pickerOpen, false); save();
    s = await app.click(button(s, "Open actions")); save();
    assert.equal(s.widgets.filter(w => w.role === "menuitem" && w.selected).length, 0);
    s = await app.key(view, "arrowup"); focused("Download");
    s = await app.key(view, "home"); focused("Duplicate");
    s = await app.key(view, "arrowdown"); focused("Rename");
    s = await app.key(view, "arrowdown"); focused("Download");
    s = await app.key(view, "space"); assert.equal(s.model.presses, 1); closed("actionsOpen", "Open actions");
    s = await app.click(button(s, "Open actions")); save();
    assert.equal(s.widgets.filter(w => w.role === "menuitem" && w.selected).length, 0);
    s = await app.key(view, "arrowdown"); focused("Duplicate");
    s = await app.key(view, "enter"); assert.equal(s.model.presses, 2); closed("actionsOpen", "Open actions");
    s = await app.click(button(s, "Choose environment")); save();
    s = await app.key(view, "arrowdown"); focused("Production");
    s = await app.key(view, "end"); focused("Staging");
    s = await app.key(view, "enter"); assert.equal(s.model.environment, 102); assert.equal(s.model.selected, 4); closed("environmentOpen", "Choose environment");
    s = await app.click(button(s, "Choose queue")); save();
    s = await app.click(item(s, "Review café")); assert.equal(s.model.selected, 2); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Reverse")); save();
    s = await app.click(button(s, "Choose queue")); assert.equal(item(s, "Review café").id, reviewId); assert.equal(item(s, "Archive").id, archiveId); save();
    s = await app.key(view, "arrowdown"); focused("Review café");
    s = await app.key(view, "home"); focused("Archive");
    s = await app.key(view, "end"); focused("Inbox");
    s = await app.key(view, "escape"); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Hide review")); save();
    s = await app.click(button(s, "Choose queue")); assert.equal(s.widgets.some(w => w.name === "Review café" && w.role === "menuitem"), false); save();
    s = await app.key(view, "arrowdown"); focused("Archive");
    s = await app.key(view, "escape"); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Hide review")); save();
    s = await app.click(button(s, "Choose queue")); assert.equal(item(s, "Review café").id, reviewId); assert.equal(item(s, "Review café").selected, true); save();
    s = await app.key(view, "escape"); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Empty")); save();
    s = await app.click(button(s, "Choose queue")); assert.equal(s.widgets.some(w => w.role === "menuitem"), false); save();
    s = await app.key(view, "arrowdown"); assert.equal(button(s, "Choose queue").focused, true); save();
    s = await app.key(view, "escape"); closed("pickerOpen", "Choose queue");
    s = await app.click(button(s, "Empty")); save();
    s = await app.click(button(s, "Choose queue")); assert.equal(item(s, "Review café").id, reviewId); save();
    s = await app.key(view, "arrowup"); focused("Review café");
    s = await app.key(view, "escape"); closed("pickerOpen", "Choose queue");
    // Closed arrows open the picker; mounted arrows move focus without
    // toggling it closed. Shift remains an activation modifier.
    s = await app.action(button(s, "Choose queue"), "focus"); save();
    for (const chord of ["return", "ctrl+enter", "alt+space", "super+arrowdown"]) {
      s = await app.key(view, chord); assert.equal(s.model.pickerOpen, false); save();
    }
    s = await app.key(view, "shift+arrowdown"); assert.equal(s.model.pickerOpen, true); save();
    s = await app.key(view, "arrowdown"); focused("Review café");
    s = await app.key(view, "shift+enter"); assert.equal(s.model.selected, 2); closed("pickerOpen", "Choose queue");
    s = await app.key(view, "arrowup"); assert.equal(s.model.pickerOpen, true); save();
    s = await app.key(view, "arrowup"); focused("Review café");
    s = await app.key(view, "shift+space"); closed("pickerOpen", "Choose queue");
    s = await app.action(button(s, "Open actions"), "focus"); save();
    s = await app.key(view, "shift+enter"); assert.equal(s.model.actionsOpen, true); save();
    s = await app.key(view, "arrowdown"); focused("Duplicate");
    s = await app.key(view, "shift+space"); assert.equal(s.model.presses, 3); closed("actionsOpen", "Open actions");
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, s.model);
    assert.deepEqual(replay.snapshot.widgets, s.widgets); snapshots.push(replay.snapshot);
    compare(snapshots);
  } finally { await app.close(); }
});
