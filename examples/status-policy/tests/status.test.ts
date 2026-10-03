import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";
const text = (bytes: unknown): string => new TextDecoder().decode(new Uint8Array(bytes as number[]));

test("status items preserve complete shell/menu state, scoped row routes, effects and replay", async () => {
  const app = await NativeApp.start({ width: 760, height: 500, wallMs: 12345 });
  try {
    let s = await app.snapshot(); const snapshots: NativeSnapshot[] = [s];
    const save = () => snapshots.push(s);
    const press = async (name: string) => { s = await app.click(findWidget(s, { role: "button", name })); save(); };
    const ids = () => s.statusItems.map(i => i.id).sort((a, b) => a - b);
    const item = (id: number) => s.statusItems.find(i => i.id === id)!;
    assert.deepEqual(ids(), [100, 200, 300]);
    assert.equal(text(item(100).presentation.title), "SESSIONS");
    assert.equal(text(item(100).items[1]!.metric && (item(100).items[1]!.metric as Record<string, unknown>).accessibility_label), "Workspace metric");
    const original = s.statusItems;
    await press("Reverse order");assert.deepEqual(s.statusItems, original);
    s = await app.statusItemAction(100, 1);save();assert.equal(s.model.count, 1);assert.equal(text(s.model.last), "Session menu received.");
    s = await app.statusItemAction(200, 1);save();assert.equal(s.model.count, 2);assert.equal(text(s.model.last), "Control menu received.");
    s = await app.statusItemAction(100, 2);save();assert.equal(s.model.opens, 0); // Disabled metric row.
    await press("Switch menu route");assert.equal(text(item(100).items[0]!.command), "control.add");
    s = await app.statusItemAction(100, 1);save();assert.equal(s.model.count, 3);assert.equal(text(s.model.last), "Control menu received.");
    await press("Hide / show session");assert.equal(item(100).visible, false);assert.deepEqual(ids(), [100, 200, 300]);
    await press("Change style");assert.equal(text(item(100).presentation.title), "SESSIONS +");assert.equal(item(100).presentation.width, 116);
    assert.equal(item(100).presentation.monospaced, true);assert.equal(item(100).presentation.font_size, 14);
    await press("Switch item set");assert.deepEqual(ids(), [100, 200]);
    await press("Reverse order");assert.deepEqual(ids(), [100, 200]);
    await press("Remove / restore");assert.deepEqual(ids(), []);
    s = await app.statusItemAction(100, 1);save();assert.equal(s.model.count, 3);
    await press("Remove / restore");assert.deepEqual(ids(), [100, 200]);assert.equal(item(100).visible, false);
    await press("Hide / show session");assert.equal(item(100).visible, true);
    await press("Switch menu route");s = await app.statusItemAction(100, 1);save();assert.equal(s.model.count, 4);assert.equal(text(s.model.last), "Session menu received.");
    await press("Switch item set");assert.deepEqual(ids(), [100, 200, 300]);
    await press("Stamp");assert.equal(s.model.stampedMs, 12345);assert.ok(s.effects.recorded > 0);
    s = await app.statusItemAction(300, 1);save();assert.deepEqual(ids(), []);
    await press("Remove / restore");assert.deepEqual(ids(), [100, 200, 300]);
    const final = s;const replay = await app.verifyReplay();assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.equal(replay.effects, final.effects.recorded);assert.deepEqual(replay.snapshot.model, final.model);
    assert.deepEqual(replay.snapshot.statusItems, final.statusItems);s = replay.snapshot;save();
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const complete = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.status.json`, JSON.stringify(complete));
      else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.status.json`, "utf8")));
    }
  } finally { await app.close(); }
});
