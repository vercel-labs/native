// The frontend-emitted contract sidecar: the document corewire's
// projections consume, emitted directly from checked analysis (no Zig
// emission in the loop). The build's per-fixture equivalence pin
// (test-contract-equivalence) holds it byte-identical to the extraction
// path at corpus scale; these tests pin the construction at unit scale:
// facts, ordering, identities, and the schema-gap teachings.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { checkFile } from "../src/frontend.ts";
import { wyhash, wyhashHex } from "../src/wyhash.ts";

/// Transpile a one-module core from a STABLE file name (core.ts in a
/// temp directory), so the document's origin facts and therefore its
/// synthesized identities are reproducible across runs.
function contractOf(source: string): Record<string, unknown> {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-core-contract-"));
  try {
    const entry = path.join(dir, "core.ts");
    fs.writeFileSync(entry, source);
    const result = checkFile(entry, { contractEntry: "src/core.ts" });
    assert.equal(result.ok, true, result.diagnostics.map((d) => d.message).join("\n") || result.typeErrors.join("\n"));
    assert.notEqual(result.contract, null);
    return JSON.parse(result.contract!) as Record<string, unknown>;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

const smallCore = `
import { asciiBytes } from "@native-sdk/core";
import { type FileDropEvent } from "@native-sdk/core/events";
export type Role = "user" | "assistant";
export interface Turn { id: number; role: Role; text: Uint8Array; }
export interface Model { turns: readonly Turn[]; nextId: number; title: Uint8Array; }
export type Msg =
  | { kind: "bump" }
  | { kind: "rename"; title: Uint8Array }
  | { kind: "fetched"; status: number; body: Uint8Array }
  | { kind: "role_set"; role: Role };
export const envMsgs = [{ env: "APP_TITLE", msg: "rename" }] as const;
export function dropMsg(drop: FileDropEvent): Msg | null {
  return drop.paths.length > 0 ? { kind: "rename", title: drop.paths[0] } : null;
}
export function turnCount(model: Model): number { return model.turns.length; }
export function initialModel(): Model {
  return { turns: [], nextId: 1, title: asciiBytes("hi") };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "bump": return { ...model, nextId: model.nextId + 1 };
    case "rename": return { ...model, title: msg.title };
    case "fetched": return { ...model, nextId: msg.status };
    case "role_set": return model;
  }
}
`;

test("a small core's contract carries types, arms, slots, and channels", () => {
  const doc = contractOf(smallCore);
  assert.equal(doc.format, 1);
  assert.equal(doc.wire_version, 3);
  assert.equal(doc.abi_version, 1);
  assert.equal(doc.entry, "src/core.ts");
  assert.equal(doc.model, "Model");
  assert.match(doc.source_hash as string, /^[0-9a-f]{16}$/);
  assert.match(doc.build_id as string, /^[0-9a-f]{16}$/);

  const types = doc.types as { structs: any[]; enums: any[]; unions: any[] };
  // Reach order: Model first (DFS through its fields), then arm payloads.
  assert.deepEqual(
    types.structs.map((s) => s.name),
    ["Model", "Turn"],
  );
  assert.deepEqual(
    types.enums.map((e) => e.name),
    ["Role"],
  );
  assert.equal(types.structs[0].origin, "core.ts");
  // Slot classes restate the inference verdicts under the extractor's
  // path grammar (the corpus equivalence pin holds the full mirroring).
  const slots = (doc.integer_slots as { slot: string; class: string }[]).map((s) => s.slot);
  assert.ok(slots.includes("Turn.id"), `slots: ${slots.join(", ")}`);
  assert.ok(slots.includes("helpers.turnCount.return"));

  const msg = doc.msg as { name: string; arms: any[] };
  assert.equal(msg.name, "Msg");
  assert.deepEqual(
    msg.arms.map((a: { name: string }) => a.name),
    ["bump", "rename", "fetched", "role_set"],
  );
  assert.deepEqual(msg.arms[0].payload, { kind: "void" });
  assert.equal(msg.arms[1].member, "title");
  assert.deepEqual(msg.arms[1].payload, { kind: "bytes" });
  // The inline number-plus-bytes shape rides the dedicated family, no
  // table entry.
  assert.equal(msg.arms[2].payload.kind, "number_bytes");
  assert.equal(msg.arms[2].payload.number_field, "status");
  assert.equal(msg.arms[2].payload.bytes_field, "body");
  assert.deepEqual(msg.arms[3].payload, { kind: "enum", name: "Role" });

  const helpers = doc.model_helpers as any[];
  assert.equal(helpers.length, 1);
  assert.equal(helpers[0].name, "turnCount");
  assert.deepEqual(helpers[0].params, []);
  assert.equal(helpers[0].arena, false);

  const channels = doc.channels as Record<string, unknown>;
  assert.deepEqual(channels.env_msgs, [{ env: "APP_TITLE", msg: "rename" }]);
  assert.equal(channels.command_msg, false);
  assert.equal(channels.drop_msg, true);
  assert.equal(doc.init_returns_cmd, false);
  assert.equal(doc.update_returns_cmd, false);
  assert.equal(doc.has_subscriptions, false);

  const abi = doc.abi as { prefix: string; exports: string[] };
  assert.equal(abi.prefix, "nsc_core_");
  assert.ok(!abi.exports.includes("command_msg"));
  assert.ok(abi.exports.includes("drop_msg"));
});

test("multi-field arm payloads table under the synthesized record name", () => {
  const doc = contractOf(`
import { asciiBytes } from "@native-sdk/core";
export interface Model { zoom: number; label: Uint8Array; }
export type Msg =
  | { kind: "zoomed"; x: number; y: number }
  | { kind: "reset" };
export function initialModel(): Model { return { zoom: 1, label: asciiBytes("a") }; }
export function update(model: Model, msg: Msg): Model {
  if (msg.kind === "zoomed") return { zoom: msg.x + msg.y, label: model.label };
  return model;
}
`);
  const types = doc.types as { structs: any[] };
  const synthesized = types.structs.find((s) => s.name === "Msg_zoomed");
  assert.notEqual(synthesized, undefined);
  assert.equal(synthesized.origin, undefined);
  const msg = doc.msg as { arms: any[] };
  assert.deepEqual(msg.arms[0].payload, { kind: "record", name: "Msg_zoomed" });
  assert.equal(msg.arms[0].member, undefined);
});

test("the pair-return shape states the cmd flags", () => {
  const doc = contractOf(`
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { n: number; }
export type Msg =
  | { kind: "tick" }
  | { kind: "fetched"; status: number; body: Uint8Array }
  | { kind: "failed"; reason: Uint8Array };
export function initialModel(): Model { return { n: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  if (msg.kind === "tick") {
    return [model, Cmd.fetch({ url: asciiBytes("https://example.test") }, { ok: "fetched", err: "failed" })];
  }
  return model;
}
`);
  assert.equal(doc.init_returns_cmd, false);
  assert.equal(doc.update_returns_cmd, true);
});

test("statusItem is projected as a launcher-bound model helper with its canonical records", () => {
  const doc = contractOf(`
import { asciiBytes } from "@native-sdk/core";
import { type StatusItemState } from "@native-sdk/core/events";
export interface Model { playing: boolean; }
export type Msg = { kind: "toggle" } | { kind: "noop" };
export function initialModel(): Model { return { playing: false }; }
export function update(model: Model, msg: Msg): Model {
  return msg.kind === "toggle" ? { playing: !model.playing } : model;
}
export function statusItem(model: Model): StatusItemState {
  return {
    iconPath: asciiBytes("assets/tray.svg"),
    tooltip: asciiBytes("Player"),
    activationCommand: asciiBytes("refresh"),
    alternateActivationCommand: asciiBytes("toggle"),
    openCommand: asciiBytes("refresh"),
    presentation: { title: asciiBytes(model.playing ? "MB on" : "MB"), width: 52, tone: "normal", iconOpacity: 1, monospaced: true },
    items: [{ id: 1, label: asciiBytes("Toggle"), command: asciiBytes("toggle"), separator: false, enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""), modifiers: { primary: false, command: false, control: false, option: false, shift: false } }],
  };
}
`);
  const helpers = doc.model_helpers as { name: string; returns: { kind: string; name: string } }[];
  assert.deepEqual(helpers.map((helper) => helper.name), ["statusItem"]);
  assert.deepEqual(helpers[0].returns, { kind: "value", name: "StatusItemState" });
  assert.deepEqual(doc.model_unbound, ["statusItem"]);
  const structs = (doc.types as { structs: { name: string }[] }).structs.map((record) => record.name);
  assert.ok(structs.includes("StatusItemState"), `structs: ${structs.join(", ")}`);
  assert.ok(structs.includes("StatusItemMenuItem"), `structs: ${structs.join(", ")}`);
  assert.ok(structs.includes("StatusItemPresentation"), `structs: ${structs.join(", ")}`);
  assert.ok(structs.includes("StatusItemModifiers"), `structs: ${structs.join(", ")}`);
});

test("Cmd.fetch accepts a line-stream route with bytes and status arms", () => {
  const doc = contractOf(`
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { lines: number; status: number; }
export type Msg =
  | { kind: "start" }
  | { kind: "line"; bytes: Uint8Array }
  | { kind: "finished"; status: number }
  | { kind: "failed"; reason: Uint8Array };
export function initialModel(): Model { return { lines: 0, status: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "start": return [model, Cmd.fetch(
      { url: asciiBytes("https://example.test/events"), maxLineBytes: 65536 },
      { key: "events", line: "line", ok: "finished", err: "failed" },
    )];
    case "line": return { ...model, lines: model.lines + 1 };
    case "finished": return { ...model, status: msg.status };
    case "failed": return model;
  }
}
`);
  assert.equal(doc.update_returns_cmd, true);
});

test("re-runs reproduce the identity fields exactly, and edits move them", () => {
  const a = contractOf(smallCore);
  const b = contractOf(smallCore);
  assert.equal(a.source_hash, b.source_hash);
  assert.equal(a.build_id, b.build_id);
  const edited = contractOf(smallCore.replace("APP_TITLE", "APP_NAME"));
  assert.notEqual(a.build_id, edited.build_id);
});

test("wyhash matches the reference test vectors", () => {
  // The vectors Zig's std.hash.Wyhash pins (wyhash test_vector.cpp).
  const vectors: [bigint, bigint, string][] = [
    [0n, 0x409638ee2bde459n, ""],
    [1n, 0xa8412d091b5fe0a9n, "a"],
    [2n, 0x32dd92e4b2915153n, "abc"],
    [3n, 0x8619124089a3a16bn, "message digest"],
    [4n, 0x7a43afb61d7f5f40n, "abcdefghijklmnopqrstuvwxyz"],
    [5n, 0xff42329b90e50d58n, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"],
    [6n, 0xc39cab13b115aad3n, "12345678901234567890123456789012345678901234567890123456789012345678901234567890"],
  ];
  const enc = new TextEncoder();
  for (const [seed, expected, input] of vectors) {
    assert.equal(wyhash(seed, enc.encode(input)), expected, input);
  }
  assert.equal(wyhashHex(0n, enc.encode("")), "0409638ee2bde459");
});
