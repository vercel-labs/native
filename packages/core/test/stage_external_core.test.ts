// Issue #770: `native dev` failed with ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING
// because the staging script statically imported the TypeScript view frontend.
// On an npm install the CLI (and this script) live under node_modules, where
// node refuses to strip `.ts`. These tests build that exact layout and hold the
// staging script to it.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const core = fileURLToPath(new URL("..", import.meta.url));
const nodeMajor = Number(process.versions.node.split(".")[0]);

function run(file: string, args: string[], cwd: string) {
  return spawnSync(process.execPath, [file, ...args], { cwd, encoding: "utf8", timeout: 120_000 });
}

/// The npm-installed CLI shape: the SDK package copied verbatim beneath
/// `node_modules/@native-sdk/cli/packages/core`, with its dependency tree
/// beside it. The copy is what matters — a symlink would resolve back out of
/// node_modules and node would allow its type stripping.
function installedLayout(root: string) {
  const sdk = path.join(root, "node_modules", "@native-sdk", "cli", "packages", "core");
  fs.mkdirSync(sdk, { recursive: true });
  for (const entry of ["package.json", "scripts", "src", "sdk", "compile-surface"]) {
    fs.cpSync(path.join(core, entry), path.join(sdk, entry), { recursive: true });
  }
  const typescript = path.join(core, "node_modules", "@typescript", "old");
  assert.ok(fs.existsSync(typescript), "packages/core dev dependencies are required (npm ci --include=dev)");
  fs.cpSync(typescript, path.join(root, "node_modules", "@typescript", "old"), { recursive: true, dereference: true });
  return sdk;
}

test("staging a ts-core app succeeds when the CLI lives under node_modules", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-stage-installed-"));
  try {
    const sdk = installedLayout(root);
    const appSrc = path.join(root, "app");
    fs.mkdirSync(appSrc);
    fs.writeFileSync(path.join(appSrc, "core.ts"), "export const count: number = 1;\n");
    fs.writeFileSync(path.join(root, "facade.ts"), "export const facade: number = 1;\n");
    fs.writeFileSync(path.join(root, "profile.json"), "{}\n");

    // The pre-fix failure, for the record: a bare import of the frontend from
    // this layout is exactly what node refuses to load. Node 24 reports it as
    // ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING.
    const probe = path.join(root, "probe.mjs");
    fs.writeFileSync(probe, `await import(${JSON.stringify(path.join(sdk, "src", "view_frontend.ts"))});\n`);
    const bare = run(probe, [], root);
    assert.notEqual(bare.status, 0);
    if (nodeMajor >= 24) assert.match(bare.stderr, /ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING/);

    const staged = path.join(root, "out");
    const result = run(path.join(sdk, "scripts", "stage_external_core.mjs"), [
      "--src", appSrc,
      "--sdk", path.join(sdk, "sdk"),
      "--static", path.join(sdk, "compile-surface", "core.ts"),
      "--facade", path.join(root, "facade.ts"),
      "--profile", path.join(root, "profile.json"),
      "--out", staged,
    ], root);
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /ERR_UNSUPPORTED_NODE_MODULES_TYPE_STRIPPING|ERR_NATIVE_SDK_TS_HOOKS/);
    assert.match(fs.readFileSync(path.join(staged, "core.ts"), "utf8"), /export const count: number = 1;/);
    assert.ok(fs.readFileSync(path.join(staged, "sdk", "core.ts"), "utf8").includes("export"));
    assert.match(fs.readFileSync(path.join(staged, "core_facade.ts"), "utf8"), /facade/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
