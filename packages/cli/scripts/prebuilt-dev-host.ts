// Writes this machine's dev host into the optional package that ships it, with the manifest
// `native dev` matches on. The release workflow runs this once per platform runner, then packs
// the directory with pnpm; nothing here publishes.
//
//   node scripts/prebuilt-dev-host.ts packages/dev-host-linux-x64 [--force] [--sdk-root DIR]
//
// --sdk-root names the tree to record as the SDK the host was built for. The release workflow
// passes the CLI package after `pnpm pack` and extraction, so the recorded digest is the one an
// install of the published package computes. Without it, this checkout's own tree is recorded.

import { chmodSync, copyFileSync, existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { sdkDigest } from "../compiler/cache.ts";
import {
  DEV_HOST_VERSION,
  PREBUILT_SCHEMA,
  devHostLibc,
  devHostSourceDigest,
  ensureDevHost,
  hostExecutableName,
  libnodeAbiIdentity,
  prebuiltPackageName,
} from "../compiler/dev-host.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function fail(message: string): never {
  console.error(`native: ${message}`);
  process.exit(1);
}

const args = process.argv.slice(2);
const target = args.find((arg) => !arg.startsWith("--"));
if (target === undefined) fail("usage: node scripts/prebuilt-dev-host.ts <package-dir> [--force] [--sdk-root DIR]");
const force = args.includes("--force");
const sdkIndex = args.indexOf("--sdk-root");
const sdkRoot = sdkIndex >= 0 ? args[sdkIndex + 1] ?? fail("--sdk-root needs a directory") : ROOT;

const packageName = prebuiltPackageName();
if (packageName === null) fail(`no prebuilt dev host ships for ${process.platform}-${process.arch} (libc ${devHostLibc() ?? "none"})`);

const outDir = resolve(target);
const cli = JSON.parse(readFileSync(join(ROOT, "package.json"), "utf8")) as { name?: string; version?: string };
if (cli.version === undefined) fail("the CLI's package.json has no version");
const pkg = JSON.parse(readFileSync(join(outDir, "package.json"), "utf8")) as { name?: string; version?: string };
if (pkg.name !== packageName) fail(`${outDir}/package.json is ${pkg.name ?? "unnamed"}, expected ${packageName}`);
if (pkg.version !== cli.version) fail(`${packageName}@${pkg.version} does not match @native-sdk/cli@${cli.version}`);
// The host is built from this checkout, and the manifest names the tree npm ships. A release
// checkout carries the same sources; anything else would ship a host that does not match what
// it records, so it is refused rather than packed.
if (resolve(sdkRoot) !== ROOT && sdkDigest(sdkRoot) !== sdkDigest(ROOT)) {
  fail(`--sdk-root ${sdkRoot} carries other runtime/shared/host sources than this checkout`);
}

const host = await ensureDevHost((message) => console.error(`native: ${message}`), { force, prebuilt: false });
// A Windows build names its output host.exe itself; either name is the build's executable.
const built = existsSync(host.executable) ? host.executable : host.executable + ".exe";
if (!existsSync(built)) fail(`the host build wrote no executable at ${host.executable}`);

const executable = hostExecutableName();
const out = join(outDir, executable);
copyFileSync(built, out);
if (process.platform !== "win32") chmodSync(out, 0o755);
const bytes = statSync(out).size;

const manifest = {
  schema: PREBUILT_SCHEMA,
  version: cli.version,
  sdk: devHostSourceDigest(sdkRoot),
  libnodeAbi: libnodeAbiIdentity(),
  devHostVersion: DEV_HOST_VERSION,
  platform: process.platform,
  arch: process.arch,
  libc: devHostLibc(),
  executable,
  bytes,
};
writeFileSync(join(outDir, "host.json"), JSON.stringify(manifest, null, 2) + "\n");
if (existsSync(join(ROOT, "LICENSE"))) copyFileSync(join(ROOT, "LICENSE"), join(outDir, "LICENSE"));

const scale = (value: number): string => `${(value / (1024 * 1024)).toFixed(1)} MB`;
console.error(`native: wrote ${packageName}@${pkg.version} ${executable} (${scale(bytes)}) for SDK ${manifest.sdk.slice(0, 12)}…`);
