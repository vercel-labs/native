// The inheritance batch: color-interpolation-filters, flood-color, flood-opacity, lighting-color
// and shape-image-threshold inherit; will-change does not. Each has its initial value, reads its
// value from a rule, inherits where it should, and serializes the way a browser prints it.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=120"><style>
body { margin: 0; }
#p {
  color-interpolation-filters: linearRGB;
  flood-color: rgb(18, 52, 86);
  flood-opacity: 0.4;
  lighting-color: rgb(171, 205, 239);
  will-change: transform;
  shape-image-threshold: 0.6;
  background-blend-mode: multiply;
  perspective: 200px;
  perspective-origin: 10px 20%;
  backface-visibility: hidden;
}
</style></head><body>
<div id="p"><div id="kid"></div></div>
<script>
const read = (el, name) => getComputedStyle(el).getPropertyValue(name);
const p = document.getElementById("p"), kid = document.getElementById("kid"), body = document.body;
const names = ["color-interpolation-filters", "flood-color", "flood-opacity", "lighting-color", "will-change",
  "shape-image-threshold", "background-blend-mode", "perspective", "perspective-origin", "backface-visibility"];
for (const n of names) console.log("parent " + n + " " + read(p, n));
for (const n of names) console.log("kid " + n + " " + read(kid, n));
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-inherit-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the properties parse without an unsupported warning", !b.stderr.includes("unsupported"), b.stderr.slice(0, 300));
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").filter((l) => l !== "");
const want = [
  "parent color-interpolation-filters linearRGB",
  "parent flood-color rgb(18, 52, 86)",
  "parent flood-opacity 0.4",
  "parent lighting-color rgb(171, 205, 239)",
  "parent will-change transform",
  "parent shape-image-threshold 0.6",
  "parent background-blend-mode multiply",
  "parent perspective 200px",
  "parent perspective-origin 10px 20%",
  "parent backface-visibility hidden",
  "kid color-interpolation-filters linearRGB",
  "kid flood-color rgb(18, 52, 86)",
  "kid flood-opacity 0.4",
  "kid lighting-color rgb(171, 205, 239)",
  "kid will-change auto",
  "kid shape-image-threshold 0.6",
  "kid background-blend-mode normal",
  "kid perspective none",
  "kid perspective-origin 50% 50%",
  "kid backface-visibility visible",
];
want.forEach((w, i) => check(w, got[i] === w, `got ${JSON.stringify(got[i])}`));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
