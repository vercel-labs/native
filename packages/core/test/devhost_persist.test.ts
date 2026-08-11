import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

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
