// A vendored module that opens with `// @ts-nocheck` keeps the pragma once native has added the
// imports that stand in for the DOM globals it uses. scriptc reads a pragma only from a file's
// leading comment, so those imports are appended to such a file rather than typed in front of it.
// The module below would fail to compile without the pragma (a `@readonly` getter is a build error
// until scriptc accepts what tsc accepts), which is what proves the pragma still applies.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const dir = mkdtempSync(join(tmpdir(), "native-pragma-"));
const app = join(dir, "app");
const pkg = join(app, "node_modules", "pragma-lib");
mkdirSync(pkg, { recursive: true });

writeFileSync(join(app, "index.html"), `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="native-window" content="width=320, height=200">
    <title>Pragma</title>
  </head>
  <body>
    <div id="out">nothing</div>
    <script type="module" src="app.ts"></script>
  </body>
</html>
`);

writeFileSync(join(app, "app.ts"), `import { label } from "pragma-lib";

document.getElementById("out")!.textContent = label();
`);

writeFileSync(join(pkg, "package.json"), JSON.stringify({ name: "pragma-lib", type: "module", exports: "./index.js" }));

// Line 1 is the pragma; `document` makes native add an import to this file.
writeFileSync(join(pkg, "index.js"), `// @ts-nocheck
export class Ticket {

	/** @readonly */
	get size() { return 3; }

}

export function label() { const d = document; return \`tickets: \${new Ticket().size}, dom: \${d === undefined ? "no" : "yes"}\`; }
`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const exe = join(dir, "pragma");
const b = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", exe], { encoding: "utf8" });
check("a vendored module's leading @ts-nocheck survives the DOM imports", b.status === 0, b.stderr);

if (b.status === 0) {
  const r = spawnSync(exe, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: "print #out", NATIVE_SNAPSHOT: join(dir, "pragma.png") },
  });
  check("the module runs with the pragma in place", r.status === 0 && r.stdout.trim() === "tickets: 3, dom: yes", `got ${JSON.stringify(r.stdout)} (exit ${r.status})\n${r.stderr}`);
}

// The imports take a line, so a diagnostic in the copied file has to point at the source line,
// not at the line one further down where the code now sits.
const app2 = join(dir, "app2");
const broken = join(app2, "node_modules", "broken-lib");
mkdirSync(broken, { recursive: true });
writeFileSync(join(app2, "index.html"), `<!doctype html>
<html>
  <head><meta charset="utf-8"><title>Broken</title></head>
  <body><script type="module" src="app.ts"></script></body>
</html>
`);
writeFileSync(join(app2, "app.ts"), `import { dom } from "broken-lib";

console.log(dom);
`);
writeFileSync(join(broken, "package.json"), JSON.stringify({ name: "broken-lib", type: "module", exports: "./index.js" }));
writeFileSync(join(broken, "index.js"), `// @ts-nocheck
export class Ticket {}

const = 1;

export const dom = document;
`);

const bad = spawnSync("node", ["compiler/cli.ts", "build", app2, "-o", join(dir, "broken")], { encoding: "utf8" });
const line = /broken-lib\/index\.js:(\d+):\d+ - error SC\d+/.exec(bad.stderr) ?? /d0-index\.js:(\d+):\d+ - error SC\d+/.exec(bad.stderr);
check(
  "a diagnostic below the pragma points at the source line",
  bad.status !== 0 && line !== null && line[1] === "4",
  `got ${JSON.stringify(line?.[0])} from:\n${bad.stderr.split("\n").filter((l) => /error SC/.test(l)).join("\n")}`,
);

if (failed > 0) process.exit(1);
