// Custom properties follow the cascade's layer order: an important declaration in an earlier
// layer beats a later layer's, a normal one takes the later layer, and an unlayered important
// declaration is the weakest of them.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>customs-layers</title><style>
@layer a, b, c;
@layer a { #c { --x: rgb(255, 0, 0) !important; --y: rgb(255, 0, 0); } }
@layer b { #c { --x: rgb(0, 0, 255) !important; --y: rgb(0, 0, 255); } }
#u { --z: rgb(255, 0, 0) !important; }
@layer c { #u { --z: rgb(0, 0, 255) !important; } }
</style></head><body>
<div id="c"></div><div id="u"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const value = (id: string, name: string): string =>
  getComputedStyle(document.getElementById(id) as HTMLElement).getPropertyValue(name);
console.log("layered " + value("c", "--x") + " " + value("c", "--y"));
console.log("unlayered " + value("u", "--z"));
`;

const EXPECTED_LOG = [
  // Important reverses the layer order (earlier layer wins); normal keeps it (later wins).
  "layered rgb(255, 0, 0) rgb(0, 0, 255)",
  // An unlayered important declaration is the weakest, so the layered one takes it.
  "unlayered rgb(0, 0, 255)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-customs-layers-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
if (got.length === EXPECTED_LOG.length) {
  for (let i = 0; i < got.length; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);
} else {
  check(`log lines (${EXPECTED_LOG.length})`, false, `got ${got.length}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
