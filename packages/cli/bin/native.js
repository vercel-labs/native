#!/usr/bin/env node
// Runs the native `native` executable from this platform's package. The sources every app build
// compiles (runtime/, shared/ and host/) ship in this package, beside this file's directory, and
// NATIVE_SDK_ROOT tells the executable where they are; scriptc and @scriptc/types are this
// package's dependencies, which the executable finds from there.
import { spawnSync } from "node:child_process";
import { accessSync, chmodSync, constants } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { executableName, hostDescription, hostPlatform, packageName } from "./platforms.js";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const platform = hostPlatform();
if (platform === undefined) fail(`no native executable for ${hostDescription()}`);

const name = packageName(platform);
let packageDir;
try {
  packageDir = dirname(createRequire(import.meta.url).resolve(`${name}/package.json`));
} catch {
  fail(`${name} is not installed; reinstall @native-sdk/cli with optional dependencies enabled`);
}

const executable = join(packageDir, "bin", executableName());
if (process.platform !== "win32") {
  try {
    accessSync(executable, constants.X_OK);
  } catch {
    try {
      chmodSync(executable, 0o755);
    } catch {
      // spawnSync reports the error.
    }
  }
}

const result = spawnSync(executable, process.argv.slice(2), {
  stdio: "inherit",
  env: { ...process.env, NATIVE_SDK_ROOT: root },
});
if (result.error) fail(`could not run ${executable}: ${result.error.message}`);
if (result.signal) process.kill(process.pid, result.signal);
process.exitCode = result.status ?? 1;

function fail(message) {
  process.stderr.write(`native: ${message}\n`);
  process.exit(1);
}
