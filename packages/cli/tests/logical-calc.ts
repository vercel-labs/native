// Math functions in the logical margin, padding, inset and scroll properties take the same values
// their physical spellings do: a calc() (or min()/max()/clamp() of one) parses on a two-sided
// shorthand even though its spaces sit inside the function, on every longhand, and in a value that
// a var() only completes at style time.
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
<html><head><meta name="native-window" content="width=300, height=300"><style>
:root { --spacing: 0.25rem; }
body { margin: 0; font-size: 16px; }
#pad { padding-inline: calc(0.25rem * 4); }
#pad2 { padding-inline: calc(4px * 3) calc(2px * 5); }
#padb { padding-block: calc(2px * 6); }
#marg { margin-inline: calc(5px + 5px) 3px; }
#margb { margin-block: calc(1px + 2px) calc(2px * 2); }
#ins { position: absolute; inset-inline: calc(2px * 5); }
#insb { position: absolute; inset-block: calc(3px * 5) calc(1px + 9px); }
#sm { scroll-margin-inline: calc(2px * 2); }
#sp { scroll-padding-block: calc(2px * 3) calc(1px * 4); }
#long { position: relative; padding-inline-start: calc(4px * 9); margin-block-end: calc(2px * 7);
  inset-inline-start: calc(3px * 11); border-inline-start: calc(1px * 2) solid rgb(0, 0, 0); }
#math { position: absolute; left: 0; top: 0;
  padding-inline: max(4px, calc(2px * 4)); margin-inline: clamp(2px, calc(3px * 2), 20px); }
#math > div { width: 10px; height: 10px; }
#tw { padding-inline: calc(var(--spacing) * 4); padding-block: calc(var(--spacing) * 2); }
#bw { border-block-width: calc(2px * 2) calc(1px * 3); border-block-style: solid; }
#rad { border-start-start-radius: calc(4px * 2); }
#size { inline-size: calc(50px * 2); }
</style></head><body>
<div id="pad"></div><div id="pad2"></div><div id="padb"></div><div id="marg"></div>
<div id="margb"></div><div id="ins"></div><div id="insb"></div><div id="sm"></div>
<div id="sp"></div><div id="long"></div><div id="math"><div></div></div><div id="tw"></div>
<div id="bw"></div><div id="rad"></div><div id="size"></div>
<div id="rt"></div><div id="rt2"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const cs = (id: string) => getComputedStyle(document.getElementById(id)!);
const rt = document.getElementById("rt")!;
rt.style.setProperty("padding-inline", "calc(4px * 5)");
rt.style.setProperty("margin-block-start", "calc(2px * 6)");
const rt2 = document.getElementById("rt2")!;
rt2.style.paddingInlineStart = "calc(1px * 8)";
requestAnimationFrame(() => requestAnimationFrame(() => {
  const out: string[] = [];
  const log = (name: string, value: string): void => { out.push(name + "=" + value); };
  const p = cs("pad");
  log("pad.inline", p.paddingInlineStart + " " + p.paddingInlineEnd);
  log("pad.physical", p.paddingLeft + " " + p.paddingRight);
  const p2 = cs("pad2");
  log("pad2.inline", p2.paddingInlineStart + " " + p2.paddingInlineEnd);
  log("pad2.physical", p2.paddingLeft + " " + p2.paddingRight);
  const pb = cs("padb");
  log("padb.inline", pb.paddingBlockStart + " " + pb.paddingBlockEnd);
  log("padb.physical", pb.paddingTop + " " + pb.paddingBottom);
  const m = cs("marg");
  log("marg.inline", m.marginInlineStart + " " + m.marginInlineEnd);
  log("marg.physical", m.marginLeft + " " + m.marginRight);
  const mb = cs("margb");
  log("margb.inline", mb.marginBlockStart + " " + mb.marginBlockEnd);
  log("margb.physical", mb.marginTop + " " + mb.marginBottom);
  log("ins.inline", cs("ins").left + " " + cs("ins").right);
  log("insb.inline", cs("insb").top + " " + cs("insb").bottom);
  log("sm.inline", cs("sm").scrollMarginInlineStart);
  log("sp.inline", cs("sp").scrollPaddingBlockStart + " " + cs("sp").scrollPaddingBlockEnd);
  const l = cs("long");
  log("long.start", l.paddingInlineStart + " " + l.marginBlockEnd + " " + l.left + " " + l.borderInlineStartWidth);
  // min()/max()/clamp() stay expressions until layout, so the child's position is what shows them.
  const mc = document.getElementById("math")!.firstElementChild!.getBoundingClientRect();
  log("math.child", mc.left + " " + mc.top);
  const tw = cs("tw");
  log("tailwind", tw.paddingInlineStart + " " + tw.paddingBlockStart);
  log("border-width", cs("bw").borderTopWidth + " " + cs("bw").borderBottomWidth);
  log("radius", cs("rad").borderTopLeftRadius);
  log("size", cs("size").inlineSize);
  log("runtime.shorthand", getComputedStyle(rt).paddingLeft + " " + getComputedStyle(rt).paddingRight
    + " " + getComputedStyle(rt).marginTop);
  log("runtime.longhand", getComputedStyle(rt2).paddingLeft);
  console.log("OUT " + out.join("|"));
}));
`;

const DIR = mkdtempSync(join(tmpdir(), "native-logical-calc-"));
writeFileSync(join(DIR, "index.html"), PAGE);
writeFileSync(join(DIR, "app.ts"), SCRIPT);
const exe = join(DIR, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", DIR, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build accepts math functions on the logical properties", !/unsupported/.test(`${b.stdout}${b.stderr}`),
  `${b.stdout}${b.stderr}`);

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame | frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const line = (r.stdout + r.stderr).split("\n").find((l) => l.startsWith("OUT ")) ?? "";
const got = line.replace(/^OUT /, "");
const field = (name: string): string => {
  const at = got.indexOf(name + "=");
  if (at < 0 || (at > 0 && got[at - 1] !== "|")) return "";
  const start = at + name.length + 1;
  const end = got.indexOf("|", start);
  return got.slice(start, end < 0 ? got.length : end);
};

check("padding-inline: calc(0.25rem * 4)", field("pad.inline") === "16px 16px" && field("pad.physical") === "16px 16px", got);
check("padding-inline: a start and an end calc()", field("pad2.inline") === "12px 10px" && field("pad2.physical") === "12px 10px", got);
check("padding-block: calc()", field("padb.inline") === "12px 12px" && field("padb.physical") === "12px 12px", got);
check("margin-inline: calc() then a length", field("marg.inline") === "10px 3px" && field("marg.physical") === "10px 3px", got);
check("margin-block: two calc()s", field("margb.inline") === "3px 4px" && field("margb.physical") === "3px 4px", got);
check("inset-inline: calc()", field("ins.inline") === "10px 10px", got);
check("inset-block: two calc()s", field("insb.inline") === "15px 10px", got);
check("scroll-margin-inline: calc()", field("sm.inline") === "4px", got);
check("scroll-padding-block: two calc()s", field("sp.inline") === "6px 4px", got);
check("logical longhands take calc()", field("long.start") === "36px 14px 33px 2px", got);
check("min()/max()/clamp() of calc()", field("math.child") === "14 0", got);
check("Tailwind v4's calc(var(--spacing) * 4)", field("tailwind") === "16px 8px", got);
check("border-block-width: two calc()s", field("border-width") === "4px 3px", got);
check("a logical corner radius takes calc()", field("radius") === "8px", got);
check("inline-size takes calc()", field("size") === "100px", got);
check("an inline style's logical shorthand takes calc()", field("runtime.shorthand") === "20px 20px 12px", got);
check("an inline style's logical longhand takes calc()", field("runtime.longhand") === "8px", got);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
