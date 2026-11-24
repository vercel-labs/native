// localStorage is a JSON file next to the app's other state. The file and the directories that
// hold it belong to the user running the app, so they are created 0600 and 0700 and a rewrite
// narrows a file that was wider; a later run reads the values back.
//   npm test

import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

function mode(path: string): number {
  return existsSync(path) ? statSync(path).mode & 0o777 : -1;
}

function describe(path: string): string {
  return `${path} is ${mode(path).toString(8)}`;
}

// The permissions below are the Linux host's own file handling.
if (process.platform !== "linux") {
  console.log("ok   the state file is 0600 in a 0700 directory (skipped on this platform)");
  console.log("\nall passed");
  process.exit(0);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=120"></head><body>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const before = localStorage.getItem("theme") ?? "none";
requestAnimationFrame(() => {
  localStorage.setItem("theme", "dark");
  localStorage.setItem("size", "42");
  console.log("before=" + before);
});
`;

const dir = mkdtempSync(join(tmpdir(), "native-storage-file-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const exe = join(dir, "app");
const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (b.status !== 0) throw new Error(`build failed\n${b.stderr}`);

// The umask a login shell usually has: anything the host leaves to it is world readable.
process.umask(0o022);

function run(store: string): string {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_SNAPSHOT: join(dir, "out.png"), NATIVE_STEPS: "frame | frame", NATIVE_STORAGE: store },
  });
  if (r.status !== 0) throw new Error(`run failed (exit ${r.status ?? r.signal})\n${r.stderr}`);
  return r.stdout;
}

const store = join(dir, "state", "app", "localStorage.json");
run(store);
const saved = existsSync(store) ? readFileSync(store, "utf8") : "";
check("the app writes its state", saved !== "", store);
check("the state file is 0600", mode(store) === 0o600, describe(store));
const stateDir = join(dir, "state", "app");
check("the directories holding it are 0700", mode(stateDir) === 0o700, describe(stateDir));
check("the file holds the values it set", saved !== "" && JSON.parse(saved).theme === "dark", saved.slice(0, 80));

const again = run(store);
check("a later run reads the state back", again.includes("before=dark"), again.trim());

// A file and its temp left by an earlier run can be wider than the app would now make them.
const wider = join(dir, "wider");
mkdirSync(wider);
chmodSync(wider, 0o755);
const widerStore = join(wider, "localStorage.json");
writeFileSync(widerStore, "{}");
chmodSync(widerStore, 0o644);
writeFileSync(`${widerStore}.tmp`, "{}");
chmodSync(`${widerStore}.tmp`, 0o666);
run(widerStore);
check("a rewrite narrows a state file that was 0644", mode(widerStore) === 0o600, describe(widerStore));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
