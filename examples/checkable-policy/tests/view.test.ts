import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const checks = ["Product café updates", "Weekly digest", "Managed reports"];
const switches = ["Notifications", "Sync over mobile data", "Managed sync"];
const widget = (s: NativeSnapshot, name: string) => findWidget(s, { role: checks.includes(name) ? "checkbox" : switches.includes(name) ? "switch" : "button", name });
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...s }) => s);
  if (backend === "zig") writeFileSync(`${reference}.preferences.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.preferences.json`, "utf8")));
};

test("checkable preferences retain state, keyboard order, identities and replay", async () => {
  const app = await NativeApp.start({ width: 920, height: 480 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], view = widget(s, "Notifications").view;
    const productId = widget(s, "Product café updates").id, digestId = widget(s, "Weekly digest").id;
    const save = () => snapshots.push(s);
    const selected = (name: string, value: boolean) => { assert.equal(widget(s, name).selected, value); save(); };
    const focused = (name: string) => { assert.equal(widget(s, name).focused, true); save(); };
    const state = (changes: number, refreshes = 0) => { assert.equal(s.model.changes, changes); assert.equal(s.model.refreshes, refreshes); save(); };
    selected("Product café updates", false); selected("Weekly digest", true);
    selected("Notifications", true); selected("Sync over mobile data", false); selected("Compact rows", true);
    assert.equal(widget(s, "Managed reports").enabled, false); assert.equal(widget(s, "Managed sync").enabled, false);
    s = await app.click(widget(s, "Product café updates")); selected("Product café updates", true); state(1);
    s = await app.key(view, "enter"); selected("Product café updates", false); state(2);
    s = await app.key(view, "space"); selected("Product café updates", true); state(3);
    s = await app.key(view, "tab"); focused("Weekly digest");
    s = await app.key(view, "space"); selected("Weekly digest", false); state(4);
    s = await app.key(view, "tab"); focused("Notifications");
    s = await app.key(view, "enter"); selected("Notifications", false); state(5);
    s = await app.key(view, "tab"); focused("Sync over mobile data");
    s = await app.key(view, "space"); selected("Sync over mobile data", true); state(6);
    s = await app.key(view, "tab"); focused("Compact rows");
    s = await app.key(view, "enter"); selected("Compact rows", false); state(7);
    s = await app.key(view, "shift+tab"); focused("Sync over mobile data");
    s = await app.action(widget(s, "Notifications"), "toggle"); selected("Notifications", true); state(8);
    s = await app.action(widget(s, "Weekly digest"), "toggle"); selected("Weekly digest", true); state(9);
    s = await app.key(view, "arrowright"); focused("Weekly digest"); state(9);
    s = await app.click(widget(s, "Refresh")); state(9, 1);
    for (const name of ["Product café updates", "Weekly digest", "Notifications", "Sync over mobile data"]) selected(name, true);
    selected("Compact rows", false);
    s = await app.click(widget(s, "Reverse"));
    assert.equal(widget(s, "Product café updates").id, productId); assert.equal(widget(s, "Weekly digest").id, digestId);
    s = await app.action(widget(s, "Weekly digest"), "focus"); s = await app.key(view, "tab"); focused("Product café updates");
    s = await app.key(view, "shift+tab"); focused("Weekly digest");
    s = await app.click(widget(s, "Hide product")); assert.ok(!s.widgets.some(w => w.name === "Product café updates")); save();
    s = await app.click(widget(s, "Refresh")); state(9, 2);
    s = await app.click(widget(s, "Hide product")); assert.equal(widget(s, "Product café updates").id, productId); selected("Product café updates", true);
    s = await app.click(widget(s, "Empty")); assert.ok(s.widgets.some(w => w.name === "No email preferences")); save();
    s = await app.click(widget(s, "Refresh")); state(9, 3); selected("Sync over mobile data", true);
    s = await app.click(widget(s, "Empty")); assert.equal(widget(s, "Weekly digest").id, digestId); selected("Weekly digest", true);
    s = await app.click(widget(s, "Lock settings"));
    for (const name of [...checks, ...switches, "Compact rows"]) assert.equal(widget(s, name).enabled, false);
    save();
    for (const name of ["Product café updates", "Notifications", "Managed reports", "Managed sync"]) {
      const target = widget(s, name), point = { x: target.bounds.x + 5, y: target.bounds.y + 5 };
      await app.pointer(target, "down", point); s = await app.pointer(target, "up", point); state(9, 3);
    }
    s = await app.click(widget(s, "Lock settings")); selected("Product café updates", true); selected("Sync over mobile data", true); selected("Compact rows", false);
    s = await app.click(widget(s, "New profile")); state(0);
    assert.equal(s.model.profile, 1); assert.notEqual(widget(s, "Product café updates").id, productId);
    selected("Product café updates", false); selected("Weekly digest", true); selected("Notifications", true); selected("Sync over mobile data", false); selected("Compact rows", true);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
