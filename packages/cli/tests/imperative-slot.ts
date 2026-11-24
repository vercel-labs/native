// Imperative slot assignment: a manual shadow root's slot takes exactly the nodes assign() gives
// it, a node moves between slots, and the assignment is validated as the DOM says.
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
<div id="host"><span id="c1">one</span><span id="c2">two</span></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function probe(): void {
  const host = document.getElementById("host")!;
  const root = host.attachShadow({ mode: "open", slotAssignment: "manual" });
  root.innerHTML = '<slot id="s1"></slot><slot id="s2"></slot>';
  const s1 = root.querySelector("#s1") as HTMLSlotElement;
  const s2 = root.querySelector("#s2") as HTMLSlotElement;
  const c1 = document.getElementById("c1")!;
  const c2 = document.getElementById("c2")!;
  let changes = 0;
  s1.addEventListener("slotchange", () => { changes++; });
  s2.addEventListener("slotchange", () => { changes++; });
  s1.assign(c1);
  const a1 = s1.assignedNodes().length;
  const slotOf1 = c1.assignedSlot === s1 ? "s1" : "other";
  s1.assign(c1, c2);
  const a2 = s1.assignedNodes().length;
  s2.assign(c1);
  const a3 = s1.assignedNodes().length;
  const b1 = s2.assignedNodes().length;
  const slotOf2 = c1.assignedSlot === s2 ? "s2" : "other";
  let threw = false;
  try { s1.assign(["x"] as any); } catch (e) { threw = true; }
  let badMode = false;
  try { document.createElement("div").attachShadow({ mode: "open", slotAssignment: "exceptional" }); } catch (e) { badMode = true; }
  const named = document.createElement("div").attachShadow({ mode: "open" });
  console.log("OUT "
    + "|a1=" + a1 + "|slotOf1=" + slotOf1
    + "|a2=" + a2
    + "|a3=" + a3 + "|b1=" + b1 + "|slotOf2=" + slotOf2
    + "|threw=" + threw + "|badMode=" + badMode
    + "|changes=" + changes
    + "|namedAssignment=" + named.slotAssignment
    + "|manualAssignment=" + root.slotAssignment);
}
probe();
`;

const dir = mkdtempSync(join(tmpdir(), "native-imperative-slot-"));
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
check("assign puts a node in the slot", field("a1") === "1" && field("slotOf1") === "s1", got);
check("assign takes the whole list", field("a2") === "2", got);
check("assigning a node to another slot moves it", field("a3") === "1" && field("b1") === "1" && field("slotOf2") === "s2", got);
check("a non-node is refused", field("threw") === "true", got);
check("an unknown slot assignment mode is refused", field("badMode") === "true", got);
check("each changed slot fired slotchange", field("changes") === "4", got);
check("a root with no mode is named", field("namedAssignment") === "named", got);
check("the manual root reports its mode", field("manualAssignment") === "manual", got);
console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
