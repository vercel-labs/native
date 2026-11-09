import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;
const field = (snapshot: NativeSnapshot) => findWidget(snapshot, { role: "textbox", name: "Feed URL" });
interface State { feedWindowOpen: boolean; url: number[]; urlAnchor: number; urlFocus: number; urlCompStart: number; urlCompEnd: number; phase: string; items: unknown[] }
const state = (snapshot: NativeSnapshot) => snapshot.model as unknown as State;
const url = (snapshot: NativeSnapshot) => new TextDecoder().decode(Uint8Array.from(state(snapshot).url));
const compare = (name: string, snapshots: NativeSnapshot[]) => {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  const path = `${reference}.${name}.json`;
  if (backend === "zig") writeFileSync(path, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(path, "utf8")), "complete native snapshots match the reference view");
};

// Canonical FeedResult wire bytes supplied by the fake service boundary.
// Real scriptc child execution and HTTP are covered by feed_reader_e2e_tests.zig.
function feedResult(): Uint8Array {
  const chunks: Buffer[] = [];
  const u32 = (value: number) => { const b = Buffer.alloc(4); b.writeUInt32LE(value); chunks.push(b); };
  const f64 = (value: number) => { const b = Buffer.alloc(8); b.writeDoubleLE(value); chunks.push(b); };
  const bytes = (value: string) => { const b = Buffer.from(value); u32(b.length); chunks.push(b); };
  bytes("Fixture café"); u32(2);
  for (const id of [1, 2]) { f64(id); bytes(`Story ${id}`); bytes(`https://example.com/${id}`); }
  f64(2);
  return Buffer.concat(chunks);
}
async function start(): Promise<NativeApp> {
  const app = await NativeApp.start();
  try {
    let snapshot = await app.snapshot();
    if (backend) assert.equal(snapshot.viewBackend, backend);
    assert.equal(snapshot.effects.requests[0]?.name, "feeds.parse");
    snapshot = await app.respond(snapshot.effects.requests[0]!.key, feedResult());
    assert.equal(state(snapshot).phase, "ready");
    assert.equal(state(snapshot).items.length, 2);
    return app;
  } catch (error) { await app.close(); throw error; }
}

test("native Unicode editing, selection and deletion keep the model and view aligned", async () => {
  const app = await start();
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot], input = field(snapshot);
    snapshot = await app.setText(input, "  café🙂/feed  ");
    assert.equal(url(snapshot), "  café🙂/feed  ");
    assert.equal(field(snapshot).text, url(snapshot));
    assert.equal(field(snapshot).id, input.id);
    snapshots.push(snapshot);
    snapshot = await app.selectText(input, 2, 7); // select café in UTF-8 bytes
    assert.equal(state(snapshot).urlAnchor, 2);
    assert.equal(state(snapshot).urlFocus, 7);
    snapshots.push(snapshot);
    snapshot = await app.key(input.view, "backspace");
    assert.equal(url(snapshot), "  🙂/feed  ");
    snapshots.push(snapshot);
    snapshot = await app.key(input.view, "arrowright");
    assert.equal(state(snapshot).urlFocus, 6); // advance over the whole emoji
    snapshot = await app.key(input.view, "backspace");
    assert.equal(url(snapshot), "  /feed  ");
    snapshots.push(snapshot);
    snapshot = await app.setText(input, "a".repeat(4095) + "🙂");
    assert.equal(state(snapshot).url.length, 4095); // refuse partial UTF-8 at capacity
    assert.equal(field(snapshot).text, "a".repeat(4095));
    snapshot = await app.key(input.view, "backspace");
    assert.equal(state(snapshot).url.length, 4094);
    snapshots.push(snapshot);
    snapshot = await app.setText(input, "");
    assert.equal(url(snapshot), "");
    snapshot = await app.key(input.view, "enter");
    assert.equal(state(snapshot).phase, "ready"); // no fetch for an empty URL
    snapshots.push(snapshot);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(replay.snapshot);
    compare("edit", snapshots);
  } finally { await app.close(); }
});

test("native IME commit, cancel, service errors and submit replay through both views", async () => {
  const app = await start();
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot], input = field(snapshot);
    snapshot = await app.setText(input, "https://example.com/");
    snapshot = await app.composeText(input, "日本");
    assert.equal(url(snapshot), "https://example.com/日本");
    assert.equal(state(snapshot).urlCompStart, 20);
    snapshots.push(snapshot);
    snapshot = await app.composeText(input, "日本語");
    assert.equal(url(snapshot), "https://example.com/日本語");
    snapshot = await app.commitComposition(input);
    assert.equal(state(snapshot).urlCompStart, -1);
    snapshots.push(snapshot);
    snapshot = await app.composeText(input, "取消");
    snapshot = await app.cancelComposition(input);
    assert.equal(url(snapshot), "https://example.com/日本語");
    assert.equal(state(snapshot).urlCompStart, -1);
    snapshots.push(snapshot);
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Parse the sample" }));
    snapshot = await app.respond(snapshot.effects.requests[0]!.key, new TextEncoder().encode('{"kind":"unrecognized_feed"}'), false);
    assert.equal(state(snapshot).phase, "failed");
    assert.ok(snapshot.widgets.some(widget => widget.name.includes("unrecognized_feed")));
    snapshots.push(snapshot);
    await app.action(input, "focus");
    snapshot = await app.key(input.view, "enter");
    assert.equal(state(snapshot).phase, "loading");
    snapshots.push(snapshot);
    const replay = await app.verifyReplay();
    assert.equal(replay.effects, 2);
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(replay.snapshot);
    compare("ime", snapshots);
  } finally { await app.close(); }
});


test("secondary window inputs, service updates, close and reopen share one model and replay", async () => {
  const app = await start();
  const main = "feed-canvas", secondary = "feed-window-canvas";
  const inView = (snapshot: NativeSnapshot, role: string, name: string, view: string) => findWidget(snapshot, { role, name, view });
  const input = (snapshot: NativeSnapshot, view: string) => inView(snapshot, "textbox", "Feed URL", view);
  const open = (snapshot: NativeSnapshot) => app.click(inView(snapshot, "button", "Open feed window", main));
  try {
    let snapshot = await app.snapshot();
    const snapshots = [snapshot];
    const mainId = input(snapshot, main).id;
    snapshot = await open(snapshot);
    assert.equal(state(snapshot).feedWindowOpen, true);
    const window = snapshot.windows.find(window => window.label === "feed")!;
    assert.ok(window);
    assert.equal(window.bounds.width, 560);
    assert.equal(window.bounds.height, 400);
    const secondaryInput = input(snapshot, secondary);
    assert.equal(secondaryInput.window, window.id);
    assert.notEqual(secondaryInput.window, input(snapshot, main).window);
    snapshots.push(snapshot);
    // Repeated model/view requests must preserve each retained tree and identity.
    snapshot = await app.frame();
    assert.equal(input(snapshot, secondary).id, secondaryInput.id);
    snapshots.push(snapshot);
    snapshot = await app.setText(secondaryInput, "café🙂/feed");
    assert.equal(input(snapshot, main).text, "café🙂/feed");
    assert.equal(input(snapshot, main).id, mainId);
    snapshots.push(snapshot);
    snapshot = await app.selectText(secondaryInput, 0, 5);
    snapshot = await app.key(secondary, "backspace");
    assert.equal(url(snapshot), "🙂/feed");
    assert.equal(input(snapshot, main).text, url(snapshot));
    snapshots.push(snapshot);
    snapshot = await app.setText(input(snapshot, main), "https://example.com/shared");
    assert.equal(input(snapshot, secondary).text, url(snapshot));
    snapshots.push(snapshot);
    // Physical pointer hit testing in the secondary canvas starts the real Msg/effect path.
    const sample = inView(snapshot, "button", "Parse the sample", secondary);
    const point = { x: sample.bounds.x + sample.bounds.width / 2, y: sample.bounds.y + sample.bounds.height / 2 };
    await app.pointer(sample, "down", point);
    snapshot = await app.pointer(sample, "up", point);
    assert.equal(state(snapshot).phase, "loading");
    for (const view of [main, secondary]) assert.ok(snapshot.widgets.some(widget => widget.view === view && widget.name === "Working"));
    snapshots.push(snapshot);
    snapshot = await app.respond(snapshot.effects.requests[0]!.key, new TextEncoder().encode("shared service failure"), false);
    for (const view of [main, secondary]) assert.ok(snapshot.widgets.some(widget => widget.view === view && widget.name === "shared service failure"));
    snapshots.push(snapshot);
    snapshot = await app.closeWindow(window);
    assert.equal(state(snapshot).feedWindowOpen, false);
    assert.ok(!snapshot.windows.some(window => window.label === "feed"));
    assert.ok(!snapshot.widgets.some(widget => widget.view === secondary));
    snapshots.push(snapshot);
    snapshot = await open(snapshot);
    assert.equal(input(snapshot, secondary).text, "https://example.com/shared");
    snapshots.push(snapshot);
    snapshot = await app.click(inView(snapshot, "button", "Parse the sample", main));
    snapshot = await app.respond(snapshot.effects.requests[0]!.key, feedResult());
    for (const view of [main, secondary]) assert.ok(snapshot.widgets.some(widget => widget.view === view && widget.name === "Fixture café"));
    snapshots.push(snapshot);
    snapshot = await app.click(inView(snapshot, "button", "Close feed window", secondary));
    assert.equal(state(snapshot).feedWindowOpen, false);
    assert.ok(!snapshot.widgets.some(widget => widget.view === secondary));
    snapshots.push(snapshot);
    snapshot = await open(snapshot);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.windows, snapshot.windows);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    snapshots.push(replay.snapshot);
    compare("windows", snapshots);
  } finally { await app.close(); }
});
