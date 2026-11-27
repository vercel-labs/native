// :link and :any-link name an <a> or <area> with an href; :visited names the visited ones, which
// a page can't tell from here, so it matches nothing. Adding or removing the href moves an
// element in and out of the first set, and the style follows.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>link-selectors</title><style>
:link { color: rgb(0, 128, 0); }
a:any-link { background-color: rgb(0, 0, 255); }
a:visited { outline-color: rgb(255, 0, 0); }
a:not(:link) { text-decoration-line: underline; }
</style></head><body>
<a id="a1" href="#">One</a>
<a id="a2">Two</a>
<div id="d1" href="#">Three</div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const color = (id: string): string => {
  const el = document.getElementById(id) as HTMLElement;
  const s = getComputedStyle(el);
  return s.color + "/" + s.backgroundColor + "/" + s.textDecorationLine + "/" + s.outlineColor;
};
const all = (): string => color("a1") + " " + color("a2") + " " + color("d1");
log("initial " + all());
log("not visited " + (document.getElementById("d1") as HTMLElement).matches(":not(:visited div)") + " " +
  (document.getElementById("a1") as HTMLElement).matches(":not(:visited a)"));
const a2 = document.getElementById("a2") as HTMLElement;
a2.setAttribute("href", "#");
const a1 = document.getElementById("a1") as HTMLElement;
a1.removeAttribute("href");
void document.documentElement.offsetTop;
log("swapped " + all());
`;

const GREEN = "rgb(0, 128, 0)";
const BLUE = "rgb(0, 0, 255)";
const UA_BLUE = "rgb(0, 0, 238)";
const BLACK = "rgb(0, 0, 0)";
const CLEAR = "rgba(0, 0, 0, 0)";
const UNDERLINE = "underline";
const NONE = "none";
// `<a>` is coloured and underlined by the UA sheet whether or not it is a link; an outline's
// colour follows the text colour, since the rule that would set it (:visited) matches nothing.
const link = `${GREEN}/${BLUE}/${UNDERLINE}/${GREEN}`;
const anchor = (text: string): string => `${text}/${CLEAR}/${UNDERLINE}/${text}`;
const other = (text: string): string => `${text}/${CLEAR}/${NONE}/${text}`;

const EXPECTED_LOG = [
  // The anchor with an href is a link, and only an <a> or <area> is an any-link: the div with an
  // href matches neither.
  `initial ${link} ${anchor(UA_BLUE)} ${other(BLACK)}`,
  // :visited names nothing, so ":not(:visited div)" is true of every div, links included.
  "not visited true true",
  `swapped ${anchor(UA_BLUE)} ${link} ${other(BLACK)}`,
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-link-selectors-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
check("the build accepts :link, :any-link and :visited", !/is not supported yet/.test(b.stderr), b.stderr.trim());

const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "frame" } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
if (got.length === EXPECTED_LOG.length) {
  for (let i = 0; i < got.length; i++) check(EXPECTED_LOG[i], got[i] === EXPECTED_LOG[i], `got ${JSON.stringify(got[i])}`);
} else {
  check(`log lines (${EXPECTED_LOG.length})`, false, `got ${got.length}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
