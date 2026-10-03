import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget } from "@native-sdk/core/testing";
const bytes = (s: string) => new TextEncoder().encode(s);
const text = (value: unknown) => new TextDecoder().decode(new Uint8Array(value as number[]));
test("complete spawn/fetch streams preserve admission, loss, terminal routing, reuse and replay", async () => {
  const app = await NativeApp.start({ width: 740, height: 640, wallMs: 123456 });
  try {
    let s = await app.snapshot(); const snapshots = [s];
    const save = () => snapshots.push(s);
    const press = async (name: string) => { s = await app.click(findWidget(s, { role: "button", name })); save(); };
    const spawnKey = () => { assert.equal(s.effects.spawns.length, 1); return s.effects.spawns[0]!.key; };
    const fetchKey = () => { assert.equal(s.effects.fetches.length, 1); return s.effects.fetches[0]!.key; };
    await press("Start process"); const first = spawnKey(); assert.equal(s.effects.spawns[0]!.output, "lines");
    assert.equal(text(s.effects.spawns[0]!.argv[0]), "/bin/sh");
    s = await app.streamLine(first, bytes("First line")); save(); assert.equal(s.model.lines, 1);
    assert.equal(spawnKey(), first);
    await press("Start process"); assert.equal(spawnKey(), first); assert.equal(text(s.model.status), "rejected");
    await press("Stream response"); assert.equal(s.effects.fetches.length, 0); assert.equal(spawnKey(), first);
    s = await app.streamLine(first, bytes("Café stream"), { truncated: true, droppedBefore: 9 }); save();
    s = await app.spawnExit(first, -7); save(); assert.equal(s.model.exitCode, -7); assert.equal(s.effects.spawns.length, 0);
    await press("Collect output"); assert.equal(spawnKey(), first); assert.equal(s.effects.spawns[0]!.output, "collect");
    s = await app.spawnExit(first, 7, "exited", bytes("Collected output\n")); save();
    assert.equal(text(s.model.output), "Collected output\n"); assert.equal(s.model.exitCode, 7);
    await press("Collect output");
    for (let chunk = 0; chunk < 33; chunk++) { s = await app.spawnOutput(spawnKey(), new Uint8Array(16384).fill(65)); save(); }
    s = await app.spawnExit(spawnKey(), 0); save(); assert.equal(text(s.model.status), "truncated");
    assert.equal(text(s.model.output), "Collected output\n");
    await press("Exit only"); s = await app.spawnExit(spawnKey(), 3); save(); assert.equal(s.model.exitCode, 3);
    await press("Start process"); await press("Cancel source"); assert.equal(s.effects.spawns.length, 0); assert.equal(text(s.model.status), "cancelled");
    await press("Cancel source"); assert.equal(text(s.model.status), "cancelled");
    await press("Independent pair"); const pair = s.effects.spawns; assert.equal(pair.length, 2); assert.notEqual(pair[0]!.key, pair[1]!.key);
    for (const request of pair) { s = await app.streamLine(request.key, bytes("Independent line")); save(); s = await app.spawnExit(request.key); save(); }
    assert.equal(s.effects.spawns.length, 0);
    for (const reason of ["signaled", "spawn_failed"] as const) {
      await press("Start process"); s = await app.spawnExit(spawnKey(), 0, reason); save(); assert.equal(text(s.model.status), reason);
    }
    await press("Stream response"); const fetch = fetchKey(); assert.equal(s.effects.fetches[0]!.response, "stream"); assert.equal(s.effects.fetches[0]!.maxLineBytes, 8192);
    s = await app.streamLine(fetch, bytes("Response line")); save();
    await press("Stream response"); assert.equal(fetchKey(), fetch); assert.equal(text(s.model.status), "rejected");
    s = await app.fetchResponse(fetch, 404); save(); assert.equal(s.model.httpStatus, 404); assert.equal(text(s.model.status), "Response complete.");
    for (const damage of ["line-cut", "line-drop", "terminal-cut", "terminal-drop"] as const) {
      await press("Stream response"); const key = fetchKey();
      if (damage.startsWith("line")) { s = await app.streamLine(key, bytes("Partial"), { truncated: damage === "line-cut", droppedBefore: damage === "line-drop" ? 1 : 0 }); save(); }
      s = await app.fetchResponse(key, 200, "ok", { truncated: damage === "terminal-cut", droppedBefore: damage === "terminal-drop" ? 1 : 0 }); save();
      assert.equal(text(s.model.status), "truncated"); assert.equal(s.effects.fetches.length, 0);
    }
    await press("Stream response"); s = await app.streamLine(fetchKey(), bytes("Partial"), { truncated: true }); save();
    s = await app.fetchResponse(fetchKey(), 0, "timed_out", { truncated: true }); save(); assert.equal(text(s.model.status), "timed_out");
    await press("Stream response"); await press("Cancel source"); assert.equal(s.effects.fetches.length, 0); assert.equal(text(s.model.status), "cancelled");
    await press("Stamp"); assert.equal(s.model.stampedMs, 123456);
    const replay = await app.verifyReplay(); assert.ok(replay.effects > 0 && replay.checkpoints > 0);
    assert.deepEqual(replay.snapshot, s); s = replay.snapshot; save();
    const backend = process.env.NATIVE_SDK_TEST_VIEW_BACKEND, reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (backend) assert.equal(s.viewBackend, backend);
    if (reference) {
      const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
      if (backend === "zig") writeFileSync(`${reference}.streams.json`, JSON.stringify(values));
      else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.streams.json`, "utf8")));
    }
    console.log(`${snapshots.length} complete snapshots; ${replay.effects} replayed effects`);
  } finally { await app.close(); }
});
