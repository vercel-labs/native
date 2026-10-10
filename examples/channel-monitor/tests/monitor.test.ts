import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("Channel Monitor owns every model byte and replays explicit unsupported producer startup", async () => {
  await using app = await NativeApp.start({ width: 560, height: 420 });
  const snapshots: NativeSnapshot[] = [];
  let snapshot = await app.snapshot(); snapshots.push(snapshot);
  assert.deepEqual(snapshot.model, {
    line_storage: Array.from({ length: 16 }, () => ({ bytes: Array(96).fill(0), length: 0 })),
    visible_count: 0, total_samples: { upper_word: 0, lower_word: 0 },
    dropped_total: 0, monitoring: false, rejected: false, source_failed: false,
  });
  for (let attempt = 0; attempt < 2; attempt++) {
    snapshot = await app.action(findWidget(snapshot, { role: "button", name: "Start monitor" }), "press");
    snapshot = await app.frame(); snapshots.push(snapshot);
    assert.deepEqual(snapshot.model, { ...snapshots[0]!.model, source_failed: true });
    assert.ok(snapshot.widgets.some(widget => widget.name === "sampler failed to start"));
    assert.deepEqual(snapshot.effects.timers, []);
  }
  const replay = await app.verifyReplay();
  assert.deepEqual(replay.snapshot.model, snapshot.model);
  snapshots.push(replay.snapshot);
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (reference) {
    const complete = snapshots.map(({ viewBackend, ...value }) => value);
    if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.channel-monitor.json`, JSON.stringify(complete));
    else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.channel-monitor.json`, "utf8")));
  }
});
