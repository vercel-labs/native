// The transition shorthand and scroll-snap-type from a script: style.transition writes the four
// longhands a declaration sets and reads them back composed; scroll-snap-type parses an axis with
// optional strictness, computes and serializes it. Snapping itself isn't implemented, so the
// property is kept and read, not acted on.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
#d { width: 10px; height: 10px; background: #f00; }
</style></head><body>
<div id="d"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;
const cs = (): CSSStyleDeclaration => getComputedStyle(d);
d.style.transition = "opacity 300ms ease 50ms";
// The longhands are read by name here: their camelCase accessors arrive with the accessor sweep.
log("longhands " + d.style.getPropertyValue("transition-property") + "|" + d.style.getPropertyValue("transition-duration") + "|"
  + d.style.getPropertyValue("transition-timing-function") + "|" + d.style.getPropertyValue("transition-delay"));
log("shorthand " + d.style.transition);
log("computed " + cs().getPropertyValue("transition-property") + "|" + cs().getPropertyValue("transition-duration") + "|" + cs().getPropertyValue("transition-delay"));

log("snap0 " + d.style.scrollSnapType + " " + cs().scrollSnapType);
d.style.scrollSnapType = "y mandatory";
log("snap1 " + d.style.scrollSnapType);
d.style.scrollSnapType = "inline";
log("snap2 " + d.style.scrollSnapType);
d.style.scrollSnapType = "none";
log("snap3 " + d.style.scrollSnapType);
log("done");
`;

// This declaration canonicalises a duration as it is set (300ms becomes 0.3s); a browser keeps
// what the script wrote and canonicalises only the computed value, so these read back in our form.
const EXPECTED = [
  "longhands opacity|0.3s|ease|0.05s",
  "shorthand opacity 0.3s ease 0.05s",
  "computed opacity|0.3s|0.05s",
  // The declaration has no scroll-snap-type of its own until one is written; the computed value is none.
  "snap0  none",
  "snap1 y mandatory",
  "snap2 inline proximity",
  "snap3 none",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-transition-shorthand-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
