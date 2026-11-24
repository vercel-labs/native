// A real custom element: <my-card> attaches a shadow tree in its constructor, styles it with
// :host and ::slotted, fills a named and a default slot, and a click on a slotted button answers
// composedPath(). The whole app is built and run.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"></head><body>
<my-card id="card"><span slot="title">Title</span><button id="btn">Go</button></my-card>
<button id="outside">out</button>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
class MyCard extends HTMLElement {
  constructor() {
    super();
    const root = this.attachShadow({ mode: "open" });
    root.innerHTML = '<style>'
      + ':host { display: block; border: 2px solid rgb(10, 20, 30); padding: 4px; }'
      + '::slotted(button) { color: rgb(1, 2, 3); }'
      + 'h2 { color: rgb(4, 5, 6); }'
      + '</style><h2><slot name="title"></slot></h2><slot></slot>';
  }
}
customElements.define("my-card", MyCard);

function probe(): void {
  const card = document.getElementById("card") as HTMLElement;
  const btn = document.getElementById("btn")!;
  const outside = document.getElementById("outside")!;
  const root = card.shadowRoot!;
  const h2 = root.querySelector("h2")!;
  const titleSlot = root.querySelector('slot[name="title"]') as HTMLSlotElement;
  const defaultSlot = root.querySelector("slot:not([name])") as HTMLSlotElement;
  let slottedPath = "";
  let slottedHost = "";
  let hostSaw = "";
  btn.addEventListener("click", (e: Event) => {
    slottedPath = e.composedPath().map((n: any) => n.localName || n.nodeName).join(">");
  });
  card.addEventListener("click", (e: Event) => {
    hostSaw = (e.target as any).localName + "/" + e.composedPath().length;
  });
  btn.click();
  slottedHost = hostSaw;
  h2.click();
  console.log("OUT "
    + "|border=" + getComputedStyle(card).borderTopColor
    + "|pad=" + getComputedStyle(card).paddingTop
    + "|btnColor=" + getComputedStyle(btn).color
    + "|outsideColor=" + getComputedStyle(outside).color
    + "|h2Color=" + getComputedStyle(h2).color
    + "|slottedPath=" + slottedPath
    + "|slottedHost=" + slottedHost
    + "|innerHost=" + hostSaw
    + "|titleSlots=" + titleSlot.assignedNodes().length
    + "|defaultSlots=" + defaultSlot.assignedNodes().length);
}
probe();
`;

const dir = mkdtempSync(join(tmpdir(), "native-my-card-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
const field = (name: string): string => {
  const at = got.indexOf("|" + name + "=");
  if (at < 0) return "";
  const start = at + name.length + 2;
  const end = got.indexOf("|", start);
  return got.slice(start, end < 0 ? got.length : end);
};
check("the card is upgraded and attached its shadow tree", got !== "", got);
check(":host styles the card", field("border") === "rgb(10, 20, 30)" && field("pad") === "4px", got);
check("::slotted(button) styles the button the default slot took", field("btnColor") === "rgb(1, 2, 3)", got);
check("::slotted(button) leaves a page button alone", field("outsideColor") === "rgb(0, 0, 0)", got);
check("the shadow tree's own h2 rule applies", field("h2Color") === "rgb(4, 5, 6)", got);
check("a click on the slotted button composes its path through the slot and the page",
  field("slottedPath") === "button>slot>#document-fragment>my-card>body>html>#document", got);
check("the page sees the slotted button as its target", field("slottedHost") === "button/5", got);
check("a click inside the shadow tree reaches the host retargeted", field("innerHost") === "my-card/4", got);
check("the named slot took one node", field("titleSlots") === "1", got);
check("the default slot took one node", field("defaultSlots") === "1", got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
