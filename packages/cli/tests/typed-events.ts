// The types a framework's window handlers need: addEventListener() on window picks the listener's
// event class from the type name, as the document's and an element's do, so a drag handler typed
// with DragEvent is a listener; and ScrollBehavior is the type the scroll options take.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"><style>
body { margin: 0; }
#box { width: 200px; height: 40px; overflow: auto; }
#pad { height: 200px; }
</style></head><body>
<div id="box"><div id="pad"></div></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const seen: string[] = [];
// A window listener is typed by the event it names, as a document's or an element's is.
const onDragOver = (event: Event): void => { seen.push(event.type + " " + String((event as DragEvent).dataTransfer !== undefined)); };
window.addEventListener("dragover", onDragOver);
window.dispatchEvent(new DragEvent("dragover"));
log("drag " + seen.join(","));
window.removeEventListener("dragover", onDragOver);
window.dispatchEvent(new DragEvent("dragover"));
log("removed " + seen.join(","));

// A listener whose parameter is the event class itself is a listener for that type name, on the
// window, the document and an element alike: the map is what types all three.
const onKey = (event: KeyboardEvent): void => { seen.push("typed " + event.key + " " + String(event.repeat)); };
window.addEventListener("keydown", onKey);
document.addEventListener("keydown", onKey);
const listenerBox = document.getElementById("box") as HTMLElement;
listenerBox.addEventListener("keydown", onKey);
window.dispatchEvent(new KeyboardEvent("keydown", { key: "k", repeat: true }));
log("typed " + seen[seen.length - 1]);

// A scroll takes the DOM's own words for how it travels.
const behavior: ScrollBehavior = "instant";
const box = document.getElementById("box") as HTMLElement;
box.scrollTo({ top: 20, behavior });
log("scrolled " + box.scrollTop);
box.scrollTo(0, 0);
log("back " + box.scrollTop);
const into: ScrollIntoViewOptions = { block: "start", inline: "nearest", behavior: "auto" };
box.scrollIntoView(into);
log("view " + box.scrollTop);
`;

const EXPECTED = [
  "drag dragover true",
  // The listener was removed, so the second dispatch hears nothing new.
  "removed dragover true",
  "typed typed k true",
  "scrolled 20",
  "back 0",
  "view 0",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-typed-events-"));
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
