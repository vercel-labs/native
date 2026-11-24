// Pointer capture: an element that takes the pointer keeps getting its moves after the pointer
// leaves it, hears that it got and lost the capture, and can hand it back early. An event's
// offsets measure from the target's box, and a pointer event stands for itself when the host
// coalesces nothing.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; background: #fff; }
#pad { position: absolute; left: 20px; top: 20px; width: 100px; height: 100px; background: #eef; }
#cushion { position: absolute; left: 0; top: 120px; width: 300px; height: 80px; background: #ffe; }
#pad2 { position: absolute; left: 20px; top: 20px; width: 100px; height: 100px; background: #efe; }
</style></head><body>
<div id="pad"></div>
<div id="cushion"><div id="pad2"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function name(t: EventTarget | null): string {
  return t instanceof Element ? t.tagName.toLowerCase() + "#" + t.id : "none";
}
const pad = document.getElementById("pad")!;
const pad2 = document.getElementById("pad2")!;

// A capture only exists while the pointer is down, so asking for one before a press is an error.
try {
  pad.setPointerCapture(3);
  log("captured");
} catch (e) {
  log("throw " + (e as Error).message.split(":")[0]);
}

pad.addEventListener("pointerdown", (e) => {
  log("pad down " + e.offsetX + "," + e.offsetY + " " + name(e.target) + " id " + e.pointerId);
  pad.setPointerCapture(e.pointerId);
  log("pad has " + pad.hasPointerCapture(e.pointerId));
});
pad.addEventListener("gotpointercapture", (e) => log("pad got " + name(e.target)));
pad.addEventListener("pointermove", (e) => {
  log("pad move " + e.offsetX + "," + e.offsetY + " of " + e.getCoalescedEvents().length);
});
pad.addEventListener("pointerup", (e) => log("pad up " + e.offsetX));
pad.addEventListener("lostpointercapture", (e) => log("pad lost " + name(e.target)));
pad.addEventListener("click", () => log("pad click"));
pad2.addEventListener("pointerdown", (e) => {
  // The same press without a capture: the move after it left the element goes elsewhere.
  log("pad2 down " + e.offsetX + "," + e.offsetY);
});
document.addEventListener("pointermove", (e) => log("target " + name(e.target)));
document.addEventListener("mousemove", (e) => log("mouse " + name(e.target)));
document.addEventListener("pointerup", (e) => log("release " + name(e.target) + " " + pad2.hasPointerCapture(1)));
log("after " + pad.hasPointerCapture(1) + " " + pad2.hasPointerCapture(1));
`;

const EXPECTED = [
  "throw NotFoundError",
  "after false false",
  // drag #pad 200 0
  "pad down 50,50 div#pad id 1",
  "pad got div#pad",
  "pad has true",
  "pad move 150,50 of 1",
  "target div#pad",
  "mouse div#pad",
  "pad move 250,50 of 1",
  "target div#pad",
  "mouse div#pad",
  "pad up 250",
  "release div#pad false",
  "pad click",
  "pad lost div#pad",
  // drag #pad2 200 0
  "pad2 down 50,50",
  "target div#cushion",
  "mouse div#cushion",
  "target div#cushion",
  "mouse div#cushion",
  "release div#cushion false",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-pointer-capture-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "drag #pad 200 0 | drag #pad2 200 0" };
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
