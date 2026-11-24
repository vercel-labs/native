// An element class that takes no constructor arguments, as a browser's HTMLElement does: a plain
// `constructor() { super(); }` builds and runs, and the registry, createElement and the markup
// parser give every element its tag after construction. This is the pattern
// `customElements.define("x-el", class extends HTMLElement { constructor() { super(); } })` needs.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; font: 13px monospace; }
</style></head><body>
<my-box id="fromMarkup">hi</my-box>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
class MyBox extends HTMLElement {
  ready: boolean;
  constructor() {
    super();
    this.ready = true;
  }
}
customElements.define("my-box", MyBox);
const markup = document.getElementById("fromMarkup") as MyBox;
log("markup " + String(markup instanceof MyBox) + " " + markup.tagName.toLowerCase() + " " + String(markup.ready) + " " + markup.textContent);
const made = document.createElement("my-box") as MyBox;
log("created " + String(made instanceof MyBox) + " " + made.tagName.toLowerCase() + " " + String(made.ready) + " " + String(made.isConnected));
document.body.appendChild(made);
made.textContent = "made";
log("appended " + String(made.isConnected) + " " + made.textContent + " " + made.localName);
`;

const EXPECTED = [
  // The element in the markup is upgraded to the class, and reads its tag and text.
  "markup true my-box true hi",
  // createElement makes an instance of the class, detached until it is inserted.
  "created true my-box true false",
  "appended true made my-box",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-element-constructor-"));
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
