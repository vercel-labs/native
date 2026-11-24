// The event kinds a browser on a desktop declares even though nothing here can produce them:
// touch, HTML5 drag and drop, clipboard and input methods. The host never fires one, but the
// classes are real, a script can make and dispatch them, and the payload a drag or a paste
// carries (a DataTransfer) holds its formats and its files.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=100"></head>
<body><div id="pad"></div><script src="app.ts"></script></body></html>`;

const SCRIPT = `
function log(s: string): void { console.log(s); }
const data = new DataTransfer();
data.setData("text/plain", "hello");
data.setData("Text/HTML", "<b>x</b>");
log("types " + data.types.join(",") + " allowed " + data.effectAllowed);
log("get " + data.getData("TEXT/PLAIN") + " " + data.getData("text/html"));
log("missing " + (data.getData("image/png") === "" ? "empty" : "wrote"));
const items = data.items;
log("items " + items.length + " " + items[0].kind + " " + items[0].type + " " + (items[0].getAsFile() === null));
data.clearData("text/plain");
log("cleared " + data.types.join(","));
data.clearData();
log("all " + data.types.length + " " + data.items.length);

const drop = new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: data, clientX: 12 });
log("drag " + (drop.dataTransfer === data) + " " + drop.clientX + " " + drop.type);
const paste = new ClipboardEvent("paste", { clipboardData: data });
log("paste " + (paste.clipboardData === data));
const composition = new CompositionEvent("compositionend", { data: "n" });
log("composition " + composition.data);

const finger = new Touch({ identifier: 7, clientX: 5, clientY: 6, force: 0.5 });
const touch = new TouchEvent("touchstart", { touches: [finger], changedTouches: [finger] });
log("touch " + touch.touches.length + " " + touch.touches[0].identifier + " "
  + touch.touches[0].pageX + " " + touch.touches[0].force + " " + touch.targetTouches.length
  + " " + touch.changedTouches.length);

// A listener for one of these hears only an event a script dispatches: the host fires none.
let heard = 0;
document.addEventListener("touchstart", () => { heard++; });
document.addEventListener("drop", () => { heard++; });
document.dispatchEvent(touch);
document.dispatchEvent(drop);
log("heard " + heard);
log("done");
`;

const EXPECTED = [
  "types text/plain,text/html allowed uninitialized",
  "get hello <b>x</b>",
  "missing empty",
  "items 2 string text/plain true",
  "cleared text/html",
  "all 0 0",
  "drag true 12 drop",
  "paste true",
  "composition n",
  "touch 1 7 5 0.5 1 1",
  "heard 2",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-declared-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "frame" };
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
