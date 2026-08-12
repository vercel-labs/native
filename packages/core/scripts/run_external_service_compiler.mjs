#!/usr/bin/env node
// Exact-pinned scriptc compile for the service class. Two output lanes over
// one staged tree: --out-exe builds the plain-scriptc child executable
// (service_host_main.ts, framed stdio), --out-archive builds the library-mode
// archive the in-process carrier links (service_inproc_main.ts under the
// staged service_profile.json). One invocation may produce either or both.
// The compiler version is verified against the one packages/core pin and the
// echo in services.contract.json before any compiler work starts.

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
      console.error("usage: run_external_service_compiler.mjs --stage <dir> --manifest <package.json> --contract <services.contract.json> (--out-exe <file> | --out-archive <file>) --host-platform <arch-os-abi> --target-platform <arch-os-abi> (--compiler <cmd> | --compiler-js <main.js>)");
      process.exit(2);
    }
    args[key.slice(2)] = value;
  }
  for (const required of ["stage", "manifest", "contract", "host-platform", "target-platform"]) {
    if (!args[required]) {
      console.error(`run_external_service_compiler.mjs: missing --${required}`);
      process.exit(2);
    }
  }
  if (!args["out-exe"] && !args["out-archive"]) {
    console.error("run_external_service_compiler.mjs: supply --out-exe, --out-archive, or both");
    process.exit(2);
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
for (const key of ["stage", "manifest", "contract", "out-exe", "out-archive", "compiler-js"]) {
  if (args[key]) args[key] = path.resolve(args[key]);
}
const argv0 = args.compiler
  ? (fs.existsSync(args.compiler) ? [args.compiler] : args.compiler.split(/\s+/))
  : [process.execPath, args["compiler-js"]];

function isNpmStaticRefusal(output) {
  const percent = output.match(/compile statically\s+\d+\s+\((\d+)%\)/i);
  return (percent !== null && Number(percent[1]) < 100)
    || /SC-NPM-STATIC|\bSC2013\b|\bSC4020\b|island fallback|cannot compile statically|static coverage[^\n]*dynamic/i.test(output);
}

function printNpmStaticTeaching() {
  console.error(
    "native check: this service package does not clear scriptc's static tier. " +
    "Choose another exact vendored package, port/vendor a static-compatible implementation, or wait for compiler support; " +
    "Native SDK never enables npm auto-fallback or --dynamic.",
  );
}

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
  const staticPackages = Array.isArray(contract.packages) ? contract.packages.map((entry) => entry.name) : [];
  if (staticPackages.length > 0) {
    const coverage = spawnSync(argv0[0], [
      ...argv0.slice(1),
      "coverage",
      "service_host_main.ts",
      "--npm-static",
      staticPackages.join(","),
    ], { cwd: work, encoding: "utf8" });
    const coverageOutput = `${coverage.stdout ?? ""}${coverage.stderr ?? ""}`;
    if (coverage.status !== 0 || isNpmStaticRefusal(coverageOutput)) {
      if (coverage.stdout) process.stdout.write(coverage.stdout);
      if (coverage.stderr) process.stderr.write(coverage.stderr);
      if (isNpmStaticRefusal(coverageOutput)) printNpmStaticTeaching();
      process.exit(coverage.status && coverage.status !== 0 ? coverage.status : 1);
    }
  }
  if (args["out-exe"]) {
    const built = path.join(work, process.platform === "win32" ? "service-host.exe" : "service-host");
    const compileArgs = [...argv0.slice(1), "build", "service_host_main.ts", "-o", built];
    if (staticPackages.length > 0) compileArgs.push("--npm-static", staticPackages.join(","));
    const result = spawnSync(argv0[0], compileArgs, {
      cwd: work,
      encoding: "utf8",
    });
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    if (result.status !== 0) {
      if (isNpmStaticRefusal(`${result.stdout ?? ""}${result.stderr ?? ""}`)) printNpmStaticTeaching();
      process.exit(result.status ?? 1);
    }
    if (!fs.existsSync(built)) {
      console.error("the external service compile produced no executable");
      process.exit(1);
    }
    fs.mkdirSync(path.dirname(args["out-exe"]), { recursive: true });
    fs.copyFileSync(built, args["out-exe"]);
    fs.chmodSync(args["out-exe"], 0o755);
  }
  if (args["out-archive"]) {
    // The in-process carrier's library archive: the staged profile pins
    // the entry (service_inproc_main.ts), the fixed symbol family, runtime
    // localization, and thread-instanced state. Library mode takes no
    // --npm-static: bare npm specifiers are static-or-refuse there, and
    // the vendored packages already staged under node_modules resolve
    // automatically.
    if (!fs.existsSync(path.join(work, "service_profile.json")) || !fs.existsSync(path.join(work, "service_inproc_main.ts"))) {
      console.error("the service stage carries no in-process entry/profile (stage with --inproc-main and --inproc-profile)");
      process.exit(2);
    }
    const builtArchive = path.join(work, "native_sdk_services");
    const result = spawnSync(argv0[0], [
      ...argv0.slice(1),
      "build",
      "--lib",
      "--profile",
      "service_profile.json",
      "-o",
      builtArchive,
    ], { cwd: work, encoding: "utf8" });
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    if (result.status !== 0) {
      if (isNpmStaticRefusal(`${result.stdout ?? ""}${result.stderr ?? ""}`)) printNpmStaticTeaching();
      process.exit(result.status ?? 1);
    }
    const producedArchive = [`${builtArchive}.lib.a`, builtArchive].find((name) => fs.existsSync(name));
    if (!producedArchive) {
      console.error("the external service compile produced no archive (expected native_sdk_services.lib.a)");
      process.exit(1);
    }
    fs.mkdirSync(path.dirname(args["out-archive"]), { recursive: true });
    fs.copyFileSync(producedArchive, args["out-archive"]);
  }
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
