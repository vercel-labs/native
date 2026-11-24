// Walks the accessibility tree of a running app over UI Automation, the way a screen reader does,
// so the Windows host's provider is checked by a real client instead of by its own code:
//   node tests/uia.ts
//
// It builds the counter example, starts it, has tests/uia/check.ps1 find the window, name its
// buttons, invoke one and read the page again, and checks that the page answered. A client's first
// call can land before the provider is ready, so the whole check is tried twice before it fails.

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

interface Check {
  window?: string;
  buttons?: string[];
  invoked?: boolean;
  before?: string[];
  after?: string[];
  error?: string;
}

const WANT_BUTTONS = ["−", "Reset", "+"];

let failed = 0;

function check(name: string, ok: boolean, detail = ""): boolean {
  console.log(`${ok ? "ok  " : "FAIL"} uia: ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
  if (!ok) failed++;
  return ok;
}

/** Builds the example into a directory of its own, and returns the executable's path. */
function build(dir: string): string | null {
  const exe = join(dir, "counter");
  const built = spawnSync(process.execPath, ["compiler/cli.ts", "build", "../../examples/counter", "-o", exe], {
    encoding: "utf8",
  });
  if (built.status !== 0) {
    console.error(((built.stdout ?? "") + (built.stderr ?? "")).split("\n").slice(-8).join("\n"));
    return null;
  }
  return exe + ".exe";
}

/** Runs the client against a started app and returns what it saw. */
async function query(exe: string): Promise<{ seen: Check; why: string }> {
  const app = spawn(exe, [], { stdio: "ignore" });
  const exited = new Promise<void>((settle) => {
    const timer = setTimeout(settle, 5000);
    app.once("exit", () => {
      clearTimeout(timer);
      settle();
    });
  });
  try {
    const client = spawnSync(
      "powershell",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join("tests", "uia", "check.ps1"),
       "-ProcessId", String(app.pid), "-TimeoutMs", "20000"],
      { encoding: "utf8", timeout: 60000 },
    );
    const text = (client.stdout ?? "").trim();
    const line = text.split("\n").map((l) => l.trim()).filter((l) => l.startsWith("{")).pop();
    if (line === undefined) return { seen: {}, why: `client printed nothing usable: ${text.slice(-200)}` };
    return { seen: JSON.parse(line) as Check, why: "" };
  } finally {
    spawnSync("taskkill", ["/PID", String(app.pid), "/F"], { stdio: "ignore" });
    // The executable's file stays open until the process has really gone, and the temporary
    // directory cannot be removed before then.
    await exited;
  }
}

/** Whether what the client saw is what a screen reader should: a named window, its buttons, and a
 *  page that answered the invoke. */
function judge(seen: Check): boolean {
  const buttons = seen.buttons ?? [];
  return seen.error === undefined && seen.window === "Counter" &&
    WANT_BUTTONS.every((name) => buttons.includes(name)) && seen.invoked === true &&
    JSON.stringify(seen.before ?? []) !== JSON.stringify(seen.after ?? []);
}

async function main(): Promise<void> {
  if (process.platform !== "win32") {
    console.log("ok   uia: only Windows runs a UI Automation client");
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), "native-uia-"));
  try {
    const exe = build(dir);
    if (!check("the counter example builds", exe !== null)) return;
    let seen: Check = {};
    let why = "";
    let ok = false;
    for (let tries = 0; tries < 2 && !ok; tries++) {
      const attempt = await query(exe as string);
      seen = attempt.seen;
      why = attempt.why;
      ok = judge(seen);
    }
    check("a client finds the window by its name", seen.window === "Counter",
          seen.error ?? `window is '${seen.window ?? ""}'`);
    check("its buttons are named",
          WANT_BUTTONS.every((name) => (seen.buttons ?? []).includes(name)),
          `buttons are ${JSON.stringify(seen.buttons ?? [])}`);
    check("invoking one changes the page",
          seen.invoked === true && JSON.stringify(seen.before ?? []) !== JSON.stringify(seen.after ?? []),
          seen.error ?? "invoking a button left the page as it was");
    if (seen.before !== undefined) {
      console.log(`     tree: ${seen.before.filter((name) => name !== "").join(" | ")}`);
    }
    if (!ok && why !== "") console.log(`     ${why}`);
  } finally {
    // A directory that cannot be removed yet is not a failed check.
    try {
      rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch {
      // Leaving it in the temp directory is harmless.
    }
  }
}

await main();
if (failed > 0) {
  console.error(`${failed} accessibility check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("the accessibility tree answers a real UI Automation client");
