// The customElements registry: a defined tag makes elements of its class, the elements already
// in the tree are upgraded, and their class hears about connection and attributes.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"></head><body>
<p id="out">ready</p>
<my-btn id="a" label="A"></my-btn>
<my-btn id="b" label="B"></my-btn>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
let connected = 0;
let disconnected = 0;

class MyBtn extends HTMLElement {
  connectedCallback(): void {
    connected++;
    log("+ " + this.id);
  }
  disconnectedCallback(): void {
    disconnected++;
    log("- " + this.id);
  }
  attributeChangedCallback(name: string, oldValue: string | null, value: string | null): void {
    log("= " + this.id + " " + name + " " + String(oldValue) + " " + String(value));
  }
}

// A detached tree made before the definition keeps plain elements until it is upgraded.
const pre = document.createElement("div");
pre.innerHTML = '<my-btn id="pre" label="P"></my-btn>';
log("pre before " + String(pre.firstElementChild instanceof MyBtn));

// --- define() upgrades the elements already in the tree, attributes first, then connected
customElements.define("my-btn", MyBtn as unknown as CustomElementConstructor);
const a = document.getElementById("a") as HTMLElement;
const b = document.getElementById("b") as HTMLElement;
log("upgraded " + String(a instanceof MyBtn) + " " + String(b instanceof MyBtn) + " " +
  a.tagName + "/" + a.localName + " " + a.getAttribute("label"));
log("counts " + String(connected) + " " + String(disconnected));

// --- attribute changes reach the class: any attribute, the id, class, style and hidden too
a.setAttribute("label", "A2");
a.setAttribute("label", "A2");
a.removeAttribute("label");
a.id = "aa";
a.className = "big";
a.style.setProperty("color", "red");
a.setAttribute("style", "color: blue");
a.hidden = true;
a.hidden = false;
log("attrs " + String(a.getAttribute("label")) + " " + a.id + " " + a.className);

// --- an element a script builds is of the class, and reports connected on insertion
const made = document.createElement("my-btn") as MyBtn;
made.id = "made";
log("made " + String(made instanceof MyBtn) + " " + made.localName + " " + made.tagName);
document.body.appendChild(made);
log("inserted " + String(connected) + " " + String(made.isConnected));

// --- leaving the document, and coming back
b.remove();
log("removed " + String(disconnected) + " " + String(b.isConnected));
document.body.appendChild(b);
log("again " + String(connected) + " " + String(disconnected));

// --- markup makes the class, and a copy is of the class with its attributes
const box = document.createElement("div");
box.innerHTML = '<my-btn id="parsed"></my-btn>';
const parsed = box.firstElementChild as MyBtn;
const copy = a.cloneNode(false) as MyBtn;
log("parsed " + String(parsed instanceof MyBtn) + " copy " + String(copy instanceof MyBtn) +
  " " + copy.id + " " + copy.getAttribute("style"));

// --- the registry: get, define again, a name without a dash, whenDefined
log("get " + String(customElements.get("my-btn") === (MyBtn as unknown as CustomElementConstructor)) +
  " " + String(customElements.get("none-yet") === undefined));
let threw = "";
try {
  customElements.define("my-btn", MyBtn as unknown as CustomElementConstructor);
} catch (e) {
  threw = String(e);
}
log("duplicate " + (threw.indexOf("NotSupportedError") >= 0 ? "NotSupportedError" : threw));
threw = "";
try {
  customElements.define("nodash", MyBtn as unknown as CustomElementConstructor);
} catch (e) {
  threw = String(e);
}
log("bad name " + (threw.indexOf("SyntaxError") >= 0 ? "SyntaxError" : threw));
customElements.whenDefined("my-btn").then((ctor) => {
  log("defined " + String(new ctor() instanceof HTMLElement));
});
let never = false;
customElements.whenDefined("never-el").then(() => {
  never = true;
});

// --- upgrade() takes a detached tree's children, and insertion connects them
customElements.upgrade(pre);
log("pre after " + String(pre.firstElementChild instanceof MyBtn));
document.body.appendChild(pre);
log("pre inserted " + String(connected) + " " + String(disconnected));

// --- replacing a connected element's children reports it disconnected
const out = document.getElementById("out") as HTMLElement;
out.replaceChildren(made);
log("moved " + String(connected) + " " + String(disconnected) + " " + String(made.parentNode === out));
out.replaceChildren();
log("emptied " + String(connected) + " " + String(disconnected) + " " + String(made.isConnected));

setTimeout(() => {
  log("pending " + String(never));
}, 0);
`;

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-custom-elements-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
// A failing run prints what it got, so the lines it missed can be read side by side.
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
const EXPECTED_LOG = [
  "pre before false",
  "= a id null a",
  "= a label null A",
  "= b id null b",
  "= b label null B",
  "+ a",
  "+ b",
  "upgraded true true MY-BTN/my-btn A",
  "counts 2 0",
  "= a label A A2",
  "= a label A2 null",
  "= aa id a aa",
  "= aa class null big",
  "= aa style color: rgb(255, 0, 0); color: rgb(0, 0, 255);",
  "= aa hidden null ",
  "= aa hidden  null",
  "attrs null aa big",
  "= made id null made",
  "made true my-btn MY-BTN",
  "+ made",
  "inserted 3 true",
  "- b",
  "removed 1 false",
  "+ b",
  "again 4 1",
  "= parsed id null parsed",
  "parsed true copy true aa color: rgb(0, 0, 255);",
  "get true true",
  "duplicate NotSupportedError",
  "bad name SyntaxError",
  "= pre id null pre",
  "= pre label null P",
  "pre after true",
  "+ pre",
  "pre inserted 5 1",
  "- made",
  "+ made",
  "moved 6 2 true",
  "- made",
  "emptied 6 3 false",
  "defined true",
  "pending false",
];

const want = EXPECTED_LOG;
// Compare line by line so a mismatch names the first line that differs.
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
