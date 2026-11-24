// Windows: the page's own link targets, window.open() with its features and name, the handles a
// page has on the windows it opened and the one that opened it, messages between them, and the
// window's life — focus, blur, visibility, its frame, fullscreen, closing and quitting.
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
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=300">
<title>Windows</title></head><body>
<p id="log">-</p>
<input id="f" value="hello">
<a id="named" href="#/settings" target="settings">settings</a>
<a id="blanklink" href="#/about" target="_blank">about</a>
<a id="plain" href="#/doc">doc</a>
<button id="open">open</button>
<button id="openblank">blank</button>
<button id="frame">frame</button>
<button id="fs">fullscreen</button>
<button id="tryclose">try close</button>
<button id="doclose">close</button>
<script type="module" src="app.ts"></script></body></html>`;

const APP = `const log = document.getElementById("log")!;
const lines: string[] = [];
function note(s: string): void { lines.push(s); log.textContent = lines.join("|"); }
let allowLeave = false;
let opened: WindowProxy | null = null;

window.addEventListener("message", (event) => {
  if (!(event instanceof MessageEvent)) return;
  note("message " + JSON.stringify(event.data) + " from " + (event.source === null ? "none" : String(event.source.id)));
});
window.addEventListener("focus", () => note("focus"));
window.addEventListener("blur", () => note("blur"));
document.addEventListener("visibilitychange", () => {
  note("visibility " + document.visibilityState + " " + String(document.hidden));
});
window.addEventListener("hashchange", () => note("hash " + location.hash));
window.addEventListener("move", () => note("move " + String(window.screenX) + "," + String(window.screenY)));
window.addEventListener("resize", () => note("resize " + String(window.innerWidth) + "x" + String(window.innerHeight)));
window.addEventListener("beforeunload", (event) => {
  if (!allowLeave) {
    event.preventDefault();
    note("kept");
  }
});
window.addEventListener("pagehide", () => console.log("pagehide"));
document.addEventListener("fullscreenchange", () => {
  note("fullscreen " + (document.fullscreenElement === null ? "none" : document.fullscreenElement.localName));
});

document.getElementById("open")!.addEventListener("click", () => {
  opened = window.open("#/settings", "settings", "width=320,height=240,left=10,top=20");
  note(opened === null ? "null" : "named " + opened.name + " " + String(opened.id));
  note("frame " + String(window.screenX) + "," + String(window.screenY) + " " + String(window.outerWidth) + "x" + String(window.outerHeight));
});
document.getElementById("openblank")!.addEventListener("click", () => {
  const w = window.open("#/x", "_blank");
  note(w === null ? "null" : "blank [" + w.name + "] " + String(w.id));
});
document.getElementById("frame")!.addEventListener("click", () => {
  window.resizeTo(500, 400);
  window.moveTo(30, 40);
});
document.getElementById("fs")!.addEventListener("click", () => document.documentElement.requestFullscreen());
document.getElementById("tryclose")!.addEventListener("click", () => window.close());
document.getElementById("doclose")!.addEventListener("click", () => { allowLeave = true; window.close(); });
document.getElementById("named")!.addEventListener("click", () => note("link"));
document.getElementById("plain")!.addEventListener("click", () => note("plain link"));

window.addEventListener("load", () => {
  note("load name=[" + window.name + "] href=" + location.href + " opener=" + (window.opener === null ? "none" : String(window.opener.id)));
  window.postMessage({ self: true }, "*");
  document.title = "Window Test";
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-windows-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
ok("the page builds", b.status === 0, b.stderr.slice(-400));

const run = (steps: string, env: Record<string, string> = {}): string[] =>
  spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps, ...env } }).stdout.trim().split("\n");

const log = (steps: string, env: Record<string, string> = {}): string => run(steps, env).join("||");

ok("a page's first window has no name and no opener, and hears its own message",
  log("wait 10 | print #log") === "load name=[] href=file:///index.html opener=none|message {\"self\":true} from none",
  log("wait 10 | print #log"));

const opened = log("click #open | print #log");
ok("window.open() names the window and hands back a handle with its id", opened.includes("named settings 2"), opened);
ok("the page's frame is its own size at the screen's corner", opened.includes("frame 0,0 400x300"), opened);

ok("a name already open is focused and handed back, not opened again",
  log("click #open | click #open | print #log").split("named settings 2").length === 3,
  log("click #open | click #open | print #log"));

ok("_blank opens a window with no name", log("click #openblank | print #log").includes("blank [] 2"),
  log("click #openblank | print #log"));

ok("a link's target opens the window it names", log("click #named | print #log").includes("link"), "");
ok("a link with no target changes the page's fragment",
  log("click #plain | print #log").includes("plain link|hash #/doc"), log("click #plain | print #log"));

const frame = log("click #frame | print #log");
ok("resizeTo() resizes the window and fires resize", frame.includes("resize 500x400"), frame);
ok("moveTo() moves the window and fires move", frame.includes("move 30,40"), frame);

ok("focus and blur are the window's own events",
  log("wait 10 | focus | blur | print #log") === "load name=[] href=file:///index.html opener=none|message {\"self\":true} from none|focus|blur",
  log("wait 10 | focus | blur | print #log"));

const hidden = log("hide | print #log | show | print #log");
ok("hiding the window makes the document hidden and fires visibilitychange",
  hidden.includes("visibility hidden true") && hidden.includes("visibility visible false"), hidden);

ok("document.title is the window's title", run("title")[0] === "Window Test", run("title")[0]);

const fs = log("click #fs | print #log");
ok("requestFullscreen() reports the element and fires fullscreenchange", fs.includes("fullscreen html"), fs);

ok("a message step arrives with its data and the window it came from",
  log("message 42 {\"hello\":\"world\"} | print #log").includes("message {\"hello\":\"world\"} from 42"), "");

const kept = run("wait 10 | click #tryclose | print #log");
ok("beforeunload can keep a window open", kept[0].endsWith("kept"), kept.join("|"));

const closed = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "wait 10 | click #doclose | print #log" },
});
ok("closing the window runs pagehide and ends the app",
  closed.status === 0 && closed.stdout.trim() === "pagehide", closed.stdout.trim());

const child = run("wait 10 | print #log", { NATIVE_WINDOW_NAME: "settings", NATIVE_WINDOW_OPENER: "17", NATIVE_WINDOW_URL: "#/two" });
ok("a window is told its name, its route and the window that opened it",
  child[0].startsWith("load name=[settings] href=file:///index.html#/two opener=17"), child.join("|"));

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
