// :link and :any-link name the HTML and SVG anchors whatever namespace a sheet makes its
// default: the elements they stand for are not the author's bare type selectors.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>link-namespace</title><style>
@namespace url(http://www.w3.org/2000/svg);
:link { color: rgb(0, 128, 0); }
</style></head><body>
<a id="html" href="#">html link</a>
<svg width="10" height="10"><a id="svg" href="#"><rect width="10" height="10"/></a></svg>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const html = document.getElementById("html") as Element;
const svg = document.getElementById("svg") as Element;
const colour = (el: Element): string => getComputedStyle(el).color;
log("html " + html.matches(":link") + " " + html.matches(":any-link") + " " + colour(html));
log("svg " + svg.matches(":link") + " " + colour(svg));
log("query " + document.querySelectorAll(":link").length);
`;

const EXPECTED_LOG = [
  "html true true rgb(0, 128, 0)",
  "svg true rgb(0, 128, 0)",
  "query 2",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-link-namespace-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

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
