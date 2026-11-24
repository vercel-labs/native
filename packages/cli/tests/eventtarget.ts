// The event target a script makes with `new EventTarget()`: its listeners, the order they run
// in at the target, the target and currentTarget a listener sees, once listeners, object
// listeners, and Node being an EventTarget as in a browser.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head><body>
<div id="box"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const t = new EventTarget();
const seen: string[] = [];
function onA(e: Event): void { seen.push("a " + e.type + " " + String(e.currentTarget === t) + " " + String(e.target === t) + " " + e.eventPhase); }
function onB(e: Event): void { seen.push("b " + e.type); }
t.addEventListener("x", onA, true);
t.addEventListener("x", onB, false);
t.addEventListener("x", onB, false);
const ev = new Event("x");
log("return " + String(t.dispatchEvent(ev)));
log("listeners " + seen.join("|"));
log("after " + String(ev.target === t) + " " + String(ev.cancelBubble));

const once = new EventTarget();
let onceCalls = 0;
once.addEventListener("y", () => { onceCalls++; }, { once: true });
once.dispatchEvent(new Event("y"));
once.dispatchEvent(new Event("y"));
log("once " + onceCalls);

const object = new EventTarget();
const obj = { handleEvent(e: Event): void { log("handleEvent " + e.type + " " + String(this === obj)); } };
object.addEventListener("z", obj);
object.dispatchEvent(new Event("z"));

let stopped = 0;
const stop = new EventTarget();
stop.addEventListener("q", (e: Event) => { e.stopImmediatePropagation(); stopped++; });
stop.addEventListener("q", () => { stopped++; });
stop.dispatchEvent(new Event("q"));
log("stop " + stopped);

const box = document.getElementById("box") as HTMLElement;
log("node " + String(box instanceof Node) + " " + String(box instanceof EventTarget) + " " + String(window.EventTarget === EventTarget));
`;

const EXPECTED = [
  "return true",
  "listeners a x true true 2|b x",
  "after true false",
  "once 1",
  "handleEvent z true",
  "stop 1",
  "node true true true",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-eventtarget-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
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
