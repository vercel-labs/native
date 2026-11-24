// A pseudo-element's own animation: Element.animate() with a pseudoElement option moves that
// pseudo-element's box, only the properties it accepts move, and a read of its computed style
// sees the value the animation has reached, as a browser's does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=320, height=120"><style>
#t { color: rgb(0, 0, 0); font-size: 16px; }
#t::first-letter { color: rgb(0, 0, 0); font-size: 20px; }
</style></head><body>
<p id="t">first letter</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const t = document.getElementById("t") as HTMLElement;
const cs = getComputedStyle(t, "::first-letter");
log("size " + cs.fontSize);
const opts = { pseudoElement: "::first-letter", duration: 2, delay: -1 };
const anim = t.animate([
  { color: "rgb(0, 100, 200)", transform: "translateX(100px)" },
  { color: "rgb(200, 0, 100)", transform: "translateX(0px)" },
], opts);
log("colour " + cs.color);
// A transform is not a ::first-letter property: it stays where it was.
log("transform " + cs.transform);
anim.cancel();
log("after cancel " + cs.color);
// An infinite duration stays at its first keyframe: no NaN in the progress.
const endless = t.animate([{ color: "rgb(0, 128, 0)" }, { color: "rgb(0, 128, 0)" }],
  { pseudoElement: "::first-letter", duration: Infinity });
log("infinite " + cs.color);
endless.cancel();
`;

const EXPECTED = [
  // The rule's own size, which only the pseudo-element's style has.
  "size 20px",
  // Halfway through a 2ms animation, one millisecond in.
  "colour rgb(100, 50, 150)",
  "transform none",
  "after cancel rgb(0, 0, 0)",
  "infinite rgb(0, 128, 0)",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-pseudo-animate-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 2" };
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
