// A CSSOM write of a longhand has to stay after a shorthand that covers it, or the shorthand's
// var() expansion puts the old value back. The order rules here are the ones Chrome 158 shows for
// the same sequences.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>cssom-var-shorthand-order</title><style>
:root { --m: 8px; }
</style></head><body>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const mk = (): HTMLElement => { const el = document.createElement("div"); document.body.appendChild(el); return el; };
const margins = (el: HTMLElement): string => {
  const cs = getComputedStyle(el);
  return cs.marginTop + " " + cs.marginLeft;
};

// A normal longhand before a var() shorthand is replaced by the shorthand.
const a = mk();
a.style.cssText = "margin-top: 10px; margin: var(--m)";
log("a " + margins(a) + " " + JSON.stringify(a.style.cssText));

// A write after the parse lands after the shorthand, so it is not undone.
a.style.marginTop = "20px";
log("a-write " + margins(a));

// An important longhand survives the shorthand.
const b = mk();
b.style.cssText = "margin-top: 10px !important; margin: var(--m)";
log("b " + margins(b));
b.style.marginTop = "20px";
log("b-write " + margins(b));

// Three CSSOM writes: longhand, shorthand, longhand.
const c = mk();
c.style.marginTop = "10px";
c.style.margin = "8px";
c.style.marginTop = "20px";
log("c " + margins(c));

// A scripted shorthand write replaces the important longhand it covers, priority included.
const d = mk();
d.style.marginTop = "10px";
d.style.setProperty("margin-top", "10px", "important");
d.style.margin = "8px";
log("d " + margins(d) + " " + JSON.stringify(d.style.getPropertyPriority("margin-top")));

const e = mk();
e.style.marginTop = "10px";
e.style.setProperty("margin-top", "10px", "important");
e.style.margin = "var(--m)";
log("e " + margins(e) + " " + JSON.stringify(e.style.getPropertyPriority("margin-top")));

const f = mk();
f.style.marginTop = "10px";
f.style.setProperty("margin-top", "10px", "important");
f.style.setProperty("margin", "8px", "important");
log("f " + margins(f) + " " + JSON.stringify(f.style.getPropertyPriority("margin-top")));
`;

const EXPECTED_LOG = [
  // Chrome: cssText "margin: var(--m);", top and left 8px.
  'a 8px 8px "margin: var(--m);"',
  "a-write 20px 8px",
  "b 10px 8px",
  "b-write 20px 8px",
  "c 20px 8px",
  // Chrome: one normal shorthand, computed 8px on every side, no priority left.
  'd 8px 8px ""',
  'e 8px 8px ""',
  // An important shorthand write keeps its own priority.
  'f 8px 8px "important"',
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-cssom-order-"));
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
