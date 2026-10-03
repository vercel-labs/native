import assert from "node:assert/strict";
import { readFileSync, writeFileSync, unlinkSync, mkdirSync } from "node:fs";
import test from "node:test";
import { resolve } from "node:path";
import { NativeApp, findWidget, type NativeSnapshot } from "@native-sdk/core/testing";

const bytes = (s: string) => new TextEncoder().encode(s);
const text = (s: NativeSnapshot) => new TextDecoder().decode(new Uint8Array(s.model.status as number[]));

test("named effects preserve complete snapshots, replacements, cancellations, routes and replay", async () => {
  // Canonical file access resolves paths before the fake executor parks an op.
  // Own a minimal fixture and refuse to replace any pre-existing file.
  const directory = resolve(".zig-cache/effect-fixture"), fixture = resolve(directory, "scratch-pad.txt");
  mkdirSync(directory, { recursive: true });
  writeFileSync(fixture, "fixture", { flag: "wx" });
  let app: NativeApp | undefined;
  try {
    app = await NativeApp.start({ width: 820, height: 650, wallMs: 12345, appDataDirectory: directory });
    let s = await app.snapshot(); const snapshots = [s];
    const save = () => snapshots.push(s);
    const press = async (name: string) => { s = await app.click(findWidget(s, { role: "button", name })); save(); };
    const file = () => { assert.equal(s.effects.files.length, 1); return s.effects.files[0]!; };
    const deliver = async (body: string, outcome: "ok" | "not_found" | "io_failed" | "truncated" = "ok") => {
      const request = file(); s = await app.fileResult(request.key, request.op, bytes(body), { outcome }); save();
    };
    await press("Save note"); assert.equal(file().op, "write"); assert.deepEqual(file().bytes, s.model.body);
    const first = file().key; await deliver(""); assert.equal(s.model.writes, 1);
    await press("Load note"); assert.equal(file().key, first); await deliver("saved bytes"); assert.equal(s.model.reads, 1);
    await press("Replace read"); assert.equal(file().op, "read"); assert.notEqual(file().key, first);
    assert.equal(s.model.clockReads, 1); assert.equal(s.model.clockAt, 12345); assert.equal(s.model.reads, 1);
    await deliver("the latest bytes"); assert.equal(s.model.latestReads, 1); assert.equal(s.model.reads, 1);
    await press("Load note"); assert.equal(file().key, first); await deliver("old");
    await press("Load note"); const generation = file().generation;
    await press("Paste note"); assert.equal(s.effects.files.length, 0); assert.equal(s.effects.clipboards.length, 1);
    const clipboard = s.effects.clipboards[0]!; assert.equal(clipboard.op, "read");
    s = await app.clipboardResult(clipboard.key, bytes("pasted bytes")); save(); assert.equal(text(s), "Note loaded.");
    await press("Read and cancel"); assert.equal(s.effects.files.length, 0); assert.equal(text(s), "Read cancelled."); assert.equal(s.model.failures, 0);
    await press("Load note"); assert.notEqual(file().generation, generation); await deliver("", "not_found"); assert.equal(text(s), "not_found");
    await press("Add a line"); assert.equal(file().op, "append"); assert.deepEqual(file().bytes, [...bytes("\nAnd one more line.")]); await deliver("");
    await press("Inspect note"); assert.equal(file().op, "stat");
    s = await app.fileResult(file().key, "stat", new Uint8Array(0), { total: 71, mtimeMs: 123456, exists: true }); save();
    assert.equal(s.model.exists, true); assert.equal(s.model.size, 71);
    await press("Read two copies"); assert.equal(s.effects.files.length, 2);
    const pair = s.effects.files.map(f => f.key); assert.notEqual(pair[0], pair[1]);
    s = await app.fileResult(pair[1]!, "read", bytes("second finishes first")); save(); assert.equal(s.model.latestReads, 2);
    s = await app.fileResult(pair[0]!, "read", bytes("first finishes second")); save(); assert.equal(s.effects.files.length, 0);
    await press("Download example"); assert.equal(s.effects.fetches.length, 1); assert.equal(s.effects.fetches[0]!.response, "buffered");
    s = await app.fetchResult(s.effects.fetches[0]!.key, 200, bytes("downloaded")); save(); assert.equal(text(s), "HTTP 200 delivered.");
    await press("Download example"); s = await app.fetchResult(s.effects.fetches[0]!.key, 200, bytes("partial"), { truncated: true }); save(); assert.equal(text(s), "truncated");
    await press("Download example"); s = await app.fetchResult(s.effects.fetches[0]!.key, 0, new Uint8Array(0), { outcome: "timed_out" }); save(); assert.equal(text(s), "timed_out");
    await press("Paste note"); s = await app.clipboardResult(s.effects.clipboards[0]!.key, new Uint8Array(0), "failed"); save(); assert.equal(text(s), "failed");
    await press("Load note"); await deliver("partial", "truncated"); assert.equal(text(s), "truncated");
    await press("Save note"); await deliver("", "io_failed"); assert.equal(text(s), "io_failed");
    await press("Delete note"); assert.equal(file().op, "delete"); await deliver(""); assert.equal(s.model.exists, false);
    await press("Reset sample"); await press("Copy note"); assert.equal(s.effects.clipboards.length, 1); assert.equal(s.effects.clipboards[0]!.op, "write");
    assert.deepEqual(s.effects.clipboards[0]!.text, s.model.body);
    s = await app.clipboardResult(s.effects.clipboards[0]!.key, new Uint8Array(0)); save();
    assert.equal(s.effects.files.length + s.effects.fetches.length + s.effects.clipboards.length, 0);
    const before = s, replay = await app.verifyReplay();
    assert.ok(replay.events > 0 && replay.checkpoints > 0); assert.equal(replay.effects, before.effects.recorded);
    // 20 OS terminals (including silent drops), two clock reads, the
    // clipboard write terminal and the journaled app-directory delivery.
    assert.equal(replay.effects, 24); assert.deepEqual(replay.snapshot, before);
    s = replay.snapshot; save();
    const reference = process.env.NATIVE_SDK_TEST_VIEW_REFERENCE;
    if (reference) {
      const values = snapshots.map(({ viewBackend, ...value }) => value);
      if (process.env.NATIVE_SDK_TEST_VIEW_BACKEND === "zig") writeFileSync(`${reference}.effects.json`, JSON.stringify(values));
      else assert.deepEqual(values, JSON.parse(readFileSync(`${reference}.effects.json`, "utf8")));
    }
    console.log(`${snapshots.length} complete snapshots, ${replay.effects} recorded effects, exact replay`);
  } finally { try { await app?.close(); } finally { unlinkSync(fixture); } }
});
