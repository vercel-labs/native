import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

test("the devhost executes atomic relational writes and delivers encoded query pages", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly rows: number; readonly done: number; readonly constrained: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "wrote" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { pages: 0, rows: 0, done: 0, constrained: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.exec([
      ["CREATE TABLE note(id INTEGER PRIMARY KEY, title TEXT NOT NULL)", []],
      ["INSERT INTO note(id,title) VALUES(?,?)", [1, "one"]],
      ["INSERT INTO note(id,title) VALUES(?,?)", [2, "two"]],
    ], { key: "seed", ok: "wrote", err: "failed" })];
    case "wrote": return [model, Cmd.db.query(
      "SELECT id,title FROM note ORDER BY id", [],
      { key: "notes", page: "page", done: "done", err: "failed" },
    )];
    case "page": return { ...model, pages: model.pages + 1, rows: model.rows + msg.bytes[4] };
    case "done": return [
      { ...model, done: model.done + 1 },
      Cmd.db.exec([
        ["INSERT INTO note(id,title) VALUES(?,?)", [3, "three"]],
        ["INSERT INTO note(id,title) VALUES(?,?)", [1, "duplicate"]],
      ], { key: "atomic", ok: "wrote", err: "failed" }),
    ];
    case "failed": return { ...model, constrained: msg.reason[0] === 99 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd db_exec seed \(3 statements committed atomically\)/);
    assert.match(run.stdout, /cmd db_query notes \(2 rows in 1 page\)/);
    assert.match(run.stdout, /cmd db_exec rejected constraint/);
    assert.match(run.stdout, /"pages":1,"rows":2,"done":1,"constrained":true/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost binds mixed named, anonymous, and numbered SQLite parameters like native", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-parameters-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly done: boolean; readonly failed: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { pages: 0, done: false, failed: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.query(
      "SELECT 1 AS valid WHERE ? = 1 AND :named = 2 AND $third = 3 AND @fourth = 4 AND ?6 = 6",
      [1, 2, 3, 4, 5, 6],
      { page: "page", done: "done", err: "failed" },
    )];
    case "page": return { ...model, pages: model.pages + 1 };
    case "done": return { ...model, done: true };
    case "failed": return { ...model, failed: true };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd db_query  \(1 rows in 1 page\)/);
    assert.match(run.stdout, /"pages":1,"done":true,"failed":false/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost coalesces and re-delivers live queries after matching commits", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-live-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, Sub } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly rows: number; readonly done: number; }
export type Msg =
  | { readonly kind: "add" }
  | { readonly kind: "wrote" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ pages: 0, rows: 0, done: 0 }, Cmd.db.exec([
    ["CREATE TABLE note(id INTEGER PRIMARY KEY, title TEXT NOT NULL) STRICT", []],
    ["INSERT INTO note(id,title) VALUES(?,?)", [1, "one"]],
  ], { key: "seed", ok: "wrote", err: "failed" })];
}
export function subscriptions(_model: Model): Sub<Msg> {
  return { op: "db_live", key: "notes", pageKind: "page", doneKind: "done", errKind: "failed",
    sql: "SELECT id,title FROM note ORDER BY id", params: [], tables: ["note"] };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "add": return [model, Cmd.batch([
      Cmd.db.exec([["INSERT INTO note(id,title) VALUES(?,?)", [2, "two"]]], { key: "add2", ok: "wrote", err: "failed" }),
      Cmd.db.exec([["UPDATE note SET title=? WHERE id=?", ["TWO", 2]]], { key: "touch2", ok: "wrote", err: "failed" }),
    ])];
    case "page": return { ...model, pages: model.pages + 1, rows: model.rows + msg.bytes[4] };
    case "done": return { ...model, done: model.done + 1 };
    case "wrote":
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"add"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal((run.stdout.match(/sub db_live notes/g) ?? []).length, 2, run.stdout);
    assert.match(run.stdout, /"pages":2,"rows":3,"done":2/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost re-evaluates live queries after schema DDL", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-schema-live-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, Sub } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly done: number; }
export type Msg =
  | { readonly kind: "alter" }
  | { readonly kind: "created" }
  | { readonly kind: "wrote" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ pages: 0, done: 0 }, Cmd.db.exec([
    ["CREATE TABLE note(id INTEGER PRIMARY KEY) STRICT", []],
  ], { ok: "created", err: "failed" })];
}
export function subscriptions(_model: Model): Sub<Msg> {
  return { op: "db_live", key: "notes", pageKind: "page", doneKind: "done", errKind: "failed",
    sql: "SELECT id FROM note ORDER BY id", params: [], tables: ["note"] };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "alter": return [model, Cmd.db.exec([
      ["ALTER TABLE note RENAME TO notes", []],
    ], { ok: "wrote", err: "failed" })];
    case "page": return { ...model, pages: model.pages + 1 };
    case "done": return { ...model, done: model.done + 1 };
    case "created":
    case "wrote":
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"alter"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal((run.stdout.match(/sub db_live notes/g) ?? []).length, 1, run.stdout);
    assert.match(run.stdout, /cmd db_live rejected misuse/);
    assert.match(run.stdout, /"pages":1,"done":1/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost rejects relational commands without the sqlite capability", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-capability-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly rejected: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { rejected: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.query("SELECT 1", [], { key: "q", page: "page", done: "done", err: "failed" })];
    case "page":
    case "done": return model;
    case "failed": return { rejected: msg.reason[0] === 114 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src", "devhost.ts"), core, "--script", script], {
      cwd: tmp,
      encoding: "utf8",
    });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd db_query rejected rejected/);
    assert.match(run.stdout, /"rejected":true/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost rejects whole relational results beyond the total row bound", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-result-bound-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly rejected: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { pages: 0, rejected: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.query(
      "WITH RECURSIVE n(value) AS (VALUES(1) UNION ALL SELECT value + 1 FROM n WHERE value < 8193) SELECT value FROM n", [],
      { key: "large", page: "page", done: "done", err: "failed" },
    )];
    case "page": return { ...model, pages: model.pages + 1 };
    case "done": return model;
    case "failed": return { ...model, rejected: msg.reason[0] === 114 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd db_query rejected rejected/);
    assert.match(run.stdout, /"pages":0,"rejected":true/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost purges staged pages when a keyed query is replaced", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-replace-pages-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly rows: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { pages: 0, rows: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.batch([
      Cmd.db.query("WITH RECURSIVE n(v) AS (VALUES(1) UNION ALL SELECT v + 1 FROM n WHERE v < 300) SELECT v FROM n", [], { key: "q", page: "page", done: "done", err: "failed" }),
      Cmd.db.query("SELECT 2 AS v", [], { key: "q", page: "page", done: "done", err: "failed" }),
    ])];
    case "page": return { pages: model.pages + 1, rows: model.rows + msg.bytes[4] };
    case "done":
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /"pages":1,"rows":1/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost preserves command-stream order across store and relational results", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-mixed-order-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export interface Model { readonly order: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "dbDone" }
  | { readonly kind: "storeDone" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { order: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.batch([
      Cmd.db.exec([["CREATE TABLE ordered(id INTEGER PRIMARY KEY)", []]], { key: "db", ok: "dbDone", err: "failed" }),
      Cmd.store.set("ordered", asciiBytes("yes"), { key: "store", ok: "storeDone", err: "failed" }),
    ])];
    case "dbDone": return { order: model.order * 10 + 1 };
    case "storeDone": return { order: model.order * 10 + 2 };
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script,
      "--capability", "sqlite", "--capability", "store",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /"order":12/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost relational SQL cannot attach paths or mutate the engine schema version", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-sandbox-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly refused: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "next" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { refused: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.exec([["ATTACH DATABASE ':memory:' AS escaped", []]], { ok: "next", err: "failed" })];
    case "next": return model;
    case "page": return model;
    case "failed": {
      const next = { refused: model.refused + 1 };
      if (next.refused === 1) return [next, Cmd.db.exec([["PRAGMA 'user_version'=9", []]], { ok: "next", err: "failed" })];
      if (next.refused === 2) return [next, Cmd.db.query("SELECT sqrt(4)", [], { page: "page", done: "next", err: "failed" })];
      return next;
    }
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal((run.stdout.match(/cmd db_exec rejected misuse/g) ?? []).length, 2);
    assert.match(run.stdout, /cmd db_query rejected misuse/);
    assert.match(run.stdout, /"refused":3/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost rejects commands that collide with a live-query key", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-live-key-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd, Sub } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly rejected: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { pages: 0, rejected: false }; }
export function subscriptions(_model: Model): Sub<Msg> {
  return { op: "db_live", key: "shared", pageKind: "page", doneKind: "done", errKind: "failed",
    sql: "SELECT 1 AS value", params: [], tables: ["note"] };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.query("SELECT 2 AS value", [], {
      key: "shared", page: "page", done: "done", err: "failed",
    })];
    case "page": return { ...model, pages: model.pages + 1 };
    case "done": return model;
    case "failed": return { ...model, rejected: msg.reason[0] === 114 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /sub db_live shared/);
    assert.match(run.stdout, /cmd db_query rejected rejected/);
    assert.doesNotMatch(run.stdout, /cmd db_query shared \(/);
    assert.match(run.stdout, /"pages":1,"rejected":true/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost shares the sixteen relational slots across live and unkeyed operations", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-slots-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    const liveSubs = Array.from({ length: 15 }, (_, index) => `
      { op: "db_live", key: "live-${index}", pageKind: "livePage", doneKind: "liveDone", errKind: "failed",
        sql: "SELECT ${index} AS value", params: [], tables: ["note"] }`).join(",");
    fs.writeFileSync(core, `
import { Cmd, Sub } from "@native-sdk/core";
export interface Model { readonly liveDone: number; readonly commandDone: number; readonly rejected: number; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "livePage"; readonly bytes: Uint8Array }
  | { readonly kind: "liveDone" }
  | { readonly kind: "commandPage"; readonly bytes: Uint8Array }
  | { readonly kind: "commandDone" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { liveDone: 0, commandDone: 0, rejected: 0 }; }
export function subscriptions(_model: Model): Sub<Msg> {
  return Sub.batch([${liveSubs}
  ]);
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.batch([
      Cmd.db.query("SELECT 101 AS value", [], { page: "commandPage", done: "commandDone", err: "failed" }),
      Cmd.db.query("SELECT 102 AS value", [], { page: "commandPage", done: "commandDone", err: "failed" }),
    ])];
    case "livePage":
    case "commandPage": return model;
    case "liveDone": return { ...model, liveDone: model.liveDone + 1 };
    case "commandDone": return { ...model, commandDone: model.commandDone + 1 };
    case "failed": return { ...model, rejected: model.rejected + (msg.reason[0] === 114 ? 1 : 0) };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal((run.stdout.match(/cmd db_query rejected rejected/g) ?? []).length, 1, run.stdout);
    assert.match(run.stdout, /"liveDone":15,"commandDone":1,"rejected":1/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost retires stale live-query slots before arming disjoint replacements", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-live-churn-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    const oldSubs = Array.from({ length: 16 }, (_, index) => `
      { op: "db_live", key: "old-${index}", pageKind: "page", doneKind: "done", errKind: "failed",
        sql: "SELECT ${index} AS value", params: [], tables: ["note"] }`).join(",");
    fs.writeFileSync(core, `
import { Sub } from "@native-sdk/core";
export interface Model { readonly replaced: boolean; readonly replacementDone: number; }
export type Msg =
  | { readonly kind: "replace" }
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { replaced: false, replacementDone: 0 }; }
export function subscriptions(model: Model): Sub<Msg> {
  if (!model.replaced) return Sub.batch([${oldSubs}
  ]);
  return { op: "db_live", key: "new", pageKind: "page", doneKind: "done", errKind: "failed",
    sql: "SELECT 100 AS value", params: [], tables: ["note"] };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "replace": return { ...model, replaced: true };
    case "done": return model.replaced ? { ...model, replacementDone: model.replacementDone + 1 } : model;
    case "page":
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, '{"kind":"replace"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.equal((run.stdout.match(/sub cancel db_live old-/g) ?? []).length, 16, run.stdout);
    assert.match(run.stdout, /sub arm db_live new/);
    assert.match(run.stdout, /"replaced":true,"replacementDone":1/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("virtual-host restarts release every live relational operation slot", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-restart-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Sub } from "@native-sdk/core";
export interface Model { readonly pages: number; readonly done: number; }
export type Msg =
  | { readonly kind: "page"; readonly bytes: Uint8Array }
  | { readonly kind: "done" }
  | { readonly kind: "failed"; readonly reason: Uint8Array };
export function initialModel(): Model { return { pages: 0, done: 0 }; }
export function subscriptions(_model: Model): Sub<Msg> {
  return { op: "db_live", key: "notes", pageKind: "page", doneKind: "done", errKind: "failed",
    sql: "SELECT 1 AS value", params: [], tables: ["note"] };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "page": return { ...model, pages: model.pages + 1 };
    case "done": return { ...model, done: model.done + 1 };
    case "failed": return model;
  }
}
`);
    fs.writeFileSync(script, `${Array.from({ length: 20 }, () => '{"restart":true}').join("\n")}\n`);
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.doesNotMatch(run.stderr, /database slot family/);
    assert.equal((run.stdout.match(/restart virtual host/g) ?? []).length, 20, run.stdout);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});

test("the devhost rejects transaction control inside an exec batch and rolls it all back", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "native-db-devhost-transaction-"));
  try {
    const core = path.join(tmp, "core.ts");
    const script = path.join(tmp, "msgs.ndjson");
    fs.writeFileSync(core, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly clean: boolean; readonly dirty: boolean; readonly retrying: boolean; }
export type Msg =
  | { readonly kind: "go" }
  | { readonly kind: "attack" }
  | { readonly kind: "failed"; readonly reason: Uint8Array }
  | { readonly kind: "clean" }
  | { readonly kind: "dirty" };
export function initialModel(): Model { return { clean: false, dirty: false, retrying: false }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.db.exec([
      ["CREATE TABLE item(id INTEGER PRIMARY KEY) STRICT", []],
    ], { ok: "attack", err: "failed" })];
    case "attack": return [model, Cmd.db.exec([
      ["INSERT INTO item(id) VALUES(1)", []],
      ["COMMIT", []],
      ["INSERT INTO item(id) VALUES(2)", []],
    ], { ok: "dirty", err: "failed" })];
    case "failed": {
      if (model.retrying) return { clean: false, dirty: true, retrying: true };
      return [{ ...model, retrying: true }, Cmd.db.exec([
        ["INSERT INTO item(id) VALUES(1)", []],
      ], { ok: "clean", err: "failed" })];
    }
    case "clean": return { clean: true, dirty: false, retrying: true };
    case "dirty": return { clean: false, dirty: true, retrying: true };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"go"}\n');
    const run = spawnSync(process.execPath, [
      path.join(packageDir, "src", "devhost.ts"), core, "--script", script, "--capability", "sqlite",
    ], { cwd: tmp, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stdout, /cmd db_exec rejected misuse/);
    assert.match(run.stdout, /"clean":true,"dirty":false,"retrying":true/);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
