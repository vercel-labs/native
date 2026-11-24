// `native dev` in island mode: a script edit is rerun in the page that is already open. The
// fixture's script logs what it does, so the test watches stdout for the new bundle, for the
// host process keeping its pid, and for the interval the last bundle started being cleared.
//
//   node tests/dev-island.ts

import { execFileSync, spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const CLI = join(ROOT, "compiler", "cli.ts");
const FIXTURE = join(ROOT, "tests", "fixtures", "dev-island");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const { libnodePack } = await import("../compiler/dev-host.ts");
if (libnodePack() === null) {
  console.log("skipped: no @scriptc/libnode pack for this platform");
  process.exit(0);
}

const appDir = mkdtempSync(join(process.env["TMPDIR"] ?? "/tmp", "native-dev-island-"));
cpSync(FIXTURE, appDir, { recursive: true });
const appFile = join(appDir, "app.ts");
const original = readFileSync(appFile, "utf8");

const lines: string[] = [];
const dev: ChildProcess = spawn(process.execPath, [CLI, "dev", appDir], {
  stdio: ["ignore", "pipe", "pipe"],
});
for (const stream of [dev.stdout, dev.stderr]) {
  let pending = "";
  stream?.on("data", (chunk: Buffer) => {
    pending += chunk.toString("utf8");
    const done = pending.split("\n");
    pending = done.pop() ?? "";
    for (const line of done) lines.push(line);
  });
}
dev.on("exit", (code) => {
  if (code !== 0 && code !== null) lines.push(`native: dev exited ${code}`);
});

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(text: string, ms: number, from = 0): Promise<boolean> {
  const deadline = performance.now() + ms;
  while (performance.now() < deadline) {
    if (lines.slice(from).some((line) => line.includes(text))) return true;
    await sleep(25);
  }
  return false;
}

/** A dev command's own child that is the dev host (the coverage check runs children too). */
function hostPidOf(commandPid: number | undefined): number {
  try {
    const out = execFileSync("pgrep", ["-P", String(commandPid)], { encoding: "utf8" }).trim();
    const pids = out.split(/\s+/).filter(Boolean).map(Number);
    for (const pid of pids.reverse()) {
      try {
        const command = execFileSync("ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8" });
        if (command.includes("dev-host")) return pid;
      } catch {
        /* already gone */
      }
    }
    return 0;
  } catch {
    return 0;
  }
}

/** The dev host of this test's session. */
function hostPid(): number {
  return hostPidOf(dev.pid);
}

// The first run on a machine builds the dev host, which compiles the whole SDK runtime.
const started = await waitFor("app started", 600_000);
check("the app's scripts ran in the host", started, lines.slice(-6).join(" | "));
check("the click reached the page", await waitFor("out clicked true true", 5000));
const pid = hostPid();
check("the host process is up", pid !== 0);

// ---------------------------------------------------------------------------
// A script edit reruns in the open page

const before = lines.length;
writeFileSync(appFile, `${original}\nconsole.log("app updated");\n`);
const t0 = performance.now();
check("the new bundle ran", await waitFor("app updated", 2000, before), `${(performance.now() - t0).toFixed(0)}ms`);
// The bundle's output can reach the pipes before the acknowledgement line does.
const timed = await waitFor("reloaded scripts in", 500, before);
const reload = lines.filter((line) => line.includes("reloaded scripts in")).at(-1) ?? "";
check("the dev command timed the reload", timed && /reloaded scripts in \d+ms/.test(reload), reload);
check("the host was not relaunched", hostPid() === pid);

// The interval the last bundle started is cleared: the new page counts from one, once.
const tickStart = lines.length;
await sleep(1000);
const ticks = lines
  .slice(tickStart)
  .map((line) => /^tick (\d+)$/.exec(line.trim()))
  .filter((m) => m !== null)
  .map((m) => Number(m![1]));
const ordered = ticks.every((n, i) => i === 0 || n === ticks[i - 1]! + 1);
check("one interval runs after the reload", ticks.length > 0 && ordered, ticks.join(","));
check("the old interval stopped", ticks.length <= 7, `${ticks.length} ticks in 1s`);

// ---------------------------------------------------------------------------
// A failing edit keeps the window; the next good one recovers

writeFileSync(appFile, `${original}\nthrow new Error("boom");\n`);
check("a top-level throw is reported", await waitFor("boom", 2000), lines.slice(-4).join(" | "));
check("the window survived the throw", hostPid() === pid);

writeFileSync(appFile, `${original}\nconsole.log("recovered");\n`);
check("a fixed edit recovers", await waitFor("recovered", 2000));
check("the host still has its pid", hostPid() === pid);

// ---------------------------------------------------------------------------
// A build's refusals, in dev: the load hook, and the background coverage check

// An import the compiler refuses fails in the island with the compiler's diagnostic, because the
// island runs the app under the same load hook a build's Node islands run under.
writeFileSync(appFile, `${original}\nimport "node:domain";\n`);
check("an unsupported builtin is refused", await waitFor("[SC1010]", 8000), lines.slice(-4).join(" | "));
check("the window survived the refusal", hostPid() === pid);

// The coverage check runs in the background after the rebuild and reports the app's own problem.
const findingsFile = join(appDir, ".native", "dev-findings.json");
writeFileSync(appFile, `${original}\nconst bad: number = "x";\n`);
const findingAt = lines.length;
check("coverage reports a type error after an edit",
  await waitFor("SC0001", 90_000, findingAt) && lines.slice(findingAt).some((line) => line.includes("coverage: app.ts:")),
  lines.slice(-4).join(" | "));
check("the window survived the coverage finding", hostPid() === pid);
check("the finding reaches the page's report", await (async () => {
  for (let i = 0; i < 300; i++) {
    try {
      if (readFileSync(findingsFile, "utf8").includes("SC0001")) return true;
    } catch {
      /* not written yet */
    }
    await sleep(100);
  }
  return false;
})());

// A clean edit clears the panel: the report is rewritten with no findings.
writeFileSync(appFile, original);
check("a fixed edit clears the coverage report", await (async () => {
  for (let i = 0; i < 600; i++) {
    try {
      if (readFileSync(findingsFile, "utf8").includes('"findings":[]')) return true;
    } catch {
      /* not written yet */
    }
    await sleep(100);
  }
  return false;
})());

// ---------------------------------------------------------------------------
// A bundle that does not build opens no window; the first save that does opens it

const brokenDir = mkdtempSync(join(process.env["TMPDIR"] ?? "/tmp", "native-dev-island-broken-"));
cpSync(FIXTURE, brokenDir, { recursive: true });
const brokenFile = join(brokenDir, "app.ts");
writeFileSync(brokenFile, `import { nothing } from "no-such-package";\nconsole.log(nothing);\n`);
const brokenLines: string[] = [];
const broken = spawn(process.execPath, [CLI, "dev", brokenDir], { stdio: ["ignore", "pipe", "pipe"] });
for (const stream of [broken.stdout, broken.stderr]) {
  let pending = "";
  stream?.on("data", (chunk: Buffer) => {
    pending += chunk.toString("utf8");
    const done = pending.split("\n");
    pending = done.pop() ?? "";
    for (const line of done) brokenLines.push(line);
  });
}
const waitBroken = async (text: string, ms: number): Promise<boolean> => {
  const deadline = performance.now() + ms;
  while (performance.now() < deadline) {
    if (brokenLines.some((line) => line.includes(text))) return true;
    await sleep(25);
  }
  return false;
};
check("a bundle that does not build says so", await waitBroken("the scripts did not bundle", 300_000),
  brokenLines.slice(-4).join(" | "));
check("no window runs a bundle that does not exist", hostPidOf(broken.pid) === 0);
writeFileSync(brokenFile, original);
check("the first save that builds opens the window", await waitBroken("reloaded scripts in", 60_000),
  brokenLines.slice(-4).join(" | "));
check("the window is a dev host", hostPidOf(broken.pid) !== 0);
broken.kill("SIGINT");
await new Promise<void>((resolve) => broken.once("exit", () => resolve()));

dev.kill("SIGINT");
await new Promise<void>((resolve) => dev.once("exit", () => resolve()));
writeFileSync(appFile, original);
process.exit(failed === 0 ? 0 : 1);
