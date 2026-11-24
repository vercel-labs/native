// CSS transitions and animations: the longhands and shorthands, their computed values and the
// way they serialize, set both from a style sheet and from script.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-anim-"));

writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>anim</title>
<style>
#a { transition: opacity 200ms ease-in 50ms; }
#b { transition-property: width, background-color; transition-duration: 1s, 0.5s;
     transition-timing-function: linear, cubic-bezier(0.1, 0.7, 1, 0.1); transition-delay: 0s, 2s; }
#c { animation: spin 1s linear 2s infinite alternate both paused; }
#d { animation-name: none; animation-duration: 3s; }
#f { transition: all 1s linear; }
</style>
</head><body>
<div id="a"></div><div id="b"></div><div id="c"></div><div id="d"></div><div id="e"></div><div id="f"></div>
<script>
  const cs = (id) => getComputedStyle(document.getElementById(id));
  const val = (id, prop) => cs(id).getPropertyValue(prop);
  console.log('a prop=' + val('a', 'transition-property'));
  console.log('a dur=' + val('a', 'transition-duration'));
  console.log('a tf=' + val('a', 'transition-timing-function'));
  console.log('a delay=' + val('a', 'transition-delay'));
  console.log('a shorthand=' + val('a', 'transition'));
  console.log('b prop=' + val('b', 'transition-property'));
  console.log('b dur=' + val('b', 'transition-duration'));
  console.log('b tf=' + val('b', 'transition-timing-function'));
  console.log('b shorthand=' + val('b', 'transition'));
  console.log('c name=' + val('c', 'animation-name'));
  console.log('c dur=' + val('c', 'animation-duration'));
  console.log('c delay=' + val('c', 'animation-delay'));
  console.log('c iter=' + val('c', 'animation-iteration-count'));
  console.log('c dir=' + val('c', 'animation-direction'));
  console.log('c fill=' + val('c', 'animation-fill-mode'));
  console.log('c play=' + val('c', 'animation-play-state'));
  console.log('c shorthand=' + val('c', 'animation'));
  console.log('d name=' + val('d', 'animation-name'));
  console.log('d dur=' + val('d', 'animation-duration'));
  const e = document.getElementById('e');
  e.style.setProperty('transition', 'color 100ms steps(4, jump-start)');
  console.log('e prop=' + val('e', 'transition-property'));
  console.log('e tf=' + val('e', 'transition-timing-function'));
  e.style.setProperty('transition-duration', 'fast');
  console.log('e dur=' + val('e', 'transition-duration'));
  console.log('f prop=' + val('f', 'transition-property'));
  console.log('f dur=' + val('f', 'transition-duration'));
</script>
</body></html>`);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png") },
});
const got = r.stdout.split("\n").slice(0, -1);
const want = [
  "a prop=opacity",
  "a dur=0.2s",
  "a tf=ease-in",
  "a delay=0.05s",
  "a shorthand=opacity 0.2s ease-in 0.05s",
  "b prop=width, background-color",
  "b dur=1s, 0.5s",
  "b tf=linear, cubic-bezier(0.1, 0.7, 1, 0.1)",
  "b shorthand=width 1s linear 0s, background-color 0.5s cubic-bezier(0.1, 0.7, 1, 0.1) 2s",
  "c name=spin",
  "c dur=1s",
  "c delay=2s",
  "c iter=infinite",
  "c dir=alternate",
  "c fill=both",
  "c play=paused",
  "c shorthand=1s linear 2s infinite alternate both paused spin",
  "d name=none",
  "d dur=3s",
  "e prop=color",
  "e tf=steps(4, start)",
  "e dur=0.1s",
  "f prop=all",
  "f dur=1s",
];
const ok = r.status === 0 && JSON.stringify(got) === JSON.stringify(want);
console.log(`${ok ? "ok  " : "FAIL"} transition and animation values parse, compute and serialize`);
if (!ok) console.log(`  got ${JSON.stringify(got, null, 1)}\n  want ${JSON.stringify(want, null, 1)}\n${r.stderr}`);
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
