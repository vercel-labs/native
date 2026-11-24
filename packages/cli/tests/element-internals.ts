// ElementInternals, for a form-associated custom element: attachInternals() on a defined tag, the
// value it submits (which new FormData(form) collects), and the constraints it reports through
// setValidity. A tag with no definition, or a second call, throws NotSupportedError, as a browser's
// attachInternals() does.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head><body>
<form id="f">
  <my-field name="amount"></my-field>
  <input name="other" value="x">
</form>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
// An element takes no constructor arguments, as HTMLElement does.
class MyField extends HTMLElement {
  internals: ElementInternals;
  constructor() {
    super();
    this.internals = this.attachInternals();
    this.internals.setFormValue("42");
  }
}
customElements.define("my-field", MyField);
const f = document.getElementById("f") as HTMLFormElement;
const field = document.querySelector("my-field") as MyField;
log("has internals " + String(field.internals instanceof ElementInternals));
log("form " + String(field.internals.form === f) + " labels " + field.internals.labels.length + " validate " + String(field.internals.willValidate));
const fd = new FormData(f);
log("data " + fd.entries().map((e) => e[0] + "=" + e[1]).join(","));
log("valid0 " + String(field.internals.validity.valid) + " msg " + JSON.stringify(field.internals.validationMessage));
field.internals.setValidity({ valueMissing: true }, "Needs a number");
log("valid1 " + String(field.internals.validity.valid) + " missing " + String(field.internals.validity.valueMissing) + " msg " + JSON.stringify(field.internals.validationMessage));
let invalid = 0;
field.addEventListener("invalid", () => { invalid++; });
log("check " + String(field.internals.checkValidity()) + " heard " + invalid);
field.internals.setValidity({}, "");
log("valid2 " + String(field.internals.checkValidity()) + " heard " + invalid);
field.internals.setFormValue(null);
log("omitted " + new FormData(f).entries().length);
try {
  document.createElement("div").attachInternals();
  log("div no throw");
} catch (e) {
  log("div throws " + String((e as Error).message.startsWith("NotSupportedError")));
}
try {
  field.attachInternals();
  log("second no throw");
} catch (e) {
  log("second throws " + String((e as Error).message.startsWith("NotSupportedError")));
}
log("done");
`;

const EXPECTED = [
  "has internals true",
  // The custom element has no label and takes part in validation; the form's entries are its
  // internals value and the input beside it, in document order.
  "form true labels 0 validate true",
  "data amount=42,other=x",
  "valid0 true msg \"\"",
  "valid1 false missing true msg \"Needs a number\"",
  // A failed check sends invalid on the element, once.
  "check false heard 1",
  "valid2 true heard 1",
  // A null value is left out of the entries.
  "omitted 1",
  "div throws true",
  "second throws true",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-internals-"));
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
