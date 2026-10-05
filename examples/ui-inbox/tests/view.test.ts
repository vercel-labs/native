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

const rows = (s: NativeSnapshot) => s.widgets.filter(w => w.role === "listitem");
const button = (s: NativeSnapshot, name: string) => findWidget(s, { role: "button", name });
const draft = (s: NativeSnapshot) => s.widgets.find(w => w.role === "textbox")!;
test("Inbox retains keyed editing, context menus, capacity, full effects and sealed replay", async () => {
  const app = await NativeApp.start({ width: 720, height: 520 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    const save = (value: NativeSnapshot) => { s = value; snapshots.push(s); };
    assert.deepEqual(rows(s).map(w => w.name), ["Prove the ui builder end to end", "Rewrite gpu-dashboard with it", "Record the authoring decisions"]);
    const original = rows(s).map(w => w.id);
    save(await app.setText(draft(s), "  Café task  "));
    save(await app.key(draft(s).view, "enter"));
    assert.equal(rows(s)[3]!.name, "Café task"); assert.equal(draft(s).text, "");
    save(await app.setText(draft(s), " \t "));
    save(await app.click(button(s, "Add task")));
    assert.equal(rows(s)[4]!.name, "Task 5");
    save(await app.setText(draft(s), "abcdefghijklmnopqrstuvwxyz12345é"));
    assert.equal(draft(s).text, "abcdefghijklmnopqrstuvwxyz12345");
    save(await app.selectText(draft(s), 0, 31));
    save(await app.composeText(draft(s), "日本"));
    save(await app.cancelComposition(draft(s)));
    save(await app.setText(draft(s), "ab"));
    save(await app.selectText(draft(s), 1, 2));
    save(await app.composeText(draft(s), "é"));
    save(await app.commitComposition(draft(s)));
    assert.equal(draft(s).text, "aé");
    save(await app.click(button(s, "Add task")));
    save(await app.contextPress(rows(s)[0]!));
    const menu = s.contextMenu!;
    assert.equal(menu.target, original[0]);
    assert.deepEqual(menu.items, [{ id: 1, label: Array.from(new TextEncoder().encode("Toggle done")), enabled: true, separator: false }]);
    save(await app.contextMenuAction(menu, 0)); assert.equal(s.contextMenu, null);
    save(await app.contextPress(rows(s)[0]!));
    const current = s.contextMenu!;
    save(await app.contextMenuAction(menu, 1)); assert.deepEqual(s.contextMenu, current);
    save(await app.contextMenuAction(current, 1)); assert.equal(s.contextMenu, null);
    assert.ok(s.widgets.some(w => w.name === "5 open · 1 done"));
    save(await app.click(findWidget(s, { role: "tab", name: "done" })));
    assert.deepEqual(rows(s).map(w => w.id), [original[0]]);
    save(await app.click(findWidget(s, { role: "tab", name: "all" })));
    assert.deepEqual(rows(s).slice(0, 3).map(w => w.id), original);
    save(await app.click(button(s, "Clear done")));
    assert.equal(rows(s).length, 5);
    save(await app.setText(draft(s), ""));
    for (let i = 5; i < 64; i++) save(await app.click(button(s, "Add task")));
    assert.equal((s.model.tasks as unknown as unknown[]).length, 64);
    save(await app.setText(draft(s), "cleared even at capacity"));
    const tasks = s.model.tasks;
    save(await app.click(button(s, "Add task")));
    assert.deepEqual(s.model.tasks, tasks); assert.equal(draft(s).text, "");
    const recorded = s;
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.deepEqual(replay.snapshot.model, recorded.model);
    assert.deepEqual(replay.snapshot.widgets, recorded.widgets);
    assert.deepEqual(replay.snapshot.effects, recorded.effects);
    assert.equal(replay.snapshot.fingerprint, recorded.fingerprint);
    save(replay.snapshot); compare(snapshots);
  } finally { await app.close(); }
});
