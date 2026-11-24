// `prefers-reduced-motion: reduce` reaching @media and matchMedia, with an author sheet that
// turns animations and transitions off under it, as the usual accessibility pattern does.
// The preference is pinned per run with NATIVE_REDUCED_MOTION.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-reduced-motion-"));

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>reduced motion</title>
<style>
@keyframes pulse { from { opacity: 0; } to { opacity: 1; } }
#m1 { opacity: 1; animation: pulse 1s linear infinite; }
#m2 { width: 0px; transition: width 1s linear; }
#m2.go { width: 100px; }
@media (prefers-reduced-motion: reduce) {
  #m1 { animation: none; }
  #m2 { transition: none; }
}
</style>
</head><body>
<div id="m1"></div><div id="m2"></div>
<button id="go">go</button>
<script>
  const cs = (id, prop) => getComputedStyle(document.getElementById(id)).getPropertyValue(prop);
  document.getElementById('go').addEventListener('click', () => {
    document.getElementById('m2').classList.add('go');
  });
  let n = 0;
  function loop() {
    if (n === 1) {
      console.log('f' + n + ' reduced=' + matchMedia('(prefers-reduced-motion: reduce)').matches +
        ' anims=' + document.getAnimations().length +
        ' m1=' + cs('m1', 'opacity') + ' m2=' + cs('m2', 'width'));
    }
    n++;
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
</script>
</body></html>`);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

const steps = ["click #go", "frame 0", "frame 500"].join(" | ");
const run = (pin: string): string[] => {
  const r = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_STEPS: steps, NATIVE_REDUCED_MOTION: pin } });
  if (r.status !== 0) {
    console.error(r.stderr);
    process.exit(1);
  }
  return r.stdout.split("\n").slice(0, -1);
};

// Midway through 1s: the pulse is at half opacity and the width transition at half its travel.
// Under reduce, the sheet's own rules leave neither running, so both show their final values.
const moving = run("0");
const still = run("1");
const want = ["f1 reduced=false anims=2 m1=0.5 m2=50px"];
const wantStill = ["f1 reduced=true anims=0 m1=1 m2=100px"];
const ok = JSON.stringify(moving) === JSON.stringify(want) && JSON.stringify(still) === JSON.stringify(wantStill);
console.log(`${ok ? "ok  " : "FAIL"} prefers-reduced-motion reaches @media and matchMedia`);
if (!ok) {
  console.log(`  got ${JSON.stringify([moving, still], null, 1)}\n  want ${JSON.stringify([want, wantStill], null, 1)}`);
}
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
