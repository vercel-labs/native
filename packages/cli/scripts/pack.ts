// Lays out the npm packages of the CLI and packs them into dist/npm:
//
//   @native-sdk/cli             the launcher (bin/native.js) and the sources every app build
//                               compiles (runtime/, shared/, host/), with scriptc and
//                               the CLI's other dependencies, and an optional dependency on each
//                               platform package
//   @native-sdk/cli-<platform>  the native executable for this host, in bin/
//
//   node scripts/pack.ts [main] [platform] [--binary <path>] [--check]
//
// With neither main nor platform, packs both. The platform package takes the executable
// scripts/build-native.ts wrote (dist/native), or the one --binary names; a Linux one must not need
// a glibc newer than 2.34. --check then runs scripts/check-install.ts on the tarballs: it installs
// them into a new project and builds an example there through a package.json script and `npx @native-sdk/cli`.
//
// The optional dependencies are added here rather than in package.json, so the workspace installs
// without the platform packages.

import { spawnSync } from "node:child_process";
import type { SpawnSyncOptions, SpawnSyncReturns } from "node:child_process";
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
// @ts-expect-error: the launcher's platform table is plain JavaScript, shared with bin/native.js.
import { executableName, hostDescription, hostPlatform, packageName, platforms } from "../bin/platforms.js";

interface Platform {
  name: string;
  os: string;
  cpu: string;
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "dist", "npm");
const windows = process.platform === "win32";
/** The oldest glibc the Linux packages support. CI links them against its sysroot
 *  (SCRIPTC_TARGET=<arch>-linux-gnu.2.34). */
const GLIBC_MINIMUM: [number, number] = [2, 34];

const args = process.argv.slice(2);
let binary: string | undefined;
let check = false;
const kinds: string[] = [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--binary") binary = resolve(args[++i] ?? fail("--binary needs a path"));
  else if (arg === "--check") check = true;
  else if (arg === "main" || arg === "platform") kinds.push(arg);
  else fail(`unknown argument ${arg}`);
}
if (kinds.length === 0) kinds.push("main", "platform");

const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as {
  name: string;
  description: string;
  homepage: string;
  engines: unknown;
  version: string;
  license: string;
  repository: unknown;
  dependencies?: { [name: string]: string };
  optionalDependencies?: { [name: string]: string };
};
// The CLI's own dependencies (scriptc, its types, the dev island's scriptc packages and esbuild),
// each pinned to the version the workspace installed and built the executable with.
const dependencies = Object.fromEntries(Object.keys(manifest.dependencies ?? {}).map((name) => [name, installedVersion(name)]));
// npm provenance requires repository.url to name the repository a package is published from, which
// is vercel-labs/native: in GitHub Actions the
// packages name the repository that builds them, elsewhere the one package.json names.
const repository = repositoryOf(manifest.repository, process.env.GITHUB_REPOSITORY);
const common = { version: manifest.version, license: manifest.license, repository };

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const tarballs: { main?: string; platform?: string } = {};
if (kinds.includes("main")) tarballs.main = packMain();
if (kinds.includes("platform")) tarballs.platform = packPlatform();
for (const tarball of Object.values(tarballs)) console.log(tarball);
if (check) {
  const r = spawnSync(process.execPath, [join(root, "scripts", "check-install.ts"), out], { stdio: "inherit" });
  if (r.status !== 0) process.exit(r.status ?? 1);
}

function packMain(): string {
  const dir = join(out, "cli");
  // The sources ship as they are: scriptc compiles runtime/ (and the shared/ modules it imports)
  // into each app, and the build compiles host/ with the platform's C compiler.
  const files = ["bin/native.js", "bin/platforms.js", "runtime", "shared", "host", "README.md", "LICENSE"];
  for (const file of files) cpSync(join(root, file), join(dir, file), { recursive: true });
  // The workspace's own manifest runs the CLI on Node from dist/native.js; the published one runs
  // the executable through the launcher.
  writeJson(join(dir, "package.json"), {
    name: manifest.name,
    ...common,
    description: manifest.description,
    homepage: manifest.homepage,
    engines: manifest.engines,
    type: "module",
    bin: { native: "bin/native.js" },
    files: ["bin", "runtime", "shared", "host", "README.md", "LICENSE"],
    // runtime/ is TypeScript source that scriptc compiles into every app, not a prebuilt package.
    scriptc: { source: true },
    dependencies,
    // The workspace's own optional packages (the dev island's per-platform libnode packs) keep
    // their ranges, since only this host's is installed; each CLI platform package is this version.
    optionalDependencies: {
      ...manifest.optionalDependencies,
      ...Object.fromEntries((platforms as Platform[]).map((p) => [packageName(p), manifest.version])),
    },
  });
  return pack(dir);
}

function packPlatform(): string {
  const platform = hostPlatform() as Platform | undefined;
  if (platform === undefined) fail(`the CLI has no platform package for ${hostDescription()}`);
  const dir = join(out, `cli-${platform.name}`);
  mkdirSync(join(dir, "bin"), { recursive: true });
  const source = binary ?? join(root, "dist", executableName());
  if (!existsSync(source)) fail(`no executable at ${source}: run node scripts/build-native.ts first`);
  const executable = join(dir, "bin", executableName());
  copyFileSync(source, executable);
  chmodSync(executable, 0o755);
  if (platform.os === "linux") checkGlibcVersions(executable);
  copyFileSync(join(root, "LICENSE"), join(dir, "LICENSE"));
  writeJson(join(dir, "package.json"), {
    name: packageName(platform),
    ...common,
    description: `The native CLI executable for ${platform.name}.`,
    os: [platform.os],
    cpu: [platform.cpu],
    files: ["bin"],
  });
  return pack(dir);
}

/** Fails if the executable needs a glibc symbol version newer than GLIBC_MINIMUM, which a build
 *  linked with the host's toolchain takes from the build machine's glibc. */
function checkGlibcVersions(executable: string): void {
  const symbols = run("objdump", ["-T", executable], { stdio: "pipe" }).stdout;
  const versionOf = (text: string): [number, number] | undefined => {
    const m = /\bGLIBC_(\d+)\.(\d+)/.exec(text);
    return m === null ? undefined : [Number(m[1]), Number(m[2])];
  };
  const newer = (a: [number, number], b: [number, number]) => a[0] > b[0] || (a[0] === b[0] && a[1] > b[1]);
  const lines = symbols.split("\n").filter((line) => versionOf(line) !== undefined);
  const tooNew = lines.filter((line) => newer(versionOf(line)!, GLIBC_MINIMUM));
  if (tooNew.length > 0) {
    const message = `${executable} needs glibc newer than ${GLIBC_MINIMUM.join(".")}:\n${tooNew.join("\n")}`;
    // A local build links with the host's glibc; only a release build has to meet the minimum.
    if (process.env.CI) fail(message);
    console.warn(`pack: warning: ${executable} needs glibc newer than ${GLIBC_MINIMUM.join(".")} (set SCRIPTC_TARGET=<arch>-linux-gnu.2.34 to link against glibc 2.34)`);
    return;
  }
  const highest = lines.map((line) => versionOf(line)!).reduce((a, b) => (newer(b, a) ? b : a), [0, 0] as [number, number]);
  console.log(`highest glibc symbol version: ${highest.join(".")}`);
}

/** The manifest's repository field, pointed at `github` (owner/name) when that is set. */
function repositoryOf(field: unknown, github: string | undefined): unknown {
  if (github === undefined || !/^[\w.-]+\/[\w.-]+$/.test(github)) return field;
  const url = `git+https://github.com/${github}.git`;
  return field !== null && typeof field === "object" ? { ...(field as object), url } : { type: "git", url, directory: "packages/cli" };
}

/** The exact version of a dependency the workspace installed, which the package pins. */
function installedVersion(name: string): string {
  return (JSON.parse(readFileSync(join(root, "node_modules", name, "package.json"), "utf8")) as { version: string }).version;
}

function pack(dir: string): string {
  const result = run("npm", ["pack", "--json", "--pack-destination", out], { cwd: dir, stdio: "pipe" });
  return join(out, (JSON.parse(result.stdout) as { filename: string }[])[0].filename);
}

function run(command: string, commandArgs: string[], options: SpawnSyncOptions & { stdio?: "inherit" | "pipe" } = {}): SpawnSyncReturns<string> {
  // npm and npx are batch files on Windows, which only a shell starts.
  const result = spawnSync(command, commandArgs, { stdio: "inherit", ...options, encoding: "utf8", shell: windows });
  if (result.status !== 0) {
    fail(`${command} ${commandArgs.join(" ")} exited with ${result.status}\n${result.stdout ?? ""}${result.stderr ?? ""}`);
  }
  return result;
}

function writeJson(path: string, value: unknown): void {
  writeFileSync(path, JSON.stringify(value, null, 2) + "\n");
}

function fail(message: string): never {
  console.error(`pack: ${message}`);
  process.exit(1);
}
