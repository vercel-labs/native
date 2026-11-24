// A page's scripts run with the DOM in place, and its load events come in the browser's order:
// DOMContentLoaded at the document with readyState "interactive", then load at the window with
// "complete". A <body onload> attribute runs as a load handler, timers run after the page, and a
// script's CDATA wrapper is markup, not script.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-load-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>Load events</title></head>
<body onload="document.getElementById('body').textContent = document.readyState;">
<p id="log"></p><p id="body"></p><p id="timer"></p>
<script><![CDATA[
  document.getElementById('log').textContent = document.readyState;
  document.addEventListener('DOMContentLoaded', function () {
    document.getElementById('log').textContent += '|' + document.readyState;
  });
  window.onload = function () {
    document.getElementById('log').textContent += '|' + document.readyState;
  };
  setTimeout(function () {
    document.getElementById('timer').textContent = 'ran';
  }, 0);
]]></script>
</body></html>`);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: {
    ...process.env,
    NATIVE_STEPS: "print #log | print #body | print #timer",
    NATIVE_SNAPSHOT: join(dir, "out.png"),
  },
});
const got = r.stdout.split("\n").slice(0, -1);
const want = ["loading|interactive|complete", "complete", "ran"];
const ok = r.status === 0 && JSON.stringify(got) === JSON.stringify(want);
console.log(`${ok ? "ok  " : "FAIL"} scripts, DOMContentLoaded, load, body onload and timers`);
if (!ok) console.log(`  got ${JSON.stringify(got)} (exit ${r.status}), want ${JSON.stringify(want)}\n${r.stderr}`);
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
