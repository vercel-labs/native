// The events a transition has over its whole life (transitionrun, transitionstart,
// transitioncancel) and the way getAnimations() reports what is running. A transition and an
// animation are both canceled by `display: none`, which is what sends the cancel events.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-anim-events-"));

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>anim events</title>
<style>
#t1 { width: 0px; transition: width 1s linear 200ms; }
#t1.go { width: 100px; }
#t1.hide { display: none; }
@keyframes spin { from { opacity: 0; } to { opacity: 1; } }
#a1 { animation: spin 1s linear; }
#a1.hide { display: none; }
</style>
</head><body>
<div id="t1"></div><div id="a1"></div>
<button id="go">go</button><button id="stop">stop</button>
<script>
  const events = {};
  for (const id of ['t1', 'a1']) {
    events[id] = [];
    for (const ev of ['transitionrun', 'transitionstart', 'transitionend', 'transitioncancel',
      'animationstart', 'animationiteration', 'animationend', 'animationcancel']) {
      document.getElementById(id).addEventListener(ev, (e) => {
        events[id].push(e.type + ':' + (e.propertyName || e.animationName) + ':' + e.elapsedTime);
      });
    }
  }
  document.getElementById('go').addEventListener('click', () => {
    document.getElementById('t1').classList.add('go');
  });
  document.getElementById('stop').addEventListener('click', () => {
    document.getElementById('t1').classList.add('hide');
    document.getElementById('a1').classList.add('hide');
  });
  let n = 0;
  let watched = null;
  function loop() {
    if (n === 0) {
      const t = document.getElementById('t1').getAnimations();
      console.log('count t1=' + t.length + ' doc=' + document.getAnimations().length);
      for (const a of t) {
        console.log('found ' + a.transitionProperty + ' ' + a.animationName + ' ' + a.playState);
        watched = a;
        a.finished.then(() => console.log('finished ' + a.transitionProperty));
      }
      const all = document.getElementById('a1').getAnimations();
      console.log('count a1=' + all.length + ' name=' + (all.length > 0 ? all[0].animationName : '-'));
    }
    if (n === 2) {
      const t = document.getElementById('t1').getAnimations()[0];
      const a = document.getElementById('a1').getAnimations()[0];
      console.log('state t1=' + t.playState + ':' + t.currentTime + ' a1=' + a.playState + ':' + a.currentTime +
        ' doc=' + document.getAnimations().length + ' subtree=' + document.documentElement.getAnimations({ subtree: true }).length);
    }
    if (n === 4) {
      console.log('events t1=' + events['t1'].join(','));
      console.log('events a1=' + events['a1'].join(','));
    }
    if (n === 3) {
      console.log('after t1=' + document.getElementById('t1').getAnimations().length +
        ' a1=' + document.getElementById('a1').getAnimations().length +
        ' doc=' + document.getAnimations().length + ' watched=' + (watched === null ? 'none' : watched.playState));
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

const steps = ["click #go", "frame 0", "frame 100", "frame 500", "click #stop", "frame 1000", "frame 1500"].join(" | ");

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png"), NATIVE_STEPS: steps },
});
const got = r.stdout.split("\n").slice(0, -1);
// The click makes the transition (transitionrun at once) and the animation is already running.
// At 500ms the transition has left its 200ms delay (transitionstart) and both are canceled by
// display: none, which reports the active time each had run for. A canceled transition settles
// its finished promise.
const want = [
  "count t1=1 doc=2",
  "found width  running",
  "count a1=1 name=spin",
  "state t1=running:500 a1=running:500 doc=2 subtree=2",
  "finished width",
  "after t1=0 a1=0 doc=0 watched=idle",
  "events t1=transitionrun:width:0,transitionstart:width:0,transitioncancel:width:0.3",
  "events a1=animationstart:spin:0,animationcancel:spin:0.5",
];
const ok = r.status === 0 && JSON.stringify(got) === JSON.stringify(want);
console.log(`${ok ? "ok  " : "FAIL"} transitions and animations report their events and getAnimations`);
if (!ok) console.log(`  got ${JSON.stringify(got, null, 1)}\n  want ${JSON.stringify(want, null, 1)}\n${r.stderr}`);
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
