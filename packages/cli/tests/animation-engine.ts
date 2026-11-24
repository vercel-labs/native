// CSS transitions and animations as they run: the values they show while they move, the frame
// clock that drives them, and the events they send. Headless time starts at zero and `frame <ms>`
// moves it, so every value here is exact.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-anim-engine-"));

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>anim engine</title>
<style>
#t1 { width: 100px; transition: width 1s linear 200ms; }
#t1.go { width: 200px; }
#t2 { background-color: rgb(0, 0, 0); opacity: 1; transition: all 1s linear; }
#t2.go { background-color: rgb(200, 100, 0); opacity: 0.5; }
#t3 { width: 0px; transition: width 1s steps(4, end); }
#t3.go { width: 100px; }
#t4 { width: 10px; height: 10px; transition: width 1s linear; }
#t4.go { width: 20px; height: 20px; }
#t5 { width: 100px; transition: width 1s linear; }
#t5.go { width: 200px; }
#t6 { width: 0px; transition: width 1s linear; }
@keyframes move { from { width: 0px; } 50% { width: 100px; } to { width: 20px; } }
#a1 { width: 5px; animation: move 1s linear; }
#a1.bump { color: rgb(1, 2, 3); }
@keyframes fade { from { opacity: 0; } to { opacity: 1; } }
#a2 { opacity: 1; animation: fade 1s linear 500ms 2 alternate forwards; }
#a3 { opacity: 0.25; animation: fade 1s linear 1s infinite paused backwards; }
</style>
</head><body>
<div id="t1"></div><div id="t2"></div><div id="t3"></div><div id="t4"></div><div id="t5"></div><div id="t6"></div>
<div id="a1"></div><div id="a2"></div><div id="a3"></div>
<button id="go">go</button><button id="back">back</button>
<script>
  const cs = (id, prop) => getComputedStyle(document.getElementById(id)).getPropertyValue(prop);
  const events = {};
  for (const id of ['t1', 't2', 't3', 't4', 't5', 't6', 'a1', 'a2', 'a3']) {
    events[id] = [];
    for (const ev of ['transitionend', 'animationstart', 'animationiteration', 'animationend']) {
      document.getElementById(id).addEventListener(ev, (e) => {
        events[id].push(e.type + ':' + (e.propertyName || e.animationName) + ':' + e.elapsedTime);
      });
    }
  }
  document.getElementById('go').addEventListener('click', () => {
    for (const id of ['t1', 't2', 't3', 't4', 't5']) document.getElementById(id).classList.add('go');
    console.log('go');
  });
  document.getElementById('back').addEventListener('click', () => {
    document.getElementById('t5').classList.remove('go');
    // A style pass in the middle of an animation must not restart it.
    document.getElementById('a1').classList.add('bump');
    // A transition a script starts by setting an inline style.
    document.getElementById('t6').style.setProperty('width', '50px');
    console.log('back');
  });
  let n = 0;
  function loop() {
    if (n === 10) {
      for (const id of ['t1', 't2', 't3', 't4', 't5', 't6', 'a1', 'a2', 'a3']) console.log('events ' + id + '=' + events[id].join(','));
    }
    console.log('f' + n + ' t1=' + cs('t1', 'width') + ' t2=' + cs('t2', 'background-color') + '/' + cs('t2', 'opacity') +
      ' t3=' + cs('t3', 'width') + ' t4=' + cs('t4', 'width') + '/' + cs('t4', 'height') +
      ' t5=' + cs('t5', 'width') + ' t6=' + cs('t6', 'width') +
      ' a1=' + cs('a1', 'width') + ' a2=' + cs('a2', 'opacity') + ' a3=' + cs('a3', 'opacity'));
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

const steps = [
  "click #go", "frame 0", "frame 100", "frame 500", "click #back", "frame 700", "frame 1000",
  "frame 1200", "frame 1500", "frame 2000", "frame 2500", "frame 3000", "frame 3500",
].join(" | ");

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png"), NATIVE_STEPS: steps },
});
const got = r.stdout.split("\n").slice(0, -1);
// t1 has a 200ms delay and 1s of linear width; t2 transitions everything; t3 holds each step;
// t4 only transitions width; t5 reverses from where it had got to; a1 runs a three-block
// keyframes; a2 has a delay, two alternate iterations and a forward fill; a3 is paused.
const want = [
  "go",
  "f0 t1=100px t2=rgb(0, 0, 0)/1 t3=0px t4=10px/20px t5=100px t6=0px a1=0px a2=1 a3=0",
  "f1 t1=100px t2=rgb(20, 10, 0)/0.95 t3=0px t4=11px/20px t5=110px t6=0px a1=20px a2=1 a3=0",
  "f2 t1=130px t2=rgb(100, 50, 0)/0.75 t3=50px t4=15px/20px t5=150px t6=0px a1=100px a2=0 a3=0",
  "back",
  "f3 t1=150px t2=rgb(140, 70, 0)/0.65 t3=50px t4=17px/20px t5=140px t6=10px a1=68px a2=0.2 a3=0",
  "f4 t1=180px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=125px t6=25px a1=5px a2=0.5 a3=0",
  "f5 t1=200px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=115px t6=35px a1=5px a2=0.7 a3=0",
  "f6 t1=200px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=100px t6=50px a1=5px a2=1 a3=0",
  "f7 t1=200px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=100px t6=50px a1=5px a2=0.5 a3=0",
  "f8 t1=200px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=100px t6=50px a1=5px a2=0 a3=0",
  "f9 t1=200px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=100px t6=50px a1=5px a2=0 a3=0",
  "events t1=transitionend:width:1",
  "events t2=transitionend:background-color:1,transitionend:opacity:1",
  "events t3=transitionend:width:1",
  "events t4=transitionend:width:1",
  "events t5=transitionend:width:1",
  "events t6=transitionend:width:1",
  "events a1=animationstart:move:0,animationend:move:1",
  "events a2=animationstart:fade:0,animationiteration:fade:1,animationend:fade:2",
  "events a3=",
  "f10 t1=200px t2=rgb(200, 100, 0)/0.5 t3=100px t4=20px/20px t5=100px t6=50px a1=5px a2=0 a3=0",
];
const ok = r.status === 0 && JSON.stringify(got) === JSON.stringify(want);
console.log(`${ok ? "ok  " : "FAIL"} transitions and animations run on the frame clock`);
if (!ok) console.log(`  got ${JSON.stringify(got, null, 1)}\n  want ${JSON.stringify(want, null, 1)}\n${r.stderr}`);
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
