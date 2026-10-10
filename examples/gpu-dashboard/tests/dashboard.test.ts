import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("GPU Dashboard owns complete status storage, controls and sealed replay", async () => {
  await using app = await NativeApp.start({ width: 1240, height: 780 });
  const snapshots: NativeSnapshot[] = [];
  let snapshot = await app.snapshot(); snapshots.push(snapshot);
  assert.deepEqual(snapshot.model, {
    refresh_count: 0, perf_animation_armed: false, mode_count: 0, live_count: 0,
    nav_selection: 0, metric_selection: null, activity_selection: null, filter_selection: null,
    auto_refresh: true, confidence: Math.fround(0.62), activity_scroll: 18, chrome_leading: 0,
    color_scheme: "light", reduce_motion: false, high_contrast: false,
    reported_planned_frame: false, status_storage: Array(192).fill(0), status_len: 0,
  });
  const cases = [
    ["Refresh dashboard", "press", "refresh_count", 1],
    ["Dashboard mode", "press", "mode_count", 1],
    ["Live render status", "press", "live_count", 1],
    ["Customers", "press", "nav_selection", 1],
    ["Activation 74.2%, up 6.1%", "press", "metric_selection", 1],
    ["High intent", "press", "filter_selection", 2],
    ["Queued invoices", "press", "activity_selection", 3],
    ["Auto refresh", "toggle", "auto_refresh", false],
  ] as const;
  for (const [name, action, field, expected] of cases) {
    snapshot = await app.action(findWidget(snapshot, { name }), action);
    snapshot = await app.frame(); snapshots.push(snapshot);
    assert.equal(snapshot.model[field], expected, name);
    assert.equal((snapshot.model.status_storage as number[]).length, 192);
    assert.ok((snapshot.model.status_len as number) > 0);
    assert.deepEqual(snapshot.effects.timers, []);
  }
  for (const [command, armed] of [["dashboard.perf-animation", true], ["dashboard.perf-animation-stop", false]] as const) {
    snapshot = await app.menu(command); snapshots.push(snapshot);
    assert.equal(snapshot.model.perf_animation_armed, armed);
  }
  const replay = await app.verifyReplay();
  assert.deepEqual(replay.snapshot.model, snapshot.model);
  snapshots.push(replay.snapshot);
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (reference) {
    const complete = snapshots.map(({ viewBackend, ...value }) => value);
    if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.gpu-dashboard.json`, JSON.stringify(complete));
    else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.gpu-dashboard.json`, "utf8")));
  }
});
