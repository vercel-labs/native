#!/usr/bin/env node
// Drive one external core compile — the lane every TypeScript core
// builds through: verify the toolchain release against the SDK's exact
// pin, run a library-mode build over the staged tree, and normalize
// the outputs to the paths the build graph declared. The compile itself co-emits the archive's
// OWN contract sidecar — the document the mirror module generates from,
// so the boot identity fence always pairs an archive with its own
// compile (the fixture driver, tests/compiled-core/build_core.sh, holds
// the same rule).
//
//   node run_external_core_compiler.mjs --stage <dir> --name <symbol name>
//     --manifest <packages/core/package.json> --frontend-sidecar <file>
//     --out-archive <file>
//     --out-sidecar <file>
//     [--host-platform <arch-os-abi> --target-platform <arch-os-abi>
//      --zig-exe <path>] [--android-ndk <dir>]
//     (--compiler <cmd> | --compiler-js <main.js>)

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith("--") || value === undefined) {
      console.error("usage: run_external_core_compiler.mjs --stage <dir> --name <n> --manifest <package.json> --frontend-sidecar <file> --out-archive <file> --out-sidecar <file> [--host-platform <arch-os-abi> --target-platform <arch-os-abi> --zig-exe <path>] (--compiler <cmd> | --compiler-js <main.js>)");
      process.exit(2);
    }
    args[key.slice(2)] = value;
  }
  for (const required of ["stage", "name", "manifest", "frontend-sidecar", "out-archive", "out-sidecar"]) {
    if (!(required in args)) {
      console.error(`run_external_core_compiler.mjs: missing --${required}`);
      process.exit(2);
    }
  }
  if (!args.compiler && !args["compiler-js"]) {
    console.error("run_external_core_compiler.mjs: supply --compiler <cmd> or --compiler-js <main.js>");
    process.exit(2);
  }
  if (Boolean(args["host-platform"]) !== Boolean(args["target-platform"])) {
    console.error("run_external_core_compiler.mjs: supply --host-platform and --target-platform together");
    process.exit(2);
  }
  return args;
}

const args = parseArgs(process.argv);
// Every path argument resolves against the INVOCATION's cwd up front:
// the compile itself runs from a scratch directory.
for (const key of ["stage", "manifest", "frontend-sidecar", "out-archive", "out-sidecar", "compiler-js", "zig-exe", "android-ndk"]) {
  if (key in args) args[key] = path.resolve(args[key]);
}
// --compiler is a COMMAND: a bare executable path (possibly containing
// spaces) or an interpreter plus script ("node .../main.js"). A path
// that exists is taken whole; anything else splits on whitespace.
const argv0 = args.compiler
  ? (fs.existsSync(args.compiler) ? [args.compiler] : args.compiler.split(/\s+/))
  : [process.execPath, args["compiler-js"]];

// App and fixture build graphs state the host and target explicitly. A
// differing target must compile the core archive through the same ScriptC
// zig-cc lane as the service archive that links beside it; otherwise a cross
// build mixes a host-format core archive with target-format Zig and service
// objects. Standalone host-only callers may omit both platform arguments.
// The pairing matrix is the pinned compiler's build matrix, shared with
// run_external_service_compiler.mjs: same-triple compiles run the native
// lane; Linux and Windows GNU targets cross-compile from any desktop host;
// macOS targets need a macOS build host.
const hostParts = args["host-platform"]?.split("-") ?? [];
const targetParts = args["target-platform"]?.split("-") ?? [];
const hostArch = hostParts[0] ?? "";
const hostOs = (hostParts[1] ?? "").split(".")[0];
const hostAbi = (hostParts[2] ?? "").split(".")[0];
const targetArch = targetParts[0] ?? "";
const targetOs = (targetParts[1] ?? "").split(".")[0];
const targetAbi = (targetParts[2] ?? "").split(".")[0];
// The two mobile families, from the build graph's Zig triple spelling:
// `aarch64-ios[-simulator]` and `aarch64-linux-android`. The pinned compiler
// admits exactly aarch64 for both — library archives, which is the only
// output this driver produces.
const iosTarget = targetOs === "ios";
const androidTarget = targetOs === "linux" && targetAbi === "android";
const mobileTarget = iosTarget || androidTarget;
// The canonical SCRIPTC_TARGET spelling for a mobile compile: the compiler
// names iOS targets with the vendor (`aarch64-apple-ios[-simulator]`) and
// Android with the Zig triple itself.
const scriptcTarget = iosTarget
  ? `aarch64-apple-ios${targetAbi === "simulator" ? "-simulator" : ""}`
  : args["target-platform"];
// A Windows host's Zig triple defaults to GNU, but an explicit same-arch MSVC
// target still compiles through native clang and the installed Windows SDK.
const nativeWindows = hostOs === "windows" && targetOs === "windows" && hostArch === targetArch &&
  (targetAbi === hostAbi || targetAbi === "msvc");
const cross = args["host-platform"] !== undefined &&
  args["target-platform"] !== args["host-platform"] && !nativeWindows;
if (mobileTarget) {
  const desktopHost = ["macos", "linux", "windows"].includes(hostOs);
  const admitted = desktopHost && targetArch === "aarch64" && (!iosTarget || hostOs === "macos");
  if (!admitted) {
    console.error(
      iosTarget && hostOs !== "macos"
        ? `TypeScript cores for an iOS target (${args["target-platform"]}) compile on a macOS build host only — the Apple SDK sysroot and Mach-O localization live there — but this build host is ${args["host-platform"]}. Build iOS apps on a Mac.`
        : `TypeScript cores compile for the mobile targets the pinned compiler covers — aarch64 iOS/iOS-simulator (macOS host) and aarch64 Android — but this build pairs host ${args["host-platform"]} with target ${args["target-platform"]}.`,
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
        ? `TypeScript cores for a cross-target Windows build (${args["target-platform"]}) require the GNU ABI: Zig supplies that target's CRT and system libraries, while an MSVC target needs a native Windows toolchain. Build ${targetArch}-windows-msvc on a matching Windows host, or cross-compile as "${targetArch}-windows-gnu".`
        : targetOs === "macos"
        ? `TypeScript cores for a macOS target (${args["target-platform"]}) compile on a macOS build host only — Apple linking needs the host toolchain's SDK — but this build host is ${args["host-platform"]}. Build macOS apps on a Mac.`
        : `TypeScript cores compile for desktop targets the pinned compiler covers — Linux and Windows GNU from a macOS/Linux/Windows build host, macOS from a macOS host — but this build pairs host ${args["host-platform"]} with target ${args["target-platform"]}.`,
    );
    process.exit(2);
  }
}
// Cross compiles ride the compiler's zig-cc lane: SCRIPTC_TARGET carries the
// compiler's own mobile spellings for iOS/Android, --zig-exe's directory
// fronts PATH, and an Android build threads the NDK location the same way
// (--android-ndk becomes ANDROID_NDK_ROOT for the sysroot discovery).
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

// The profile's determinism-fence table is RELEASE-PINNED DATA (see
// tools/corewire/emit_profile.zig): its ids resolve against one
// toolchain release's surface manifest, so the supplied command must BE
// the release the SDK pins — the exact-pinned dependency of
// packages/core (the ONE place the pin lives).
const manifest = JSON.parse(fs.readFileSync(args.manifest, "utf8"));
const pin = manifest.dependencies?.scriptc;
if (typeof pin !== "string" || !/^\d+\.\d+\.\d+$/.test(pin)) {
  console.error("the SDK's packages/core/package.json carries no exact external core compiler pin — the SDK tree is broken; reinstall or re-clone it");
  process.exit(2);
}
const versionProbe = spawnSync(argv0[0], [...argv0.slice(1), "-v"], { encoding: "utf8" });
const reported = (versionProbe.stdout ?? "").trim();
if (versionProbe.status !== 0 || reported.length === 0) {
  console.error(`the external core compiler did not report a version (${argv0.join(" ")} -v failed) — run \`npm ci --prefix <sdk>/packages/core\` to install the pinned release, or point NATIVE_SDK_CORE_COMPILER at a working command`);
  process.exit(2);
}
if (reported !== pin) {
  console.error(`external core toolchain reports version ${reported}, but the profile's fence table is pinned to ${pin} — supply that release (npm ci --prefix <sdk>/packages/core installs it), or bump the pin when the fence table has been re-verified against the new release's surface manifest`);
  process.exit(2);
}

// The compile runs in its own scratch copy: the staged tree is a build
// output another step owns, and the toolchain writes beside its entry.
const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-external-core-"));
try {
  fs.cpSync(args.stage, work, { recursive: true });
  const build = spawnSync(argv0[0], [...argv0.slice(1), "build", "--lib", "--profile", "profile.json", "-o", args.name], {
    cwd: work,
    stdio: "inherit",
    env: compileEnv,
  });
  if (build.status !== 0) process.exit(build.status ?? 1);

  // The toolchain writes the ar archive at the bare -o name (some
  // releases add .lib.a); the link input needs a recognized extension.
  const produced = [`${args.name}.lib.a`, args.name].find((name) => fs.existsSync(path.join(work, name)));
  if (!produced) {
    console.error(`the external core compile produced no archive (expected ${args.name}.lib.a or ${args.name})`);
    process.exit(1);
  }
  const sidecar = path.join(work, "core.contract.json");
  if (!fs.existsSync(sidecar)) {
    console.error("the external core compile emitted no core.contract.json beside the archive — the co-emitted sidecar is the mirror's contract; the compile is incomplete");
    process.exit(1);
  }
  fs.mkdirSync(path.dirname(args["out-archive"]), { recursive: true });
  fs.mkdirSync(path.dirname(args["out-sidecar"]), { recursive: true });
  fs.copyFileSync(path.join(work, produced), args["out-archive"]);

  // The pinned compiler owns the archive contract (including its build id),
  // while the SDK frontend owns facts the compiler release predates. Carry
  // exactly those checked persistence facts across the compile boundary.
  const compiledContract = JSON.parse(fs.readFileSync(sidecar, "utf8"));
  const frontendContract = JSON.parse(fs.readFileSync(args["frontend-sidecar"], "utf8"));
  if (!/^[0-9a-f]{16}$/.test(frontendContract.model_fingerprint ?? "") || typeof frontendContract.has_migrate !== "boolean") {
    console.error("the frontend contract is missing its checked persistence metadata — the SDK frontend and build driver are out of sync");
    process.exit(1);
  }
  compiledContract.model_fingerprint = frontendContract.model_fingerprint;
  compiledContract.has_migrate = frontendContract.has_migrate;
  fs.writeFileSync(args["out-sidecar"], `${JSON.stringify(compiledContract, null, 2)}\n`);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
