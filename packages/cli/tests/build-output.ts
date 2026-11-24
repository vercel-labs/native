// What an app build prints and leaves behind: scriptc's warnings about the SDK's own code are left
// out, the app's own are kept, and no LLVM IR is left next to the executable.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { withoutSdkWarnings } from "../compiler/build-output.ts";
import { outputPaths, pageDataPath } from "../compiler/build.ts";

let failed = 0;
function ok(name: string, cond: boolean): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}`);
}

const sdk = "/sdk";
const sample = [
  "/sdk/runtime/style.ts:731:25 - warning SC6001: converting this value",
  "",
  "  730 | function f() {",
  "      |   ^",
  "",
  "/app/src/app.ts:4:2 - warning SC6014: objects of this type enumerate their keys",
  "",
  "  hint: create every property in one object literal",
  "",
  "2 warnings: the program compiled, but these sites can behave differently from Node.",
  "",
  "warning SC6101: 2 functions that likely run often use untyped values, which runs slower than typed code:",
  "  refreshSubtree (../../runtime/sheets.ts:140): `node` is `any`, in a loop",
  "  mk (src/app.ts:2): `o` is `any`, called in a loop",
  "  hint: add types to compile these statically; see scriptc coverage --explain-dynamic",
  "",
  "The program compiled. Adding types to these functions lets scriptc compile them to faster code.",
].join("\n");
const got = withoutSdkWarnings(sample, sdk, ["/", "/sdk/examples/x"], (abs) => abs.replace("/sdk/examples/x/src/", ""));
ok("the SDK's SC6001 is left out", !got.includes("style.ts"));
ok("the app's SC6014 is kept", got.includes("/app/src/app.ts:4:2 - warning SC6014"));
ok("the warning count is the app's", got.includes("1 warning: the program compiled"));
ok("the SDK's slow function is left out", !got.includes("refreshSubtree"));
ok("the app's slow function is kept, at its own path", got.includes("mk (app.ts:2)") && got.includes("1 function that likely runs often uses"));
const sdkOnly = withoutSdkWarnings(sample.split("\n").filter((l) => !l.includes("app.ts")).join("\n"), sdk, ["/", "/sdk/examples/x"]);
ok("nothing but SDK warnings prints nothing", !sdkOnly.includes("warning") && !sdkOnly.includes("The program compiled"));

// scriptc shows only so many warnings and counts the rest in a summary line. When every one of
// them was the SDK's, the summary is all that is left of them, and the build should print nothing.
const hidden = [
  "/sdk/runtime/style.ts:731:25 - warning SC6001: converting this value",
  "",
  "3 warnings: the program compiled, but these sites can behave differently from Node.",
  "",
  "2 more warnings not shown (SC6014 ×2); 'scriptc coverage --print=diagnostics' lists every site.",
].join("\n");
const hiddenOut = withoutSdkWarnings(hidden, sdk, ["/"]);
ok("a summary of the warnings it hid prints nothing either", hiddenOut.trim() === "");
const mixed = `${hidden}\n/app/src/app.ts:4:2 - warning SC6014: the app's own`;
ok("but it stays beside a warning of the app's", withoutSdkWarnings(mixed, sdk, ["/"]).includes("more warnings not shown"));

const dir = mkdtempSync(join(tmpdir(), "native-build-output-"));
writeFileSync(join(dir, "index.html"), '<html><body><p id="o">-</p><script type="module" src="app.ts"></script></body></html>');
writeFileSync(join(dir, "app.ts"), 'document.getElementById("o")!.textContent = "hi";\n');
const out = join(dir, "out");
const r = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", join(out, "app")], { encoding: "utf8" });
ok("the build succeeds", r.status === 0);
ok("no scriptc warnings about the SDK", !/runtime\/|shared\/|host\//.test(r.stderr.split("\n").filter((l) => /SC\d{4}/.test(l)).join("\n")));

// The page is data in the bundle, not part of the program: a markup edit rewrites the tables and
// keeps the executable, and the edited page is what the app runs.
const exe = join(out, "app");
const resources = outputPaths(exe, true).resources;
const exeBefore = readFileSync(exe);
writeFileSync(join(dir, "index.html"), '<html><body><p id="o">-</p><p id="e">edited</p><script type="module" src="app.ts"></script></body></html>');
const edit = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
ok("a markup edit skips scriptc", edit.stderr.includes("scriptc skipped"));
ok("a markup edit keeps the executable", readFileSync(exe).equals(exeBefore));
ok("a markup edit writes the new tables into the bundle", readFileSync(pageDataPath(resources), "utf8").includes("edited"));
const edited = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "print #e" } });
ok("the edited page is what runs", edited.stdout.trim() === "edited");
// macOS writes an app bundle beside the path that runs it; elsewhere the executable keeps a
// resources directory beside it, which holds the page's tables even when the app names no files.
const expected = process.platform === "darwin" ? "app,app.app" : "app,app.resources";
ok("only the executable and its app bundle are left in the output directory",
  existsSync(join(out, "app")) && readdirSync(out).sort().join(",") === expected);
writeFileSync(join(dir, "file"), "");
const bad = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", join(dir, "file", "app")], { encoding: "utf8" });
ok("an output under a file is a one-line error", bad.status !== 0 && bad.stderr.includes("is a file, not a directory") && !bad.stderr.includes("node:fs"));

// An app inside a CommonJS package (a package.json with no "type": "module") still builds: the
// build dir carries its own package.json, so its generated ES modules aren't read as CommonJS.
const pkgDir = mkdtempSync(join(tmpdir(), "native-build-output-cjs-"));
writeFileSync(join(pkgDir, "package.json"), '{ "name": "host-package" }');
const inner = join(pkgDir, "app");
spawnSync("mkdir", ["-p", inner]);
writeFileSync(join(inner, "index.html"), '<html><body><p id="o">-</p><script type="module" src="app.ts"></script></body></html>');
writeFileSync(join(inner, "app.ts"), 'document.getElementById("o")!.textContent = "ran";\n');
const cjs = spawnSync("node", ["compiler/cli.ts", "build", inner, "-o", join(pkgDir, "out")], { encoding: "utf8" });
ok("an app inside a CommonJS package builds", cjs.status === 0 && !cjs.stderr.includes("SC1013"));
const ran = spawnSync(join(pkgDir, "out"), [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "print #o" } });
ok("and runs", ran.stdout.trim() === "ran");

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
