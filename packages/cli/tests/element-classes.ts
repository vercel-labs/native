// Every element is an instance of the class its tag names, and the members a script reads on
// those classes (a control's form and validity, a label's control, a select's options, a
// textarea's value and selection) answer as they do in a browser.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=300"></head><body>
<form id="signup">
  <label id="name-label" for="name">Name</label>
  <input id="name" name="name" required value="Ada">
  <label id="wrap-label"><input id="agree" type="checkbox" required></label>
  <select id="plan" name="plan">
    <optgroup label="Plans">
      <option value="free">Free</option>
      <option value="pro" selected>Pro</option>
    </optgroup>
  </select>
  <textarea id="notes" name="notes" rows="3" cols="20">hello</textarea>
  <button id="send" name="send" value="1">Send</button>
</form>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };

const form = document.getElementById("signup") as HTMLFormElement;
const name = document.getElementById("name") as HTMLInputElement;
const agree = document.getElementById("agree") as HTMLInputElement;
const plan = document.getElementById("plan") as HTMLSelectElement;
const notes = document.getElementById("notes") as HTMLTextAreaElement;
const send = document.getElementById("send") as HTMLButtonElement;
const nameLabel = document.getElementById("name-label") as HTMLLabelElement;
const wrapLabel = document.getElementById("wrap-label") as HTMLLabelElement;

// --- each tag makes its own class, and the classes are still elements
log("classes " + String(form instanceof HTMLFormElement) + " " + String(name instanceof HTMLInputElement) +
  " " + String(plan instanceof HTMLSelectElement) + " " + String(notes instanceof HTMLTextAreaElement) +
  " " + String(send instanceof HTMLButtonElement) + " " + String(nameLabel instanceof HTMLLabelElement) +
  " " + String(form instanceof HTMLElement) + " " + String(name instanceof HTMLElement));
log("not " + String(name instanceof HTMLButtonElement) + " " + String(plan instanceof HTMLInputElement));

// --- form association
log("form " + String(name.form === form) + " " + String(plan.form === form) + " " +
  String(notes.form === form) + " " + String(send.form === form));
log("elements " + String(form.elements.length) + " " + String(form.length));

// --- labels
log("label control " + String(nameLabel.control === name) + " " + String(wrapLabel.control === agree) +
  " " + nameLabel.htmlFor);
log("labels " + String(name.labels.length) + " " + String(name.labels[0] === nameLabel));

// --- values and defaults
log("value " + name.value + " " + name.defaultValue + " " + name.textLength);
name.value = "Grace";
log("after set " + name.value + " " + name.defaultValue);
notes.value = "line one\\nline two";
log("textarea " + notes.textLength + " " + notes.rows + " " + notes.cols);

// --- selection
name.setSelectionRange(1, 3);
log("selection " + name.selectionStart + " " + name.selectionEnd + " " + name.selectionDirection);
name.setRangeText("ra", 1, 3, "end");
log("range text " + name.value + " " + name.selectionStart);
notes.select();
log("textarea selection " + notes.selectionStart + " " + notes.selectionEnd);

// --- select and options
log("select " + plan.value + " " + String(plan.selectedIndex) + " " + String(plan.length) +
  " " + String(plan.options.length));
log("option " + plan.options[0].value + "/" + plan.options[0].text + "/" + String(plan.options[0].selected) +
  " " + plan.options[1].value + "/" + String(plan.options[1].selected) + "/" + String(plan.options[1].index));
plan.value = "free";
log("picked " + plan.value + " " + String(plan.selectedIndex) + " " + String(plan.options[1].selected) +
  " " + String(plan.selectedOptions.length));
plan.selectedIndex = 1;
log("index " + plan.value);

// --- validity
name.value = "Grace";
log("missing " + String(name.validity.valueMissing) + " " + String(name.checkValidity()) + " [" + name.validationMessage + "]");
name.value = "";
log("empty " + String(name.validity.valueMissing) + " " + String(name.checkValidity()) + " [" + name.validationMessage + "]");
name.setCustomValidity("Already taken.");
log("custom " + String(name.validity.customError) + " " + String(name.validity.valid) + " [" + name.validationMessage + "]");
name.setCustomValidity("");
log("cleared " + String(name.validity.customError) + " " + String(name.willValidate));
let invalids = 0;
name.addEventListener("invalid", () => { invalids++; });
name.checkValidity();
log("invalid events " + String(invalids));
log("checkbox " + String(agree.validity.valueMissing) + " [" + agree.validationMessage + "]");
agree.checked = true;
log("checked " + String(agree.validity.valueMissing) + " " + String(agree.checkValidity()));
log("select required " + String(plan.checkValidity()));

// --- form-level checks and reset
name.value = "Ada";
log("form valid " + String(form.checkValidity()));
name.disabled = true;
log("disabled " + String(name.disabled) + " " + String(name.hasAttribute("disabled")) + " " +
  String(name.willValidate) + " " + String(name.validity.valueMissing));
name.disabled = false;
log("enabled " + String(name.hasAttribute("disabled")));
form.reset();
log("reset " + name.value + " " + notes.value + " " + String(agree.checked));

// --- elements a browser builds, and files a script sets
const div = document.createElement("div");
log("made " + String(div instanceof HTMLDivElement) +
  " " + String(document.createElement("ul") instanceof HTMLUListElement) +
  " " + String(document.createElement("td") instanceof HTMLTableCellElement) +
  " " + String(document.createElement("td") instanceof HTMLTableElement));
const file = new File("resume.txt", 12, "text/plain");
const picker = document.createElement("input") as HTMLInputElement;
picker.type = "file";
picker.files = [file];
log("file " + picker.files.length + " " + picker.files[0].name + " " + picker.files[0].size +
  " " + picker.files[0].type);
const bar = document.createElement("progress") as HTMLProgressElement;
log("progress " + String(bar.position));
bar.value = 5;
bar.max = 10;
log("progress value " + String(bar.position));
const dlg = document.createElement("dialog") as HTMLDialogElement;
dlg.open = true;
log("dialog " + String(dlg.open) + " " + String(dlg.isModal));
dlg.close("bye");
log("closed " + String(dlg.open) + " " + dlg.returnValue);
`;

const EXPECTED_LOG = [
  "classes true true true true true true true true",
  "not false false",
  "form true true true true",
  "elements 5 5",
  "label control true true name",
  "labels 1 true",
  "value Ada Ada 3",
  "after set Grace Ada",
  "textarea 17 3 20",
  "selection 1 3 forward",
  "range text Grace 3",
  "textarea selection 0 17",
  "select pro 1 2 2",
  "option free/Free/false pro/true/1",
  "picked free 0 false 1",
  "index pro",
  "missing false true []",
  "empty true false [Please fill out this field.]",
  "custom true false [Already taken.]",
  "cleared false true",
  "invalid events 1",
  "checkbox true [Please check this box if you want to proceed.]",
  "checked false true",
  "select required true",
  "form valid true",
  "disabled true true false false",
  "enabled false",
  "reset Ada hello false",
  "made true true true false",
  "file 1 resume.txt 12 text/plain",
  "progress -1",
  "progress value 0.5",
  "dialog true false",
  "closed false bye",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-elements-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const png = join(dir, "out.png");
const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const got = r.stdout.split("\n").slice(0, -1);
const want = EXPECTED_LOG;
// Compare line by line so a mismatch names the first line that differs.
check(`log lines (${want.length})`, got.length === want.length, `got ${got.length}: ${JSON.stringify(got.slice(want.length))}`);
const n = Math.min(got.length, want.length);
for (let i = 0; i < n; i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
