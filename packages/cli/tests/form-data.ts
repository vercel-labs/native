// FormData: the entries a form would submit, in document order, and the set a script builds and
// edits itself. The list a form gives, the "on" a checkbox with no value submits, the order
// append(), set() and delete() leave, and what get(), getAll(), has(), keys(), values() and
// forEach() answer are all Chrome's for the same page.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"><style>
body { margin: 0; font: 16px monospace; }
</style></head><body>
<form id="frm">
  <input name="q" value="hello">
  <input type="checkbox" id="c" name="c" checked>
  <input type="checkbox" name="c2" value="yes" checked>
  <input type="checkbox" name="c3" value="no">
  <input type="radio" name="r" value="one" checked>
  <input type="radio" name="r" value="two">
  <input name="dis" value="x" disabled>
  <input value="anon">
  <input type="hidden" name="h" value="4">
  <button type="submit" name="btn" value="Go">Go</button>
</form>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
function strings(list: FormDataEntryValue[]): string[] {
  const out: string[] = [];
  for (const v of list) out.push(String(v));
  return out;
}
function show(fd: FormData): string {
  return fd.entries().map((e: [string, FormDataEntryValue]) =>
    e[0] + "=" + (typeof e[1] === "string" ? e[1] : "file:" + (e[1] as File).name)).join(",");
}
// The build has no <select> or <textarea> in markup yet, so the page makes them, which is where a
// dynamic tree gets them too; a browser's DOM ends up the same.
const frm = document.getElementById("frm") as HTMLFormElement;
const sel = document.createElement("select") as HTMLSelectElement;
sel.name = "s";
const o1 = document.createElement("option") as HTMLOptionElement;
o1.value = "first";
o1.text = "First";
const o2 = document.createElement("option") as HTMLOptionElement;
o2.value = "second";
o2.text = "Second";
o2.selected = true;
sel.appendChild(o1);
sel.appendChild(o2);
frm.appendChild(sel);
const multi = document.createElement("select") as HTMLSelectElement;
multi.name = "m";
multi.multiple = true;
for (const v of ["a", "b", "c"]) {
  const o = document.createElement("option") as HTMLOptionElement;
  o.value = v;
  o.text = v.toUpperCase();
  o.selected = v !== "b";
  multi.appendChild(o);
}
frm.appendChild(multi);
const ta = document.createElement("textarea") as HTMLTextAreaElement;
ta.name = "t";
ta.value = "line";
frm.appendChild(ta);

log("form " + show(new FormData(frm)));

const d = new FormData();
d.append("a", "1");
d.append("b", "2");
d.append("a", "3");
log("all " + show(d) + " get " + String(d.get("a")) + " has " + d.has("a") + " " + d.has("z"));
log("getall " + strings(d.getAll("a")).join("|") + " keys " + d.keys().join("|")
  + " values " + strings(d.values()).join("|"));
d.set("a", "9");
log("set " + show(d) + " getall " + strings(d.getAll("a")).join("|"));
d.delete("a");
log("delete " + show(d) + " " + String(d.get("a")));
const seen: string[] = [];
d.forEach((value: FormDataEntryValue, key: string) => { seen.push(key + ":" + value); });
log("each " + seen.join(","));

// A checkbox with no value attribute submits "on", which is also what its value property reads.
const box = document.getElementById("c") as HTMLInputElement;
log("prop " + box.value);
`;

const EXPECTED = [
  // Named controls in document order; a disabled one, an unnamed one and a button submit nothing,
  // an unchecked box nothing, and the unchecked radio not at all.
  "form q=hello,c=on,c2=yes,r=one,h=4,s=second,m=a,m=c,t=line",
  "all a=1,b=2,a=3 get 1 has true false",
  "getall 1|3 keys a|b|a values 1|2|3",
  // set() replaces the first entry under the name and drops the rest, in place.
  "set a=9,b=2 getall 9",
  "delete b=2 null",
  "each b:2",
  "prop on",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-form-data-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame 0" };
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
