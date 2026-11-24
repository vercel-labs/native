// The accessibility tree the host hands the platform's assistive technology: roles, names, values
// and frames for the rendered page, and nothing for what style or ARIA hides. The dump runs
// through the same host code a screen reader queries (NATIVE_AX_DUMP prints it), so it needs no
// accessibility permission. macOS names roles the way AppKit does and Linux the way AT-SPI does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=300"></head><body>
<h1>Shop</h1>
<p>Hello <b>world</b></p>
<button id="b">Buy</button>
<a href="#x">A link</a>
<input id="i" type="text" aria-label="Search" value="bees">
<input id="c" type="checkbox" checked aria-label="Agree">
<div aria-hidden="true"><button>hidden</button></div>
<h2>More</h2>
<p id="live" aria-live="polite">Ready</p>
<button id="go">Refresh</button>
<input id="val" value="one" aria-label="Amount">
<script>
document.getElementById("go").addEventListener("click", function () {
  document.getElementById("live").textContent = "Updated";
});
</script>
</body></html>`;

/** The role names the dump prints: AppKit's on macOS, AT-SPI's on Linux. */
const ROLES = process.platform === "darwin"
  ? { heading: "AXHeading", staticText: "AXStaticText", button: "AXButton", link: "AXLink",
      textField: "AXTextField", checkBox: "AXCheckBox" }
  : { heading: "heading", staticText: "static", button: "button", link: "link",
      textField: "entry", checkBox: "check box" };

/** The line a role and a label describe, whatever else the dump says about it. */
function roleLine(role: string, label: string): RegExp {
  return new RegExp(`${role} .*label=\\[${label}\\]`);
}

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-accessibility-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_AX_DUMP: "1", NATIVE_STEPS: "frame 2" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const out = r.stdout.split("\n");
const at = out.findIndex((l) => l.startsWith("AX TREE"));
const end = out.findIndex((l) => l.startsWith("AX END"));
check("the host builds a tree", at >= 0 && end > at, `tree ${at}..${end}`);
const lines = at >= 0 && end > at ? out.slice(at + 1, end).map((l) => l.trim()).filter((l) => l !== "") : [];
for (const line of lines) console.log(`     tree ${line}`);

const find = (re: RegExp): string => lines.find((l) => re.test(l)) ?? "";
const heading = find(roleLine(ROLES.heading, "Shop"));
check("a heading is a heading with its text", heading !== "", heading);
check("the paragraph reads as one static-text stop", find(roleLine(ROLES.staticText, "Hello world")) !== "",
  find(new RegExp(`${ROLES.staticText} `)));
const button = find(roleLine(ROLES.button, "Buy"));
check("a button carries its label", button !== "", button);
check("and a frame assistive technology can point at",
  / (\d+)x(\d+) /.test(button) && !/ 0x0 /.test(button), button);
const link = find(roleLine(ROLES.link, "A link"));
check("an inline link has the width of its line fragments", link !== "" && !/ 0x0 /.test(link), link);
const field = find(new RegExp(`${ROLES.textField} .*label=\\[Search\\] value=\\[bees\\]`));
check("a text field carries its name and value", field !== "", field);
const box = find(new RegExp(`${ROLES.checkBox} .*label=\\[Agree\\] value=\\[1\\]`));
check("a checked box says it is checked", box !== "", box);
check("an aria-hidden subtree is left out", !lines.some((l) => l.includes("[hidden]")),
  lines.find((l) => l.includes("[hidden]")) ?? "");
check("the tree keeps document order", lines.findIndex((l) => l.includes("[Shop]")) <
  lines.findIndex((l) => l.includes("[More]")), "");

// A click that focuses the button marks that node: assistive technology is told the focus changed.
const env2: NodeJS.ProcessEnv = { ...env, NATIVE_STEPS: "click #b | frame 2" };
const r2 = spawnSync(exe, [], { encoding: "utf8", env: env2 });
if (r2.status !== 0) throw new Error(`render failed\n${r2.stderr}`);
const out2 = r2.stdout.split("\n");
// The click's frame dumps the tree a second time, with the focused control marked.
const run2 = out2.filter((l) => l.includes(ROLES.button) || l.includes("focused"));
for (const line of run2) console.log(`     focused run ${line.trim()}`);
const focused = run2.find((l) => l.includes("focused"));
check("the focused control is marked focused", focused !== undefined && focused.includes(ROLES.button),
  focused ?? "no focused node");

// A live region's new text is announced, and a control whose value moved says so.
const env3: NodeJS.ProcessEnv = { ...env, NATIVE_STEPS: "click #go | frame 2 | click #val | key End | type xyz | frame 2" };
const r3 = spawnSync(exe, [], { encoding: "utf8", env: env3 });
if (r3.status !== 0) throw new Error(`render failed\n${r3.stderr}`);
check("a live region's new text is announced", r3.stdout.includes("AX ANNOUNCE 0 [Updated]"),
  r3.stdout.split("\n").find((l) => l.startsWith("AX ANNOUNCE")) ?? "no announcement");
check("a control's value change is reported", r3.stdout.includes("AX VALUE "),
  r3.stdout.split("\n").find((l) => l.startsWith("AX VALUE")) ?? "no value change");
const typed = r3.stdout.split("\n").find((l) => l.includes("value=[onexyz]")) ?? "";
check("the field reports its caret and line", typed.includes("sel=6,0 line=0"), typed);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
