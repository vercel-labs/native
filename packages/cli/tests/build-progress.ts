// What a build says while it compiles: scriptc's phase timing read as one line per phase in a
// pipe or CI, and a live animated line in a terminal, with an estimate from the last build.
//   npm test

import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BuildProgress, formatDuration, nextBuildPhase, parseTimingLine, phaseForScriptcPhase } from "../compiler/progress.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// scriptc's timing lines

const timing = parseTimingLine('scriptc timing {"phase":"native-object","phase_ms":178707.9,"total_ms":249762.5}');
ok("a timing line is parsed", timing?.phase === "native-object" && timing.phaseMs === 178707.9 && timing.totalMs === 249762.5);
ok("a lowering line is parsed too", parseTimingLine('scriptc lowering {"phase":"ffi-validate","phase_ms":0.2,"total_ms":0.2}')?.phase === "ffi-validate");
ok("a warning is not a timing line", parseTimingLine("src/app.ts:4:2 - warning SC6014: something") === null);
ok("malformed timing JSON is not a timing line", parseTimingLine("scriptc timing {") === null);
ok("resolving is a phase", phaseForScriptcPhase("frontend-load") === "resolving");
ok("lowering is compiling", phaseForScriptcPhase("lower") === "compiling");
ok("the LLVM passes are generating", ["llvm-emit-rewrites", "llvm-emit-int32", "llvm-emit-analyses", "llvm-emit"].every((p) => phaseForScriptcPhase(p) === "generating"));
ok("the native object is optimizing", phaseForScriptcPhase("native-object") === "optimizing");
ok("so is the native compile that follows a cache miss", phaseForScriptcPhase("executable-cache-miss") === "optimizing");
ok("the link steps are linking", ["runtime-stage", "link-inputs", "native-link"].every((p) => phaseForScriptcPhase(p) === "linking"));
ok("cache bookkeeping is not shown", phaseForScriptcPhase("frontend-cache-miss") === null && phaseForScriptcPhase("complete") === null);
ok("a finished phase hands the line to the one now running",
  nextBuildPhase("frontend-load") === "compiling" && nextBuildPhase("lower") === "checking" &&
  nextBuildPhase("native-object") === "linking" && nextBuildPhase("native-link") === null);
ok("durations read as seconds and minutes", formatDuration(3210) === "3.2s" && formatDuration(178000) === "2m 58s");

// ---------------------------------------------------------------------------
// The reporter, both ways

function capture(tty: boolean): { stream: NodeJS.WriteStream; text: () => string } {
  let text = "";
  const stream = {
    isTTY: tty,
    write(chunk: string): boolean {
      text += chunk;
      return true;
    },
  } as unknown as NodeJS.WriteStream;
  return { stream, text: () => text };
}

{
  const out = capture(false);
  const progress = new BuildProgress({ stream: out.stream, tty: false });
  progress.beginScriptc();
  await sleep(180);
  progress.scriptc("frontend-load");
  await sleep(180);
  progress.scriptc("lower");
  await sleep(180);
  progress.finish();
  const text = out.text();
  ok("a pipe gets one finished line per phase",
    text.includes("resolved modules in") && text.includes("compiled TypeScript in") && text.includes("checked the program in"),
    JSON.stringify(text));
  ok("each line names the phase that just finished, in order",
    text.indexOf("resolved modules in") < text.indexOf("compiled TypeScript in") &&
    text.indexOf("compiled TypeScript in") < text.indexOf("checked the program in"), text);
  ok("a pipe gets no live line", !text.includes("\r") && !text.includes("\x1b"), JSON.stringify(text));
}

{
  const out = capture(true);
  const progress = new BuildProgress({ stream: out.stream, tty: true, estimateMs: 2000 });
  progress.beginScriptc();
  // As below: two redraw ticks, so a line is drawn even when the first lands just under the
  // minimum phase time.
  await sleep(250);
  progress.finish();
  const text = out.text();
  ok("a terminal gets a live line with a spinner", text.includes("\r") && /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(text), JSON.stringify(text));
  ok("a terminal gets the phase's elapsed time", /resolving modules .* [0-9.]+s/.test(text), JSON.stringify(text));
  ok("a terminal gets the estimate an earlier build gives", text.includes("~") && text.includes("%"), JSON.stringify(text));
  ok("a terminal still gets the finished line", text.includes("resolved modules in"), JSON.stringify(text));
}

{
  // Nothing written until the build prints something of its own: an interrupted live line starts on
  // a new line, and the phase is painted again on the next redraw.
  const out = capture(true);
  const progress = new BuildProgress({ stream: out.stream, tty: true });
  progress.beginScriptc();
  // The redraw runs every 100 ms and skips a phase younger than MIN_PHASE_MS, so the first tick can
  // land just short of it; waiting past two ticks guarantees a line was drawn to clear.
  await sleep(250);
  progress.interrupt();
  const before = out.text();
  progress.finish();
  ok("an interrupted live line is cleared before the build's own text", before.endsWith("\r\x1b[2K"), JSON.stringify(before.slice(-12)));
}

// ---------------------------------------------------------------------------
// A build, with a stand-in compiler that reports phases like scriptc

const work = mkdtempSync(join(tmpdir(), "native-progress-"));
const app = join(work, "app");
mkdirSync(app, { recursive: true });
writeFileSync(join(app, "index.html"), '<html><body><p id="o">-</p><script type="module" src="app.ts"></script></body></html>');
writeFileSync(join(app, "app.ts"), 'document.getElementById("o")!.textContent = "hi";\n');

const compiler = join(work, "fake-scriptc.mjs");
writeFileSync(compiler, `#!/usr/bin/env node
// A stand-in for scriptc: the phase lines a build reads, with the output it writes.
import { writeFileSync, writeSync } from "node:fs";
const args = process.argv.slice(2);
const at = args.indexOf("-o");
const out = at < 0 ? null : args[at + 1];
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
let total = 0;
const emit = (phase, ms) => {
  sleep(ms);
  total += ms;
  writeSync(2, "scriptc timing " + JSON.stringify({ phase, phase_ms: ms, total_ms: total }) + "\\n");
};
emit("frontend-cache-miss", 10);
emit("frontend-load", 300);
emit("lower", 400);
emit("ir-validate", 250);
emit("llvm-emit", 400);
emit("executable-cache-miss", 10);
emit("native-object", 900);
emit("link-inputs", 100);
emit("native-link", 250);
writeSync(2, "src/app.ts:2:1 - warning SC6014: the compiler's own warning\\n");
emit("complete", 10);
if (out !== null) writeFileSync(out, "#!/bin/sh\\nexit 0\\n", { mode: 0o755 });
`);

let scriptcPath: string;
if (process.platform === "win32") {
  scriptcPath = join(work, "fake-scriptc.cmd");
  writeFileSync(scriptcPath, `@echo off\r\nnode "%~dp0fake-scriptc.mjs" %*\r\n`);
} else {
  scriptcPath = compiler;
  chmodSync(compiler, 0o755);
}

const env = {
  ...process.env,
  NATIVE_SCRIPTC: scriptcPath,
  NATIVE_NO_CACHE: "1",
  NATIVE_CACHE_DIR: join(work, "cache"),
  CI: "1",
};
const out = join(work, "app", "out", "app");
const first = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", out], { encoding: "utf8", env });
ok("the build with the stand-in compiler succeeds", first.status === 0, first.stderr);
const shown = (["resolved modules", "compiled TypeScript", "checked the program", "generated code", "optimized code", "linked"] as const);
let at = -1;
let ordered = true;
for (const phase of shown) {
  const found = first.stderr.indexOf(`${phase} in `);
  if (found < 0 || found < at) ordered = false;
  at = found;
}
ok("a pipe shows each phase once, in order", ordered, first.stderr);
ok("a pipe shows no animation", !first.stderr.includes("\r") && !first.stderr.includes("\x1b"), first.stderr);
ok("the compiler's timing lines stay out of the log", !first.stderr.includes("scriptc timing"), first.stderr);
ok("the compiler's warnings still print", first.stderr.includes("warning SC6014: the compiler's own warning"), first.stderr);
ok("the summary line still prints last", /native: .*scriptc [0-9.]+s/.test(first.stderr.trim().split("\n").pop() ?? ""), first.stderr);

// A second build of the same app compiles again (its executable is gone) and, having the first
// build's duration on record, estimates where it is in a terminal.
rmSync(join(app, "out"), { recursive: true, force: true });
if (process.platform === "win32") {
  console.log("ok   (skipped) the terminal build: no pty on Windows");
} else {
  const ttyEnv = { ...env, TERM: "xterm" };
  delete (ttyEnv as { CI?: string }).CI;
  const command = `node compiler/cli.ts build ${JSON.stringify(app)} -o ${JSON.stringify(out)}`;
  const scriptArgs = process.platform === "darwin"
    ? ["-q", "/dev/null", "/bin/sh", "-c", command]
    : ["-qec", command, "/dev/null"];
  // The pty tool differs across systems (BSD script has no -e); one that can't run a command
  // skips the terminal half rather than failing the test.
  const probe = process.platform === "darwin"
    ? spawnSync("script", ["-q", "/dev/null", "/bin/sh", "-c", "true"], { encoding: "utf8", env: ttyEnv })
    : spawnSync("script", ["-qec", "true", "/dev/null"], { encoding: "utf8", env: ttyEnv });
  const second = probe.error === undefined && probe.status === 0
    ? spawnSync("script", scriptArgs, { encoding: "utf8", env: ttyEnv })
    : probe;
  if (probe.error !== undefined || probe.status !== 0) {
    console.log("ok   (skipped) the terminal build: no script(1) pty on this system");
  } else {
    const text = second.stdout;
    ok("a terminal build succeeds", second.status === 0, `${text}\n${second.stderr}`);
    ok("a terminal build animates the phase", text.includes("\r") && /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(text), text);
    ok("a terminal build names the phase it is in", /native: (compiling TypeScript|optimizing code|generating code)/.test(text), text);
    ok("a terminal build estimates from the last build", text.includes("~") && text.includes("%"), text);
    ok("a terminal build ends with the summary on its own line", /\nnative: .*scriptc [0-9.]+s/.test(text), text);
    ok("a terminal build leaves no raw timing lines", !text.includes("scriptc timing"), text);
  }
}

rmSync(work, { recursive: true, force: true });

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
