// A style declaration answers to a property name a script computes, the way a browser's does:
// style["margin-left"], style[prop] for a camelCase prop, style.cssFloat, and
// getComputedStyle(el)[prop]. Its own members (cssText, length, the methods) keep answering, and a
// method called through that view acts on the declaration.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head><body>
<div id="d">x</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const d = document.getElementById("d") as HTMLElement;

// A named write reaches the property it spells, dashed or camelCase, and the computed value with it.
(d.style as any)["margin-left"] = "7px";
log("dashed " + d.style.marginLeft + "|" + getComputedStyle(d).marginLeft + "|" + getComputedStyle(d).getPropertyValue("margin-left"));
const dashed = "padding-top";
(d.style as any)[dashed] = "3px";
log("computed key " + (getComputedStyle(d) as any)["padding-top"] + "|" + getComputedStyle(d).paddingTop);
const camel = "paddingLeft";
(d.style as any)[camel] = "4px";
log("camel key " + d.style.paddingLeft + "|" + getComputedStyle(d).paddingLeft);

// cssFloat is the DOM's alias for float.
(d.style as any).cssFloat = "right";
log("cssFloat " + (d.style as any).cssFloat + "|" + getComputedStyle(d).float);

// A custom property, as written.
(d.style as any)["--gap"] = "5px";
log("custom " + d.style.getPropertyValue("--gap"));

// The declaration's own members answer as they did: the methods, the block text, and whether a
// name is a property at all.
log("members " + (typeof d.style.setProperty) + " " + (typeof d.style.cssText) +
  " " + ("display" in d.style) + " " + ("border-left-width" in d.style) + " " + ("nonsense" in d.style));
d.style.setProperty("height", "9px");
log("method " + d.style.height + "|" + getComputedStyle(d).height);
d.style.removeProperty("height");
log("removed " + d.style.height);

// cssText through the view replaces the whole block.
d.style.cssText = "width: 12px; color: rgb(1, 2, 3)";
log("cssText " + d.style.width + "|" + getComputedStyle(d).color + "|" + d.style.marginLeft + "|" + d.style.paddingLeft);

// A named write reaches the cascade a computed style reads, and so does the inherit a script
// writes the same way (the WPT inheritance helper does exactly this with "float" and "clear").
const p = document.createElement("div");
const kid = document.createElement("div");
document.body.appendChild(p);
p.appendChild(kid);
(p.style as any)["float"] = "left";
log("float " + getComputedStyle(p).float + "|" + getComputedStyle(p).getPropertyValue("float"));
kid.style.setProperty("float", "inherit");
log("inherit " + getComputedStyle(kid).float);
log("readback " + (kid.style as any)["float"]);
(kid.style as any)["float"] = "revert";
log("revert " + getComputedStyle(kid).float);
log("done");
`;

const EXPECTED = [
  "dashed 7px|7px|7px",
  "computed key 3px|3px",
  "camel key 4px|4px",
  "cssFloat right|right",
  "custom 5px",
  "members function string true true false",
  "method 9px|9px",
  "removed ",
  "cssText 12px|rgb(1, 2, 3)||",
  "float left|left",
  "inherit left",
  "readback inherit",
  "revert none",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-style-named-props-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 1" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
