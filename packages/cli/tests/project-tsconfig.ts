// An app without a tsconfig of its own gets one in .native naming the entry as the project, so
// scriptc reads the packages copied beside it as dependencies rather than as the app's own
// sources. An app that has a tsconfig keeps it.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=200, height=100"></head>
<body><div id="o">…</div><script type="module" src="app.ts"></script></body></html>`;

const APP = `document.getElementById("o")!.textContent = "ok";`;

const dir = mkdtempSync(join(tmpdir(), "native-project-tsconfig-"));
let failed = 0;

function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function app(name: string, tsconfig?: string): string {
  const root = join(dir, name);
  mkdirSync(root);
  writeFileSync(join(root, "index.html"), PAGE);
  writeFileSync(join(root, "app.ts"), APP);
  if (tsconfig !== undefined) writeFileSync(join(root, "tsconfig.json"), tsconfig);
  return root;
}

function build(root: string): { status: number | null; stderr: string } {
  const r = spawnSync("node", ["compiler/cli.ts", "build", root, "-o", join(root, "out")],
    { encoding: "utf8" });
  return { status: r.status, stderr: r.stderr };
}

// --- An app with no tsconfig ----------------------------------------------------------------

const plain = app("plain");
const built = build(plain);
check("an app without a tsconfig builds", built.status === 0, built.stderr.slice(-600));
const generated = join(plain, ".native", "tsconfig.json");
check("the build writes a project tsconfig", existsSync(generated));
if (existsSync(generated)) {
  const config = JSON.parse(readFileSync(generated, "utf8"));
  check("the entry is the project's only file",
    JSON.stringify(config.files) === JSON.stringify(["./entry.ts"]), JSON.stringify(config.files));
  check("strictNullChecks is set", config.compilerOptions.strictNullChecks === true,
    JSON.stringify(config.compilerOptions));
  check("no JSX mode is named", config.compilerOptions.jsx === undefined,
    JSON.stringify(config.compilerOptions));
}

// --- An app with its own tsconfig ------------------------------------------------------------

const own = app("own", JSON.stringify({ compilerOptions: { strictNullChecks: true } }));
const built2 = build(own);
check("an app with its own tsconfig builds", built2.status === 0, built2.stderr.slice(-600));
check("its tsconfig is not replaced", !existsSync(join(own, ".native", "tsconfig.json")));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
