// Compile the profile generator for the build host with the SDK's exact pin.
// This library has no contract sidecar, so scriptc's native library command
// can build it directly, without the app-core sidecar compatibility path.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { compilerArgv, publishedScriptcArgv } from "../../packages/core/scripts/compiler_command.mjs";

const args = {};
for (let i = 2; i < process.argv.length; i += 2) {
  const key = process.argv[i];
  const value = process.argv[i + 1];
  if (!key?.startsWith("--") || value === undefined) throw new Error("expected --option value pairs");
  args[key.slice(2)] = value;
}
for (const key of ["stage", "manifest", "out", "host-platform", "zig-exe"]) {
  if (!args[key]) throw new Error(`missing --${key}`);
}
const manifest = path.resolve(args.manifest);
const pin = JSON.parse(fs.readFileSync(manifest, "utf8")).dependencies?.scriptc;
if (typeof pin !== "string" || !/^\d+\.\d+\.\d+$/.test(pin)) throw new Error("the SDK must pin an exact scriptc release");
const command = args.compiler ? compilerArgv(args.compiler) : publishedScriptcArgv(manifest);
const version = spawnSync(command[0], [...command.slice(1), "-v"], { encoding: "utf8" });
if (version.status !== 0 || version.stdout.trim() !== pin) {
  throw new Error(`the corewire profile generator requires scriptc ${pin}; reinstall the SDK dependencies or fix NATIVE_SDK_CORE_COMPILER`);
}

const work = fs.mkdtempSync(path.join(os.tmpdir(), "native-profile-"));
try {
  fs.cpSync(path.resolve(args.stage), work, { recursive: true });
  // This tool always executes on the host, even for an iOS/Android/Windows
  // app target. Do not inherit a caller's cross-compilation environment.
  const env = { ...process.env };
  delete env.SCRIPTC_TARGET;
  delete env.SCRIPTC_CC;
  if (args["host-platform"].includes("-windows-gnu")) {
    env.SCRIPTC_TARGET = args["host-platform"];
    env.SCRIPTC_CC = "zigcc";
    env.PATH = `${path.dirname(args["zig-exe"])}${path.delimiter}${env.PATH ?? ""}`;
  }
  const build = spawnSync(command[0], [...command.slice(1), "build", "--lib", "--profile", "profile_library.json", "-o", "profile"], {
    cwd: work, env, stdio: "inherit",
  });
  if (build.status !== 0) process.exitCode = build.status ?? 1;
  else {
    const artifact = ["profile.lib.a", "profile"].find(file => fs.existsSync(path.join(work, file)));
    if (!artifact) throw new Error("scriptc produced no profile-generator archive");
    fs.copyFileSync(path.join(work, artifact), path.resolve(args.out));
  }
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
