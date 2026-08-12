import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

test("the devhost performs record-store batches, reads, and prefix scans", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-store-devhost-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly hits: number; readonly pageCount: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "again" }
  | { readonly kind: "wrote" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "scanned"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { hits: 0, pageCount: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.store.setMany([
      ["chat/1", asciiBytes("one")], ["chat/2", asciiBytes("two")],
    ], { key: "seed", ok: "wrote", err: "failed" })];
    case "wrote":
    case "again": return [model, Cmd.store.get("chat/1", { key: "read", ok: "loaded", err: "failed" })];
    case "loaded": return [{ ...model, hits: msg.bytes[0] }, Cmd.store.scan("chat/", { limit: 1 }, { key: "page", ok: "scanned", err: "failed" })];
    case "scanned": return { ...model, pageCount: msg.bytes[0] };
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n{"restart":true}\n{"kind":"again"}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "store"], {
      cwd: tmp,
      encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd store_set_many seed \(2 records stored atomically\)/);
    assert.match(run.stdout, /cmd store_get read chat\/1 \(hit\)/);
    assert.match(run.stdout, /cmd store_scan page chat\/ \(1 records, more\)/);
    assert.match(run.stdout, /"hits":1,"pageCount":1/);
    assert.equal((run.stdout.match(/cmd store_get read chat\/1 \(hit\)/g) ?? []).length, 2);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost defers store results so replacement and cancel match native batches", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-store-devhost-order-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly first: number; readonly second: number; readonly cancelled: number; readonly hit: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "first" }
  | { readonly kind: "second" }
  | { readonly kind: "cancelled" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { first: 0, second: 0, cancelled: 0, hit: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.batch([
      Cmd.store.set("doc/replaced", asciiBytes("one"), { key: "replace", ok: "first", err: "failed" }),
      Cmd.store.set("doc/replaced", asciiBytes("two"), { key: "replace", ok: "second", err: "failed" }),
      Cmd.store.set("doc/cancelled", asciiBytes("kept"), { key: "cancel", ok: "cancelled", err: "failed" }),
      Cmd.cancel("cancel"),
    ])];
    case "first": return { ...model, first: model.first + 1 };
    case "second": return [{ ...model, second: model.second + 1 }, Cmd.store.get("doc/cancelled", { key: "read", ok: "loaded", err: "failed" })];
    case "cancelled": return { ...model, cancelled: model.cancelled + 1 };
    case "loaded": return { ...model, hit: msg.bytes[0] };
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "store",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd cancel cancel \(store result dropped\)/);
    assert.match(run.stdout, /"first":0,"second":1,"cancelled":0,"hit":1/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost keeps initial-model store results behind the complete boot batch", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-store-devhost-boot-order-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly first: number; readonly second: number; readonly ticks: number; }
export type Msg =
  | { readonly kind: "first" }
  | { readonly kind: "second" }
  | { readonly kind: "tick"; readonly atMs: number }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ first: 0, second: 0, ticks: 0 }, Cmd.batch([
    Cmd.store.set("doc/boot", asciiBytes("one"), { key: "replace", ok: "first", err: "failed" }),
    Cmd.now("tick"),
    Cmd.store.set("doc/boot", asciiBytes("two"), { key: "replace", ok: "second", err: "failed" }),
  ])];
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "first": return { ...model, first: model.first + 1 };
    case "second": return { ...model, second: model.second + 1 };
    case "tick": return { ...model, ticks: model.ticks + 1 };
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, "");
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "store",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /"first":0,"second":1,"ticks":1/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost uses encoded key identity and rejects fractional scan limits", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-store-devhost-key-bytes-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model {
  readonly value: number;
  readonly records: number;
  readonly invalidLimit: number;
  readonly rejected: boolean;
}
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "wrote" }
  | { readonly kind: "loaded"; readonly bytes: Uint8Array }
  | { readonly kind: "scanned"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model {
  return { value: 0, records: 0, invalidLimit: 0.5, rejected: false };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.batch([
      Cmd.store.set("\\uD800", asciiBytes("one"), { key: "first", ok: "wrote", err: "failed" }),
      Cmd.store.set("\\uD801", asciiBytes("two"), { key: "second", ok: "wrote", err: "failed" }),
      Cmd.store.get("\\uD800", { key: "read", ok: "loaded", err: "failed" }),
    ])];
    case "wrote": return model;
    case "loaded": return [
      { ...model, value: msg.bytes[1] },
      Cmd.store.scan("", { limit: 10 }, { key: "page", ok: "scanned", err: "failed" }),
    ];
    case "scanned": return [
      { ...model, records: msg.bytes[0] },
      Cmd.store.scan("", { limit: model.invalidLimit }, { key: "invalid", ok: "scanned", err: "failed" }),
    ];
    case "failed": return { ...model, rejected: msg.reason[0] === 111 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "store",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd store_get read .+ \(hit\)/);
    assert.match(run.stdout, /cmd store_scan page  \(1 records\)/);
    assert.match(run.stdout, /cmd store_scan rejected over_bound/);
    assert.match(run.stdout, /"value":116,"records":1,"invalidLimit":0.5,"rejected":true/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost rejects store commands without the app.zon capability", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-store-devhost-capability-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly rejected: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "wrote" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { rejected: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.store.set("doc/one", asciiBytes("one"), { key: "write", ok: "wrote", err: "failed" })];
    case "wrote": return model;
    case "failed": return { rejected: msg.reason.length === 8 && msg.reason[0] === 114 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src", "devhost.ts"), core, "--script", script], {
      cwd: tmp,
      encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd store_set rejected rejected/);
    assert.match(run.stdout, /"rejected":true/);
    assert.doesNotMatch(run.stdout, /stored in virtual host memory/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
