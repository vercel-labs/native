import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { installedRelease } from "../scripts/scriptc_toolchain.mjs";
import { compilerArgv, publishedScriptcArgv } from "../scripts/compiler_command.mjs";

test("Windows npm scriptc shims execute the package's published bin through Node", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-command-"));
  try {
    const nodeModules = path.join(root, "node_modules");
    const shim = path.join(nodeModules, ".bin", "scriptc.cmd");
    const packageRoot = path.join(nodeModules, "scriptc");
    const publishedBin = path.join(packageRoot, "dist", "bootstrap.js");
    fs.mkdirSync(path.dirname(shim), { recursive: true });
    fs.mkdirSync(path.dirname(publishedBin), { recursive: true });
    fs.writeFileSync(shim, "@echo off\r\n");
    fs.writeFileSync(path.join(packageRoot, "package.json"), JSON.stringify({ bin: { scriptc: "dist/bootstrap.js" } }));
    fs.writeFileSync(publishedBin, "// published compiler bin\n");

    assert.deepEqual(
      compilerArgv(shim, { platform: "win32", node: "C:\\Node\\node.exe", env: {} }),
      ["C:\\Node\\node.exe", publishedBin],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("Windows npm scriptc shims execute a native package bin directly", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-command-"));
  try {
    const nodeModules = path.join(root, "node_modules");
    const shim = path.join(nodeModules, ".bin", "scriptc.cmd");
    const packageRoot = path.join(nodeModules, "scriptc");
    const publishedBin = path.join(packageRoot, "bin", "scriptc.exe");
    fs.mkdirSync(path.dirname(shim), { recursive: true });
    fs.mkdirSync(path.dirname(publishedBin), { recursive: true });
    fs.writeFileSync(shim, "@echo off\r\n");
    fs.writeFileSync(path.join(packageRoot, "package.json"), JSON.stringify({ bin: { scriptc: "bin/scriptc.exe" } }));
    fs.writeFileSync(publishedBin, "native compiler bin");

    assert.deepEqual(
      compilerArgv(shim, { platform: "win32", node: "C:\\Node\\node.exe", env: {} }),
      [publishedBin],
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("Windows batch-file compiler overrides use cmd.exe while other commands stay direct", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "native-scriptc-command-"));
  try {
    const override = path.join(root, "custom compiler.cmd");
    fs.writeFileSync(override, "@echo off\r\n");
    assert.deepEqual(
      compilerArgv(override, { platform: "win32", env: { ComSpec: "C:\\Windows\\System32\\cmd.exe" } }),
      ["C:\\Windows\\System32\\cmd.exe", "/d", "/s", "/c", override],
    );
    assert.deepEqual(compilerArgv(override, { platform: "linux" }), [override]);
    assert.deepEqual(compilerArgv("node ./compiler.js", { platform: "win32" }), ["node", "./compiler.js"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("published scriptc command follows the native package bin", () => {
  const coreRoot = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const argv = publishedScriptcArgv(path.join(coreRoot, "package.json"), { node: "node24" });
  assert.equal(argv.length, 1);
  assert.equal(argv[0], path.join(installedRelease(path.join(coreRoot, "package.json"))!.root, "release", "bin", process.platform === "win32" ? "scriptc.exe" : "scriptc"));
});
