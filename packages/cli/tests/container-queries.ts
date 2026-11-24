// Container queries: `container-type`/`container-name`/the `container` shorthand, `@container` with
// the size features and their ranges, and/or/not, a missing container reading as unknown, the cq
// units, the size containment a container-type implies, and the extra style pass a query needs
// when the size it reads only exists after layout.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=600, height=400"><style>
body { margin: 0; font-size: 16px; }
.q { height: 10px; }

/* The nearest container decides: 300px wide, so only the 200px query applies. */
#c1 { container-type: inline-size; width: 300px; }
#c1 .q { width: 10px; }
@container (min-width: 200px) { #c1 .q { width: 40px; } }
@container (min-width: 400px) { #c1 .q { width: 80px; } }

/* A named container is only found by a query with its name. */
#c2 { container-type: inline-size; container-name: side; width: 250px; }
#c2 .a { width: 11px; }
#c2 .b { width: 12px; }
@container side (width > 249px) { #c2 .a { width: 30px; } }
@container other (width > 1px) { #c2 .b { width: 99px; } }

/* The shorthand, a chained range, and not(). */
#c3 { container: card / inline-size; width: 260px; }
#c3 .a { width: 13px; }
#c3 .b { width: 14px; }
#c3 .c { width: 15px; }
@container card (200px <= width <= 300px) { #c3 .a { width: 32px; } }
@container card ((width > 500px) or (width < 100px)) { #c3 .b { width: 33px; } }
@container card (not (width > 500px)) { #c3 .c { width: 34px; } }

/* The block axis, the ratio and the orientation need container-type: size. */
#c4 { container-type: size; width: 100px; height: 50px; }
#c4 .a { height: 11px; }
#c4 .b { height: 12px; }
#c4 .c { height: 13px; }
#c4 .d { height: 14px; }
@container (min-height: 40px) { #c4 .a { height: 21px; } }
@container (orientation: landscape) { #c4 .b { height: 22px; } }
@container (aspect-ratio > 1.5) { #c4 .c { height: 23px; } }
@container (aspect-ratio < 1.5) { #c4 .d { height: 24px; } }

/* cq units measure the nearest container, and fall back to the viewport on an axis it has none. */
#c5 { container-type: inline-size; width: 400px; }
#c5 .a { width: 12px; }
#c5 .b { width: 13px; }
#c4 .e { width: 14px; }
#c4 .f { width: 15px; }
@container (min-width: 1px) {
  #c5 .a { width: 50cqw; }
  #c5 .b { width: 10cqh; }
  #c4 .e { width: 50cqw; }
  #c4 .f { width: 50cqi; }
}

/* Size containment: the content doesn't size a container-type: size box. */
#c6 { container-type: size; width: 80px; }
#c6 .tall { height: 200px; }
/* ... and inline-size containment sizes an auto-width inline-block at zero. */
#c7 { container-type: inline-size; display: inline-block; }
#c7 .w { width: 120px; height: 10px; }

/* A style query finds the nearest container, even one that is only a container by name. */
#c8 { container-name: theme; --mode: dark; }
#c8 .q { width: 16px; height: 10px; }
@container theme style(--mode: dark) { #c8 .q { width: 70px; } }
@container theme style(--mode: light) { #c8 .q { height: 90px; } }

/* The container is an ancestor, never the element itself. */
#self { container-type: inline-size; width: 120px; padding-left: 0; }
@container (width > 50px) { #self { padding-left: 9px; } }

/* A percentage width only settles in layout, so the query needs a second style pass. */
#c9 { container-type: inline-size; width: 50%; }
#c9 .q { width: 17px; height: 10px; }
@container (min-width: 250px) { #c9 .q { width: 60px; } }

/* An inline-size-only container can't answer a block-axis query, even with the size it has. */
#c10 { container-type: inline-size; width: 200px; height: 30px; }
#c10 .q { width: 18px; height: 10px; }
@container (min-height: 1px) { #c10 .q { width: 44px; } }

/* A cq unit inside a calc() or a max() measures the container as a plain one does. */
#c12 { container-type: inline-size; width: 200px; }
#c12 .a { height: 10px; width: calc(50cqw - 10px); }
#c12 .b { height: 10px; width: max(10px, 25cqw); }

/* A comma-separated condition list is an or: either side matching applies the rule. */
#c13 { container-type: inline-size; width: 200px; }
#c13 .q { width: 20px; height: 10px; }
@container (width < 100px), (width > 150px) { #c13 .q { width: 45px; } }
@container (width < 100px), (width > 400px) { #c13 .r { width: 46px; } }

/* cq units in values the style pass leaves unresolved: a transform, a shadow, a grid track,
   the clip margin, and a calc() of them. */
#c14 { container-type: inline-size; width: 300px; }
#c14 .t { width: 10px; height: 10px; transform: translateX(50cqw); }
#c14 .u { width: 10px; height: 10px; transform: translateX(calc(50cqw - 10px)); }
#c14 .s { width: 10px; height: 10px; box-shadow: 10cqw 0 0 red; }
#c14 .g { display: grid; grid-template-columns: 25cqw 10px; }
#c14 .m { width: 10px; height: 10px; overflow: hidden; overflow-clip-margin: 5cqw; }

/* A runtime sheet's @container rule applies like a compiled one, inside its @media too. */
#c11 { container-type: inline-size; width: 150px; }
#c11 .q { width: 19px; height: 10px; }
</style></head><body>
<div id="c1"><div class="q" id="q1"></div></div>
<div id="c2"><div class="a" id="q2a"></div><div class="b" id="q2b"></div></div>
<div id="c3"><div class="a" id="q3a"></div><div class="b" id="q3b"></div><div class="c" id="q3c"></div></div>
<div id="c4"><div class="a" id="q4a"></div><div class="b" id="q4b"></div><div class="c" id="q4c"></div>
  <div class="d" id="q4d"></div><div class="e" id="q4e"></div><div class="f" id="q4f"></div></div>
<div id="c5"><div class="a" id="q5a"></div><div class="b" id="q5b"></div></div>
<div id="c6"><div class="tall"></div></div>
<div id="c7"><div class="w"></div></div>
<div id="c8"><div class="q" id="q8"></div></div>
<div id="self"></div>
<div id="c9"><div class="q" id="q9"></div></div>
<div id="c10"><div class="q" id="q10"></div></div>
<div id="c11"><div class="q" id="q11"></div></div>
<div id="c12"><div class="a" id="q12a"></div><div class="b" id="q12b"></div></div>
<div id="c13"><div class="q" id="q13"></div></div>
<div id="c14"><div class="t" id="q14t"></div><div class="u" id="q14u"></div><div class="s" id="q14s"></div>
  <div class="g" id="q14g"><div id="q14g1"></div></div><div class="m" id="q14m"></div></div>
<script type="module">
const runtime = new CSSStyleSheet();
runtime.replaceSync("@container (min-width: 100px) { #q11 { width: 65px; } }" +
  " @media (min-width: 500px) { @container (min-width: 100px) { #q11 { height: 66px; } } }" +
  " @container (min-width: 900px) { #q11 { padding-left: 7px; } }");
document.adoptedStyleSheets = [runtime];
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const rect = (sel: string): DOMRect => document.querySelector(sel)!.getBoundingClientRect();
    const log = (name: string, value: string): void => { console.log(name + " " + value); };
    log("min-width", rect("#q1").width + "");
    log("named", rect("#q2a").width + " " + rect("#q2b").width);
    log("range", rect("#q3a").width + " " + rect("#q3b").width + " " + rect("#q3c").width);
    log("block", rect("#q4a").height + " " + rect("#q4b").height + " " + rect("#q4c").height + " " + rect("#q4d").height);
    log("units", rect("#q5a").width + " " + rect("#q5b").width + " " + rect("#q4e").width + " " + rect("#q4f").width);
    log("size containment", rect("#c6").height + "");
    log("inline containment", rect("#c7").width + "");
    log("style query", rect("#q8").width + " " + rect("#q8").height);
    log("self", getComputedStyle(document.querySelector("#self")!, "").paddingLeft);
    log("second pass", rect("#q9").width + "");
    log("block axis needs size", rect("#q10").width + "");
    log("calc units", rect("#q12a").width + " " + rect("#q12b").width);
    log("comma list", rect("#q13").width + "");
    const t = getComputedStyle(document.querySelector("#q14t")!, "");
    const u = getComputedStyle(document.querySelector("#q14u")!, "");
    const sh = getComputedStyle(document.querySelector("#q14s")!, "");
    const m = getComputedStyle(document.querySelector("#q14m")!, "");
    log("paint units", t.transform + " | " + u.transform + " | " + sh.getPropertyValue("box-shadow") + " | " + rect("#q14g1").width);
    log("clip units", m.getPropertyValue("overflow-clip-margin"));
    log("runtime sheet", rect("#q11").width + " " + rect("#q11").height + " " + getComputedStyle(document.querySelector("#q11")!, "").paddingLeft);
    const c3 = getComputedStyle(document.querySelector("#c3")!, "");
    log("computed", c3.containerType + " " + c3.containerName + " " + c3.getPropertyValue("container"));
    const q1 = document.querySelector("#q1") as HTMLElement;
    q1.style.setProperty("container", "panel / size");
    log("style attribute", q1.style.getPropertyValue("container") + " " + q1.style.getPropertyValue("container-type"));
  });
});
</script>
</body></html>`;

const EXPECTED_LOG = [
  "min-width 40",
  "named 30 12",
  "range 32 14 34",
  "block 21 22 23 14",
  "units 200 40 50 50",
  "size containment 0",
  "inline containment 0",
  "style query 70 10",
  "self 0px",
  "second pass 60",
  "block axis needs size 18",
  "calc units 90 50",
  "comma list 45",
  "paint units matrix(1, 0, 0, 1, 150, 0) | matrix(1, 0, 0, 1, 140, 0) | rgb(255, 0, 0) 30px 0px 0px 0px | 75",
  "clip units 15px",
  "runtime sheet 65 66 0px",
  "computed inline-size card card / inline-size",
  "style attribute panel / size size",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-container-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "frame | frame" },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
check(`log lines (${EXPECTED_LOG.length})`, got.length === EXPECTED_LOG.length,
  `got ${got.length}: ${JSON.stringify(got.slice(EXPECTED_LOG.length))}`);
const n = Math.min(got.length, EXPECTED_LOG.length);
for (let i = 0; i < n; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
