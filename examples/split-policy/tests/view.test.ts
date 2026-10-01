import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot, type NativeWidget } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  if (backend === "zig") writeFileSync(`${reference}.workspace.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.workspace.json`, "utf8")));
};
const point = (widget: NativeWidget) => ({ x: widget.bounds.x + widget.bounds.width / 2, y: widget.bounds.y + widget.bounds.height / 2 });
const step = (value: number, amount: number) => Math.fround(Math.fround(value) + Math.fround(amount));

test("nested workspace splits mirror fractions, clamp panes, retain keyed previews and replay", async () => {
  const app = await NativeApp.start({ width: 1040, height: 660 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], save = () => snapshots.push(s);
    const group = (name: string) => findWidget(s, { role: "group", name });
    const button = (name: string) => findWidget(s, { role: "button", name });
    const divider = (name: string) => {
      const bounds = group(name).bounds;
      const matches = s.widgets.filter(widget => widget.role === "separator" && widget.name === "Split divider" &&
        widget.bounds.x >= bounds.x && widget.bounds.x < bounds.x + bounds.width &&
        widget.bounds.y === bounds.y && widget.bounds.height === bounds.height).toSorted((a, b) => a.bounds.x - b.bounds.x);
      assert.ok(matches.length, name);
      return matches[0]!;
    };
    const view = divider("Workspace panes").view;
    const value = (name: string, expected: number) => { assert.equal(divider(name).value, Math.fround(expected), name); save(); };
    const modelValue = (field: string, expected: number) => { assert.equal(s.model[field], expected, field); save(); };
    const focused = (name: string) => { assert.equal(divider(name).focused, true, name); save(); };
    const bounds = (name: string, first: number, second: number) => {
      const available = Math.fround(group(name).bounds.width - divider(name).bounds.width);
      return { low: Math.fround(first / available), high: Math.fround(1 - Math.fround(second / available)) };
    };
    const notesId = divider("Notes").id, reviewId = divider("Review").id;
    modelValue("sidebar", 0.24); modelValue("editor", 0.58);
    value("Workspace panes", 0.24); value("Editor panes", 0.58); value("Notes", 0.4);
    assert.equal(divider("Review").enabled, false);
    s = await app.action(divider("Workspace panes"), "focus"); focused("Workspace panes");
    let expected = Math.fround(0.24);
    for (const [key, amount] of [["arrowright", 0.05], ["shift+arrowright", 0.1], ["arrowleft", -0.05], ["shift+arrowleft", -0.1]] as const) {
      s = await app.key(view, key); expected = step(expected, amount); modelValue("sidebar", expected); value("Workspace panes", expected);
    }
    let edges = bounds("Workspace panes", 150, 390);
    s = await app.key(view, "home"); modelValue("sidebar", edges.low); value("Workspace panes", edges.low);
    s = await app.key(view, "arrowleft"); modelValue("sidebar", edges.low);
    s = await app.key(view, "end"); modelValue("sidebar", edges.high); value("Workspace panes", edges.high);
    const resizes = s.model.resizes;
    for (const key of ["arrowup", "arrowdown", "enter", "space", "pageup", "pagedown", "super+arrowleft", "ctrl+arrowright", "alt+home"]) {
      s = await app.key(view, key); assert.equal(s.model.resizes, resizes); save();
    }
    s = await app.click(button("Writing preset")); modelValue("sidebar", 0.3); modelValue("editor", 0.45);
    s = await app.action(divider("Workspace panes"), "focus");
    s = await app.key(view, "tab"); focused("Editor panes");
    s = await app.key(view, "shift+arrowright"); modelValue("editor", step(0.45, 0.1));
    s = await app.key(view, "shift+tab"); focused("Workspace panes");
    s = await app.action(divider("Editor panes"), "focus");
    edges = bounds("Editor panes", 200, 180);
    s = await app.key(view, "home"); modelValue("editor", edges.low); value("Editor panes", edges.low);
    s = await app.key(view, "end"); modelValue("editor", edges.high); value("Editor panes", edges.high);
    const outer = divider("Workspace panes"), root = group("Workspace panes"), available = root.bounds.width - outer.bounds.width;
    const destination = (fraction: number) => ({ x: root.bounds.x + available * fraction + outer.bounds.width / 2, y: point(outer).y });
    s = await app.pointer(outer, "down", point(outer)); save();
    s = await app.pointer(outer, "drag", destination(-0.2)); modelValue("sidebar", bounds("Workspace panes", 150, 390).low);
    s = await app.pointer(outer, "drag", destination(1.2)); modelValue("sidebar", bounds("Workspace panes", 150, 390).high);
    s = await app.pointer(outer, "drag", destination(0.25)); save();
    s = await app.pointer(outer, "up", destination(0.25)); modelValue("sidebar", 0.25); value("Workspace panes", 0.25);
    s = await app.click(button("Refresh")); modelValue("sidebar", 0.25); save();
    s = await app.action(divider("Notes"), "focus"); focused("Notes");
    s = await app.key(view, "arrowright"); value("Notes", step(0.4, 0.05));
    const retained = divider("Notes").value!;
    s = await app.click(button("Refresh")); value("Notes", retained);
    s = await app.click(button("Reverse")); assert.equal(divider("Notes").id, notesId); assert.equal(divider("Review").id, reviewId); value("Notes", retained);
    s = await app.click(button("Preview preset")); value("Notes", 0.7);
    s = await app.click(button("Hide notes")); assert.ok(!s.widgets.some(widget => widget.role === "group" && widget.name === "Notes")); save();
    s = await app.click(button("Hide notes")); assert.equal(divider("Notes").id, notesId); value("Notes", 0.7);
    s = await app.click(button("Empty")); assert.ok(s.widgets.some(widget => widget.name === "No previews")); save();
    s = await app.click(button("Refresh")); save();
    s = await app.click(button("Empty")); assert.equal(divider("Notes").id, notesId); value("Notes", 0.7);
    s = await app.click(button("Lock layout")); save();
    const before = s.model;
    for (const name of ["Workspace panes", "Editor panes", "Notes", "Review"]) {
      assert.equal(divider(name).enabled, false);
      const target = divider(name), origin = point(target);
      await app.pointer(target, "down", origin);
      await app.pointer(target, "drag", { x: origin.x + 50, y: origin.y });
      s = await app.pointer(target, "up", { x: origin.x + 50, y: origin.y });
      assert.deepEqual(s.model, before); save();
    }
    s = await app.click(button("Lock layout"));
    s = await app.click(button("New workspace")); assert.notEqual(divider("Notes").id, notesId); modelValue("sidebar", 0.24); modelValue("editor", 0.58); value("Notes", 0.4);
    assert.equal(s.model.workspace, 1); assert.equal(s.model.resizes, 0);
    const replay = await app.verifyReplay(); assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
