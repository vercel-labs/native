// Compiles the CLI (compiler/ and shared/) with scriptc into the native executable the npm
// package ships: dist/native, or dist/native.exe on Windows.
//
//   node scripts/build-native.ts [--dev] [--output <path>] [scriptc build options…]
//
// Contributors run the CLI from source with Node; this is the release build of the same code. The
// executable is marked with NATIVE_SDK_BINARY (compiler/root.ts), which is how it knows to look
// for runtime/, shared/ and host/ beside itself (or where NATIVE_SDK_ROOT says) instead of beside
// the file it was compiled from. `--dev` compiles at scriptc's dev optimization, which builds
// faster. Other options go to `scriptc build`. SCRIPTC names another scriptc executable than the
// installed one. On Windows scriptc links with zig, which has to be on the PATH.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const windows = process.platform === "win32";

const args = process.argv.slice(2);
let output = join(root, "dist", windows ? "native.exe" : "native");
let dev = false;
const passed: string[] = [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--dev") dev = true;
  else if (arg === "--output" || arg === "-o") output = resolve(args[++i] ?? fail(`${arg} needs a path`));
  else if (arg.startsWith("--output=")) output = resolve(arg.slice("--output=".length));
  else passed.push(arg);
}

const scriptc = process.env.SCRIPTC ?? installedScriptc();
mkdirSync(dirname(output), { recursive: true });
// The compiler's islands (esbuild runs the app's bundle in the dev host) come from a Node pack
// installed beside the CLI; scriptc does not search pnpm's layout for it, so name it here. A pack
// the caller names wins.
const libnode = process.env.SCRIPTC_LIBNODE ?? installedLibnode();
const build = [
  "build",
  join(root, "compiler", "cli.ts"),
  ...(libnode === null ? [] : ["--libnode", libnode]),
  `--define=process.env.NATIVE_SDK_BINARY="1"`,
  `--optimization=${dev ? "dev" : "speed"}`,
  "--no-keep-llvm",
  ...passed,
  "-o",
  output,
];
console.error(`$ ${scriptc} ${build.join(" ")}`);
const r = spawnSync(scriptc, build, { cwd: root, stdio: "inherit" });
if (r.error) fail(`could not run ${scriptc}: ${r.error.message}`);
if (r.status !== 0) process.exit(r.status ?? 1);
const built = windows && !output.toLowerCase().endsWith(".exe") && existsSync(output + ".exe") ? output + ".exe" : output;
if (!existsSync(built)) fail(`scriptc did not write ${built}`);
// The IR scriptc keeps beside an executable, when an older scriptc ignored --no-keep-llvm.
rmSync(join(dirname(output), "cli.ll"), { force: true });

// The executable answers --version with the version it was built from.
const version = spawnSync(built, ["--version"], { encoding: "utf8", env: { ...process.env, NATIVE_SDK_ROOT: root } });
const want = (JSON.parse(readFileSync(join(root, "package.json"), "utf8")) as { version: string }).version;
if (version.status !== 0 || version.stdout.trim() !== want) {
  fail(`${built} --version printed ${JSON.stringify(version.stdout.trim())} (status ${version.status}), not ${want}:\n${version.stderr}`);
}
console.error(`built ${built} (${want})`);

/** The Node-island pack installed for this platform, if any: `@scriptc/libnode-<platform>-<arch>`,
 *  with a libc suffix on Linux (libnode-linux-x64-gnu) as pnpm names it. */
function installedLibnode(): string | null {
  const scoped = join(root, "node_modules", "@scriptc");
  const wanted = `libnode-${process.platform}-${process.arch}`;
  for (const name of existsSync(scoped) ? readdirSync(scoped) : []) {
    if (name === wanted || name.startsWith(wanted + "-")) return join(scoped, name);
  }
  return null;
}

/** The compiler the install placed: scriptc's own executable, as compiler/build.ts finds it. */
function installedScriptc(): string {
  // pnpm links the CLI's own dependencies into packages/cli/node_modules.
  const pkg = join(root, "node_modules", "scriptc");
  const exe = join(pkg, "bin", "scriptc.exe");
  if (existsSync(exe)) return exe;
  const scoped = join(root, "node_modules", "@scriptc");
  for (const name of existsSync(scoped) ? readdirSync(scoped) : []) {
    if (!name.startsWith("cli-")) continue;
    for (const candidate of [join(scoped, name, "bin", "scriptc.exe"), join(scoped, name, "bin", "scriptc")]) {
      if (existsSync(candidate)) return candidate;
    }
  }
  return "scriptc";
}

function fail(message: string): never {
  console.error(`build-native: ${message}`);
  process.exit(1);
}
