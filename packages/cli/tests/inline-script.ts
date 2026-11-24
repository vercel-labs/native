// Inline <script> is compiled like an external classic script, in document order.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-inline-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><title>Inline</title></head><body>
<p id="out">start</p>
<script>
  var out = document.getElementById('out');
  out.textContent = 'a';
</script>
<script src="mid.js"></script>
<script>
  document.getElementById('out').textContent += 'c';
</script>
</body></html>`);
writeFileSync(join(dir, "mid.js"), `document.getElementById('out').textContent += 'b';\n`);

const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) {
  console.error(b.stderr);
  process.exit(1);
}

const r = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "print #out", NATIVE_SNAPSHOT: join(dir, "out.png") },
});
const got = r.stdout.split("\n").slice(0, -1);
const ok = r.status === 0 && JSON.stringify(got) === JSON.stringify(["abc"]);
console.log(`${ok ? "ok  " : "FAIL"} inline and external scripts run in document order`);
if (!ok) console.log(`  got ${JSON.stringify(got)} (exit ${r.status})\n${r.stderr}`);
console.log(ok ? "\nall passed" : "\n1 failed");
process.exit(ok ? 0 : 1);
