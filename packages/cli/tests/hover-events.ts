// mouseover/mouseout, mouseenter/mouseleave and their pointer counterparts: which element each
// one targets, the order they fire in, the relatedTarget each carries, and how far each bubbles.
// The order is the one the web's own tests expect: out, leave, over, enter, with the pointer
// events before the mouse ones.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=400, height=400"><style>
html, body { margin: 0; height: 100%; }
#a { position: absolute; left: 0; top: 0; width: 320px; height: 300px; background: #dde; }
#b { position: absolute; left: 40px; top: 40px; width: 100px; height: 100px; background: #cdc; }
#c { position: absolute; left: 0; top: 320px; width: 100px; height: 60px; background: #ecc; }
#log { position: absolute; left: 320px; top: 0; }
</style></head><body>
<div id="a"><div id="b"></div></div>
<div id="c"></div>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const name = (n: EventTarget | null): string => {
  if (n === null) return "-";
  if (n === document) return "document";
  const el = n as Element;
  return el.id !== undefined && el.id !== "" ? el.id : el.tagName.toLowerCase();
};
const record = (e: Event): void => {
  const m = e as MouseEvent;
  // The current target shows where a non-bubbling event landed, the target where a bubbling one
  // came from.
  console.log(e.type + " target=" + name(m.target) + " related=" + name(m.relatedTarget) +
    " at=" + name(e.currentTarget) + " bubbles=" + String(e.bubbles));
};
// Over and out bubble to the document; enter and leave don't, so each box listens for itself.
for (const type of ["pointerover", "pointerout", "mouseover", "mouseout"]) {
  document.addEventListener(type, record);
}
for (const id of ["a", "b", "c"]) {
  const el = document.getElementById(id)!;
  for (const type of ["pointerenter", "pointerleave", "mouseenter", "mouseleave"]) {
    el.addEventListener(type, record);
  }
}
`;

const dir = mkdtempSync(join(tmpdir(), "native-hover-events-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = {
  ...process.env,
  // #a's own box, then its child #b, back to #a, then out to #c, then within #c (no events).
  NATIVE_STEPS: "hover #a | hover #b | hover #a | hover #c | hover #c",
};
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);

const EXPECTED = [
  // Entering #a from outside the window: the pointer events come first, then the mouse ones,
  // each with no related target.
  "pointerover target=a related=- at=document bubbles=true",
  "pointerenter target=a related=- at=a bubbles=false",
  "mouseover target=a related=- at=document bubbles=true",
  "mouseenter target=a related=- at=a bubbles=false",
  // Onto the child: #a hears out even though the pointer is still inside it, and only #b is
  // entered. #a gets no leave, and #a's over listener sees nothing.
  "pointerout target=a related=b at=document bubbles=true",
  "pointerover target=b related=a at=document bubbles=true",
  "pointerenter target=b related=a at=b bubbles=false",
  "mouseout target=a related=b at=document bubbles=true",
  "mouseover target=b related=a at=document bubbles=true",
  "mouseenter target=b related=a at=b bubbles=false",
  // Back to the parent: #b is left entirely, so leave follows out, and #a hears over again
  // without a second enter.
  "pointerout target=b related=a at=document bubbles=true",
  "pointerleave target=b related=a at=b bubbles=false",
  "pointerover target=a related=b at=document bubbles=true",
  "mouseout target=b related=a at=document bubbles=true",
  "mouseleave target=b related=a at=b bubbles=false",
  "mouseover target=a related=b at=document bubbles=true",
  // To the unrelated box: #a is left, out then leave, and #c is entered.
  "pointerout target=a related=c at=document bubbles=true",
  "pointerleave target=a related=c at=a bubbles=false",
  "pointerover target=c related=a at=document bubbles=true",
  "pointerenter target=c related=a at=c bubbles=false",
  "mouseout target=a related=c at=document bubbles=true",
  "mouseleave target=a related=c at=a bubbles=false",
  "mouseover target=c related=a at=document bubbles=true",
  "mouseenter target=c related=a at=c bubbles=false",
];

const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
check(`events (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
