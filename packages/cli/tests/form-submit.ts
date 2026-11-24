// Form submission: a click on a submit button and Enter in a text field submit the form they are
// in, after checking it unless novalidate; a listener can cancel the submit event.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=560"></head><body>
<form id="f">
  <input id="q" name="q">
  <button id="go">Go</button>
</form>
<form id="g">
  <input id="only" name="only">
</form>
<form id="h" novalidate>
  <input id="needed" name="needed" required>
  <button id="send">Send</button>
</form>
<button id="clear" form="f" type="reset">Clear</button>
<button id="strict" type="button">Strict</button>
<form id="d">
  <input id="di" disabled>
  <button id="dgo" disabled>Disabled</button>
  <button id="ok">Ok</button>
  <fieldset id="fs" disabled>
    <legend><button id="lg">Legend</button></legend>
    <button id="fgo">Nope</button>
  </fieldset>
</form>
<p id="out">ready</p>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const f = document.getElementById("f") as HTMLFormElement;
const g = document.getElementById("g") as HTMLFormElement;
const h = document.getElementById("h") as HTMLFormElement;
const q = document.getElementById("q") as HTMLInputElement;
const go = document.getElementById("go") as HTMLButtonElement;
const send = document.getElementById("send") as HTMLButtonElement;
const needed = document.getElementById("needed") as HTMLInputElement;
const strict = document.getElementById("strict") as HTMLButtonElement;
let submits = 0;

function submitterName(e: SubmitEvent): string {
  return e.submitter === null ? "null" : (e.submitter as HTMLElement).id;
}

// f cancels every submit, so a test can see preventDefault stop the submission.
f.addEventListener("submit", (e) => {
  const se = e as SubmitEvent;
  submits++;
  log("f submit " + submits + " [" + q.value + "] by " + submitterName(se) +
    " cancelable " + String(se.cancelable) + " bubbles " + String(se.bubbles));
  e.preventDefault();
  log("f cancelled");
});
g.addEventListener("submit", (e) => {
  const se = e as SubmitEvent;
  log("g submit [x] by " + submitterName(se));
});
h.addEventListener("submit", (e) => {
  const se = e as SubmitEvent;
  log("h submit by " + submitterName(se));
});
needed.addEventListener("invalid", () => {
  log("invalid needed " + (needed.validationMessage !== "" ? "message" : "no message"));
});
f.addEventListener("reset", () => {
  log("f reset");
});
strict.addEventListener("click", () => {
  h.noValidate = false;
  log("strict on " + String(h.noValidate));
});

// --- requestSubmit names its submitter, submit() doesn't check, and a wrong control is refused
f.requestSubmit(go);
f.submit();
let threw = "";
try {
  f.requestSubmit(g.elements[0] as HTMLElement);
} catch (e) {
  threw = String(e);
}
log("wrong submitter " + (threw.indexOf("submit button") >= 0 ? "TypeError" : threw));
threw = "";
try {
  f.requestSubmit(send);
} catch (e) {
  threw = String(e);
}
log("other form " + (threw.indexOf("isn't a control") >= 0 ? "NotFoundError" : threw));

// --- a disabled control takes no click event: not its own, and not one a pointer sends it
const d = document.getElementById("d") as HTMLFormElement;
const di = document.getElementById("di") as HTMLInputElement;
const dgo = document.getElementById("dgo") as HTMLButtonElement;
const fgo = document.getElementById("fgo") as HTMLButtonElement;
const dClicks = (id: string): void => {
  const el = document.getElementById(id) as HTMLElement;
  el.addEventListener("click", () => { log("clicked " + id); });
};
dClicks("di");
dClicks("dgo");
dClicks("fgo");
d.addEventListener("submit", (e) => {
  log("d submit by " + submitterName(e as SubmitEvent));
});
dgo.click();
di.click();
log("programmatic clicks done");

setTimeout(() => {
  const out = document.getElementById("out") as HTMLElement;
  out.textContent = "done " + String(submits) + " " + String(needed.willValidate);
}, 0);
`;

// Enter in #q submits through the form's default button; #only is a form's only field, so it
// submits the form itself; #h is novalidate until #strict turns that off.
const STEPS = [
  "click #q", "type Ada", "key Enter",
  "click #go",
  "click #only", "type x", "key Enter",
  "click #send",
  "click #strict", "click #send",
  "click #clear",
  "click #di", "click #dgo", "click #ok", "click #fgo", "click #lg",
].join(" | ");

const EXPECTED_LOG = [
  "f submit 1 [] by go cancelable true bubbles true",
  "f cancelled",
  "f submit 2 [] by null cancelable true bubbles true",
  "f cancelled",
  "wrong submitter TypeError",
  "other form NotFoundError",
  "programmatic clicks done",
  "f submit 3 [Ada] by go cancelable true bubbles true",
  "f cancelled",
  "f submit 4 [Ada] by go cancelable true bubbles true",
  "f cancelled",
  "g submit [x] by null",
  "h submit by send",
  "strict on false",
  "invalid needed message",
  "f reset",
  "d submit by ok",
  "d submit by lg",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-form-submit-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: STEPS },
});
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
// Compare line by line so a mismatch names the first line that differs.
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
