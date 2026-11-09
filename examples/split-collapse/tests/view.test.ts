import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync } from "node:fs";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

function compare(snapshots: readonly NativeSnapshot[]): void {
  const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
  if (!reference) return;
  const values = snapshots.map(({ viewBackend, ...snapshot }) => snapshot);
  if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.split-collapse.json`, JSON.stringify(values));
  else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.split-collapse.json`, "utf8")));
}

test("all three animation modes retain divider identity, complete effects and replay", async () => {
  const snapshots: NativeSnapshot[] = [];
  for (const mode of ["runtime", "manual", "markup"]) {
      const app = await NativeApp.start({ width: 800, height: 520, environment: [
        { name: "SPLIT_COLLAPSE_MANUAL", value: mode === "runtime" ? "0" : "1" },
        { name: "SPLIT_COLLAPSE_MARKUP", value: mode === "markup" ? "1" : "0" },
        { name: "SPLIT_COLLAPSE_WEB", value: "1" },
        { name: "SPLIT_COLLAPSE_AUTO_MS", value: "+2_0" },
      ] });
      try {
        let s = await app.snapshot();
        const save = () => snapshots.push(s);
        const divider = () => findWidget(s, { role: "separator", name: "Split divider" });
        const toggle = () => findWidget(s, { role: "button", name: "Toggle sidebar" });
        const id = divider().id;
        assert.equal(s.model.manual_requested, mode !== "runtime");
        assert.equal(s.model.markup_mode, mode === "markup");
        assert.equal(s.model.collapsed, false);
        assert.equal(s.effects.timers.length, 1);
        assert.equal(s.effects.timers[0]!.intervalMs, 20);
        assert.equal(s.effects.timers[0]!.mode, "repeating");
        assert.equal(s.webViews.length, 1);
        assert.equal(s.webViews[0]!.url, "https://example.com");
        save();
        s = await app.click(toggle()); save();
        assert.equal(s.model.collapsed, true);
        for (let i = 0; i < 16; i++) { s = await app.frame(); save(); }
        assert.equal(s.model.tween, null);
        assert.equal(s.model.fraction, Math.fround(0.06));
        assert.equal(divider().id, id);
        s = await app.fireTimer(s.effects.timers[0]!.key); save();
        assert.equal(s.model.collapsed, false);
        for (let i = 0; i < 4; i++) { s = await app.frame(); save(); }
        s = await app.click(toggle()); save(); // Reverse while expanding.
        for (let i = 0; i < 16; i++) { s = await app.frame(); save(); }
        assert.equal(s.model.collapsed, true);
        assert.equal(s.model.fraction, Math.fround(0.06));
        s = await app.action(divider(), "focus"); save();
        s = await app.key(divider().view, "arrowright"); save();
        assert.ok((divider().value as number) > Math.fround(0.06));
        if (mode === "manual") assert.ok((s.model.fraction as number) > Math.fround(0.06));
        for (let i = 0; i < 16; i++) { s = await app.frame(); save(); }
        assert.equal(divider().id, id);
        const recorded = s;
        const replay = await app.verifyReplay();
        assert.ok(replay.events > 0 && replay.effects > 0 && replay.checkpoints > 0);
        assert.deepEqual(replay.snapshot, recorded);
        snapshots.push(replay.snapshot);
      } finally { await app.close(); }
  }
  compare(snapshots);
});


test("launch configuration refuses undeclared duplicate and framework directory channels", async () => {
  for (const environment of [
    [{ name: "UNKNOWN_MODE", value: "1" }],
    [{ name: "SPLIT_COLLAPSE_MANUAL", value: "1" }, { name: "SPLIT_COLLAPSE_MANUAL", value: "0" }],
    [{ name: "NATIVE_SDK_APP_DATA_DIR", value: "/arbitrary" }],
  ]) {
    await assert.rejects(NativeApp.start({ environment }), /EnvironmentChannelMissing|DuplicateEnvironmentChannel|ReservedEnvironmentChannel/);
  }
});
