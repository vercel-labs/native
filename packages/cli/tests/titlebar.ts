// A page that draws into the titlebar: <meta name="native-window" content="titlebar=…"> options,
// env(titlebar-area-*) and env(safe-area-inset-top) for laying out around the window's controls,
// and app-region: drag areas, whose presses move the window instead of reaching the page.
// Headless, the titlebar area is the macOS default for the style (86px of a 52px bar for
// hidden-inset), since there is no window to ask.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` (${detail})`}`);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=200, titlebar=hidden-inset, min-width=300">
<style>
body { margin: 0; }
#bar { height: env(titlebar-area-height, 10px); padding-left: env(titlebar-area-x, 0px); app-region: drag; }
#btn { app-region: no-drag; }
#plain { height: env(nope, 7px); }
</style></head><body>
<div id="bar"><span id="btn">button</span></div><div id="plain"></div><p id="log">-</p>
<script type="module" src="app.ts"></script></body></html>`;

const APP = `const log = document.getElementById("log")!;
const bar = document.getElementById("bar")!;
const wco = navigator.windowControlsOverlay;
requestAnimationFrame(() => {
const s = getComputedStyle(bar);
const r = wco.getTitlebarAreaRect();
log.textContent = [bar.getBoundingClientRect().height, s.paddingLeft, s.getPropertyValue("app-region"),
  getComputedStyle(document.getElementById("btn")!).getPropertyValue("app-region"),
  document.getElementById("plain")!.getBoundingClientRect().height,
  wco.visible, r.x, r.y, r.width, r.height, r.left, r.right, r.bottom].join(" ");
});
bar.addEventListener("click", (e) => { if (e.target === bar) log.textContent = "bar clicked"; });
document.getElementById("btn")!.addEventListener("click", () => { log.textContent = "button clicked"; });
`;

const dir = mkdtempSync(join(tmpdir(), "native-titlebar-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
ok("the page builds", b.status === 0, b.stderr.slice(-300));
const run = (steps: string) => spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps } }).stdout.trim().split("\n");

const first = run("frame 16 | print #log")[0];
ok("env(titlebar-area-height) and env(titlebar-area-x) fill the bar, and app-region reads back",
  first === "52 86px drag no-drag 7 true 86 0 314 52 86 400 52", first);
ok("navigator.windowControlsOverlay reports the same area as a DOMRect", first.endsWith(" true 86 0 314 52 86 400 52"), first);
ok("a press in the drag area doesn't reach the page", run("frame 16 | click #bar | print #log")[0] === first);
ok("a no-drag child inside it is clickable", run("frame 16 | click #btn | print #log")[0] === "button clicked");

writeFileSync(join(dir, "index.html"), PAGE.replace("titlebar=hidden-inset", "titlebar=sideways, colour=blue"));
const w = spawnSync("node", ["compiler/cli.ts", "check", dir], { encoding: "utf8" });
ok("an unknown titlebar style is a warning", w.stderr.includes("unknown titlebar 'sideways'"));
ok("so is an unknown option", w.stderr.includes("unknown option 'colour'"));

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
