import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";
const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const radio = (s: NativeSnapshot, name: string) => findWidget(s, { role: "radio", name });
const button = (s: NativeSnapshot, name: string) => findWidget(s, { role: "button", name });
const compare = (name: string, snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...s }) => s);
  if (backend === "zig") writeFileSync(`${reference}.${name}.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.${name}.json`, "utf8")));
};
test("radio selection, nested scopes, arrows, edges, Tab, identity and replay match", async () => {
  const app = await NativeApp.start({ width: 760, height: 580 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], view = radio(s, "Standard").view;
    const expressId = radio(s, "Express").id;
    const cycle = async (selected: string, nested: string) => {
      s = await app.action(button(s, "Reset"), "focus"); snapshots.push(s);
      for (const name of [selected, nested, "Reverse", "Hide priority", "Reset"]) {
        s = await app.key(view, "tab");
        assert.equal(findWidget(s, { role: name === selected || name === nested ? "radio" : "button", name }).focused, true); snapshots.push(s);
      }
      for (const name of ["Hide priority", "Reverse", nested, selected, "Reset"]) {
        s = await app.key(view, "shift+tab");
        assert.equal(findWidget(s, { role: name === selected || name === nested ? "radio" : "button", name }).focused, true); snapshots.push(s);
      }
    };
    await cycle("Priority café", "Paper");
    const check = (name: string, selected: number, changes: number) => {
      assert.equal(s.model.selected, selected);
      assert.equal(s.model.changes, changes);
      assert.equal(radio(s, name).selected, true);
      assert.equal(s.widgets.filter(w => w.role === "radio" && w.selected).length, 2);
      snapshots.push(s);
    };
    s = await app.click(radio(s, "Priority café")); check("Priority café", 2, 0);
    await app.action(radio(s, "Priority café"), "focus");
    s = await app.key(view, "space"); check("Priority café", 2, 0);
    s = await app.key(view, "enter"); check("Priority café", 2, 0);
    s = await app.key(view, "arrowright"); check("Express", 3, 1);
    assert.equal(radio(s, "Express").focused, true);
    s = await app.key(view, "arrowdown"); check("Standard", 1, 2);
    s = await app.key(view, "arrowleft"); check("Express", 3, 3);
    s = await app.key(view, "arrowup"); check("Priority café", 2, 4);
    s = await app.key(view, "home"); check("Standard", 1, 5);
    s = await app.key(view, "end"); check("Express", 3, 6);
    s = await app.key(view, "end"); check("Express", 3, 6);
    await app.action(button(s, "Reset"), "focus");
    s = await app.key(view, "tab");
    assert.equal(radio(s, "Express").focused, true); snapshots.push(s);
    s = await app.key(view, "tab");
    assert.equal(radio(s, "Paper").focused, true); snapshots.push(s);
    s = await app.key(view, "arrowright");
    assert.equal(s.model.nested, 12); assert.equal(s.model.selected, 3);
    assert.equal(radio(s, "Reusable").selected, true); snapshots.push(s);
    s = await app.key(view, "tab");
    assert.equal(button(s, "Reverse").focused, true); snapshots.push(s);
    s = await app.key(view, "shift+tab");
    assert.equal(radio(s, "Reusable").focused, true); snapshots.push(s);
    s = await app.key(view, "shift+tab");
    assert.equal(radio(s, "Express").focused, true); snapshots.push(s);
    const disabled = radio(s, "Unavailable");
    assert.equal(disabled.enabled, false);
    const point = { x: disabled.bounds.x + disabled.bounds.width / 2, y: disabled.bounds.y + disabled.bounds.height / 2 };
    await app.pointer(disabled, "down", point);
    s = await app.pointer(disabled, "up", point);
    assert.equal(s.model.changes, 7); snapshots.push(s);
    s = await app.click(button(s, "Reverse"));
    assert.equal(radio(s, "Express").id, expressId); snapshots.push(s);
    await app.action(radio(s, "Express"), "focus");
    s = await app.key(view, "arrowright"); check("Standard", 1, 8);
    s = await app.key(view, "end"); check("Priority café", 2, 9);
    s = await app.click(button(s, "Hide priority"));
    assert.equal(s.widgets.some(w => w.role === "radio" && w.name === "Priority café"), false); snapshots.push(s);
    await cycle("Express", "Reusable");
    await app.action(button(s, "Reset"), "focus");
    s = await app.key(view, "tab");
    assert.equal(radio(s, "Express").focused, true); snapshots.push(s);
    s = await app.click(button(s, "Hide priority"));
    assert.equal(radio(s, "Priority café").selected, true); snapshots.push(s);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, s.model);
    assert.deepEqual(replay.snapshot.widgets, s.widgets); snapshots.push(replay.snapshot);
    compare("navigation", snapshots);
  } finally { await app.close(); }
});
