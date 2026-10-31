import assert from "node:assert/strict";
import test from "node:test";
import { NativeApp, findWidget, type NativeSnapshot, type JsonValue } from "@native-sdk/core/testing";

function deck(snapshot: NativeSnapshot): Record<string, JsonValue> {
  return snapshot.model.deck as Record<string, JsonValue>;
}
function playback(snapshot: NativeSnapshot): Record<string, JsonValue> {
  return deck(snapshot).playback as Record<string, JsonValue>;
}

test("Deck shipping player and playlist preserve controls, exact copy effects and whole-session replay", async () => {
  await using app = await NativeApp.start({ width: 512, height: 264, timeoutMs: 60000 });
  let snapshot = await app.snapshot();
  assert.equal(playback(snapshot).now, null);
  assert.equal(playback(snapshot).playing, false);
  assert.equal(deck(snapshot).playlist_open, false);
  assert.deepEqual(deck(snapshot).covers, Array.from({ length: 8 }, () => [48]));
  assert.equal((deck(snapshot).url_base_buffer as number[]).length, 256);
  assert.equal((deck(snapshot).cache_dir_buffer as number[]).length, 512);
  assert.equal(snapshot.windows.length, 1);
  snapshot = await app.menu("deck.playlist");
  snapshot = await app.frame();
  assert.equal(deck(snapshot).playlist_open, true);
  assert.equal(snapshot.windows.length, 2);
  const rows = snapshot.widgets.filter(w => w.view === "playlist-canvas" && w.role === "listitem");
  assert.equal(rows.length, 68);
  snapshot = await app.click(rows[0]!);
  snapshot = await app.frame();
  assert.equal(playback(snapshot).now, 1);
  assert.equal(playback(snapshot).playing, true);
  for (const [name, playing] of [["Pause", false], ["Play", true], ["Stop", false]] as const) {
    snapshot = await app.click(findWidget(snapshot, { role: "button", name, view: "deck-canvas" }));
    snapshot = await app.frame();
    assert.equal(playback(snapshot).playing, playing);
  }
  assert.equal(playback(snapshot).elapsed_ms, 0);
  const search = findWidget(snapshot, { role: "textbox", name: "Search library", view: "playlist-canvas" });
  snapshot = await app.setText(search, "does not match this catalog");
  snapshot = await app.frame();
  assert.equal(snapshot.widgets.filter(w => w.role === "listitem").length, 0);
  assert.ok(snapshot.widgets.some(w => w.name === "No tracks match"));
  snapshot = await app.menu("deck.dismiss", 2);
  snapshot = await app.frame();
  assert.equal(snapshot.widgets.filter(w => w.role === "listitem").length, 68);
  const row = snapshot.widgets.find(w => w.view === "playlist-canvas" && w.role === "listitem")!;
  snapshot = await app.contextPress(row);
  const menu = snapshot.contextMenu!;
  assert.ok(menu);
  const copy = menu.items.find(item => Buffer.from(item.label).toString() === "Copy Title")!;
  snapshot = await app.contextMenuAction(menu, copy.id);
  assert.equal(snapshot.effects.spawns.length, 1);
  assert.deepEqual(snapshot.effects.spawns[0], {
    key: "2", argv: [[...Buffer.from("/usr/bin/pbcopy")]], stdin: [...Buffer.from(row.name)], output: "lines", maxLineBytes: 4096,
  });
  snapshot = await app.spawnExit("2");
  snapshot = await app.frame();
  assert.equal(deck(snapshot).copies_done, 1);
  assert.equal(deck(snapshot).copy_failed, false);
  snapshot = await app.closeWindow(snapshot.windows.find(w => w.label === "playlist")!);
  snapshot = await app.frame();
  assert.equal(deck(snapshot).playlist_open, false);
  assert.equal(snapshot.windows.length, 1);
  const replay = await app.verifyReplay();
  assert.deepEqual(replay.snapshot.model, snapshot.model);
  assert.deepEqual(replay.snapshot.widgets, snapshot.widgets);
  assert.deepEqual(replay.snapshot.effects, snapshot.effects);
  assert.deepEqual(replay.snapshot.windows, snapshot.windows);
});
