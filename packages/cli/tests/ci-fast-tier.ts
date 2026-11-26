// The pull-request fast tier must keep at least one React example: React's compiler path and
// runtime are what a change most often breaks, and CI's required examples check covers only the
// apps the tier names.
//   npm test

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../../..", import.meta.url));
const ci = readFileSync(join(ROOT, ".github/workflows/ci.yml"), "utf8");
const examples = [...ci.matchAll(/fast_example:\s*([A-Za-z0-9_-]+)/g)].map((m) => m[1]);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check("the fast tier names examples", examples.length > 0, JSON.stringify(examples));
const react = examples.filter((name) => {
  try {
    const pkg = JSON.parse(readFileSync(join(ROOT, "examples", name, "package.json"), "utf8")) as {
      dependencies?: { [name: string]: string };
    };
    return pkg.dependencies?.["react"] !== undefined;
  } catch {
    return false;
  }
});
check("the fast tier includes a React example", react.length > 0, JSON.stringify(examples));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
