import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, truncateSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("typography retains complete snapshots, effects and replay across model themes", async () => {
  const app = await NativeApp.start({ width: 560, height: 360 });
  try {
    let snapshot = await app.snapshot();
    const snapshots: NativeSnapshot[] = [snapshot];
    const identities = snapshot.widgets.map(widget => widget.id);
    for (let index = 0; index < 12; index++) {
      const name = index % 2 === 0 ? "Change size" : "Change accent";
      snapshot = await app.click(findWidget(snapshot, { role: "button", name }));
      snapshots.push(snapshot);
      assert.deepEqual(snapshot.widgets.map(widget => widget.id), identities);
      assert.ok(findWidget(snapshot, { role: "text", name: snapshot.model.large ? "Large type" : "Regular type" }));
      assert.deepEqual(snapshot.effects, snapshots[0]!.effects);
    }
    assert.deepEqual(snapshot.model, { large: false, accent: false });
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.equal(replay.effects, 0);
    assert.deepEqual(replay.snapshot.model, snapshot.model);
    assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
    assert.deepEqual(replay.snapshot.effects, snapshot.effects);
    snapshots.push(replay.snapshot);
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const complete = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.typography.json`, JSON.stringify(complete));
      else assert.deepEqual(complete, JSON.parse(readFileSync(`${reference}.typography.json`, "utf8")));
    }
  } finally { await app.close(); }
});

test("declared fonts refuse missing, malformed and over-budget assets before startup", () => {
  const executable = resolve(process.env.NATIVE_SDK_TEST_HOST!);
  const directory = mkdtempSync(join(tmpdir(), "native-font-startup-"));
  const font = join(directory, "assets", "GeistMono-Regular.ttf");
  try {
    mkdirSync(join(directory, "assets"));
    for (const failure of ["FileNotFound", "FontParseFailed", "StreamTooLong"]) {
      if (failure === "FontParseFailed") writeFileSync(font, "not a font");
      if (failure === "StreamTooLong") truncateSync(font, 24 * 1024 * 1024 + 1);
      const result = spawnSync(executable, [], { cwd: directory, input: JSON.stringify({ op: "start", width: 560, height: 360 }) + "\n", encoding: "utf8", timeout: 15000 });
      assert.equal(result.error, undefined);
      assert.match(result.stdout + result.stderr, new RegExp(failure));
      assert.doesNotMatch(result.stdout, /"snapshot":/);
    }
  } finally { rmSync(directory, { recursive: true }); }
});
