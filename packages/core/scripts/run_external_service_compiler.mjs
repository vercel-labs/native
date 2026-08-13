#!/usr/bin/env node
// Exact-pinned scriptc compile for the service class. Two output lanes over
// one staged tree: --out-exe builds the plain-scriptc child executable
// (service_host_main.ts, framed stdio), --out-archive builds the library-mode
// archive the in-process carrier links (service_inproc_main.ts under the
// staged service_profile.json). One invocation may produce either or both.
// The compiler version is verified against the one packages/core pin and the
// echo in services.contract.json before any compiler work starts. Host/target
// pairings follow the pinned compiler's build matrix: same-triple compiles run
// natively; Linux and Windows GNU targets cross-compile from any desktop host
// over the compiler's zig-cc lane; macOS targets need a macOS build host.
// Mobile targets (aarch64 iOS, iOS simulator, and Android) are archive-only:
// --out-archive is admitted (iOS from a macOS host, Android from any desktop
// host with an NDK), --out-exe refuses with the in-process pointer.

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
      console.error("usage: run_external_service_compiler.mjs --stage <dir> --manifest <package.json> --contract <services.contract.json> (--out-exe <file> | --out-archive <file>) --host-platform <arch-os-abi> --target-platform <arch-os-abi> [--zig-exe <path>] [--android-ndk <dir>] (--compiler <cmd> | --compiler-js <main.js>)");
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

// The pairing matrix the pinned compiler covers. Same-triple compiles run
// the native lane (host clang, no cross env). Different triples run the
// compiler's zig-cc lane: Linux and Windows GNU targets build from any
// desktop host (the compiler cross-compiles its runtime and localizes ELF and
// COFF objects itself); macOS targets build on a macOS host only, where Apple
// linking rides the host toolchain's SDK.
const platformOs = (platform) => (platform.split("-")[1] ?? "").split(".")[0];
const platformArch = (platform) => platform.split("-")[0] ?? "";
const platformAbi = (platform) => (platform.split("-")[2] ?? "").split(".")[0];
const hostArch = platformArch(args["host-platform"]);
const hostOs = platformOs(args["host-platform"]);
const hostAbi = platformAbi(args["host-platform"]);
const targetOs = platformOs(args["target-platform"]);
const targetArch = platformArch(args["target-platform"]);
const targetAbi = platformAbi(args["target-platform"]);
// The two mobile families, from the build graph's Zig triple spelling:
// `aarch64-ios[-simulator]` and `aarch64-linux-android`. The pinned compiler
// admits exactly aarch64 for both, library archives only.
const iosTarget = targetOs === "ios";
const androidTarget = targetOs === "linux" && targetAbi === "android";
const mobileTarget = iosTarget || androidTarget;
// The canonical SCRIPTC_TARGET spelling for a mobile compile: the compiler
// names iOS targets with the vendor (`aarch64-apple-ios[-simulator]`) and
// Android with the Zig triple itself.
const scriptcTarget = iosTarget
  ? `aarch64-apple-ios${targetAbi === "simulator" ? "-simulator" : ""}`
  : args["target-platform"];
// Zig names a native Windows host with the GNU ABI by default, while a user
// may explicitly target MSVC on that same machine. That remains native
// compiler work; an exact native GNU triple does too.
const nativeWindows = hostOs === "windows" && targetOs === "windows" && hostArch === targetArch &&
  (targetAbi === hostAbi || targetAbi === "msvc");
const cross = args["target-platform"] !== args["host-platform"] && !nativeWindows;
if (mobileTarget) {
  // Mobile services are archive-only: there is no child process to spawn on
  // iOS or Android, so the plain-scriptc executable lane refuses here.
  if (args["out-exe"]) {
    console.error(
      `TypeScript services for ${args["target-platform"]} build library archives only: mobile apps cannot spawn a sibling service process. ` +
      "Use the in-process carrier (--out-archive) — the mobile default.",
    );
    process.exit(2);
  }
  const desktopHost = ["macos", "linux", "windows"].includes(hostOs);
  const admitted = desktopHost && targetArch === "aarch64" && (!iosTarget || hostOs === "macos");
  if (!admitted) {
    console.error(
      iosTarget && hostOs !== "macos"
        ? `TypeScript services for an iOS target (${args["target-platform"]}) compile on a macOS build host only — the Apple SDK sysroot and Mach-O localization live there — but this build host is ${args["host-platform"]}. Build iOS service apps on a Mac.`
        : `TypeScript services compile for the mobile targets the pinned compiler covers — aarch64 iOS/iOS-simulator (macOS host) and aarch64 Android — but this build pairs host ${args["host-platform"]} with target ${args["target-platform"]}.`,
    );
    process.exit(2);
  }
} else if (cross) {
  const desktopHost = ["macos", "linux", "windows"].includes(hostOs);
  const admitted = desktopHost &&
    (targetOs === "linux" ||
      (targetOs === "windows" && targetAbi === "gnu") ||
      (targetOs === "macos" && hostOs === "macos"));
  if (!admitted) {
    console.error(
      targetOs === "windows" && targetAbi !== "gnu"
        ? `TypeScript services for a cross-target Windows build (${args["target-platform"]}) require the GNU ABI: Zig supplies that target's CRT and system libraries, while an MSVC target needs a native Windows toolchain. Build ${targetArch}-windows-msvc on a matching Windows host, or cross-compile as "${targetArch}-windows-gnu".`
        : targetOs === "macos"
        ? `TypeScript services for a macOS target (${args["target-platform"]}) compile on a macOS build host only — Apple linking needs the host toolchain's SDK — but this build host is ${args["host-platform"]}. Build macOS service apps on a Mac.`
        : `TypeScript services compile for desktop targets the pinned compiler covers — Linux and Windows GNU from a macOS/Linux/Windows build host, macOS from a macOS host — but this build pairs host ${args["host-platform"]} with target ${args["target-platform"]}.`,
    );
    process.exit(2);
  }
}

// Runtime localization is narrower than executable cross-compilation. The
// in-process archive's object merger supports native Linux through host
// binutils, cross-ELF for x86_64/aarch64 (Android included), COFF for
// x86_64, and Mach-O — iOS device and simulator included — on a macOS host.
// Keep this preflight in lockstep with ScriptC 0.0.29's compileLibrary guard
// so `in_process` refusals teach before compiler work.
if (args["out-archive"]) {
  const archiveSupported =
    (targetOs === "linux" && (!cross || ["x86_64", "aarch64"].includes(targetArch))) ||
    (targetOs === "windows" && targetArch === "x86_64" && (!cross || targetAbi === "gnu")) ||
    ((targetOs === "macos" || iosTarget) && hostOs === "macos");
  if (!archiveSupported) {
    console.error(
      `TypeScript in-process services cannot build a runtime-localized archive for ${args["target-platform"]} from ${args["host-platform"]}. ` +
      "The pinned compiler supports native Linux, cross-Linux x86_64/aarch64 (Android included), native Windows x86_64, cross-Windows x86_64 GNU, and macOS/iOS targets on a macOS host. " +
      "Use the child carrier (the desktop default), or choose a supported in-process target.",
    );
    process.exit(2);
  }
}
for (const key of ["stage", "manifest", "contract", "out-exe", "out-archive", "compiler-js", "zig-exe", "android-ndk"]) {
  if (args[key]) args[key] = path.resolve(args[key]);
}
const argv0 = args.compiler
  ? (fs.existsSync(args.compiler) ? [args.compiler] : args.compiler.split(/\s+/))
  : [process.execPath, args["compiler-js"]];

// Cross compiles hand the compiler its zig-cc lane: the target triple as
// SCRIPTC_TARGET (the compiler's own mobile spellings for iOS/Android), and
// (when the build graph supplied its own zig) that zig's directory at the
// front of PATH so the lane never depends on an ambient install. An Android
// build threads the NDK location the same way (--android-ndk becomes
// ANDROID_NDK_ROOT for the compiler's sysroot discovery). Native compiles
// keep the process environment untouched.
const compileEnv = cross
  ? {
      ...process.env,
      SCRIPTC_CC: "zigcc",
      SCRIPTC_TARGET: scriptcTarget,
      ...(args["zig-exe"]
        ? { PATH: `${path.dirname(args["zig-exe"])}${path.delimiter}${process.env.PATH ?? ""}` }
        : {}),
      ...(args["android-ndk"] && androidTarget ? { ANDROID_NDK_ROOT: args["android-ndk"] } : {}),
    }
  : process.env;

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
    ], { cwd: work, encoding: "utf8", env: compileEnv });
    const coverageOutput = `${coverage.stdout ?? ""}${coverage.stderr ?? ""}`;
    if (coverage.status !== 0 || isNpmStaticRefusal(coverageOutput)) {
      if (coverage.stdout) process.stdout.write(coverage.stdout);
      if (coverage.stderr) process.stderr.write(coverage.stderr);
      if (isNpmStaticRefusal(coverageOutput)) printNpmStaticTeaching();
      process.exit(coverage.status && coverage.status !== 0 ? coverage.status : 1);
    }
  }
  if (args["out-exe"]) {
    const built = path.join(work, targetOs === "windows" ? "service-host.exe" : "service-host");
    const compileArgs = [...argv0.slice(1), "build", "service_host_main.ts", "-o", built];
    if (staticPackages.length > 0) compileArgs.push("--npm-static", staticPackages.join(","));
    const result = spawnSync(argv0[0], compileArgs, {
      cwd: work,
      encoding: "utf8",
      env: compileEnv,
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
    ], { cwd: work, encoding: "utf8", env: compileEnv });
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
