#!/usr/bin/env node
// Exact-pinned plain-scriptc executable compile for the service host. The
// version is verified against the one packages/core pin and the echo in
// services.contract.json before any compiler work starts.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) {
      console.error("usage: run_external_service_compiler.mjs --stage <dir> --manifest <package.json> --contract <services.contract.json> --out-exe <file> --host-platform <arch-os-abi> --target-platform <arch-os-abi> (--compiler <cmd> | --compiler-js <main.js>)");
      process.exit(2);
    }
    args[key.slice(2)] = value;
  }
  for (const required of ["stage", "manifest", "contract", "out-exe", "host-platform", "target-platform"]) {
    if (!args[required]) {
      console.error(`run_external_service_compiler.mjs: missing --${required}`);
      process.exit(2);
    }
  }
  if (!args.compiler && !args["compiler-js"]) {
    console.error("run_external_service_compiler.mjs: supply --compiler or --compiler-js");
    process.exit(2);
  }
  return args;
}

const args = parseArgs(process.argv);
if (args["target-platform"] !== args["host-platform"]) {
  console.error(
    `TypeScript services currently compile only for the build host (${args["host-platform"]}), but the app targets ${args["target-platform"]}. ` +
    "Build the service app on its target platform until the pinned service compiler supports cross-target executables.",
  );
  process.exit(2);
}
for (const key of ["stage", "manifest", "contract", "out-exe", "compiler-js"]) {
  if (args[key]) args[key] = path.resolve(args[key]);
}
const argv0 = args.compiler
  ? (fs.existsSync(args.compiler) ? [args.compiler] : args.compiler.split(/\s+/))
  : [process.execPath, args["compiler-js"]];

const manifest = JSON.parse(fs.readFileSync(args.manifest, "utf8"));
const pin = manifest.dependencies?.scriptc;
const contract = JSON.parse(fs.readFileSync(args.contract, "utf8"));
if (typeof pin !== "string" || !/^\d+\.\d+\.\d+$/.test(pin)) {
  console.error("packages/core/package.json carries no exact scriptc pin");
  process.exit(2);
}
if (contract.compiler_version !== pin) {
  console.error(`services contract echoes scriptc ${contract.compiler_version}, but packages/core pins ${pin} — regenerate the contract with this SDK`);
  process.exit(2);
}
const probe = spawnSync(argv0[0], [...argv0.slice(1), "-v"], { encoding: "utf8" });
const reported = (probe.stdout ?? "").trim();
if (probe.status !== 0 || reported !== pin) {
  console.error(`service compiler reports ${reported || "no version"}, but the SDK pins ${pin}`);
  process.exit(2);
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-external-services-"));
try {
  fs.cpSync(args.stage, work, { recursive: true });
  const built = path.join(work, process.platform === "win32" ? "service-host.exe" : "service-host");
  const result = spawnSync(argv0[0], [...argv0.slice(1), "build", "service_host_main.ts", "-o", built], {
    cwd: work,
    stdio: "inherit",
  });
  if (result.status !== 0) process.exit(result.status ?? 1);
  if (!fs.existsSync(built)) {
    console.error("the external service compile produced no executable");
    process.exit(1);
  }
  fs.mkdirSync(path.dirname(args["out-exe"]), { recursive: true });
  fs.copyFileSync(built, args["out-exe"]);
  fs.chmodSync(args["out-exe"], 0o755);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
