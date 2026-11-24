// calc() in every length property: folded at build time when the units agree, a row the runtime
// evaluates against the percentage base otherwise, inside min()/max()/clamp(), through a var(),
// and a substituted value that doesn't parse dropping its declaration with a warning.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=300"><style>
body { margin: 0; font-size: 20px; }
html { font-size: 20px; }
#radius { width: 50px; height: 40px; border-radius: calc(10px * 1.5); }
#varr { width: 50px; height: 40px; --r: 8px; border-radius: calc(var(--r) * 1.5); }
#half { width: calc(50% - 10px); }
#pad { padding: calc(2px + 3px) calc(10px / 2); }
#gap { display: flex; gap: calc(4px * 2); }
#abs { position: absolute; top: calc(10px - 2px); left: calc(100% / 4); }
#fs { font-size: calc(10px * 1.6); }
#fsmix { font-size: calc(100% - 2px); }
#lh { font-size: 10px; line-height: calc(1em * 1.5); }
#tf { width: 100px; transform: translateX(calc(10px * 2)); }
#tfmix { width: 100px; transform: translateX(calc(50% - 10px)); }
#shadow { box-shadow: calc(2px * 2) 0px rgb(0, 0, 0); }
#nested { width: calc(min(50%, 100px) + 5px); }
#clamped { width: clamp(20px, calc(10px * 3), 50px); }
#badcalc { width: calc(10px+5px); }
/* The other math functions: a length rounded to a step, a remainder, and an absolute value. */
#roundup { width: round(up, 25px, 10px); }
#roundnearest { width: round(25px, 10px); }
#modlen { width: mod(25px, 10px); }
#remlen { letter-spacing: rem(-25px, 10px); }
#abslen { width: abs(-40px); }
/* A number where a length is wanted is invalid, so the declaration is dropped. */
#badmin { width: 40px; width: min(0, 100%); }
#badvar, #badvar2 { --n: 1; width: 40px; height: 40px; border-radius: calc(var(--n) * 1.5); }
#emwidth { font-size: 10px; width: calc(2em + 10px); }
#empad { font-size: 10px; padding: calc(1em + 4px); }
#emgap { display: flex; font-size: 6px; gap: calc(1em + 2px); }
#emfs { font-size: calc(1em + 2px); }
#emlh { font-size: 10px; line-height: calc(1em + 5px); }
#emtf { font-size: 10px; width: 100px; transform: translateX(calc(1em + 4px)); }
#emshadow { font-size: 5px; box-shadow: calc(1em + 2px) 0px rgb(0, 0, 0); }
#emmin { font-size: 7px; width: min(2em, 100px); }
#emborder { font-size: 10px; width: 20px; height: 20px; border: calc(1em + 1px) solid rgb(0, 0, 0); }
#emls { font-size: 10px; letter-spacing: calc(1em - 8px); }
#emout { font-size: 4px; outline: 1px solid rgb(0, 0, 0); outline-offset: calc(1em + 1px); }
/* A calc() term may be a calc() of its own, as Tailwind writes it after a var() is substituted. */
/* A rem is the root's font size and lh the element's used line height, inside a calc too. */
#remwidth { width: calc(2rem + 10px); }
#remmix { width: calc(50% - 1rem); }
#remmin { width: min(2rem, 100px); }
#lhline { font-size: 10px; line-height: 30px; margin-top: calc((1lh - 10px) / 2); }
#nestcalc { width: calc(10px * calc(1 + 1)); }
#nestvar { --rev: 0; width: calc(10px * calc(1 - var(--rev))); }
/* A calc() of angles folds, and so does one inside a colour function's components. */
#angcalc { width: 40px; height: 20px; transform: rotate(calc(45deg * -2)); }
#angvar { width: 40px; height: 20px; --angle: 45deg; transform: rotate(calc(var(--angle) * -2)); }
#skewcalc { width: 40px; height: 20px; transform: skewX(calc(10deg + 10deg)); }
#huecalc { width: 10px; height: 10px; background-color: hsl(calc(0 + 120), 100%, 50%); }
#gradcalc { width: 10px; height: 10px; background-image: linear-gradient(hsl(calc(0 + 120), 100%, 50%), hsl(calc(0 + 240), 100%, 50%)); }
#mq { width: 20px; height: 5px; }
#mqmin { width: 5px; }
@media (max-width: calc(10em + 50px)) { #mq { height: 30px; } }
@media (min-width: calc(20em + 100px)) { #mq { width: 60px; } }
@media (min-width: min(300px, 50vw)) { #mqmin { width: 40px; } }
</style></head><body>
<div id="radius"></div><div id="varr"></div><div id="half"></div><div id="pad"></div>
<div id="gap"><div id="g1" style="width: 10px; height: 10px"></div><div id="g2" style="width: 10px; height: 10px"></div></div>
<div id="abs"></div><div id="fs"></div><div id="fsmix"></div><div id="lh">x</div>
<div id="tf"></div><div id="tfmix"></div><div id="shadow"></div><div id="nested"></div>
<div id="clamped"></div><div id="badcalc"></div><div id="badvar"></div><div id="badvar2"></div>
<div id="emwidth"></div><div id="empad"><div id="epc" style="width: 10px; height: 10px"></div></div>
<div id="emgap"><div id="eg1" style="width: 10px; height: 10px"></div><div id="eg2" style="width: 10px; height: 10px"></div></div>
<div id="emfs"></div><div id="emlh">x</div><div id="emtf"></div><div id="emshadow"></div><div id="emmin"></div>
<div id="emborder"></div><div id="emls">x</div><div id="emout"></div><div id="mq"></div><div id="mqmin"></div>
<div id="angcalc"></div><div id="angvar"></div><div id="skewcalc"></div><div id="huecalc"></div><div id="gradcalc"></div>
<div id="nestcalc"></div><div id="nestvar"></div>
<div id="remwidth"></div><div id="remmix"></div><div id="remmin"></div>
<div id="lhwrap" style="position: absolute; top: 240px; left: 0; width: 100px"><div style="height: 20px"></div><div id="lhline">x</div></div>
<div id="roundup"></div><div id="roundnearest"></div><div id="modlen"></div><div id="remlen"></div><div id="abslen"></div><div id="badmin"></div>
<script type="module">
const cs = (sel: string): CSSStyleDeclaration => getComputedStyle(document.querySelector(sel)!, "");
const log = (name: string, value: string): void => { console.log(name + " " + value); };

log("radius", cs("#radius").borderTopLeftRadius);
log("varr", cs("#varr").borderTopLeftRadius);
log("pad", cs("#pad").paddingTop + " " + cs("#pad").paddingLeft);
log("fs", cs("#fs").fontSize);
log("fsmix", cs("#fsmix").fontSize);
log("lh", cs("#lh").lineHeight);
log("shadow", cs("#shadow").boxShadow);
// A value that doesn't parse is invalid at computed-value time: the property keeps its initial
// value, and the run says so on stderr.
log("badcalc", cs("#badcalc").width);
log("badvar", cs("#badvar").borderTopLeftRadius);
log("emfs", cs("#emfs").fontSize);
log("emlh", cs("#emlh").lineHeight);
log("emshadow", cs("#emshadow").boxShadow);
log("emborder", cs("#emborder").borderTopWidth);
log("emls", cs("#emls").letterSpacing);
log("emout", cs("#emout").outlineOffset);
log("angcalc", cs("#angcalc").transform);
log("angvar", cs("#angvar").transform);
log("skewcalc", cs("#skewcalc").transform);
log("huecalc", cs("#huecalc").backgroundColor);

requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    const rect = (sel: string): DOMRect => document.querySelector(sel)!.getBoundingClientRect();
    log("half", rect("#half").width + "");
    log("gap", rect("#g2").left + "");
    log("abs", rect("#abs").top + " " + rect("#abs").left);
    log("tf", rect("#tf").left + " " + cs("#tf").transform);
    log("tfmix", rect("#tfmix").left + " " + cs("#tfmix").transform);
    log("nested", rect("#nested").width + "");
    log("clamped", rect("#clamped").width + "");
    log("emwidth", rect("#emwidth").width + "");
    log("empad", rect("#epc").left + " " + (rect("#epc").top - rect("#empad").top));
    log("emgap", rect("#eg2").left + "");
    log("emtf", rect("#emtf").left + " " + cs("#emtf").transform);
    log("emmin", rect("#emmin").width + "");
    log("mq", rect("#mq").width + " " + rect("#mq").height);
    log("mqmin", rect("#mqmin").width + "");
    log("remwidth", rect("#remwidth").width + "");
    log("remmix", rect("#remmix").width + "");
    log("remmin", rect("#remmin").width + "");
    log("lhline", rect("#lhline").top + "");
    log("nestcalc", rect("#nestcalc").width + "");
    log("nestvar", rect("#nestvar").width + "");
    log("math", rect("#roundup").width + " " + rect("#roundnearest").width + " " + rect("#modlen").width +
      " " + rect("#abslen").width + " " + cs("#remlen").letterSpacing);
    log("badmin", cs("#badmin").width);
  });
});
</script>
</body></html>`;

const EXPECTED_LOG = [
  "radius 15px",
  "varr 12px",
  "pad 5px 5px",
  "fs 16px",
  "fsmix 18px",
  "lh 15px",
  "shadow rgb(0, 0, 0) 4px 0px 0px 0px",
  "badcalc auto",
  "badvar 0px",
  "emfs 22px",
  "emlh 15px",
  "emshadow rgb(0, 0, 0) 7px 0px 0px 0px",
  "emborder 11px",
  "emls 2px",
  "emout 5px",
  "angcalc matrix(0, -1, 1, 0, 0, 0)",
  "angvar matrix(0, -1, 1, 0, 0, 0)",
  "skewcalc matrix(1, 0, 0.36397, 1, 0, 0)",
  "huecalc rgb(0, 255, 0)",
  "half 90",
  "gap 18",
  "abs 8 50",
  "tf 0 matrix(1, 0, 0, 1, 20, 0)",
  "tfmix 0 matrix(1, 0, 0, 1, 40, 0)",
  "nested 105",
  "clamped 30",
  "emwidth 30",
  "empad 14 14",
  "emgap 18",
  "emtf 0 matrix(1, 0, 0, 1, 14, 0)",
  "emmin 14",
  "mq 20 30",
  "mqmin 40",
  "remwidth 50",
  "remmix 80",
  "remmin 40",
  "lhline 270",
  "nestcalc 20",
  "nestvar 10",
  "math 30 30 5 40 -5px",
  "badmin 40px",
];

// The two elements share one rule, so the same property and value warn once.
const EXPECTED_WARNING = "native: 'border-radius: calc(1 * 1.5)' is invalid at computed-value time";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-calc-"));
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

// The build reports the malformed calc() and the run reports the substituted one.
// A colour function's components are folded inside a gradient's own arguments too.
check("a gradient stop takes a calc() colour", !b.stderr.includes("unsupported gradient colour stop"), b.stderr);
check("the build reports calc(10px+5px)", b.stderr.includes("unsupported value 'calc(10px+5px)'"), b.stderr);
const warnings = r.stderr.split("\n").filter((line) => line.includes("invalid at computed-value time"));
check(`one runtime warning (${EXPECTED_WARNING})`, warnings.length === 1 && warnings[0].startsWith(EXPECTED_WARNING),
  JSON.stringify(warnings));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
