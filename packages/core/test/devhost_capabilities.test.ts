import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
test("the virtual host routes byte commands, exact clocks and complete one-shot and repeating timers", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-capability-devhost-"));
  try {
    const entry = path.join(dir, "core.ts"), script = path.join(dir, "script.ndjson");
    fs.writeFileSync(entry, `
import { Cmd, asciiBytes } from "@native-sdk/core";
export type TimerOutcome = "rejected" | "fired";
export interface Model { readonly once: number; readonly pulses: number; readonly stamp: Uint8Array; readonly key: Uint8Array; readonly timestamp: Uint8Array; }
export type Msg = { readonly kind: "go" } | { readonly kind: "stop" }
  | { readonly kind: "clock"; readonly bytes: Uint8Array }
  | { readonly kind: "once"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: TimerOutcome }
  | { readonly kind: "pulse"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: TimerOutcome };
export function commandMsg(name: Uint8Array): Msg | null {
  return name.length === 2 && name[0] === 103 && name[1] === 111 ? { kind: "go" } : null;
}
export function initialModel(): Model { return { once: 0, pulses: 0, stamp: asciiBytes(""), key: asciiBytes(""), timestamp: asciiBytes("") }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "go": return [model, Cmd.batch([Cmd.wallTime("clock"), Cmd.timerResult("once", 10, "one_shot", { result: "once" }), Cmd.timerResult("pulse", 20, "repeating", { result: "pulse" })])];
    case "clock": return { ...model, stamp: msg.bytes };
    case "once": return { ...model, once: model.once + 1, key: msg.key, timestamp: msg.timestampNs };
    case "pulse": return { ...model, pulses: model.pulses + 1, key: msg.key, timestamp: msg.timestampNs };
    case "stop": return [model, Cmd.cancel("pulse")];
  }
}
`);
    fs.writeFileSync(script, '{"advance":1.5}\n{"command":"go"}\n{"advance":40}\n{"kind":"stop"}\n{"advance":100}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src/devhost.ts"), entry, "--script", script], { cwd: dir, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const models = run.stdout.split("\n").filter(line => line.startsWith("model ")).map(line => JSON.parse(line.slice(6)));
    const last = models.at(-1);
    assert.equal(last.once, 1); assert.equal(last.pulses, 2);
    assert.deepEqual(last.stamp, { $bytes: "1" });
    assert.deepEqual(last.key, { $bytes: "pulse" });
    assert.deepEqual(last.timestamp, { $bytes: "41500000" });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("the virtual host returns complete explicit file refusals", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-file-devhost-"));
  try {
    const entry = path.join(dir, "core.ts"), script = path.join(dir, "script.ndjson");
    fs.writeFileSync(entry, `
import { Cmd, asciiBytes, type FileResultArm } from "@native-sdk/core";
export interface Model { readonly last: FileResultArm | null; }
export type Msg = { readonly kind: "read" } | { readonly kind: "write" } | ({ readonly kind: "done" } & FileResultArm);
export function initialModel(): Model { return { last: null }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "read": return [model, Cmd.readFileResult(asciiBytes("notes.txt"), { key: "read", result: "done" })];
    case "write": return [model, Cmd.writeFileResult(asciiBytes("notes.txt"), asciiBytes("body"), { key: "write", result: "done" })];
    case "done": return { last: msg };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"read"}\n{"kind":"write"}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src/devhost.ts"), entry, "--script", script], { cwd: dir, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const replies = run.stdout.split("\n").filter(line => line.startsWith("model ")).map(line => JSON.parse(line.slice(6)).last).filter(Boolean).filter((reply, i, all) => i === 0 || JSON.stringify(reply) !== JSON.stringify(all[i - 1]));
    assert.equal(replies.length, 2);
    for (const [i, reply] of replies.entries()) assert.deepEqual(reply, {
      kind: "done", key: { $bytes: i === 0 ? "read" : "write" }, operation: i === 0 ? "read" : "write", event: "terminal", outcome: "rejected", bytes: { $bytes: "" }, totalBytes: { $bytes: "0" }, mtimeMs: { $bytes: "0" }, exists: false, droppedBefore: 0,
    });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test("virtual complete timers preserve unkeyed owners, rearm modes and report capacity and interval refusal", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-timer-devhost-"));
  try {
    const entry = path.join(dir, "core.ts"), script = path.join(dir, "script.ndjson");
    fs.writeFileSync(entry, `
import { Cmd } from "@native-sdk/core";
export interface Model { readonly fired: number; readonly rejected: number; }
export type Msg = { readonly kind: "arm" } | { readonly kind: "replace" } | { readonly kind: "cancel" }
  | { readonly kind: "done"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: "fired" | "rejected" };
export function initialModel(): Model { return { fired: 0, rejected: 0 }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "arm": {
      const cmds: Cmd<Msg>[] = [];
      for (let i = 0; i < 15; i += 1) cmds.push(Cmd.timerResult("", 10, "one_shot", { result: "done" }));
      cmds.push(Cmd.timerResult("named", 5, "repeating", { result: "done" }));
      cmds.push(Cmd.timerResult("overflow", 10, "one_shot", { result: "done" }));
      cmds.push(Cmd.timerResult("invalid", 0.5, "one_shot", { result: "done" }));
      return [model, Cmd.batch(cmds)];
    }
    case "replace": return [model, Cmd.timerResult("named", 10, "one_shot", { result: "done" })];
    case "cancel": return [model, Cmd.cancel("")];
    case "done": return msg.outcome === "fired" ? { ...model, fired: model.fired + 1 } : { ...model, rejected: model.rejected + 1 };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"arm"}\n{"kind":"replace"}\n{"kind":"cancel"}\n{"advance":30}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src/devhost.ts"), entry, "--script", script], { cwd: dir, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const last = run.stdout.split("\n").filter(line => line.startsWith("model ")).map(line => JSON.parse(line.slice(6))).at(-1);
    assert.deepEqual(last, { fired: 16, rejected: 2 });
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});


test("virtual byte-key file commands retain complete terminals and cancellation uses exact bytes", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "native-byte-key-devhost-"));
  try {
    const entry = path.join(dir, "core.ts"), script = path.join(dir, "script.ndjson");
    fs.writeFileSync(entry, `
import { Cmd, asciiBytes, type FileResultArm } from "@native-sdk/core";
export interface Model { readonly fired: number; readonly last: FileResultArm | null; }
export type Msg = { readonly kind: "arm" } | { readonly kind: "bad_cancel" } | { readonly kind: "good_cancel" } | { readonly kind: "tick" } | { readonly kind: "read" } | { readonly kind: "write" } | ({ readonly kind: "done" } & FileResultArm);
export function initialModel(): Model { return { fired: 0, last: null }; }
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "arm": return [model, Cmd.batch([Cmd.delay("�", 10, "tick"), Cmd.delay("slot", 10, "tick")])];
    case "bad_cancel": return [model, Cmd.cancelKey(new Uint8Array([255]))];
    case "good_cancel": return [model, Cmd.cancelKey(asciiBytes("slot"))];
    case "tick": return { ...model, fired: model.fired + 1 };
    case "read": return [model, Cmd.readFileResultKey(asciiBytes("read-key"), asciiBytes("notes.txt"), { result: "done" })];
    case "write": return [model, Cmd.writeFileResultKey(asciiBytes("write-key"), asciiBytes("notes.txt"), asciiBytes("body"), { result: "done" })];
    case "done": return { ...model, last: msg };
  }
}
`);
    fs.writeFileSync(script, '{"kind":"arm"}\n{"kind":"bad_cancel"}\n{"kind":"good_cancel"}\n{"advance":10}\n{"kind":"read"}\n{"kind":"write"}\n');
    const run = spawnSync(process.execPath, [path.join(packageDir, "src/devhost.ts"), entry, "--script", script], { cwd: dir, encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const models = run.stdout.split("\n").filter(line => line.startsWith("model ")).map(line => JSON.parse(line.slice(6)));
    assert.equal(models.at(-1).fired, 1);
    for (const [key, operation] of [["read-key", "read"], ["write-key", "write"]]) {
      const reply = models.find(model => model.last?.key?.$bytes === key)?.last;
      assert.deepEqual(reply, { kind: "done", key: { $bytes: key }, operation, event: "terminal", outcome: "rejected", bytes: { $bytes: "" }, totalBytes: { $bytes: "0" }, mtimeMs: { $bytes: "0" }, exists: false, droppedBefore: 0 });
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
