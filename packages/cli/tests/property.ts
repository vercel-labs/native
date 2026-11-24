// The @property rule: a registered custom property's initial value standing in where nothing sets
// it, registered properties not inheriting unless they say so, a value outside the declared syntax
// behaving as unset, and an invalid rule being dropped.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=240, height=180"><style>
body { margin: 0; }
/* Registers --own as a colour that does not inherit: a child that doesn't set it keeps the
   initial value rather than the root's blue. */
@property --own {
  syntax: "*";
  inherits: false;
  initial-value: rgb(255, 0, 0);
}
/* The same with inherits: true, so the child does see the root's blue. */
@property --shared {
  syntax: "*";
  inherits: true;
  initial-value: rgb(255, 0, 0);
}
/* No initial value: the property is guaranteed-invalid until something sets it. */
@property --none {
  syntax: "*";
  inherits: false;
}
/* A typed property: only a length belongs to it, and the initial value is a length. */
@property --len {
  syntax: "<length>";
  inherits: false;
  initial-value: 7px;
}
/* A typed property whose initial value is not of its syntax: the whole rule is ignored. */
@property --bad {
  syntax: "<length>";
  inherits: false;
  initial-value: rgb(1, 2, 3);
}
/* A registered property whose initial value is a shadow the element itself never sets. */
@property --tw-a {
  syntax: "*";
  inherits: false;
  initial-value: 0 0 #0000;
}
:root { --own: rgb(0, 0, 255); --shared: rgb(0, 0, 255); --len: 11px; }
#own { color: var(--own); }
#shared { color: var(--shared); }
#none { color: var(--none, rgb(0, 128, 0)); }
#len { --len: 11px; width: var(--len); }
#len-bad { --len: rgb(1, 2, 3); width: var(--len); }
#bad { --bad: 20px; width: var(--bad); height: 3px; background: rgb(0, 0, 0); }
#shadow { --tw-a: 3px 3px rgb(255, 0, 0); }
#shadow span { box-shadow: var(--tw-a), 1px 1px 2px rgb(0, 0, 0); }
@media (min-width: 1px) { @property --media { syntax: "<percentage>"; inherits: false; initial-value: 50%; } }
#media { width: var(--media); }
@media (min-width: 1px) {
  @property --media { syntax: "<percentage>"; inherits: false; initial-value: 25%; }
}
</style></head><body>
<div id="own">own</div>
<div id="shared">shared</div>
<div id="none">none</div>
<div id="len"></div>
<div id="len-bad"></div>
<div id="bad"></div>
<div id="shadow"><span>shadow</span></div>
<div id="media"></div>
<script type="module">
const cs = (sel: string): CSSStyleDeclaration => getComputedStyle(document.querySelector(sel)!, "");
const log = (name: string, value: string): void => { console.log(name + " " + value); };
log("own", cs("#own").color);
log("shared", cs("#shared").color);
log("none", cs("#none").color);
log("len", cs("#len").width);
log("len-bad", cs("#len-bad").width);
log("bad-rule", cs("#bad").width);
log("media", cs("#media").width);
log("shadow", cs("#shadow span").boxShadow);
</script>
</body></html>`;

const EXPECTED_LOG = [
  // Not inheriting: the child of :root gets the initial value, not :root's blue.
  "own rgb(255, 0, 0)",
  // Inheriting: the root's blue reaches the child.
  "shared rgb(0, 0, 255)",
  // No initial value: the guaranteed-invalid property falls back.
  "none rgb(0, 128, 0)",
  // A length of the registered property, and the initial one where the value doesn't belong to
  // the syntax.
  "len 11px",
  "len-bad 7px",
  // The rule with a mismatched initial value was ignored, so --bad stays an ordinary custom
  // property, and the element's own value is what its width reads.
  "bad-rule 20px",
  // The later @property rule wins.
  "media 25%",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-property-"));
const app = join(dir, "app");
mkdirSync(app);
writeFileSync(join(app, "index.html"), PAGE);
const exe = join(app, "exe");
const b = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: "" } });
const checkOut = spawnSync("node", ["compiler/cli.ts", "check", app], { encoding: "utf8" }).stderr;
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);

for (const e of EXPECTED_LOG) {
  const name = e.slice(0, e.indexOf(" "));
  const line = got.find((l) => l.startsWith(name + " "));
  check(e, line === e, `got ${JSON.stringify(line)}`);
}
// A non-inheriting registration's initial value is what a child reads, not the parent's red.
const shadowLine = got.find((l) => l.startsWith("shadow ")) ?? "";
check("a non-inheriting registration's initial value reaches the child, not the parent's value",
  shadowLine.startsWith("shadow rgba(0, 0, 0, 0) 0px 0px 0px 0px,") &&
  !shadowLine.includes("3px 3px"), shadowLine);
// The invalid rule is reported at build time, so the author can see why it did nothing.
check("the invalid rule is reported", checkOut.includes("invalid @property rule"),
  JSON.stringify(checkOut.split("\n").slice(0, 3)));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
