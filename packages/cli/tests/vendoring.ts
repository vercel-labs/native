// A package written for a bundler: its imports leave off the file extension, and it names a
// sibling package that only the app's install has. The build copies every file it reaches into
// the build dir so the DOM can be bound there, including the files a type-only import names.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"><style>
body { margin: 0; }
#box { width: 100px; height: 20px; }
</style></head><body>
<div id="root"></div>
<script src="app.ts"></script>
</body></html>`;

const APP = `
import { make, NAME, type Box } from "fake-pkg/entry";
const box: Box | null = null;
const el = make();
document.getElementById("root")!.appendChild(el);
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const r = el.getBoundingClientRect();
    console.log(NAME + " " + r.width + "x" + r.height + " " +
      getComputedStyle(el).getPropertyValue("height") + " " + String(box));
  });
});
`;

// A package with no node_modules of its own: extensionless relative imports, a bare import of a
// package only the app installed, and a type-only re-export of a file that names a DOM type.
const FAKE_PKG = {
  "package.json": JSON.stringify({ name: "fake-pkg", type: "module", exports: { "./entry": "./src/entry.ts" } }),
  "src/entry.ts": `
import { makeBox } from "dep-two";
import { label } from "./label";
export type { Box } from "./types";
export const NAME = "vendored";
export function make(): HTMLElement {
  const el = makeBox();
  el.textContent = label;
  return el;
}
`,
  "src/label.ts": `export const label = "box";\n`,
  "src/types.ts": `export type Box = { el: HTMLElement };\n`,
};

const DEP_TWO = {
  "package.json": JSON.stringify({ name: "dep-two", type: "module", exports: "./main.ts" }),
  "main.ts": `
export function makeBox(): HTMLElement {
  const el = document.createElement("div");
  el.id = "box";
  return el;
}
`,
};

const EXPECTED_LOG = ["vendored 100x20 20px null"];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function install(dir: string, files: Record<string, string>): void {
  for (const [path, text] of Object.entries(files)) {
    const p = join(dir, path);
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, text);
  }
}

const dir = mkdtempSync(join(tmpdir(), "native-vendoring-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
install(join(dir, "node_modules", "fake-pkg"), FAKE_PKG);
install(join(dir, "node_modules", "dep-two"), DEP_TWO);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

// A snapshot path ends the run after the steps; the output itself is only for the log check.
const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame", NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
