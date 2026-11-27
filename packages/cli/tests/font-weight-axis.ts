// A face declared with a weight range (`font-weight: 100 900` on one @font-face) is a variable
// font, and CSS's font-weight sets its wght axis: the same text is wider at 900 than at 100. The
// Linux host set that axis from the start; the macOS host only set axes a run named in
// font-variation-settings, so every weight drew the file's default instance and the two widths
// came out equal.
//
// The check measures the same text at the two ends of the range and requires the heavier one to be
// wider, which happens only when the axis is set.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The Windows host's variation support is not covered by this check; the two hosts that read a
// page's own faces are.
if (process.platform === "win32") {
  console.log("ok   font-weight sets a variable face's wght axis (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "inter-latin.woff2");
if (!existsSync(FIXTURE)) {
  console.log("ok   font-weight sets a variable face's wght axis (needs the inter-latin.woff2 fixture)");
  console.log("\nall passed");
  process.exit(0);
}

const TEXT = "Hamburgefonstiv";
const SIZE = 40;

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=600, height=160"><style>
@font-face { font-family: V; src: url("v.woff2"); font-weight: 100 900; }
body { margin: 0; font-family: V; font-size: ${SIZE}px; white-space: nowrap; }
span { display: inline-block; }
</style></head><body>
<span id="light" style="font-weight: 100">${TEXT}</span>
<span id="heavy" style="font-weight: 900">${TEXT}</span>
<script src="app.ts"></script>
</body></html>`;

// The spans are laid out by the first frame, so the widths are read in a later one.
const SCRIPT = `
requestAnimationFrame(() => requestAnimationFrame(() => {
  console.log("light=" + document.getElementById("light")!.getBoundingClientRect().width.toFixed(2));
  console.log("heavy=" + document.getElementById("heavy")!.getBoundingClientRect().width.toFixed(2));
}));
`;

const dir = mkdtempSync(join(tmpdir(), "native-font-weight-axis-"));
copyFileSync(FIXTURE, join(dir, "v.woff2"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 0 | frame 16" } });
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}`);
const widths: Record<string, number> = {};
for (const line of r.stdout.split("\n")) {
  const m = /^(light|heavy)=([\d.]+)$/.exec(line.trim());
  if (m) widths[m[1]] = Number(m[2]);
}

check("the light end measures", widths.light > 0, `${widths.light}`);
check("font-weight sets the wght axis: 900 is wider than 100",
  widths.heavy > widths.light * 1.02, `light ${widths.light}, heavy ${widths.heavy}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
