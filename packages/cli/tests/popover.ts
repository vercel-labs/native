// Popovers and inert: a popover draws only while it is open, its invoker opens and closes it,
// a press outside closes it, and Escape closes it; an inert subtree takes no pointer events and
// no focus. Both are driven the way a person would, through the pointer and keyboard paths.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400">
<style>
#menu { color: rgb(0, 0, 255); }
#menu:popover-open { color: rgb(255, 0, 0); }
</style></head><body>
<button id="open" popovertarget="menu">Open</button>
<div id="menu" popover>
  <p id="item">Item</p>
  <button id="close" popovertarget="menu" popovertargetaction="hide">Close</button>
</div>
<p id="status">closed</p>
<p id="bg">background</p>
<button id="shower" popovertarget="menu" popovertargetaction="show">Show</button>
<div id="inertbox" inert><button id="dead">Dead</button></div>
<button id="live">Live</button>
<div id="made" popover="manual">made</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const menu = document.getElementById("menu") as HTMLElement;
const status = document.getElementById("status") as HTMLElement;
const bg = document.getElementById("bg") as HTMLElement;
const open = document.getElementById("open") as HTMLButtonElement;
const shower = document.getElementById("shower") as HTMLButtonElement;
const box = document.getElementById("inertbox") as HTMLElement;
const dead = document.getElementById("dead") as HTMLButtonElement;
const live = document.getElementById("live") as HTMLButtonElement;
const made = document.getElementById("made") as HTMLElement;
const close = document.getElementById("close") as HTMLButtonElement;

let menuOpen = false;
let madeOpen = false;

// --- the attributes and the properties that mirror them
log("attr " + String(menu.popover) + " " + String(bg.popover) + " " + String(made.popover));
log("target " + String(open.popoverTargetElement === menu) + " " + shower.popoverTargetAction);
log("display " + getComputedStyle(menu).display + " color " + getComputedStyle(menu).color);

// --- inert takes its subtree out of focus, the element itself or its own attribute
log("inert " + String(box.inert) + " " + String(dead.inert) + " focusable " + String(dead.isFocusable) + " " + String(live.isFocusable));
box.inert = false;
log("inert off " + String(dead.isFocusable));
box.inert = true;
log("inert on " + String(dead.isFocusable));

menu.addEventListener("beforetoggle", (e: Event) => {
  const t = e as ToggleEvent;
  log("before " + t.oldState + ">" + t.newState);
});
menu.addEventListener("toggle", (e: Event) => {
  const t = e as ToggleEvent;
  menuOpen = t.newState === "open";
  status.textContent = t.newState;
  // The :popover-open rule follows the state, so the color flips with it.
  log("color " + getComputedStyle(menu).color);
});
made.addEventListener("toggle", (e: Event) => { madeOpen = (e as ToggleEvent).newState === "open"; });

dead.addEventListener("click", () => log("dead click"));
live.addEventListener("click", () => log("live click"));
for (const el of [open, close, shower, live, dead]) el.addEventListener("focus", () => log("focus " + el.id));

// --- the errors the API has: no popover attribute, or not showing
let err = "";
try { bg.showPopover(); } catch (e) { err = String(e); }
log("no attr " + (err.indexOf("NotSupportedError") >= 0 ? "NotSupportedError" : err));
err = "";
try { menu.hidePopover(); } catch (e) { err = String(e); }
log("not open " + (err.indexOf("InvalidStateError") >= 0 ? "InvalidStateError" : err));

// --- a manual popover stays open when an auto one opens
made.showPopover();
log("manual open " + String(madeOpen) + " display " + getComputedStyle(made).display);
log("toggle " + String(menu.togglePopover()) + " auto open " + String(menuOpen) + " manual " + String(madeOpen));
menu.hidePopover();
made.hidePopover();

// --- popoverTargetElement names the target through the attribute, giving it an id
shower.popoverTargetElement = made;
log("set target " + String(shower.getAttribute("popovertarget")) + " same " + String(shower.popoverTargetElement === made));
shower.popoverTargetElement = null;
log("clear target " + String(shower.getAttribute("popovertarget")));
shower.popoverTargetElement = menu;

// --- a popover that leaves the document closes
made.showPopover();
made.remove();
log("removed " + String(madeOpen) + " " + String(made.isConnected));
`;

// A press outside the open popover closes it; a press on an inert button reaches nothing.
const STEPS = [
  "frame 0",
  "print #status",
  "click #dead",
  "print #status",
  "click #open",
  "print #status",
  "click #bg",
  "print #status",
  "click #open",
  "key Escape",
  "print #status",
  "click #shower",
  "key Tab", "key Tab", "key Tab",
  "print #status",
  "key Escape",
  "print #status",
].join(" | ");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-popover-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: STEPS } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = [
  "attr auto null manual",
  "target true show",
  "display none color rgb(0, 0, 255)",
  "inert true false focusable false true",
  "inert off true",
  "inert on false",
  "no attr NotSupportedError",
  "not open InvalidStateError",
  "manual open true display block",
  "before closed>open",
  "color rgb(255, 0, 0)",
  "toggle true auto open true manual true",
  "before open>closed",
  "color rgb(0, 0, 255)",
  "set target made same true",
  "clear target null",
  "removed false false",
  "closed",
  "closed",
  "focus open",
  "before closed>open",
  "color rgb(255, 0, 0)",
  "open",
  "before open>closed",
  "color rgb(0, 0, 255)",
  "closed",
  "focus open",
  "before closed>open",
  "color rgb(255, 0, 0)",
  "before open>closed",
  "color rgb(0, 0, 255)",
  "closed",
  "focus shower",
  "before closed>open",
  "color rgb(255, 0, 0)",
  "focus live",
  "focus open",
  "focus close",
  "open",
  "before open>closed",
  "color rgb(0, 0, 255)",
  "closed",
];

check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
