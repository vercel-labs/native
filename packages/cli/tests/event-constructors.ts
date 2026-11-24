// Event constructors convert their arguments the way WebIDL says rather than refusing them: the
// type is a required DOMString (no argument is a TypeError, null and undefined are "null" and
// "undefined"), the init dictionary converts each member (a DOMString member stringifies, a
// double member uses ToNumber and refuses a non-finite result), and an init that isn't an object
// is a TypeError. A transition's Animation.effect reports the timing it runs with.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
#x { width: 10px; height: 10px; }
#t { width: 100px; transition: width 1s linear 200ms; }
#t.go { width: 200px; }
</style></head><body>
<div id="x">x</div><div id="t"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function shows(f: () => any): string {
  try { return String(f()); } catch (e: any) { return "throw:" + (e instanceof TypeError ? "TypeError" : String(e)); }
}
log("missing " + shows(() => new AnimationEvent()));
log("nulltype " + shows(() => new AnimationEvent(null as any).type));
log("undeftype " + shows(() => new AnimationEvent(undefined as any).type));
log("animname " + shows(() => new AnimationEvent("x", { animationName: null } as any).animationName)
  + " " + shows(() => new AnimationEvent("x", { animationName: false } as any).animationName)
  + " " + shows(() => new AnimationEvent("x", { animationName: 0.5 } as any).animationName)
  + " " + shows(() => new AnimationEvent("x", { animationName: [1, 2, 3] } as any).animationName)
  + " " + shows(() => new AnimationEvent("x", { animationName: {} } as any).animationName));
log("elapsed " + shows(() => new AnimationEvent("x", { elapsedTime: null } as any).elapsedTime)
  + " " + shows(() => new AnimationEvent("x", { elapsedTime: true } as any).elapsedTime)
  + " " + shows(() => new AnimationEvent("x", { elapsedTime: "0.5" } as any).elapsedTime)
  + " " + shows(() => new AnimationEvent("x", { elapsedTime: NaN } as any).elapsedTime)
  + " " + shows(() => new AnimationEvent("x", { elapsedTime: [0.5, 1] } as any).elapsedTime));
log("property " + shows(() => new TransitionEvent("x", { propertyName: null } as any).propertyName)
  + " " + shows(() => new TransitionEvent("x", { propertyName: {} } as any).propertyName));
log("init " + shows(() => new AnimationEvent("x", 5 as any)));

// The event the runtime dispatches still carries the values it was made with.
const el = document.getElementById("x") as HTMLElement;
let heard = "";
el.addEventListener("click", (e: Event) => { heard = (e as MouseEvent).button + "/" + e.type + "/" + e.bubbles; });
el.dispatchEvent(new MouseEvent("click", { bubbles: true, button: 2 }));
log("dispatch " + heard);

// A transition reports an effect with the timing it runs with.
const t = document.getElementById("t") as HTMLElement;
getComputedStyle(t).width;
t.className = "go";
const effect = t.getAnimations()[0].effect;
const animation = t.getAnimations()[0];
const made = new AnimationEvent("evt", { animation } as any);
log("animationmember " + (made.animation === animation) + " " + (new AnimationEvent("evt").animation === null)
  + " " + shows(() => new AnimationEvent("evt", { animation: {} } as any).animation));
const timing = effect === null ? null : effect.getTiming();
log("timing " + (timing === null ? "null" : timing.duration + "/" + timing.delay + "/" +
  timing.easing + "/" + timing.fill + "/" + timing.iterations));
function frameLog(n: number): void {
  if (effect === null) { log("f" + n + " none"); return; }
  const computed = effect.getComputedTiming();
  log("f" + n + " " + computed.duration + "/" + computed.delay + "/" + computed.progress);
}
let n = 0;
function loop(): void {
  frameLog(n);
  n++;
  if (n < 2) requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
`;

const EXPECTED = [
  "missing throw:TypeError",
  "nulltype null",
  "undeftype undefined",
  "animname null false 0.5 1,2,3 [object Object]",
  "elapsed 0 1 0.5 throw:TypeError throw:TypeError",
  "property null [object Object]",
  "init throw:TypeError",
  "dispatch 2/click/true",
  "animationmember true true throw:TypeError",
  "timing 1000/200/linear/backwards/1",
  "f0 1000/200/0",
  "f1 1000/200/0.5",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-event-constructors-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0 | frame 700" };
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
