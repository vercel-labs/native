import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import test from "node:test";
import { dirname } from "node:path";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";
function compare(values: readonly NativeSnapshot[]) {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const snapshots = values.map(({ viewBackend, ...s }) => s);
  if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") {
    mkdirSync(dirname(reference), { recursive: true });
    writeFileSync(`${reference}.json`, JSON.stringify(snapshots));
  } else assert.deepEqual(snapshots, JSON.parse(readFileSync(`${reference}.json`, "utf8")), "complete snapshots must match the reference view");
}

const button = (s: NativeSnapshot, name: string) => findWidget(s, { role: "button", name });
test("Canvas Preview retains toolbar, commands, full tray records, frame state and replay", async () => {
  const app = await NativeApp.start({ width: 960, height: 640 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    const save = (value: NativeSnapshot) => { s = value; snapshots.push(s); };
    assert.ok(s.widgets.some(w => w.name === "URL: https://example.com/"));
    assert.equal(s.webViews.length, 1); assert.equal(s.webViews[0]!.url, "https://example.com/");
    assert.equal(s.statusItems.length, 1);
    const tray = s.statusItems[0]!;
    assert.equal(new TextDecoder().decode(new Uint8Array(tray.tooltip)), "Native SDK Canvas Preview");
    assert.equal(tray.items.length, 4);
    save(await app.frame()); assert.equal(s.model.gpu_frames_seen, true);
    save(await app.click(button(s, "Docs"))); assert.equal(s.model.page, "docs");
    assert.ok(s.widgets.some(w => w.name === "URL: https://native-sdk.dev/"));
    assert.equal(s.webViews[0]!.url, "https://native-sdk.dev/");
    save(await app.click(button(s, "Reload"))); assert.equal(s.model.reload_count, 1);
    save(await app.menu("app.example")); assert.equal(s.model.page, "example");
    save(await app.statusItemAction(tray.id, 2)); assert.equal(s.model.page, "docs");
    save(await app.statusItemAction(tray.id, 3)); assert.equal(s.model.reload_count, 2);
    save(await app.statusItemAction(tray.id, 1)); assert.equal(s.model.page, "example");
    assert.deepEqual(s.statusItems, [tray]);
    const before = s.model;
    save(await app.menu("unknown")); assert.deepEqual(s.model, before);
    const recorded = s;
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.deepEqual(replay.snapshot.model, recorded.model);
    assert.deepEqual(replay.snapshot.widgets, recorded.widgets);
    assert.deepEqual(replay.snapshot.effects, recorded.effects);
    assert.deepEqual(replay.snapshot.statusItems, recorded.statusItems);
    assert.deepEqual(replay.snapshot.webViews, recorded.webViews);
    assert.equal(replay.snapshot.fingerprint, recorded.fingerprint);
    save(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
