import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import { automationProtocolFingerprint, journalFormatFingerprint, readDevhostJournal } from "../src/devhost_journal.mjs";

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
    assert.match(pins.stdout, new RegExp(`session journal format\\s+0x${journalFormatFingerprint.toString(16)}`));
    assert.match(pins.stdout, new RegExp(`automation protocol\\s+0x${automationProtocolFingerprint.toString(16).padStart(16, "0")}`));
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
});
