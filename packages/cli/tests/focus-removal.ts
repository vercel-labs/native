// Focus doesn't survive the element leaving the page: removing the focused element, or one whose
// focus is being taken, leaves the document with no focused element and nothing matching
// :focus-within. A detached element can't take focus either.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><title>focus-removal</title></head><body>
<div id="root"><div id="container" tabindex="-1"><input id="in"></div></div>
<div id="loose" tabindex="-1"></div>
<input id="a"><input id="b"><input id="c">
<dialog id="dlg"><input id="din"></dialog>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const active = (): string => {
  const a = document.activeElement;
  return a === null ? "null" : (a.id !== "" ? a.id : a.tagName.toLowerCase());
};
const root = document.getElementById("root") as HTMLElement;
const container = document.getElementById("container") as HTMLElement;
const input = document.getElementById("in") as HTMLElement;
input.focus();
log("focused " + active() + " " + container.matches(":focus-within") + " " + root.matches(":focus-within"));

// Losing focus to the container removes it first, so the focus has nowhere to go.
input.addEventListener("focusout", () => { root.innerHTML = ""; });
container.focus();
log("removed " + active() + " " + container.matches(":focus-within") + " " +
  root.matches(":focus-within") + " " + input.matches(":focus"));

// An element outside the document takes no focus.
const loose = document.getElementById("loose") as HTMLElement;
loose.remove();
loose.focus();
log("detached " + active() + " " + loose.matches(":focus"));

// A blur handler that focuses something else keeps the focus it took.
const a = document.getElementById("a") as HTMLElement;
const b = document.getElementById("b") as HTMLElement;
const c = document.getElementById("c") as HTMLElement;
a.focus();
a.addEventListener("blur", () => { b.focus(); });
c.focus();
log("reentrant " + active());

// Focus inside a modal dialog stays inside it: the page around it sees no :focus-within.
const dlg = document.getElementById("dlg") as HTMLDialogElement;
const di = document.getElementById("din") as HTMLElement;
dlg.showModal();
di.focus();
log("toplayer " + active() + " dlg=" + dlg.matches(":focus-within") + " body=" +
  document.body.matches(":focus-within"));
`;

const EXPECTED_LOG = [
  "focused in true true",
  // activeElement falls back to the body; the removed subtree matches nothing.
  "removed body false false false",
  "detached body false",
  "reentrant b",
  // The dialog is on the top layer, so the body above it is not within the focus.
  "toplayer din dlg=true body=false",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-focus-removal-"));
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
