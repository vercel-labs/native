// Drives the input method's composition through the Windows host, the way a keyboard does: the app
// is started with NATIVE_IME_TEST set (which gives its window an IME context), tests/ime/drive.ps1
// posts the input method's own messages — a preview, then a commit — and the app prints what the
// page's composition events told it, which is what this reads. A run that never sees the composing
// text, or never commits the chosen text, fails.
//   node tests/ime.ts

import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PREVIEW = "にほん";
const COMMIT = "日本";

let failed = 0;

function check(name: string, ok: boolean, detail = ""): boolean {
  console.log(`${ok ? "ok  " : "FAIL"} ime: ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
  if (!ok) failed++;
  return ok;
}

/** Builds the example into a directory of its own, and returns the executable's path. */
function build(dir: string): string | null {
  const exe = join(dir, "ime");
  const built = spawnSync(process.execPath, ["compiler/cli.ts", "build", "../../examples/ime", "-o", exe], {
    encoding: "utf8",
  });
  if (built.status !== 0) {
    console.error(((built.stdout ?? "") + (built.stderr ?? "")).split("\n").slice(-8).join("\n"));
    return null;
  }
  return exe + ".exe";
}

/** Starts the app, has the driver post the composition, and returns the lines the page printed. */
async function drive(exe: string): Promise<string[]> {
  const app = spawn(exe, [], { stdio: ["ignore", "pipe", "ignore"], env: { ...process.env, NATIVE_IME_TEST: "1" } });
  const lines: string[] = [];
  let partial = "";
  app.stdout?.setEncoding("utf8");
  app.stdout?.on("data", (chunk: string) => {
    partial += chunk;
    let at = partial.indexOf("\n");
    while (at >= 0) {
      lines.push(partial.slice(0, at));
      partial = partial.slice(at + 1);
      at = partial.indexOf("\n");
    }
  });
  const exited = new Promise<void>((settle) => {
    const timer = setTimeout(settle, 5000);
    app.once("exit", () => {
      clearTimeout(timer);
      settle();
    });
  });
  try {
    const driver = spawnSync(
      "powershell",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join("tests", "ime", "drive.ps1"),
       "-ProcessId", String(app.pid)],
      { encoding: "utf8", timeout: 60000 },
    );
    if (driver.status !== 0) return [];
    // The commit is posted 700 ms after the preview; give the page a moment to say so.
    const until = Date.now() + 5000;
    while (Date.now() < until && !lines.some((line) => line.startsWith("end "))) {
      await new Promise((settle) => setTimeout(settle, 100));
    }
    return lines;
  } finally {
    spawnSync("taskkill", ["/PID", String(app.pid), "/F"], { stdio: "ignore" });
    await exited;
  }
}

/** Whether the page saw the composing text in the field and then the committed text in its place. */
function judge(lines: string[]): boolean {
  const preview = lines.some((line) => line.startsWith("update ") && line.includes(PREVIEW));
  const commit = lines.some((line) => line.startsWith("end ") && line.includes(COMMIT));
  return preview && commit;
}

async function main(): Promise<void> {
  if (process.platform !== "win32") {
    console.log("ok   ime: only Windows drives an input method's messages");
    return;
  }
  const dir = mkdtempSync(join(tmpdir(), "native-ime-"));
  try {
    const exe = build(dir);
    if (!check("the composition example builds", exe !== null)) return;
    let lines: string[] = [];
    for (let tries = 0; tries < 2 && !judge(lines); tries++) lines = await drive(exe as string);
    const preview = lines.find((line) => line.startsWith("update ") && line.includes(PREVIEW)) ?? "";
    const commit = lines.find((line) => line.startsWith("end ") && line.includes(COMMIT)) ?? "";
    check("the composing text is in the field before it is committed", preview !== "",
          lines.length === 0 ? "the page printed nothing" : `printed ${JSON.stringify(lines.slice(-4))}`);
    check("the committed text replaces it", commit !== "", `printed ${JSON.stringify(lines.slice(-4))}`);
    if (preview !== "") console.log(`     preview: ${preview}`);
    if (commit !== "") console.log(`     commit:  ${commit}`);
  } finally {
    try {
      rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    } catch {
      // Leaving it in the temp directory is harmless.
    }
  }
}

await main();
if (failed > 0) {
  console.error(`${failed} composition check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
console.log("the input method composes into the page, and the page commits what it chose");
