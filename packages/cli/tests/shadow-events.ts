// An event that crosses a shadow boundary is retargeted for listeners outside it, and its
// composed path shows each listener the nodes it can see.
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
<html><head><meta name="native-window" content="width=200, height=100"></head><body>
<div id="host"><p id="light">light</p></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function probe(): void {
  const host = document.getElementById("host")!;
  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = '<slot></slot><p id="inner">inner</p>';
  const inner = root.querySelector("#inner")!;
  const slot = root.querySelector("slot")!;
  const light = document.getElementById("light")!;
  const log: string[] = [];
  const name = (n: any) => n === inner ? "inner" : n === light ? "light" : n === host ? "host" : n === slot ? "slot" : "other";
  inner.addEventListener("ping", (e: Event) => { log.push("inner t=" + name(e.target) + " p=" + e.composedPath().length); });
  slot.addEventListener("ping", (e: Event) => { log.push("slot t=" + name(e.target) + " p=" + e.composedPath().length); });
  root.addEventListener("ping", (e: Event) => { log.push("root t=" + name(e.target) + " p=" + e.composedPath().length); });
  host.addEventListener("ping", (e: Event) => { log.push("host t=" + name(e.target) + " p=" + e.composedPath().length); });
  document.addEventListener("ping", (e: Event) => { log.push("doc t=" + name(e.target) + " p=" + e.composedPath().length); });
  inner.dispatchEvent(new Event("ping", { bubbles: true, composed: true }));
  log.push("--");
  inner.dispatchEvent(new Event("ping", { bubbles: true }));
  log.push("--");
  light.dispatchEvent(new Event("ping", { bubbles: true, composed: true }));
  log.push("--");
  // A non-bubbling event still reaches the host it is retargeted to, at the target phase.
  host.addEventListener("nop", (e: Event) => { log.push("nop-host t=" + name(e.target)); });
  document.addEventListener("nop", (e: Event) => { log.push("nop-doc"); });
  inner.dispatchEvent(new Event("nop", { composed: true }));
  log.push("--");
  // Once dispatch is over there is no path left to report.
  const pd = new Event("pd", { bubbles: true, composed: true });
  inner.dispatchEvent(pd);
  log.push("postPath=" + pd.composedPath().length);
  // An event that never left its shadow tree drops its target once dispatch is over.
  const nc = new Event("ncx", { bubbles: true });
  inner.dispatchEvent(nc);
  log.push("postTarget=" + (nc.target === null ? "null" : "set"));
  // A composed event keeps the target it would have had with no listener: the host.
  log.push("composedPostTarget=" + (pd.target === host ? "host" : "other"));
  // At the target, capture listeners run before bubble listeners whatever order they were added.
  const order: string[] = [];
  document.addEventListener("ord", () => { order.push("doc"); });
  inner.addEventListener("ord", () => { order.push("bubble"); });
  inner.addEventListener("ord", () => { order.push("capture"); }, true);
  inner.dispatchEvent(new Event("ord", { bubbles: true }));
  log.push("order=" + order.join(","));
  log.push("--");
  // A related target retargets for the listener; a related target that is the target itself
  // ends the path at the tree's root, so the page never hears it.
  let relatedRoot = "";
  let relatedDoc = "";
  root.addEventListener("rt", (e: Event) => { relatedRoot = name(e.target) + ">" + name((e as MouseEvent).relatedTarget); });
  document.addEventListener("rt", () => { relatedDoc = "heard"; });
  inner.dispatchEvent(new MouseEvent("rt", { bubbles: true, composed: true, relatedTarget: inner }));
  log.push("related root=" + relatedRoot + " doc=" + relatedDoc);
  log.push("--");
  // A closed tree's nodes are hidden from listeners outside it, but the listener inside sees all.
  const host2 = document.createElement("div");
  document.body!.appendChild(host2);
  const root2 = host2.attachShadow({ mode: "closed" });
  root2.innerHTML = '<p id="inner2">x</p>';
  const inner2 = root2.querySelector("#inner2")!;
  let closedDoc = "";
  let closedRoot = "";
  document.addEventListener("cl2", (e: Event) => { closedDoc = (e.target as any).localName + "/" + e.composedPath().length; });
  root2.addEventListener("cl2", (e: Event) => { closedRoot = (e.target as any).localName + "/" + e.composedPath().length; });
  const cc = new Event("cl2", { bubbles: true, composed: true });
  inner2.dispatchEvent(cc);
  log.push("closed-doc " + closedDoc + " closed-root " + closedRoot
    + " closedPostTarget=" + (cc.target === host2 ? "host2" : cc.target === null ? "null" : "other"));
  console.log("OUT " + log.join(" | "));
}
console.log("BEFORE");
probe();
console.log("AFTER");
`;

const dir = mkdtempSync(join(tmpdir(), "native-shadow-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame 1" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "").trim();
// A composed event from the shadow tree: the inside listener sees the inner target and the whole
// path; the host and document see the host as the target (open trees stay visible).
const composed = "inner t=inner p=6 | root t=inner p=6 | host t=host p=6 | doc t=host p=6";
// An uncomposed one stops at the shadow root.
const uncomposed = "inner t=inner p=2 | root t=inner p=2";
// A slotted node's event travels through the slot it was given to; the node is in the page's
// tree, so it is its own target everywhere.
const slotted = "slot t=light p=7 | root t=light p=7 | host t=light p=7 | doc t=light p=7";
// The ord event is not composed, so the document never hears it; the target captures first.
const want = `${composed} | -- | ${uncomposed} | -- | ${slotted} | -- | nop-host t=host | -- | postPath=0 | postTarget=null | composedPostTarget=host | order=capture,bubble | -- | related root=inner>inner doc= | -- | closed-doc div/4 closed-root p/6 closedPostTarget=host2`;
check("retargeting and composedPath across a shadow boundary", got === want, `got ${JSON.stringify(got)}`);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
