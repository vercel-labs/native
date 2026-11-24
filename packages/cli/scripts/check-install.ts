// Installs the CLI's npm packages from a directory of tarballs (scripts/pack.ts writes them to
// dist/npm) into a new project, as a user installs them, and builds an example there:
//
//   node scripts/check-install.ts <tarball-dir>
//
// It takes the main package and this host's platform package, and runs the CLI the ways its docs
// say to: `npx @native-sdk/cli --version` and `npx @native-sdk/cli check` for one-off commands,
// and `npm run build` for the project's "build": "native build" script, on a copy of the
// repository's examples/counter. That covers the installed executable, the sources the main
// package carries, and the scriptc npm installed with them.

import { spawnSync } from "node:child_process";
import type { SpawnSyncOptions, SpawnSyncReturns } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const windows = process.platform === "win32";
const host = `${process.platform}-${process.arch}`;

const from = resolve(process.argv[2] ?? join(root, "dist", "npm"));
const tarballs = readdirSync(from).filter((name) => name.endsWith(".tgz"));
const main = tarballs.find((name) => /^native-sdk-cli-\d/.test(name));
const platform = tarballs.find((name) => name.startsWith(`native-sdk-cli-${host}-`));
if (main === undefined) fail(`no @native-sdk/cli tarball in ${from}`);
if (platform === undefined) fail(`no @native-sdk/cli-${host} tarball in ${from}`);
const version = /^native-sdk-cli-(.+)\.tgz$/.exec(main)![1];

const dir = join(tmpdir(), `native-cli-install-${process.pid}`);
rmSync(dir, { recursive: true, force: true });
mkdirSync(dir, { recursive: true });
try {
  // The app is the project directory, as in Getting started, with the scripts the docs describe.
  cpSync(join(root, "..", "..", "examples", "counter"), dir, {
    recursive: true,
    filter: (src) => !/[\\/](\.native|node_modules|build|package\.json)$/.test(src),
  });
  const project = { name: "counter", private: true, type: "module", scripts: { dev: "native dev", build: "native build -o out/counter" } };
  writeFileSync(join(dir, "package.json"), JSON.stringify(project, null, 2) + "\n");
  run("npm", ["install", "--no-audit", "--no-fund", "-D", join(from, main), join(from, platform)], { cwd: dir });

  const printed = run("npx", ["@native-sdk/cli", "--version"], { cwd: dir, stdio: "pipe" }).stdout.trim();
  if (printed !== version) fail(`npx @native-sdk/cli --version printed ${printed}, not ${version}`);
  console.log(`npx @native-sdk/cli --version: ${printed}`);

  const checked = run("npx", ["@native-sdk/cli", "check"], { cwd: dir, stdio: "pipe" });
  console.log(`npx @native-sdk/cli check: ${checked.stderr.trim().split("\n").pop()}`);

  const exe = join(dir, "out", windows ? "counter.exe" : "counter");
  run("npm", ["run", "build"], { cwd: dir });
  if (!existsSync(exe) || statSync(exe).size === 0) fail(`npm run build wrote no ${exe}`);
  console.log(`npm run build: ok (${(statSync(exe).size / 1e6).toFixed(1)} MB)`);
} finally {
  rmSync(dir, { recursive: true, force: true });
}

function run(command: string, args: string[], options: SpawnSyncOptions & { stdio?: "inherit" | "pipe" } = {}): SpawnSyncReturns<string> {
  // npm and npx are batch files on Windows, which only a shell starts.
  const result = spawnSync(command, args, { stdio: "inherit", ...options, encoding: "utf8", shell: windows });
  if (result.status !== 0) {
    fail(`${command} ${args.join(" ")} exited with ${result.status}\n${result.stdout ?? ""}${result.stderr ?? ""}`);
  }
  return result;
}

function fail(message: string): never {
  console.error(`check-install: ${message}`);
  process.exit(1);
}
