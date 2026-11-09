import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const expectedBackend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const start = async () => {
  const app = await NativeApp.start({ width: 840, height: 560 });
  try {
    if (expectedBackend) assert.equal((await app.snapshot()).viewBackend, expectedBackend);
    return app;
  } catch (error) { await app.close(); throw error; }
};
const card = (snapshot: NativeSnapshot, name: string) => findWidget(snapshot, { role: "listitem", name });
const cards = (snapshot: NativeSnapshot) => snapshot.widgets.filter(widget => widget.role === "listitem");
interface BoardState {
  readonly cards: readonly { readonly id: number; readonly column: "todo" | "doing" | "done" }[];
  readonly droppedCount: number;
  readonly draggingId: number;
  readonly dragBeforeId: number;
  readonly todoScroll: number;
}
const state = (snapshot: NativeSnapshot) => snapshot.model as unknown as BoardState;
const compare = (name: string, snapshots: readonly NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  const path = `${reference}.${name}.json`;
  if (expectedBackend === "zig") writeFileSync(path, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(path, "utf8")), "complete native snapshots must match the reference view");
};

// This battery runs against both the reference and compiled TypeScript views.
test("Kanban records, avatars, add, file drops and replay use the committed core", async () => {
  const app = await start();
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot];
    assert.equal(cards(snapshot).length, 10);
    assert.equal(snapshot.widgets.length, 88);
    assert.equal(card(snapshot, "Retry failed agent runs").id, "3463696004314092110");
    assert.ok(snapshot.widgets.some(widget => widget.name === "NAT-1841"));
    assert.equal(snapshot.widgets.filter(widget => widget.role === "image").length, 10);
    const originalIds = cards(snapshot).map(widget => widget.id);
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Add card" }));
    assert.equal(state(snapshot).cards.length, 11);
    assert.ok(card(snapshot, "Investigate agent task 11"));
    snapshot = await app.dropFiles("other-canvas", ["/tmp/ignored.txt"]);
    assert.equal(state(snapshot).cards.length, 11);
    snapshot = await app.dropFiles("", ["/tmp/café.txt", "C:\\work\\design.pdf"]);
    assert.equal(state(snapshot).cards.length, 13);
    assert.equal(state(snapshot).droppedCount, 2);
    assert.ok(card(snapshot, "café.txt"));
    assert.ok(card(snapshot, "design.pdf"));
    assert.deepEqual(cards(snapshot).filter(widget => originalIds.includes(widget.id)).map(widget => widget.id), originalIds);
    snapshots.push(snapshot);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    assert.equal(replay.snapshot.fingerprint, snapshot.fingerprint);
    snapshots.push(replay.snapshot);
    compare("records", snapshots);
  } finally { await app.close(); }
});

test("Kanban drag projects one slot, reorders, reparents and cancels with stable identities", async () => {
  const app = await start();
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot];
    const source = card(snapshot, "Preserve reconnect output");
    const originalCards = state(snapshot).cards;
    const destination = { x: 80, y: 120 };
    snapshot = await app.beginDrag(source, destination);
    assert.equal(state(snapshot).draggingId, 2);
    assert.deepEqual(state(snapshot).cards, originalCards);
    assert.equal(cards(snapshot).length, 10);
    assert.equal(card(snapshot, source.name).id, source.id);
    assert.ok(card(snapshot, source.name).bounds.y < card(snapshot, "Retry failed agent runs").bounds.y);
    snapshots.push(snapshot);
    snapshot = await app.pointer(source, "up", destination);
    assert.equal(state(snapshot).draggingId, 0);
    assert.equal(state(snapshot).cards[0].id, 2);
    snapshots.push(snapshot);
    const reorderedCards = state(snapshot).cards;
    snapshot = await app.beginDrag(card(snapshot, source.name), { x: 760, y: 500 });
    assert.equal(card(snapshot, source.name).id, source.id);
    assert.ok(card(snapshot, source.name).bounds.x > 560);
    snapshots.push(snapshot);
    snapshot = await app.key(source.view, "escape");
    assert.equal(state(snapshot).draggingId, 0);
    assert.deepEqual(state(snapshot).cards, reorderedCards);
    assert.ok(card(snapshot, source.name).bounds.x < 280);
    snapshots.push(snapshot);
    const firstDone = card(snapshot, "Log agent handoffs"), secondDone = card(snapshot, "Document sandbox denials");
    const gap = (firstDone.bounds.y + firstDone.bounds.height / 2 + secondDone.bounds.y + secondDone.bounds.height / 2) / 2;
    snapshot = await app.drag(card(snapshot, source.name), { x: 760, y: gap });
    assert.equal(card(snapshot, source.name).id, source.id);
    assert.ok(card(snapshot, source.name).bounds.x > 560);
    const done = state(snapshot).cards.filter(item => item.column === "done");
    assert.deepEqual(done.map(item => item.id), [4, 2, 5, 9, 10]);
    snapshots.push(snapshot);
    snapshot = await app.drag(card(snapshot, source.name), { x: 80, y: 500 });
    assert.equal(card(snapshot, source.name).id, source.id);
    assert.ok(card(snapshot, source.name).bounds.x < 280);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(snapshot, replay.snapshot);
    compare("drag", snapshots);
  } finally { await app.close(); }
});

test("Kanban controlled scroll feeds payloads and drag insertion uses the content offset", async () => {
  const app = await start();
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot];
    const add = findWidget(snapshot, { role: "button", name: "Add card" });
    for (let i = 0; i < 5; i++) snapshot = await app.click(add);
    const newest = card(snapshot, "Investigate agent task 15");
    assert.ok(newest.bounds.y + newest.bounds.height > 560);
    snapshot = await app.wheel(findWidget(snapshot, { role: "group", name: "Todo cards" }), 320);
    assert.ok(state(snapshot).todoScroll > 0);
    const scrolled = card(snapshot, newest.name);
    assert.equal(scrolled.id, newest.id);
    assert.ok(scrolled.bounds.y < newest.bounds.y);
    assert.ok(scrolled.bounds.y + scrolled.bounds.height <= 560);
    snapshots.push(snapshot);
    snapshot = await app.beginDrag(scrolled, { x: 100, y: 140 });
    assert.notEqual(state(snapshot).dragBeforeId, 0);
    assert.notEqual(state(snapshot).dragBeforeId, 2);
    snapshots.push(snapshot);
    snapshot = await app.key(scrolled.view, "escape");
    assert.equal(state(snapshot).draggingId, 0);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(snapshot, replay.snapshot);
    compare("scroll", snapshots);
  } finally { await app.close(); }
});
