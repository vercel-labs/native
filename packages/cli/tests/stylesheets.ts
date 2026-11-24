// Stylesheets from <link rel=stylesheet>: a remote one is a warning and is skipped, while the
// page keeps the sheets it does have; a local one that's missing is still an error.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-sheets-"));

function app(name: string, html: string, css?: string): string {
  const d = join(dir, name);
  mkdirSync(d);
  writeFileSync(join(d, "index.html"), html);
  if (css !== undefined) writeFileSync(join(d, "style.css"), css);
  return d;
}

function build(dir: string, exe: string): { status: number | null; out: string } {
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  return { status: b.status, out: `${b.stdout}${b.stderr}` };
}

const CSS = "body { margin: 0; background: #070b16; } #box { width: 100px; height: 50px; background: #8be9fd; }";
const PAGE = (sheets: string) => `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="native-window" content="width=200, height=100">
${sheets}
</head>
<body><div id="box">hi</div></body>
</html>`;

// --- A remote sheet is skipped and the local one beside it still applies ---------------------

const remote = app("remote", PAGE(`<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400&display=swap">
<link rel="stylesheet" href="style.css">`), CSS);
const exe = join(dir, "remote-app");
const b = build(remote, exe);
check("a page with a remote stylesheet builds", b.status === 0, b.out.split("\n").slice(-4).join("\n"));
check("the remote stylesheet is a warning", /warning: remote stylesheet 'https:\/\/fonts\.googleapis\.com\//.test(b.out), b.out);
check("the remote stylesheet is not an error", !/error: .*stylesheet/.test(b.out), b.out);

const png = join(dir, "remote.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png, NATIVE_STEPS: "print #box" } });
check("the page runs", run.status === 0 && run.stdout.trim() === "hi", `${run.status} ${JSON.stringify(run.stdout)}`);
const img = decodePng(png);
const at = (x: number, y: number) => `${img.rgba[(y * 2 * img.w + x * 2) * 4]},${img.rgba[(y * 2 * img.w + x * 2) * 4 + 1]},${img.rgba[(y * 2 * img.w + x * 2) * 4 + 2]}`;
check("the local sheet beside it is applied", at(70, 40) === "139,233,253", `got ${at(70, 40)}`);
check("the rest of the page is styled too", at(150, 80) === "7,11,22", `got ${at(150, 80)}`);

// --- A local sheet that's missing is still an error ----------------------------------------

const missing = app("missing", PAGE(`<link rel="stylesheet" href="gone.css">`));
const m = build(missing, join(dir, "missing-app"));
check("a missing local stylesheet fails the build", m.status !== 0, `exit ${m.status}`);
check("the missing sheet is an error", /error: stylesheet 'gone\.css' not found/.test(m.out), m.out);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
