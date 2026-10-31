import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const compare = (snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  if (backend === "zig") writeFileSync(`${reference}.desk.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.desk.json`, "utf8")));
};

test("research panels retain independent widths through rebuilds, keyed changes and replay", async () => {
  const app = await NativeApp.start({ width: 960, height: 600 });
  try {
    let s = await app.snapshot();
    if (backend) assert.equal(s.viewBackend, backend);
    const snapshots = [s], save = () => snapshots.push(s);
    const panel = (name: string) => findWidget(s, { role: "group", name });
    const button = (name: string) => findWidget(s, { role: "button", name });
    const width = (name: string, expected: number) => { assert.equal(panel(name).bounds.width, expected, name); save(); };
    const click = async (name: string) => { s = await app.click(button(name)); save(); };
    const drag = async (name: string, delta: number) => {
      const target = panel(name), origin = { x: target.bounds.x + target.bounds.width - 4, y: target.bounds.y + target.bounds.height / 2 };
      s = await app.pointer(target, "down", origin); save();
      const destination = { x: origin.x + delta, y: origin.y };
      s = await app.pointer(target, "drag", destination, { x: delta, y: 0 }); save();
      s = await app.pointer(target, "up", destination); save();
    };
    const notesId = panel("Notes").id, referenceId = panel("Reference").id;
    width("Sources", 240); width("Notes", 220); width("Reference", 240);
    assert.equal(panel("Reference").enabled, false);
    const model = s.model, neighbor = panel("Reading area").bounds;
    const child = findWidget(s, { role: "text", name: "Field notes" }).bounds;
    await drag("Sources", 12.5); width("Sources", 252.5);
    assert.deepEqual(s.model, model);
    assert.deepEqual(panel("Reading area").bounds, neighbor);
    assert.deepEqual(findWidget(s, { role: "text", name: "Field notes" }).bounds, child);
    await click("Refresh"); width("Sources", 252.5);
    await drag("Sources", -1000); width("Sources", 144);
    await drag("Notes", 32.25); width("Notes", 252.25);
    await drag("Reference", 70); width("Reference", 240);
    await click("Wide defaults"); width("Notes", 252.25);
    await click("Reverse"); assert.equal(panel("Notes").id, notesId); assert.equal(panel("Reference").id, referenceId); width("Notes", 252.25);
    await drag("Notes", -1000); width("Notes", 112);
    await click("Taller cards"); width("Notes", 160);
    await click("Taller cards"); width("Notes", 160);
    await drag("Notes", 23.5); width("Notes", 183.5);
    await click("Refresh"); width("Notes", 183.5);
    await click("Hide notes"); assert.ok(!s.widgets.some(widget => widget.role === "group" && widget.name === "Notes"));
    await click("Hide notes"); assert.equal(panel("Notes").id, notesId); width("Notes", 300);
    await click("Empty"); assert.ok(s.widgets.some(widget => widget.name === "No research cards"));
    await click("Refresh"); await click("Empty"); assert.equal(panel("Notes").id, notesId); width("Notes", 300);
    await click("Lock panels"); width("Sources", 240); width("Notes", 300);
    const locked = s.model;
    for (const name of ["Sources", "Notes", "Reference"]) {
      assert.equal(panel(name).enabled, false);
      await drag(name, 70); assert.deepEqual(s.model, locked);
    }
    await click("Lock panels"); width("Sources", 240); width("Notes", 300);
    await drag("Notes", -40); width("Notes", 260);
    await click("Wide defaults"); width("Notes", 260);
    await click("New desk"); assert.notEqual(panel("Notes").id, notesId); width("Sources", 240); width("Notes", 220);
    assert.equal(s.model.desk, 1); assert.equal(s.model.refreshes, 0);
    const replay = await app.verifyReplay(); assert.deepEqual(replay.snapshot.model, s.model); assert.deepEqual(replay.snapshot.widgets, s.widgets);
    snapshots.push(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
