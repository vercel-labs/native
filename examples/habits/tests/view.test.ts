import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import test from "node:test";
import { dirname } from "node:path";
import { NativeApp, findWidget, type NativeSnapshot, type NativeWidget } from "@native-sdk/core/testing";

const rows = (s: NativeSnapshot) => s.widgets.filter(w => w.role === "listitem");
const button = (s: NativeSnapshot, name: string) => findWidget(s, { role: "button", name });
const done = (s: NativeSnapshot, row: NativeWidget) => s.widgets.find(w => w.role === "button" && w.name === "Done today" && w.bounds.y >= row.bounds.y && w.bounds.y < row.bounds.y + row.bounds.height)!;
function compare(name: string, values: NativeSnapshot[]) {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const snapshots = values.map(({ viewBackend, ...s }) => s);
  if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") {
    mkdirSync(dirname(reference), { recursive: true });
    writeFileSync(`${reference}.${name}.json`, JSON.stringify(snapshots));
  }
  else assert.deepEqual(snapshots, JSON.parse(readFileSync(`${reference}.${name}.json`, "utf8")), "complete snapshots must match the native view");
}

test("Habits preserves streaks, keyed filtering, keyboard navigation, capacity and complete replay", async () => {
  // The 64-row session replays every intermediate tree in one request.
  // Allow bounded headroom when the compiled driver shares CI with builds.
  const app = await NativeApp.start({ width: 720, height: 520, timeoutMs: 60000 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND) assert.equal(s.viewBackend, process.env.NATIVE_SDK_TEST_VIEW_BACKEND);
    const save = (value: NativeSnapshot) => { s = value; snapshots.push(s); };
    assert.deepEqual(rows(s).map(w => w.name), ["Meditate", "Exercise", "Read 20 pages"]);
    assert.ok(s.widgets.some(w => w.name === "3 habits · 21 total days"));
    const original = rows(s).map(w => w.id), meditate = rows(s)[0]!;
    const originalDone = done(s, meditate).id;
    save(await app.click(button(s, "New habit")));
    assert.equal(rows(s).length, 4); assert.equal(rows(s)[3]!.name, "Habit 4");
    save(await app.click(done(s, rows(s)[0]!)));
    assert.equal((s.model.habits as unknown as { streak: number }[])[0]!.streak, 13);
    assert.ok(s.widgets.some(w => w.name === "4 habits · 22 total days"));
    save(await app.click(findWidget(s, { role: "radio", name: "active" })));
    assert.deepEqual(rows(s).map(w => w.id), [original[0], original[2]]);
    assert.equal(done(s, rows(s)[0]!).id, originalDone);
    save(await app.click(done(s, rows(s)[0]!)));
    assert.equal((s.model.habits as unknown as { streak: number }[])[0]!.streak, 14);
    save(await app.click(findWidget(s, { role: "radio", name: "all" })));
    assert.deepEqual(rows(s).slice(0, 3).map(w => w.id), original);
    const view = button(s, "New habit").view;
    await app.action(button(s, "New habit"), "focus");
    save(await app.key(view, "enter")); assert.equal(rows(s).length, 5);
    save(await app.key(view, "tab")); assert.equal(findWidget(s, { role: "radio", name: "all" }).focused, true);
    save(await app.key(view, "arrowright")); assert.equal(s.model.filter, "active");
    save(await app.key(view, "arrowleft")); assert.equal(s.model.filter, "all");
    for (let i = 5; i < 64; i++) save(await app.click(button(s, "New habit")));
    assert.equal((s.model.habits as unknown as unknown[]).length, 64); assert.equal(s.model.next_id, 65);
    const full = s.model;
    save(await app.click(button(s, "New habit"))); assert.deepEqual(s.model, full);
    assert.equal(done(s, rows(s)[0]!).id, originalDone);
    const recorded = s;
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.deepEqual(replay.snapshot.model, recorded.model);
    assert.deepEqual(replay.snapshot.widgets, recorded.widgets);
    assert.deepEqual(replay.snapshot.effects, recorded.effects);
    assert.equal(replay.snapshot.fingerprint, recorded.fingerprint);
    save(replay.snapshot); compare("session", snapshots);
  } finally { await app.close(); }
});
