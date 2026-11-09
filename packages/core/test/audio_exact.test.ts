import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { Cmd, asciiBytes } from "../sdk/core.ts";
import { checkFile } from "../src/frontend.ts";
import { check } from "./helpers.ts";

const fixture = new URL("../../../tests/ts-core/audio-exact/core.ts", import.meta.url);

test("exact audio keeps all report fields as bytes and admits both load-owned routes", () => {
  const result = checkFile(fixture.pathname, { contractEntry: "src/core.ts" });
  assert.equal(result.ok, true, result.typeErrors.join("\n") || result.diagnostics.map(d => d.message).join("\n"));
  const contract = JSON.parse(result.contract!);
  for (const name of ["first", "second"]) {
    const arm = contract.msg.arms.find((arm: { name: string }) => arm.name === name);
    const record = contract.types.structs.find((record: { name: string }) => record.name === arm.payload.name);
    assert.deepEqual(record.fields.filter((field: { type: { kind: string } }) => field.type.kind === "bytes").map((field: { name: string }) => field.name), ["key", "positionMs", "durationMs", "bands"]);
    assert.equal(record.fields.length, 7);
  }
});

test("exact audio refuses missing keys, numeric counters and incomplete state vocabularies", () => {
  const source = fs.readFileSync(fixture, "utf8");
  for (const candidate of [
    source.replaceAll('readonly key: Uint8Array; readonly state:', 'readonly state:'),
    source.replaceAll('readonly positionMs: Uint8Array; readonly durationMs:', 'readonly positionMs: number; readonly durationMs:'),
    source.replaceAll('readonly durationMs: Uint8Array; readonly playing:', 'readonly durationMs: number; readonly playing:'),
    source.replace('import type { AudioState, AudioTransport } from "@native-sdk/core/events";', 'import type { AudioTransport } from "@native-sdk/core/events"; export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected";'),
  ]) {
    const result = check(candidate);
    assert.equal(result.ok, false);
    assert.ok(result.typeErrors.length > 0 || result.diagnostics.length > 0);
  }
});

test("exact audio factories retain source bytes and single-player transport declarations", () => {
  const key = asciiBytes("18446744073709551615"), path = asciiBytes("music/track.mp3"), cacheDir = asciiBytes("cache");
  assert.deepEqual(Cmd.audioPlayExact<{ kind: "event"; key: Uint8Array; state: "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum"; positionMs: Uint8Array; durationMs: Uint8Array; playing: boolean; buffering: boolean; bands: Uint8Array }>(key, { path, cacheDir }, { event: "event" }), {
    op: "audio_play_exact", key, eventKind: "event", path, url: new Uint8Array(0), cachePath: new Uint8Array(0), cacheDir, expectedBytes: 0,
  });
  for (const control of [{ kind: "pause" }, { kind: "play" }, { kind: "stop" }, { kind: "seek", positionMs: key }, { kind: "volume", value: 0.375 }] as const)
    assert.deepEqual(Cmd.audioTransport(control), { op: "audio_transport", transport: control });
});
