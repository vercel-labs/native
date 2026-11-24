// The patterns a UI Automation client drives, not only the tree it reads: an app built here is
// walked by a real IUIAutomation client — the way a screen reader or agent-desktop drives a
// browser's page. It finds the window's Document, finds elements by their AutomationId and their
// name, invokes a button, writes a field's value, toggles a checkbox, steps a range, expands a
// select, picks a radio, focuses an element and hit-tests a point; it reads the heading level, a
// link's address, a description and the Text pattern's range back. Then it drives the todo
// example: a value written into its field, Add pressed, and the new item and the count in the tree.
//   node tests/uia-patterns.ts

import { spawn, spawnSync } from "node:child_process";
import { closeSync, mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

if (process.platform !== "win32") {
  console.log(`ok   skipped: UI Automation is Windows's accessibility API (this is ${process.platform})`);
  process.exit(0);
}

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=480, height=620"><title>Form</title></head><body>
<main id="m">
<h1>Order</h1>
<nav id="n"><a id="help" href="https://example.com/help">Help</a></nav>
<label for="qty">Quantity</label> <input id="qty" type="number" value="1" min="0" max="9">
<input id="name" placeholder="Your name">
<textarea id="notes" aria-label="Notes"></textarea>
<input id="agree" type="checkbox"> <label for="agree">I agree</label>
<input id="r1" type="radio" name="pick" aria-label="First"> <input id="r2" type="radio" name="pick" aria-label="Second">
<input id="vol" type="range" aria-label="Volume" value="50">
<select id="size" aria-label="Size"><option>Small</option><option selected>Large</option></select>
<button id="buy" aria-describedby="hint">Buy</button>
<button id="mute" aria-pressed="false">Mute</button>
<p id="hint">Ships tomorrow</p>
<ul><li>One</li><li>Two</li></ul>
<div id="row">Clickable row</div>
<p id="out" role="status">Ready</p>
</main>
<script>
const out = document.getElementById("out");
const log = (t) => { console.log(t); out.textContent = t; };
const name = document.getElementById("name");
document.getElementById("buy").addEventListener("click", () => log("clicked buy " + name.value));
document.getElementById("row").addEventListener("click", () => log("clicked row"));
document.getElementById("mute").addEventListener("click", (e) => {
  const b = e.currentTarget;
  b.setAttribute("aria-pressed", b.getAttribute("aria-pressed") === "true" ? "false" : "true");
  log("mute " + b.getAttribute("aria-pressed"));
});
name.addEventListener("input", () => log("input " + name.value));
name.addEventListener("change", () => log("change " + name.value));
document.getElementById("agree").addEventListener("change", (e) => log("agree " + e.target.checked));
document.getElementById("vol").addEventListener("input", (e) => log("vol " + e.target.value));
for (const radio of document.querySelectorAll('input[name="pick"]')) {
  radio.addEventListener("change", (e) => log("pick " + e.target.getAttribute("aria-label")));
}
</script>
</body></html>`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): boolean {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
  if (!ok) failed++;
  return ok;
}

function sleep(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

const dir = mkdtempSync(join(tmpdir(), "native-uia-patterns-"));

/** Runs the client against a process: its stdout, trimmed. */
function clientRun(probe: string, pid: number, ...args: string[]): string {
  const r = spawnSync(probe, [String(pid), ...args], { encoding: "utf8", timeout: 60000 });
  return (r.stdout ?? "").trim();
}

/** Repeats a client call until its output satisfies `test`: the tree arrives once a client asks,
 *  and an action reaches the page a frame or two later. */
function clientUntil(probe: string, pid: number, test: (out: string) => boolean, ...args: string[]): string {
  let out = "";
  // A client that can't find the window already waited ten seconds for it; three in a row means
  // there is nothing to wait for.
  let missing = 0;
  for (let i = 0; i < 60; i++) {
    out = clientRun(probe, pid, ...args);
    if (test(out)) return out;
    if (out === "NOWINDOW") {
      if (++missing >= 3) return out;
    } else {
      missing = 0;
    }
    sleep(250);
  }
  return out;
}

/** Whether the app's page printed `want`, which its console.log sends to the pipe. */
function logged(appLog: () => string, want: string): boolean {
  for (let i = 0; i < 80; i++) {
    if (appLog().includes(want)) return true;
    sleep(100);
  }
  return false;
}

function main(): void {
  const probe = join(dir, "probe.exe");
  const built = spawnSync(
    "zig",
    ["c++", "-target", "x86_64-windows-gnu", "-O1", "-fno-exceptions", join("tests", "uia", "probe.cpp"),
     "-o", probe, "-lole32", "-loleaut32", "-luuid"],
    { encoding: "utf8", timeout: 300000 },
  );
  if (built.error !== undefined) {
    console.log(`ok   skipped: the UI Automation client needs zig on the PATH (${built.error.message})`);
    return;
  }
  if (!check("the UI Automation client builds", built.status === 0, (built.stderr ?? "").slice(-500))) return;

  writeFileSync(join(dir, "index.html"), PAGE);
  const exe = join(dir, "form");
  const page = spawnSync(process.execPath, ["compiler/cli.ts", "build", dir, "-o", exe], {
    encoding: "utf8",
    timeout: 1500000,
  });
  if (!check("the probe page builds", page.status === 0, ((page.stdout ?? "") + (page.stderr ?? "")).slice(-800))) return;

  // The app's console.log goes to a file the test reads back between its blocking client calls;
  // an event handler would never run while the test is waiting on one.
  const logPath = join(dir, "form.log");
  const logFd = openSync(logPath, "w");
  const app = spawn(exe + ".exe", [], { stdio: ["ignore", logFd, logFd] });
  const seen = (): string => {
    try {
      return readFileSync(logPath, "utf8");
    } catch {
      return "";
    }
  };
  const run = (...args: string[]): string => clientRun(probe, app.pid ?? 0, ...args);
  const until = (test: (out: string) => boolean, ...args: string[]): string =>
    clientUntil(probe, app.pid ?? 0, test, ...args);
  try {
    const document = until((out) => out.startsWith("Document name="), "document");
    check("a client finds the window's Document, named by the page's title",
          document === "Document name=[Form]", document);

    const tree = until((out) => out.includes("id=[buy]"), "tree");
    check("the page's elements hang under the Document",
          tree.includes("aria=[heading]") && tree.includes("id=[name]") && tree.includes("id=[agree]") &&
            tree.includes("aria=[list]") && tree.includes("id=[size]"),
          tree.split("\n").slice(0, 8).join(" | "));

    check("AutomationId is the element's id", run("get", "buy", "id") === "buy" && run("get", "agree", "id") === "agree",
          `buy=${run("get", "buy", "id")} agree=${run("get", "agree", "id")}`);
    check("an element without an id has no AutomationId", run("get", "name:Order", "id") === "",
          run("get", "name:Order", "id"));

    check("an h1 is a heading at level 1", run("get", "name:Order", "heading") === "80051",
          run("get", "name:Order", "heading"));
    check("its role and localized type are the page's",
          run("get", "name:Order", "ariarole") === "heading" &&
            run("get", "name:Order", "localized") === "heading",
          `${run("get", "name:Order", "ariarole")} ${run("get", "name:Order", "localized")}`);
    check("a landmark says which it is", run("get", "m", "landmark") === "80002", run("get", "m", "landmark"));

    check("a field's name is its placeholder", run("get", "name", "name") === "Your name", run("get", "name", "name"));
    check("a button's description is its aria-describedby",
          run("get", "buy", "description") === "Ships tomorrow", run("get", "buy", "description"));
    check("a link's value is its address", run("get", "help", "value") === "https://example.com/help",
          run("get", "help", "value"));

    const written = run("setvalue", "name", "Ada Lovelace");
    check("Value.SetValue reaches the page", written === "DONE", written);
    check("the page hears input and then change",
          logged(seen, "input Ada Lovelace") && logged(seen, "change Ada Lovelace"), seen().slice(-200));
    check("the value reads back", until((out) => out === "Ada Lovelace", "get", "name", "value") === "Ada Lovelace",
          run("get", "name", "value"));
    check("the Text pattern's DocumentRange is the value", run("get", "name", "text") === "Ada Lovelace",
          run("get", "name", "text"));
    check("a field is not read-only", run("get", "name", "readonly") === "false", run("get", "name", "readonly"));

    // An action runs once: its result is read into a variable, not run again for the detail.
    const invoked = run("invoke", "buy");
    check("Invoke presses the button", invoked === "DONE", invoked);
    check("the page's own click handler ran", logged(seen, "clicked buy Ada Lovelace"), seen().slice(-200));

    check("a checkbox starts unchecked", run("get", "agree", "toggle") === "off", run("get", "agree", "toggle"));
    check("its ARIA properties say so", run("get", "agree", "ariaproperties").includes("checked=false"),
          run("get", "agree", "ariaproperties"));
    const toggled = run("toggle", "agree");
    check("Toggle flips it", toggled === "DONE", toggled);
    check("ToggleState follows", until((out) => out === "on", "get", "agree", "toggle") === "on",
          run("get", "agree", "toggle"));
    check("and the page heard the change", logged(seen, "agree true"), seen().slice(-200));

    check("a range reports its bounds", until((out) => out === "50 0 100", "get", "vol", "range") === "50 0 100",
          run("get", "vol", "range"));
    const ranged = run("setrange", "vol", "70");
    check("RangeValue.SetValue reaches the page", ranged === "DONE", ranged);
    check("the page heard the new value", logged(seen, "vol 70"), seen().slice(-200));
    check("and the range reads back", until((out) => out === "70 0 100", "get", "vol", "range") === "70 0 100",
          run("get", "vol", "range"));

    check("ExpandCollapse opens the select's picker", run("expand", "size") === "DONE", run("expand", "size"));
    check("the select reports expanded", until((out) => out === "expanded", "get", "size", "expanded") === "expanded",
          run("get", "size", "expanded"));
    check("Collapse closes it", run("collapse", "size") === "DONE", run("collapse", "size"));
    check("and it reports collapsed", until((out) => out === "collapsed", "get", "size", "expanded") === "collapsed",
          run("get", "size", "expanded"));

    check("SelectionItem chooses a radio", run("select", "r1") === "DONE", run("select", "r1"));
    check("the radio reports selected", until((out) => out === "true", "get", "r1", "selected") === "true",
          run("get", "r1", "selected"));
    check("its sibling does not", run("get", "r2", "selected") === "false", run("get", "r2", "selected"));
    check("and the page heard the choice", logged(seen, "pick First"), seen().slice(-200));

    check("SetFocus focuses the field", run("focus", "name") === "DONE", run("focus", "name"));
    check("GetFocusedElement is that field", until((out) => out.startsWith("name "), "focused").startsWith("name "),
          run("focused"));
    check("ElementFromPoint at the button's centre finds it", run("frompoint", "buy") === "buy", run("frompoint", "buy"));
  } finally {
    if (app.pid !== undefined) spawnSync("taskkill", ["/PID", String(app.pid), "/F"], { stdio: "ignore" });
  }

  // The todo example, driven from a client: the field is found by the name its placeholder gives
  // it, a value is written into it, Add is pressed, and the new item and the count are in the tree.
  const todoExe = join(dir, "todo");
  const todoBuild = spawnSync(process.execPath,
    ["compiler/cli.ts", "build", join("..", "..", "examples", "todo"), "-o", todoExe],
    { encoding: "utf8", timeout: 1500000 });
  if (!check("the todo example builds", todoBuild.status === 0, ((todoBuild.stdout ?? "") + (todoBuild.stderr ?? "")).slice(-800)))
    return;
  const todo = spawn(todoExe + ".exe", [], { stdio: ["ignore", "pipe", "pipe"] });
  let todoLog = "";
  todo.stdout?.on("data", (chunk) => { todoLog += String(chunk); });
  const trun = (...args: string[]): string => clientRun(probe, todo.pid ?? 0, ...args);
  const tuntil = (test: (out: string) => boolean, ...args: string[]): string =>
    clientUntil(probe, todo.pid ?? 0, test, ...args);
  try {
    const todoDocument = tuntil((out) => out.startsWith("Document name="), "document");
    check("the todo example's Document is named by its title", todoDocument === "Document name=[Todos]", todoDocument);
    check("its field is named by its placeholder", trun("get", "new", "name") === "What needs doing?",
          trun("get", "new", "name"));
    check("a value written into the field reaches the page", trun("setvalue", "new", "Buy milk") === "DONE", "");
    check("Add presses", trun("invoke", "add") === "DONE", "");
    const added = tuntil((out) => out.includes("name=[Buy milk]") && out.includes("name=[1 item left]"), "tree");
    check("the new todo and the count are in the tree",
          added.includes("name=[Buy milk]") && added.includes("name=[1 item left]"), added.split("\n").slice(-8).join(" | "));
  } finally {
    if (todo.pid !== undefined) spawnSync("taskkill", ["/PID", String(todo.pid), "/F"], { stdio: "ignore" });
  }
}

try {
  main();
} finally {
  // An executable that is still being released cannot always be removed yet.
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 250 });
  } catch {
    // Leaving it in the temp directory is harmless.
  }
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
