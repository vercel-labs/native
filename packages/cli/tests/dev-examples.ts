// Every example reloads when its script changes. Each app is copied, started under `native dev`,
// and given the edit a developer would make — a line added to its script — and the dev command has
// to acknowledge the new bundle and the host has to run it. A classic `<script src="app.ts">` is
// part of the page's one classic scope, and its TypeScript is parsed as such; the canvas example
// keeps its script inline, so its page is what gets the edit.
//
//   node tests/dev-examples.ts               (every example)
//   node tests/dev-examples.ts ime webgl-cube  (just those)

import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const CLI = join(ROOT, "compiler", "cli.ts");
const EXAMPLES = join(ROOT, "..", "..", "examples");

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

const wanted = process.argv.slice(2);
const names = readdirSync(EXAMPLES, { withFileTypes: true })
  .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
  .map((entry) => entry.name)
  .filter((name) => wanted.length === 0 || wanted.includes(name))
  .sort();
if (names.length === 0) {
  console.error(`no such example: ${wanted.join(", ")}`);
  process.exit(2);
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** The line the dev command prints when the host ran the new bundle, or when it didn't. */
const RELOADED = "reloaded scripts in";
const FAILED = "script reload failed";

/**
 * Opens the app under `native dev` and answers whether one edit reaches the page. The command's
 * output is watched from the moment it starts, because the first bundle's build can be a minute.
 */
async function reloads(name: string): Promise<{ ok: boolean; detail: string }> {
  const source = join(EXAMPLES, name);
  const appDir = mkdtempSync(join(tmpdir(), `native-dev-${name}-`));
  // The app's own files, with its installed dependencies linked in from the checkout: an edit of
  // the copy never touches the example.
  cpSync(source, appDir, {
    recursive: true,
    filter: (from) => !["node_modules", ".native"].includes(basename(from)),
  });
  const modules = join(source, "node_modules");
  if (existsSync(modules)) symlinkSync(modules, join(appDir, "node_modules"), "dir");

  const scriptFile = join(appDir, "app.ts");
  // The script lives in index.html when the page carries it inline, as canvas does.
  const target = existsSync(scriptFile) ? scriptFile : join(appDir, "index.html");
  const original = readFileSync(target, "utf8");
  const marker = `native dev reloaded ${name}`;

  /**
   * Adds the marker to the copy: the first line of the script, or the first line of the page's
   * inline one. It goes first so it runs whatever the app's own code does after it — an example
   * whose first statements need a host feature the island answers differently still proves the
   * new bundle ran.
   */
  const edit = (attempt: number): void => {
    const line = `console.log(${JSON.stringify(`${marker} ${attempt}`)});`;
    if (target === scriptFile) {
      writeFileSync(target, `${line}\n${original}`);
      return;
    }
    const open = original.indexOf(">", original.indexOf("<script"));
    writeFileSync(target, `${original.slice(0, open + 1)}${line}\n${original.slice(open + 1)}`);
  };

  const lines: string[] = [];
  let dev: ChildProcess | null = null;
  try {
    dev = spawn(process.execPath, [CLI, "dev", appDir], { stdio: ["ignore", "pipe", "pipe"] });
    for (const stream of [dev.stdout, dev.stderr]) {
      let pending = "";
      stream?.on("data", (chunk: Buffer) => {
        pending += chunk.toString("utf8");
        const done = pending.split("\n");
        pending = done.pop() ?? "";
        for (const line of done) lines.push(line);
      });
    }
    const exited = (): boolean => dev === null || dev.exitCode !== null || dev.signalCode !== null;

    const waitFor = async (test: (line: string) => boolean, ms: number, from = 0): Promise<string | null> => {
      const deadline = performance.now() + ms;
      while (performance.now() < deadline) {
        const hit = lines.slice(from).find(test);
        if (hit !== undefined) return hit;
        if (exited()) return null;
        await sleep(20);
      }
      return null;
    };

    // The first session on a machine builds the dev host, which compiles the whole SDK runtime.
    const watching = await waitFor((line) => line.includes("watching") || line.includes("failed"), 600_000);
    if (watching === null || !watching.includes("watching")) {
      return { ok: false, detail: lines.slice(-6).join(" | ") || "the dev command did not start" };
    }
    // The page mounts a moment after the command starts watching; an edit that lands before it
    // would be the token the host reads on mount, so a second edit is made if the first is missed.
    await sleep(200);
    let from = lines.length;
    edit(1);
    let reloaded = await waitFor((line) => line.includes(RELOADED) || line.includes(FAILED), 20_000, from);
    if (reloaded === null || !reloaded.includes(RELOADED)) {
      from = lines.length;
      edit(2);
      reloaded = await waitFor((line) => line.includes(RELOADED) || line.includes(FAILED), 20_000, from);
    }
    if (reloaded === null) return { ok: false, detail: `no reload in 20s: ${lines.slice(-4).join(" | ")}` };
    if (!reloaded.includes(RELOADED)) return { ok: false, detail: reloaded };
    // The bundle's output can reach the pipe before the acknowledgement line does.
    if ((await waitFor((line) => line.includes(marker), 2000, from)) === null)
      return { ok: false, detail: `${reloaded}; the new bundle never printed its marker` };
    return { ok: true, detail: reloaded };
  } finally {
    if (dev !== null && dev.exitCode === null) {
      dev.kill("SIGINT");
      await new Promise<void>((resolve) => dev!.once("exit", () => resolve()));
    }
    rmSync(appDir, { recursive: true, force: true });
  }
}

for (const name of names) {
  const started = performance.now();
  const result = await reloads(name);
  const took = Math.round(performance.now() - started);
  check(`${name} reloads on a script edit (${took}ms)`, result.ok, result.detail);
}

console.log(failed === 0 ? `\nall ${names.length} examples reloaded` : `\n${failed} of ${names.length} examples did not reload`);
process.exit(failed === 0 ? 0 : 1);
