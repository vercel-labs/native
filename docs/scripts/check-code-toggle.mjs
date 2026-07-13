// Regression pin for the TS | Zig code toggle: assert the *prerendered*
// HTML actually contains the tab headers. The toggle once shipped broken —
// a client component introspected its RSC children, saw one opaque node,
// and silently fell back to stacked fences on every page — and nothing
// caught it because no check looked at rendered output. This one does.
//
// For every page.mdx that uses <CodeToggle>, the built HTML under
// ${NEXT_DIST_DIR:-.next}/server/app must contain exactly as many
// role="tablist" headers as the source has <CodeToggle> usages.
//
// Runs after `next build` as part of `pnpm check`.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const docsDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const appDir = join(docsDir, "src", "app");
const distDir = join(docsDir, process.env.NEXT_DIST_DIR || ".next");
const htmlDir = join(distDir, "server", "app");

function* mdxPages(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) yield* mdxPages(full);
    else if (entry === "page.mdx") yield full;
  }
}

function count(haystack, needle) {
  return haystack.split(needle).length - 1;
}

let failures = 0;
let togglePages = 0;

for (const page of mdxPages(appDir)) {
  const expected = count(readFileSync(page, "utf8"), "<CodeToggle>");
  if (expected === 0) continue;
  togglePages += 1;

  const route = relative(appDir, dirname(page)); // e.g. "typescript/packages"
  const htmlPath = join(htmlDir, `${route}.html`);
  if (!existsSync(htmlPath)) {
    console.error(`FAIL /${route}: no prerendered HTML at ${htmlPath} — expected a static page with ${expected} code toggle(s)`);
    failures += 1;
    continue;
  }

  const actual = count(readFileSync(htmlPath, "utf8"), 'role="tablist"');
  if (actual !== expected) {
    console.error(`FAIL /${route}: ${expected} <CodeToggle> usage(s) in MDX but ${actual} role="tablist" in prerendered HTML — the toggle is falling back to stacked fences`);
    failures += 1;
  } else {
    console.log(`ok   /${route}: ${actual} code toggle(s) rendered with tabs`);
  }
}

if (togglePages === 0) {
  console.error("FAIL: no page.mdx uses <CodeToggle> — if the component was renamed, update scripts/check-code-toggle.mjs so this pin keeps checking rendered output");
  failures += 1;
}

if (failures > 0) process.exit(1);
console.log(`code-toggle check passed: ${togglePages} page(s) verified`);
