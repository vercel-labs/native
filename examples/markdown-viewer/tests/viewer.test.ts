import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NativeApp, findWidget } from "@native-sdk/core/testing";
import { sampleTable } from "../src/samples.ts";

const text = new TextEncoder();
const decode = (bytes: unknown): string => new TextDecoder().decode(Uint8Array.from(bytes as number[]));

test("embedded samples preserve the original document bytes", () => {
  for (const [index, name] of ["welcome", "tour", "spec", "notes"].entries()) {
    assert.deepEqual(sampleTable[index]!.body, new Uint8Array(readFileSync(new URL(`../src/samples/${name}.md`, import.meta.url))));
  }
});

test("compiled Markdown Viewer keeps complete edited and saved state through replay", async t => {
  const data = mkdtempSync(join(tmpdir(), "markdown-viewer-test-"));
  t.after(() => rmSync(data, { recursive: true, force: true }));
  const old = join(data, "old.md"), next = join(data, "new.md");
  await using app = await NativeApp.start({ width: 1200, height: 760, appDataDirectory: data });
  let snapshot = await app.snapshot();
  assert.equal(snapshot.model.active_sample_id, 1);
  assert.equal(snapshot.model.sample_picker_open, false);
  assert.deepEqual(snapshot.model.details_expanded, Array(16).fill(false));
  assert.equal((snapshot.model.preview_images as unknown[]).length, 12);
  assert.ok(decode((snapshot.model.editor as { text: number[] }).text).startsWith("# Markdown Viewer"));
  const bootRead = snapshot.effects.files.find(file => file.op === "read");
  assert.ok(bootRead);
  assert.equal(bootRead.path, join(data, "recent.txt"));
  snapshot = await app.fileResult(bootRead.key, "read", text.encode(`${old}\n${old}\n`));
  assert.equal((snapshot.model.recents as unknown[]).length, 2);
  const source = findWidget(snapshot, { role: "textbox", name: "Markdown source" });
  snapshot = await app.setText(source, "# Owned document\n\nCafé 日本 🙂\n\n<details><summary>More</summary>Exact state</details>");
  assert.equal(snapshot.model.active_sample_id, 0);
  assert.ok(snapshot.widgets.some(widget => widget.text.includes("Owned document")));
  snapshot = await app.setText(findWidget(snapshot, { role: "textbox", name: "Document path" }), next);
  snapshot = await app.click(findWidget(snapshot, { role: "button", name: "Save As" }));
  const write = snapshot.effects.files.find(file => file.op === "write" && file.path === next);
  assert.ok(write);
  assert.equal(decode(write.bytes), decode((snapshot.model.editor as { text: number[] }).text));
  snapshot = await app.fileResult(write.key, "write");
  const recentWrite = snapshot.effects.files.find(file => file.op === "write");
  assert.ok(recentWrite);
  assert.equal(recentWrite.path, bootRead.path);
  assert.equal(decode(recentWrite.bytes), `${next}\n${old}\n${old}\n`);
  snapshot = await app.fileResult(recentWrite.key, "write");
  assert.equal(decode(snapshot.model.current_path), next);
  assert.equal(decode(snapshot.model.note), "Saved new.md");
  const complete = snapshot;
  const replay = await app.verifyReplay();
  assert.ok(replay.events > 0 && replay.checkpoints > 0);
  assert.deepEqual(replay.snapshot, complete);
});

test("compiled Markdown Viewer sample picker retains identities and exact geometry", async () => {
  await using app = await NativeApp.start({ width: 960, height: 560 });
  let snapshot = await app.snapshot();
  const trigger = findWidget(snapshot, { role: "button", name: "Sample picker" });
  snapshot = await app.click(trigger);
  assert.equal(snapshot.model.sample_picker_open, true);
  const sample = findWidget(snapshot, { role: "menuitem", name: "Reading notes" });
  snapshot = await app.click(sample);
  assert.equal(snapshot.model.active_sample_id, 4);
  assert.equal(snapshot.model.sample_picker_open, false);
  assert.equal(findWidget(snapshot, { role: "button", name: "Sample picker" }).id, trigger.id);
  assert.ok(findWidget(snapshot, { role: "button", name: "Save" }).enabled === false);
  const editor = findWidget(snapshot, { role: "textbox", name: "Markdown source" });
  assert.ok(editor.bounds.width > 0 && editor.bounds.height > 0);
  const replay = await app.verifyReplay();
  assert.deepEqual(replay.snapshot, snapshot);
});

test("compiled Markdown Viewer retains exact image ownership and complete replay after eviction", async () => {
  await using app = await NativeApp.start({ width: 960, height: 560 });
  let snapshot = await app.snapshot();
  const source = findWidget(snapshot, { role: "textbox", name: "Markdown source" });
  snapshot = await app.setText(source, "# Images\n\n![one](https://images.test/é.png)\n\n![two](https://images.test/failure.png)");
  assert.equal(snapshot.effects.images.length, 2);
  const request = snapshot.effects.images[0]!;
  assert.ok(BigInt(request.id) > 9007199254740991n);
  const pending = (snapshot.model.preview_images as unknown as { identity: { imageLower: number; imageUpper: number } }[])[0]!;
  assert.equal(BigInt(request.id), BigInt(pending.identity.imageUpper) * 4294967296n + BigInt(pending.identity.imageLower));
  assert.equal(decode(request.url), "https://images.test/é.png");
  const failed = snapshot.effects.images[1]!;
  snapshot = await app.imageBytes(request.id, new Uint8Array(readFileSync(new URL("./pixel.png", import.meta.url))));
  const loaded = (snapshot.model.preview_images as unknown as { loaded: boolean; width: number; height: number }[])[0]!;
  assert.deepEqual({ loaded: loaded.loaded, width: loaded.width, height: loaded.height }, { loaded: true, width: 2, height: 3 });
  snapshot = await app.imageResult(failed.id, { outcome: "http_status", status: 503 });
  assert.equal(snapshot.effects.images.length, 0);
  snapshot = await app.setText(source, "# Images\n\n![one](https://images.test/é.png)\n\nRetained pixels");
  assert.equal(snapshot.effects.images.length, 0);
  snapshot = await app.setText(source, "# Evicted\n\nEvery registration released");
  assert.ok((snapshot.model.preview_images as unknown as { loaded: boolean }[]).every(image => !image.loaded));
  const replay = await app.verifyReplay();
  assert.ok(replay.effects > 0);
  assert.deepEqual(replay.snapshot, snapshot);
});
