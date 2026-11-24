// What the check command reports: it compiles the front end a build does, the module graph the
// page's scripts import included. A class an imported module sets is still a class a rule can
// match, so only rules nothing can match are reported as removed.
//
//   node tests/check.ts

import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compileFrontEnd } from "../compiler/build.ts";

let failed = 0;
function ok(name: string, cond: boolean, detail = ""): void {
  if (!cond) failed++;
  console.log(`${cond ? "ok  " : "FAIL"} ${name}${cond || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-check-"));
const app = join(dir, "app");
mkdirSync(app);
writeFileSync(join(app, "index.html"), `<!doctype html>
<html>
  <head><title>Cards</title><link rel="stylesheet" href="style.css"></head>
  <body><main id="root"></main><script type="module" src="app.ts"></script></body>
</html>`);
writeFileSync(join(app, "style.css"), [
  "body { margin: 0 }",
  ".card { padding: 12px }",
  ".brand { color: #4338ca }",
  "blockquote { color: red }",
  "",
].join("\n"));
// Two rules' classes are set from a module the page imports and never spells out.
writeFileSync(join(app, "card.ts"), [
  "export function card(label: string): HTMLElement {",
  '  const el = document.createElement("div");',
  '  el.className = "card";',
  '  const name = document.createElement("span");',
  '  name.className = "brand";',
  "  name.textContent = label;",
  "  el.appendChild(name);",
  "  return el;",
  "}",
  "",
].join("\n"));
writeFileSync(join(app, "app.ts"), [
  'import { card } from "./card.ts";',
  'document.getElementById("root")!.appendChild(card("Hello"));',
  "",
].join("\n"));

const r = spawnSync("node", ["compiler/cli.ts", "check", app], { encoding: "utf8" });
ok("the app checks clean", r.status === 0, r.stderr.slice(-500));
ok("a rule an imported module matches is kept", !r.stderr.includes(".card") && !r.stderr.includes(".brand"), r.stderr);
// A tag neither the page nor any module it imports makes can still never match, so the analysis
// keeps eliminating it.
ok("a rule nothing can match is still reported",
  r.stderr.includes("rule 'blockquote' matches no element and was removed"), r.stderr);

// The figures in its summary are the build's own, not a partial compile's.
const built = compileFrontEnd(app);
const counts = /(\d+) nodes, (\d+) rules/.exec(r.stderr);
ok("check counts the nodes and rules the build compiles",
  counts !== null && Number(counts[1]) === built.app.stats.elements && Number(counts[2]) === built.app.stats.rules,
  `${counts?.[0] ?? "no counts"}; the build compiles ${built.app.stats.elements} nodes, ${built.app.stats.rules} rules`);

if (failed > 0) {
  console.error(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
