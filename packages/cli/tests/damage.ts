// Damage-limited painting: a frame that only changed a box in a scroller paints just the damaged
// rectangles, and NATIVE_VERIFY_DAMAGE's full repaint agrees with it pixel for pixel. A scroll
// still takes the full path.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=400, height=320"><style>
html, body { margin: 0; background: #ffffff; font: 13px/1.4 sans-serif; }
#chat { position: absolute; left: 10px; top: 10px; width: 360px; height: 260px; overflow: auto;
  border: 1px solid #cccccc; background: #fafafa; }
.row { padding: 4px 6px; border-bottom: 1px solid #e5e5e5; color: #222222; }
#count { position: absolute; left: 10px; top: 286px; color: #333333; }
#add { position: absolute; left: 300px; top: 280px; width: 80px; height: 28px; }
</style></head><body>
<div id="chat">
  <div class="row">line one</div><div class="row">line two</div><div class="row">line three</div>
  <div class="row">line four</div><div class="row">line five</div><div class="row">line six</div>
  <div class="row">line seven</div><div class="row">line eight</div><div class="row">line nine</div>
  <div class="row">line ten</div><div class="row">line eleven</div><div class="row">line twelve</div>
  <div class="row">line thirteen</div><div class="row">line fourteen</div><div class="row">line fifteen</div>
  <div class="row">line sixteen</div><div class="row">line seventeen</div><div class="row">line eighteen</div>
  <div class="row">line nineteen</div><div class="row">line twenty</div>
  <div class="row" id="middle">middle row</div>
  <div class="row" id="last">streaming: </div>
</div>
<div id="count">0</div>
<button id="add">add</button>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `let n = 0;
const last = document.getElementById("last")!;
const count = document.getElementById("count")!;
function token(): void {
  const text = last.textContent === null ? "" : last.textContent;
  last.textContent = text + " token" + (++n);
  count.textContent = String(n);
}
setInterval(token, 50);
document.getElementById("add")!.addEventListener("click", token);
const chat = document.getElementById("chat") as HTMLElement;
chat.scrollTop = chat.scrollHeight;
const middle = document.getElementById("middle")!;
middle.addEventListener("click", () => {
  const text = middle.textContent === null ? "" : middle.textContent;
  middle.textContent = text + " edited in the middle";
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-damage-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

const steps = "wait 250 | wait 250 | wait 250 | scrolltop #chat | click #middle | wait 150 | scrolltop #chat | wheel #chat -300 | wheel #chat -200 | scrolltop #chat | wait 200";
const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: steps,
    NATIVE_INCREMENTAL_LAYOUT: "1",
    NATIVE_VERIFY_DAMAGE: "1",
    NATIVE_FRAME_TIMES: "1",
    NATIVE_DAMAGE_STATS: "1",
  },
});
if (r.status !== 0) throw new Error(`run failed\n${r.stderr}\n${r.stdout}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const damage: { limited: number; rects: number; reason: string }[] = [];
const verify: { bad: number; rects: number; frame: number }[] = [];
for (const line of r.stderr.split("\n")) {
  const d = /^native: damage limited=(\d+) rects=(\d+) reason=(\S+)/.exec(line);
  if (d !== null) damage.push({ limited: Number(d[1]), rects: Number(d[2]), reason: d[3] });
  const v = /^native: damage verify mismatched=(\d+) rects=(\d+) frame=(\d+)$/.exec(line);
  if (v !== null) verify.push({ bad: Number(v[1]), rects: Number(v[2]), frame: Number(v[3]) });
}

const limited = damage.filter((d) => d.limited === 1);
check("some frames painted only damage", limited.length > 0, `${damage.length} painted frames`);
check("damaged frames name rectangles", limited.every((d) => d.rects > 0 && d.rects <= 8),
  JSON.stringify(limited.slice(0, 5)));
check("the verify pass ran", verify.length > 0, `${verify.length} verifications`);
check("damaged frames match the full repaint", verify.every((v) => v.bad === 0),
  JSON.stringify(verify.filter((v) => v.bad > 0).slice(0, 5)));
check("nothing outside the damage is left stale", verify.every((v) => v.frame === 0),
  JSON.stringify(verify.filter((v) => v.frame > 0).slice(0, 5)));
check("a scroll composites its scrollport", damage.some((d) => d.reason === "composite"),
  JSON.stringify(damage) + " stdout=" + JSON.stringify(r.stdout.trim().split("\n")));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
