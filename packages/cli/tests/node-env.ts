// Bundlers define process.env.NODE_ENV for the libraries they compile, and packages such as React
// branch on it: the development build reports every warning in detail, the production one strips
// them. native passes the same define to scriptc — "production" for a release build, "development"
// for a dev build — so a library's conditional picks the branch the build is for. This checks both
// define strings and an app that prints the branch it took.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { nodeEnvDefine } from "../compiler/build.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The define each build kind hands scriptc, as scriptc's --define takes it.
check("a release build defines production", nodeEnvDefine(false) === 'process.env.NODE_ENV="production"', nodeEnvDefine(false));
check("a dev build defines development", nodeEnvDefine(true) === 'process.env.NODE_ENV="development"', nodeEnvDefine(true));

// An app whose script takes a branch on the variable: the compile-time define decides which
// branch survives, so what the page prints is what the define said.
const dir = mkdtempSync(join(tmpdir(), "native-node-env-"));
writeFileSync(join(dir, "index.html"), `<!doctype html>
<html><head><meta name="native-window" content="width=300, height=200"></head>
<body><div id="root"></div><script type="module" src="app.ts"></script></body></html>
`);
writeFileSync(join(dir, "app.ts"), `
const mode = process.env.NODE_ENV;
const el = document.getElementById("root");
if (el !== null) el.textContent = mode === undefined ? "unset" : mode;
`);

const out = join(dir, "node-env");
const built = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", out], { encoding: "utf8" });
check("the app builds", built.status === 0, (built.stderr ?? "").trim().split("\n").slice(-3).join("\n"));

const ran = spawnSync(out, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "frame 0 | print #root" },
});
const printed = (ran.stdout ?? "").trim();
check("a release build takes the production branch", printed === "production", JSON.stringify(printed));

if (failed > 0) process.exit(1);
