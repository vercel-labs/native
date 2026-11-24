// The build cache: a build whose inputs all match one an earlier build stored reuses that
// build's executable, an edit changes the key, and a stored entry restores the executable,
// the dev tables and the manifest of every module.
//   npm test

import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { BuildCache, changedModules, fastKey, moduleName, programIdentity, programKey, programManifest, readBuildRecord, sdkDigest, summarizeModules } from "../compiler/cache.ts";
import { build, pageDataPath } from "../compiler/build.ts";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

let failed = 0;
function ok(name: string, cond: boolean): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}`);
}

const work = mkdtempSync(join(tmpdir(), "native-cache-"));
process.env["NATIVE_CACHE_DIR"] = join(work, "cache");
delete process.env["NATIVE_NO_CACHE"];

const appDir = join(work, "app");
mkdirSync(appDir, { recursive: true });
const markup = `<!doctype html>
<html><head><meta name="native-window" content="width=120, height=80"></head>
<body><p id="p">text</p><script type="module" src="app.ts"></script></body></html>
`;
writeFileSync(join(appDir, "index.html"), markup);
writeFileSync(join(appDir, "app.ts"), `document.getElementById("p")!.textContent = "one";\n`);
const output = join(work, "out", "app");
// A bundled build carries the app metadata, so its key is the packaged one.
const options = { appDir, out: output, dev: false, packaged: true, root: ROOT, input: join(appDir, "index.html") };

// The same inputs name the same build, and any input the build reads names another one.
const first = fastKey(options);
ok("the same inputs share a key", first === fastKey(options));
writeFileSync(join(appDir, "app.ts"), `document.getElementById("p")!.textContent = "two";\n`);
const edited = fastKey(options);
ok("an edited module changes the key", edited !== first);

mkdirSync(join(appDir, "node_modules", "tiny"), { recursive: true });
writeFileSync(join(appDir, "node_modules", "tiny", "index.js"), "export const n = 1;\n");
const withDep = fastKey(options);
writeFileSync(join(appDir, "node_modules", "tiny", "index.js"), "export const n = 22;\n");
ok("a changed installed dependency changes the key", fastKey(options) !== withDep);

ok("dev and release builds don't share a key", fastKey({ ...options, dev: true }) !== fastKey(options));

// The SDK's own sources are part of the key: editing the runtime or the host invalidates it.
const sdkCopy = join(work, "sdk");
for (const dir of ["runtime", "shared", "host"]) mkdirSync(join(sdkCopy, dir), { recursive: true });
writeFileSync(join(sdkCopy, "runtime", "dom.ts"), "export const n = 1;\n");
writeFileSync(join(sdkCopy, "shared", "props.ts"), "export const p = 1;\n");
writeFileSync(join(sdkCopy, "host", "linux.c"), "int main(void) { return 0; }\n");
const sdkBefore = sdkDigest(sdkCopy);
writeFileSync(join(sdkCopy, "runtime", "dom.ts"), "export const n = 2;\n");
ok("editing the runtime changes the SDK digest", sdkDigest(sdkCopy) !== sdkBefore);

// A build's own output, inside the app directory, is not one of its inputs.
const defaultOut = join(appDir, "app");
const beforeOutput = fastKey({ ...options, out: defaultOut });
writeFileSync(defaultOut, "a previous build");
ok("a build's own output is not an input", fastKey({ ...options, out: defaultOut }) === beforeOutput);

// A stored entry restores its executable, and the dev tables beside it.
const cache = BuildCache.open();
ok("the cache opens where NATIVE_CACHE_DIR points", cache !== null && cache.root === join(work, "cache"));
const fakeBin = join(work, "fake-bin");
writeFileSync(fakeBin, "#!/bin/sh\necho restored\n");
chmodSync(fakeBin, 0o755);
const devData = join(work, "dev.json");
writeFileSync(devData, '{"page":1}');
const current = fastKey(options);
const key = programKey(current, new Map([["src/app.ts", "a"]]));
cache!.save({
  key,
  fast: current,
  out: output,
  dev: true,
  bin: fakeBin,
  devData,
  summary: "1 node, 0 rules (0 conditional, 0 dead removed)",
  stderr: "",
  diagnostics: "",
  files: new Map([["src/app.ts", "a"], ["gen.ts", "b"]]),
});
const hit = cache!.lookupFast(current);
ok("a fast key finds the stored build", hit !== null && hit.key === key);
ok("the entry remembers its module manifest", hit !== null && hit.files.get("gen.ts") === "b");

const restored = join(work, "out", "restored");
cache!.restore(hit!, restored, join(appDir, ".native", "dev.json"));
ok("the executable is restored", existsSync(restored));
ok("the dev tables are restored beside the app", readFileSync(join(appDir, ".native", "dev.json"), "utf8") === '{"page":1}');
ok("the restored executable runs", readFileSync(restored, "utf8").includes("restored"));

// Restoring lands a new executable while a dev session still runs the old one: the write
// goes to a temporary name and is renamed, so a running executable is never written into.
const running = join(work, "running");
writeFileSync(running, "#!/bin/sh\nsleep 5\n");
chmodSync(running, 0o755);
const child = spawn(running, [], { stdio: "ignore" });
let replaced = true;
try {
  cache!.restore(hit!, running, null);
} catch {
  replaced = false;
}
child.kill();
ok("a running executable is replaced, not written into", replaced && readFileSync(running, "utf8").includes("restored"));

// A release entry carries the page tables its bundle needs, and the identity of the program its
// executable compiles. An edit to the page alone leaves that identity as it is; the app's scripts
// are part of it.
const releaseFiles = new Map([["src/app.ts", "a"]]);
const program = programIdentity(options, releaseFiles);
writeFileSync(join(appDir, "index.html"), markup.replace(">text<", ">text and more text<"));
ok("a markup edit leaves the program's identity alone", programIdentity(options, releaseFiles) === program);
ok("a script edit changes it", programIdentity(options, new Map([["src/app.ts", "b"]])) !== program);
// The edit restored, so the build below is the one the entries above describe.
writeFileSync(join(appDir, "index.html"), markup);

const releasePage = join(work, "release-page.json");
writeFileSync(releasePage, '{"title":"tables"}');
cache!.save({
  key: programKey(current, releaseFiles),
  fast: current,
  out: output,
  dev: false,
  bin: fakeBin,
  pageData: releasePage,
  program,
  summary: "1 node, 0 rules (0 conditional, 0 dead removed)",
  stderr: "",
  diagnostics: "",
  files: releaseFiles,
});

// A build answered from the cache doesn't run the compiler: the entry's executable is the
// build's output, the bundle gets the entry's page tables, and the build reports itself cached.
process.env["NATIVE_CACHE_DIR"] = join(work, "cache");
const result = await build(appDir, output);
ok("build() answers from the cache", result.cached);
ok("build() writes the stored executable", readFileSync(output, "utf8").includes("restored"));
ok("build() writes the entry's page tables into the bundle", readFileSync(pageDataPath(output + ".resources"), "utf8") === '{"title":"tables"}');
ok("build() returns the requested output", result.output === output);
ok("build() records the program its executable compiles", readBuildRecord(appDir, output)?.program === program);
ok("a build record is kept per output", readBuildRecord(appDir, join(work, "elsewhere")) === null);

// The manifest tells a dev session which modules an edit changed.
const before = new Map([["src/app.ts", "a"], ["src/gen.ts", "b"], ["src/gone.ts", "c"]]);
const after = new Map([["src/app.ts", "A"], ["src/gen.ts", "b"], ["src/added.ts", "d"]]);
const changed = changedModules(before, after);
ok("the change report names edited, removed and added modules", JSON.stringify(changed) === JSON.stringify(["src/added.ts", "src/app.ts", "src/gone.ts"]));
ok("vendored copies keep their package path", moduleName("src/deps/preact/dist/preact.cjs") === "preact/dist/preact.cjs" && moduleName("src/app.ts") === "app.ts");
ok("a long change list is shortened", summarizeModules(["a", "b", "c", "d", "e"], 3) === "a, b, c and 2 more");

// The cache stays inside its cap.
process.env["NATIVE_CACHE_MAX_MB"] = "0.001";
cache!.save({
  key: programKey(edited, new Map([["src/app.ts", "x"]])),
  fast: edited,
  out: output,
  dev: false,
  bin: fakeBin,
  summary: "",
  stderr: "",
  diagnostics: "",
  files: new Map(),
});
ok("an over-cap save evicts the oldest entry", cache!.lookupFast(current) === null);
delete process.env["NATIVE_CACHE_MAX_MB"];

// The dev command's state, control and ready files are runtime data, not inputs of the program:
// a state file that changes when the app exits must not make the next build a new program.
const buildDir = join(work, "build");
mkdirSync(join(buildDir, "src"), { recursive: true });
for (const name of ["entry.ts", "boot.ts", "gen.ts", "dev.json", "dev-state.json", "dev.ctl", "dev-ready"]) {
  writeFileSync(join(buildDir, name), name);
}
const manifest = programManifest(buildDir);
ok("the program manifest holds its modules", manifest.has("entry.ts") && manifest.has("boot.ts") && manifest.has("gen.ts"));
ok("the dev command's files are not program inputs",
  !manifest.has("dev.json") && !manifest.has("dev-state.json") && !manifest.has("dev.ctl") && !manifest.has("dev-ready"));

process.env["NATIVE_NO_CACHE"] = "1";
ok("NATIVE_NO_CACHE turns the cache off", BuildCache.open() === null);
delete process.env["NATIVE_NO_CACHE"];

process.exitCode = failed > 0 ? 1 : 0;
if (failed > 0) console.error(`${failed} check(s) failed`);
