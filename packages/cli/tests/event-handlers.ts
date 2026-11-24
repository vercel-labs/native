// Inline event handler attributes (`onclick="…"`, `oninput`, `<body onload>`) are compiled into
// listeners on the element they're written on, with `this` and `event` as HTML gives them, and
// the load event fires once the page's first layout is done. Steps with no snapshot still run and
// the app exits after them.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=600"><style>
html, body { margin: 0; }
body { font: 16px/1 monospace; }
#sc { width: 200px; height: 100px; overflow: auto; }
#tall { height: 500px; }
</style></head><body onload="document.getElementById('sc').scrollTop = 50; document.getElementById('load').textContent = 'load ' + (this === window) + ' ' + (event.target === document) + ' ' + document.getElementById('sc').scrollHeight">
<div id="sc"><div id="tall"></div></div>
<button id="b" onclick="this.textContent = 'clicked ' + event.type">press</button>
<button id="order" onclick="document.getElementById('seq').textContent = 'attr'">order</button>
<div id="seq"></div>
<input id="i" oninput="document.getElementById('typed').textContent = event.type + ' ' + event.target.value">
<div id="typed"></div>
<a id="a" href="#top" onclick="return false">link</a>
<button id="keep" onclick="return true">keep</button>
<button id="gone" onclick="document.getElementById('gone').textContent = 'ran'">gone</button>
<div id="cancelA"></div>
<div id="cancelB"></div>
<div id="attr" onclick="1"></div>
<div id="attrtext"></div>
<div id="attrget"></div>
<div id="load"></div>
<script>
const text = (id: string): string => {
  const el = document.getElementById(id);
  return el === null ? "" : el.textContent;
};
// A listener the script adds runs after the attribute's handler, which is attached first.
document.getElementById("order").addEventListener("click", () => {
  document.getElementById("seq").textContent = text("seq") + ", script";
});
// The attribute handler's "return false" cancels the event; "return true" doesn't.
document.getElementById("a").addEventListener("click", (e) => {
  document.getElementById("cancelA").textContent = String(e.defaultPrevented);
});
document.getElementById("keep").addEventListener("click", (e) => {
  document.getElementById("cancelB").textContent = String(e.defaultPrevented);
});
// Clearing the property removes the attribute's handler, as it does a script's.
document.getElementById("gone").onclick = null;
document.getElementById("attrtext").textContent =
  typeof document.getElementById("b").onclick + " " + String(document.getElementById("gone").onclick);
document.getElementById("attrget").textContent = String(document.getElementById("attr").getAttribute("onclick"));
// A window listener hears load after the body's attribute handler.
window.addEventListener("load", () => {
  document.getElementById("load").textContent = text("load") + " then window";
});
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-handlers-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
check("the build doesn't warn that handlers are ignored",
  !build.stderr.includes("inline event handlers are ignored"), build.stderr);
// The compiled handler wrapper must typecheck statically: an `any` in it would make scriptc warn
// (SC6104) on every app whose page has a handler attribute, which an app author can't act on.
check("the build prints no warnings", !build.stderr.includes("warning"), build.stderr);

const steps = [
  "scrolltop #sc", "print #load",
  "click #b", "print #b",
  "click #order", "print #seq",
  "click #i", "type abc", "print #typed",
  "click #a", "print #cancelA",
  "click #keep", "print #cancelB",
  "click #gone", "print #gone",
  "print #attrtext", "print #attrget",
].join(" | ");
const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: join(dir, "out.png") },
});
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);
const got = run.stdout.split("\n").slice(0, -1);
const want = [
  // The body's onload ran after layout: it scrolled the container, and could read its height.
  "50",
  "load true true 500 then window",
  // `this` is the element, `event` the event.
  "clicked click",
  // The attribute's handler comes before the listener the script adds.
  "attr, script",
  // `event.target` is the input, with the text typed into it.
  "input abc",
  // `return false` cancels the event, `return true` leaves it alone.
  "true",
  "false",
  // `onclick = null` detached the attribute's handler, and the attribute itself is still there.
  "gone",
  "function null",
  "1",
];
check(`print lines`, got.length === want.length, `got ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) {
  check(`${want[i]}`, got[i] === want[i], `got ${JSON.stringify(got[i])}`);
}

// Steps without a snapshot run headlessly too, then the app exits instead of staying up as a
// window, so a CI run that only checks printed output doesn't hang.
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: steps };
delete env.NATIVE_SNAPSHOT;
const bare = spawnSync(exe, [], { encoding: "utf8", env, timeout: 60000 });
check("steps without a snapshot exit 0", bare.status === 0 && bare.signal === null,
  `status ${bare.status} signal ${bare.signal}${bare.stderr === "" ? "" : `\n${bare.stderr}`}`);
const bareGot = bare.stdout.split("\n").slice(0, -1);
check("steps without a snapshot print the same lines", bareGot.join("\n") === want.join("\n"),
  `got ${JSON.stringify(bareGot)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
