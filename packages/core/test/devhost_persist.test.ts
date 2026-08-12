import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { automationProtocolFingerprint, journalFormatFingerprint, readDevhostJournal } from "../src/devhost_journal.mjs";

function runTemporaryDevhost(
  files: Record<string, string>,
  options: { script?: readonly string[]; serviceCwd?: boolean; env?: NodeJS.ProcessEnv; timeout?: number } = {},
): { run: ReturnType<typeof spawnSync>; serviceCwd: string } {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-devhost-services-"));
  const serviceCwd = path.join(root, "app-data");
  try {
    for (const [relative, source] of Object.entries(files)) {
      const absolute = path.join(root, relative);
      fs.mkdirSync(path.dirname(absolute), { recursive: true });
      fs.writeFileSync(absolute, source);
    }
    const script = path.join(root, "scenario.ndjson");
    fs.writeFileSync(script, `${(options.script ?? ['{"settle":true}']).join("\n")}\n`);
    const argv = [
      path.join(packageDir, "src", "devhost.ts"),
      path.join(root, "src", "core.ts"),
      "--script",
      script,
    ];
    if (options.serviceCwd) argv.push("--service-cwd", serviceCwd);
    const run = spawnSync(process.execPath, argv, {
      cwd: root,
      encoding: "utf8",
      env: options.env ?? process.env,
      timeout: options.timeout ?? 10_000,
    });
    return { run, serviceCwd };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function lastModel(stdout: string): Record<string, unknown> {
  const line = stdout.split("\n").filter((candidate) => candidate.startsWith("model ")).at(-1);
  assert.ok(line, stdout);
  return JSON.parse(line.slice("model ".length)) as Record<string, unknown>;
}

test("the devhost keeps Cmd.persist in memory and restores it through the boot route", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-core", "persist_fixture.ts"),
    "--script",
    path.join(repo, "tests", "ts-core", "persist_devhost.ndjson"),
    "--persist-ok",
    "restored",
    "--persist-none",
    "fresh_boot",
    "--persist-err",
    "restore_failed",
  ], { cwd: repo, encoding: "utf8" });

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /cmd persist \(stored in virtual host memory\)/);
  assert.match(run.stdout, /restart virtual host/);
  assert.match(run.stdout, /"value":1.*"restoreState":1/);
});

test("the devhost rejects a persistence route that names no Msg arm", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-core", "persist_fixture.ts"),
    "--persist-ok",
    "restored",
    "--persist-none",
    "typo",
    "--persist-err",
    "restore_failed",
  ], { cwd: repo, encoding: "utf8" });

  assert.equal(run.status, 1, run.stdout);
  assert.match(run.stderr, /NS1033/);
  assert.match(run.stderr, /route `typo` \(none\) names no Msg arm/);
  assert.doesNotMatch(run.stdout, /^model /m);
});

test("the devhost executes typed services, vendored npm, and stream events directly under node", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-services", "ok", "src", "core.ts"),
    "--script",
    path.join(repo, "tests", "ts-services", "ok", "devhost.ndjson"),
    "--service-package",
    "escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d",
  ], { cwd: repo, encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /service feeds\.parse ok/);
  assert.match(run.stdout, /cmd channel_open key=77 event=stream_event/);
  assert.match(run.stdout, /"successes":3,"failures":0,"chunks":3/);
});

test("devhost services use the app-data cwd and the packaged environment allowlist", () => {
  const { run, serviceCwd } = runTemporaryDevhost({
    "src/core.ts": `
import { Cmd } from "@native-sdk/core";
import { authorityInspect } from "@native-sdk/services";
export interface Model { readonly facts: Uint8Array; readonly failed: boolean; }
export type Msg =
  | { readonly kind: "inspected"; readonly facts: Uint8Array }
  | { readonly kind: "failed"; readonly error: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ facts: new Uint8Array(0), failed: false }, authorityInspect({ key: "authority", ok: "inspected", err: "failed" })];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "inspected": return [{ facts: msg.facts, failed: false }, Cmd.none];
    case "failed": return [{ facts: msg.error, failed: true }, Cmd.none];
  }
}`,
    "src/services/authority.ts": `
export function inspect(): Uint8Array {
  return new TextEncoder().encode(JSON.stringify({
    cwd: process.cwd(),
    tz: process.env.TZ ?? "",
    secret: process.env.DEVHOST_SECRET ?? "",
    sdk: process.env.NATIVE_SDK_SECRET ?? "",
  }));
}`,
  }, {
    serviceCwd: true,
    env: { ...process.env, TZ: "UTC", DEVHOST_SECRET: "must-not-cross", NATIVE_SDK_SECRET: "must-not-cross-sdk" },
  });

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, new RegExp(path.basename(serviceCwd)));
  assert.match(run.stdout, /\\"tz\\":\\"UTC\\"/);
  assert.doesNotMatch(run.stdout, /must-not-cross/);
});

test("a service module import failure fails its queued request instead of hanging before ready", () => {
  const { run } = runTemporaryDevhost({
    "src/core.ts": `
import { Cmd } from "@native-sdk/core";
import { brokenRun } from "@native-sdk/services";
export interface Model { readonly failures: number; }
export type Msg =
  | { readonly kind: "done"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly error: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ failures: 0 }, brokenRun({ key: "broken", ok: "done", err: "failed" })];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "done": return [{ failures: -1 }, Cmd.none];
    case "failed": return [{ failures: model.failures + 1 }, Cmd.none];
  }
}`,
    "src/services/broken.ts": `
const invalid = JSON.parse("{");
void invalid;
export function run(): Uint8Array { return new Uint8Array(0); }`,
  });

  assert.equal(run.status, 0, run.stderr);
  assert.equal(lastModel(run.stdout).failures, 1);
});

test("a service terminal handler can immediately reuse the completed route key", () => {
  const { run } = runTemporaryDevhost({
    "src/core.ts": `
import { Cmd } from "@native-sdk/core";
import { workerRun } from "@native-sdk/services";
export interface Model { readonly successes: number; readonly failures: number; }
export type Msg =
  | { readonly kind: "done"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly error: Uint8Array };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ successes: 0, failures: 0 }, workerRun({ key: "same", ok: "done", err: "failed" })];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "done": {
      const next = { successes: model.successes + 1, failures: model.failures };
      if (next.successes === 1) return [next, workerRun({ key: "same", ok: "done", err: "failed" })];
      return [next, Cmd.none];
    }
    case "failed": return [{ successes: model.successes, failures: model.failures + 1 }, Cmd.none];
  }
}`,
    "src/services/worker.ts": `export function run(): Uint8Array { return new Uint8Array([1]); }`,
  });

  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(lastModel(run.stdout), { successes: 2, failures: 0 });
});

test("the devhost enforces @streamBuffer and reports dropped chunks", () => {
  const { run } = runTemporaryDevhost({
    "src/core.ts": `
import { Cmd } from "@native-sdk/core";
import { streamBurst } from "@native-sdk/services";
export type StreamState = "data" | "closed" | "rejected";
export interface Model { readonly chunks: number; readonly dropped: number; readonly closed: boolean; readonly failures: number; }
export type Msg =
  | { readonly kind: "done"; readonly bytes: Uint8Array }
  | { readonly kind: "failed"; readonly error: Uint8Array }
  | { readonly kind: "stream_event"; readonly key: number; readonly state: StreamState; readonly bytes: Uint8Array; readonly droppedPending: number; readonly droppedTotal: number };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ chunks: 0, dropped: 0, closed: false, failures: 0 }, streamBurst({ key: "burst", channelKey: 91, event: "stream_event", ok: "done", err: "failed" })];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "done": return [model, Cmd.none];
    case "failed": return [{ ...model, failures: model.failures + 1 }, Cmd.none];
    case "stream_event": return [{
      ...model,
      chunks: msg.state === "data" ? model.chunks + 1 : model.chunks,
      dropped: msg.droppedTotal,
      closed: msg.state === "closed" ? true : model.closed,
    }, Cmd.none];
  }
}`,
    "src/services/stream.ts": `
/** @streamBuffer 1 */
export function burst(emit: (chunk: Uint8Array) => void): Uint8Array {
  const chunk = new Uint8Array([1]);
  for (let index = 0; index < 50000; index++) emit(chunk);
  return chunk;
}`,
  }, { timeout: 20_000 });

  assert.equal(run.status, 0, run.stderr);
  const model = lastModel(run.stdout);
  assert.equal(model.failures, 0);
  assert.equal(model.closed, true);
  assert.ok((model.chunks as number) > 0 && (model.chunks as number) < 50_000, JSON.stringify(model));
  assert.ok((model.dropped as number) > 0, JSON.stringify(model));
});

test("the devhost cooperatively cancels streams and enforces service deadlines", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-services", "ok", "src", "core.ts"),
    "--script",
    path.join(repo, "tests", "ts-services", "ok", "devhost_cancel.ndjson"),
    "--service-package",
    "escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d",
  ], { cwd: repo, encoding: "utf8" });
  for (const marker of ["hang.started", "stream-hang.started"]) {
    fs.rmSync(path.join(repo, marker), { force: true });
  }

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /cmd cancel stream-hang \(service cancellation requested\)/);
  assert.match(run.stdout, /service feeds\.streamHang err/);
  assert.match(run.stdout, /service feeds\.hang err/);
  assert.match(run.stdout, /\\"kind\\":\\"timeout\\"/);
  assert.match(run.stdout, /"successes":1,"failures":2,"chunks":1/);
});

test("service deadlines include time spent in the devhost queue", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const blockerMarker = path.join(repo, "queued-blocker.started");
  const probeMarker = path.join(repo, "queued-probe.started");
  fs.rmSync(blockerMarker, { force: true });
  fs.rmSync(probeMarker, { force: true });
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-services", "ok", "src", "core.ts"),
    "--script",
    path.join(repo, "tests", "ts-services", "ok", "devhost_queued_deadline.ndjson"),
    "--service-package",
    "escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d",
  ], { cwd: repo, encoding: "utf8" });
  const blockerStarted = fs.existsSync(blockerMarker);
  const probeStarted = fs.existsSync(probeMarker);
  fs.rmSync(blockerMarker, { force: true });
  fs.rmSync(probeMarker, { force: true });

  assert.equal(run.status, 0, run.stderr);
  assert.equal(blockerStarted, true);
  assert.equal(probeStarted, false);
  assert.match(run.stdout, /"successes":1,"failures":2/);
  assert.match(run.stdout, /\\"kind\\":\\"timeout\\"/);
});

test("the devhost keeps duplicate, unkeyed, and streaming service admission aligned with native", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-services", "ok", "src", "core.ts"),
    "--script",
    path.join(repo, "tests", "ts-services", "ok", "devhost_regressions.ndjson"),
    "--service-package",
    "escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d",
  ], { cwd: repo, encoding: "utf8" });

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /"successes":5,"failures":2,"chunks":3/);
});

test("a clean service worker exit fails the request and settles the devhost", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const run = spawnSync(process.execPath, [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-services", "ok", "src", "core.ts"),
    "--script",
    path.join(repo, "tests", "ts-services", "ok", "devhost_exit.ndjson"),
    "--service-package",
    "escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d",
  ], { cwd: repo, encoding: "utf8", timeout: 10_000 });

  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /service worker exited/);
  assert.match(run.stdout, /"successes":1,"failures":1,"chunks":0/);
});

test("a devhost service recording replays without starting services and uses the runtime journal identity", () => {
  const packageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const repo = path.resolve(packageDir, "..", "..");
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "native-devhost-journal-"));
  const journal = path.join(scratch, "session.journal");
  const argv = [
    path.join(packageDir, "src", "devhost.ts"),
    path.join(repo, "tests", "ts-services", "ok", "src", "core.ts"),
    "--script",
    path.join(repo, "tests", "ts-services", "ok", "devhost_journal.ndjson"),
    "--service-package",
    "escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d",
    "--app-name",
    "ts-services-e2e",
    "--canvas-label",
    "fixture-canvas",
    "--window-width",
    "320",
    "--window-height",
    "200",
  ];
  try {
    const recorded = spawnSync(process.execPath, argv, {
      cwd: repo, encoding: "utf8", env: { ...process.env, NATIVE_SDK_SESSION_RECORD: journal },
    });
    assert.equal(recorded.status, 0, recorded.stderr);
    const records = readDevhostJournal(journal);
    assert.ok(records.some((record) => record.type === "effect" && record.kind === 9));
    assert.ok(records.some((record) => record.type === "effect" && record.kind === 12));

    const replayed = spawnSync(process.execPath, [...argv.slice(0, 2), ...argv.slice(4)], {
      cwd: repo, encoding: "utf8", env: { ...process.env, NATIVE_SDK_SESSION_REPLAY: journal },
    });
    assert.equal(replayed.status, 0, replayed.stderr);
    assert.match(replayed.stdout, /service feeds\.parse replay ok/);
    assert.match(replayed.stdout, /"successes":3,"failures":0,"chunks":3/);
    assert.doesNotMatch(replayed.stdout, /service feeds\..+ \d+\.\d+ms/);

    const pins = spawnSync("zig", ["build", "print-pins"], { cwd: repo, encoding: "utf8" });
    assert.equal(pins.status, 0, pins.stderr);
    assert.match(pins.stdout, new RegExp(`session journal format\\s+0x${journalFormatFingerprint.toString(16).padStart(16, "0")}`));
    assert.match(pins.stdout, new RegExp(`automation protocol\\s+0x${automationProtocolFingerprint.toString(16).padStart(16, "0")}`));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
});
