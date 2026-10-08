import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import test from "node:test";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

test("the component gallery preserves every specimen, theme and replay across view backends", async () => {
  const app = await NativeApp.start({ width: 1080, height: 760 });
  try {
    let snapshot = await app.snapshot();
    const snapshots: NativeSnapshot[] = [];
    const save = (value: NativeSnapshot) => {
      snapshot = value;
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND) assert.equal(value.viewBackend, process.env.NATIVE_SDK_TEST_VIEW_BACKEND);
      snapshots.push(value);
    };
    save(snapshot);
    assert.equal(snapshot.model.selectedComponentId, 1);
    const accordion = findWidget(snapshot, { role: "treeitem", name: "Accordion" });
    save(await app.action(accordion, "focus"));
    for (let id = 2; id <= 34; id++) {
      save(await app.key(accordion.view, "arrowdown"));
      assert.equal(snapshot.model.selectedComponentId, id);
      const component = (snapshot.model.components as { id: number; label: number[] }[]).find(item => item.id === id);
      assert.ok(component);
      const label = new TextDecoder().decode(new Uint8Array(component.label));
      assert.ok(snapshot.widgets.some(widget => widget.role === "text" && widget.name === label));
      assert.ok(snapshot.widgets.some(widget => widget.role === "treeitem" && widget.name === label && widget.selected));
    }
    save(await app.click(findWidget(snapshot, { role: "button", name: "Geist" })));
    save(await app.click(findWidget(snapshot, { role: "button", name: "Pink" })));
    const recorded = snapshot;
    const replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0);
    assert.deepEqual(replay.snapshot.model, recorded.model);
    assert.deepEqual(replay.snapshot.widgets, recorded.widgets);
    assert.deepEqual(replay.snapshot.effects, recorded.effects);
    assert.equal(replay.snapshot.fingerprint, recorded.fingerprint);
    save(replay.snapshot);
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const values = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") {
        mkdirSync(dirname(reference), { recursive: true });
        writeFileSync(`${reference}.json`, JSON.stringify(values));
      } else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.json`, "utf8")), "complete gallery snapshots must match the reference view");
    }
  } finally {
    await app.close();
  }
});
