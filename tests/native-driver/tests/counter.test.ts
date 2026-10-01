import assert from "node:assert/strict";
import test from "node:test";
import { NativeApp, findWidget } from "@native-sdk/core/testing";
const expectedBackend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND;

test("compiled counter: input, committed state, widgets, effects and replay", async () => {
  const app = await NativeApp.start({ wallMs: 77000 });
  try {
    let snapshot = await app.snapshot();
    if (expectedBackend) assert.equal(snapshot.viewBackend, expectedBackend);
    assert.equal(snapshot.model.count, 0);
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "+" }));
    assert.equal(snapshot.model.count, 1);
    assert.ok(snapshot.widgets.some(widget => widget.name.includes("total: 1")));
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Stamp" }));
    assert.equal(snapshot.model.stampedMs, 77000);
    assert.equal(snapshot.effects.recorded, 1);
    assert.ok(snapshot.widgets.some(widget => widget.name.includes("stamped: 77000ms")));
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0);
    assert.ok(replay.checkpoints > 0);
    assert.equal(replay.effects, 1);
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.equal(replay.snapshot.fingerprint, snapshot.fingerprint);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
  } finally {
    await app.close();
  }
});

test("counter view preserves native identities and layout across rebuilds", async () => {
  const app = await NativeApp.start({ width: 480, height: 320 });
  try {
    let snapshot = await app.snapshot();
    if (expectedBackend) assert.equal(snapshot.viewBackend, expectedBackend);
    assert.equal(snapshot.widgets.length, 14);
    const plus = findWidget(snapshot, { role: "button", name: "+" });
    assert.equal(plus.id, "4995393829508032300");
    assert.equal(findWidget(snapshot, { role: "switch", name: "Tick every second" }).id, "8424760395709847335");
    const ids = snapshot.widgets.map(widget => widget.id);
    const bounds = snapshot.widgets.map(widget => widget.bounds);
    snapshot = await app.click(plus);
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Stamp" }));
    assert.deepEqual(snapshot.widgets.map(widget => widget.id), ids);
    for (let i = 0; i < 100; i++) snapshot = await app.frame();
    assert.equal(snapshot.model.count, 1);
    assert.ok(snapshot.widgets.some(widget => widget.name.includes("total: 1 | stamped: 0ms")));
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Reset" }));
    assert.deepEqual(snapshot.widgets.map(widget => widget.bounds), bounds);
  } finally {
    await app.close();
  }
});

test("two compiled cores have independent state and process lifetimes", async (t) => {
  const first = await NativeApp.start();
  t.after(() => first.close());
  const second = await NativeApp.start();
  try {
    const initial = await first.snapshot();
    const changed = await first.click(findWidget(initial, { role: "button", name: "+" }));
    assert.equal(changed.model.count, 1);
    assert.equal((await second.snapshot()).model.count, 0);
    await first.close();
    assert.equal((await second.snapshot()).model.count, 0);
  } finally {
    await Promise.all([first.close(), second.close()]);
  }
});

test("a native dispatch error rejects instead of returning stale state", async () => {
  const app = await NativeApp.start();
  try {
    const widget = findWidget(await app.snapshot(), { role: "button", name: "+" });
    await assert.rejects(app.click({ ...widget, id: "18446744073709551615" }), /Native test host exited/);
  } finally {
    await app.close();
  }
});

test("fake requests preserve arbitrary bytes, timers fire explicitly, and results replay", async () => {
  const app = await NativeApp.start();
  try {
    let snapshot = await app.snapshot();
    snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Load" }));
    assert.equal(snapshot.effects.requests.length, 1);
    const request = snapshot.effects.requests[0]!;
    assert.equal(request.name, "status.read");
    assert.deepEqual(request.bytes, [...new TextEncoder().encode("ready")]);
    const bytes = new Uint8Array([0, 255, 128, 65]);
    snapshot = await app.respond(request.key, bytes);
    bytes.fill(42);
    assert.deepEqual(snapshot.model.status, [0, 255, 128, 65]);
    assert.equal(snapshot.effects.requests.length, 0);
    snapshot = await app.click(findWidget(snapshot, { role: "switch", name: "Tick every second" }));
    assert.equal(snapshot.effects.timers.length, 1);
    assert.equal(snapshot.model.tickCount, 0);
    snapshot = await app.fireTimer(snapshot.effects.timers[0]!.key);
    assert.equal(snapshot.model.tickCount, 1);
    const replay = await app.verifyReplay();
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.equal(replay.effects, 1);
  } finally {
    await app.close();
  }
});
