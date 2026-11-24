// Menus: the window's menu bar from <menu type="application">, context menus from the
// contextmenu attribute, the menuitem attributes (label, accesskey, command, disabled), the
// CommandEvent a command fires, and the commands the platform runs itself.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` (${detail})`}`);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=300">
<title>Menus</title></head><body>
<menu type="application" id="app-menu">
  <menuitem label="Say Hello" accesskey="H" id="say"></menuitem>
  <menuitem label="Greyed" disabled id="greyed"></menuitem>
  <hr>
  <menu label="Edit">
    <menuitem command="--copy"></menuitem>
    <menuitem command="--select-all" accesskey="Shift+A"></menuitem>
    <menuitem label="Custom" command="--my-thing"></menuitem>
    <menuitem command="--quit"></menuitem>
  </menu>
</menu>
<menu type="context" id="row-menu">
  <menuitem command="--copy"></menuitem>
  <hr>
  <menuitem label="Remove" id="remove"></menuitem>
</menu>
<p id="log">-</p>
<input id="f" value="hello">
<div id="row" contextmenu="row-menu">row</div>
<div id="blocked" contextmenu="row-menu">blocked</div>
<script type="module" src="app.ts"></script></body></html>`;

const APP = `const log = document.getElementById("log")!;
const lines: string[] = [];
function note(s: string): void { lines.push(s); log.textContent = lines.join("|"); }
let allowQuit = false;

document.addEventListener("command", (event) => {
  if (event instanceof CommandEvent) {
    note("command " + event.command + " from " + (event.source === null ? "none" : event.source.localName));
  }
});
document.addEventListener("contextmenu", () => note("contextmenu"));
document.getElementById("blocked")!.addEventListener("contextmenu", (event) => {
  event.preventDefault();
  note("cancelled");
});
document.getElementById("say")!.addEventListener("click", () => note("say clicked"));
document.getElementById("greyed")!.addEventListener("click", () => note("greyed clicked"));
document.getElementById("remove")!.addEventListener("click", () => note("removed"));

window.addEventListener("beforeunload", (event) => {
  if (!allowQuit) {
    event.preventDefault();
    note("kept");
  }
});

window.addEventListener("load", () => {
  const menu = document.getElementById("app-menu")!;
  note("display " + getComputedStyle(menu).display);
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-menus-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), APP);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
ok("the page builds", build.status === 0, build.stderr.slice(-400));

const pasteboard = join(dir, "pasteboard.txt");
const run = (steps: string, extra: Record<string, string> = {}): string[] =>
  spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: steps, NATIVE_PASTEBOARD: pasteboard, ...extra },
  }).stdout.replace(/\n+$/, "").split("\n");
const log = (steps: string, extra: Record<string, string> = {}): string => run(steps, extra).join("||");

const SPEC = [
  "\t\t0",
  "  Say Hello\tH\t0",
  "  Greyed\t\t1",
  "  -\t\t0",
  "Edit\t\t0",
  "  Copy\t\t0",
  "  Select All\tShift+A\t0",
  "  Custom\t\t0",
  "  Quit\t\t0",
].join("\n");

ok("the menu bar's markup becomes its spec: labels, accesskeys, disabled items and nesting",
  run("menu").join("\n") === SPEC, JSON.stringify(run("menu").join("\n")));

ok("a menu declared in the page draws nothing", log("print #log").includes("display none"), log("print #log"));

ok("choosing an item clicks its element", log("menuclick /Say Hello | print #log").endsWith("say clicked"),
  log("menuclick /Say Hello | print #log"));
ok("a disabled item can't be chosen", !log("menuclick /Greyed | print #log").includes("greyed clicked"),
  log("menuclick /Greyed | print #log"));

const custom = log("menuclick Edit/Custom | print #log");
ok("a command fires at its menuitem with the command and source, then the page's listener sees it",
  custom.endsWith("command --my-thing from menuitem"), custom);

const copied = log("click #f | menuclick Edit/Select All | selection #f | menuclick Edit/Copy");
ok("--select-all and --copy act on the focused field", copied.includes("sel 0,5"), copied);
ok("--copy puts the field's selection on the pasteboard", readFileSync(pasteboard, "utf8") === "hello",
  JSON.stringify(readFileSync(pasteboard, "utf8")));

const removed = log("contextmenu #row | print #log", { NATIVE_MENU_CHOICE: "2" });
ok("a context menu's item is clicked on the element whose contextmenu attribute names it",
  removed.endsWith("contextmenu|removed"), removed);

const copyChoice = log("contextmenu #row | print #log", { NATIVE_MENU_CHOICE: "0" });
ok("a context menu's command runs too", copyChoice.endsWith("command --copy from menuitem"), copyChoice);

const cancelled = log("contextmenu #blocked | print #log", { NATIVE_MENU_CHOICE: "2" });
ok("preventDefault() on contextmenu keeps the declared menu from showing",
  cancelled.endsWith("cancelled|contextmenu"), cancelled);

const quit = run("menuclick Edit/Quit | print #log");
ok("--quit runs beforeunload, which can keep the app up", quit[0].endsWith("kept"), quit.join("||"));

const appMenu = log("menu");
ok("an item's command gives it a standard label", appMenu.includes("  Copy\t\t0"), appMenu);

if (failed > 0) {
  console.error(`\n${failed} check(s) failed`);
  process.exit(1);
}
