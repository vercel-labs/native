// Docs honesty gate: every complete app-core sample in the docs transpiles.
//
// Scans docs/src/app/**/page.mdx for ```ts fences (with or without a
// :filename info-string suffix) and runs the full
// pipeline (tsc semantics + subset rules + emission) over each block that
// is a whole core — the discriminator is `export function update(`, the
// one export every complete core carries. Fragments (case-arm excerpts,
// type-only declarations) are teaching excerpts of the same idioms and are
// skipped here; the complete cores around them are what this test pins.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { transpile } from "./helpers.ts";

const repoRoot = path.dirname(
  path.dirname(path.dirname(path.dirname(fileURLToPath(import.meta.url)))),
);
const docsAppDir = path.join(repoRoot, "docs", "src", "app");

function mdxPages(dir: string): string[] {
  const pages: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) pages.push(...mdxPages(full));
    else if (entry.name === "page.mdx") pages.push(full);
  }
  return pages;
}

function tsFences(source: string): string[] {
  return [...source.matchAll(/^```ts(?::[^\n]*)?\n([\s\S]*?)^```$/gm)].map((match) => match[1]);
}

test("docs samples: every complete core in the docs transpiles clean", () => {
  assert.ok(fs.existsSync(docsAppDir), `docs pages not found at ${docsAppDir}`);
  let cores = 0;
  for (const page of mdxPages(docsAppDir)) {
    for (const fence of tsFences(fs.readFileSync(page, "utf8"))) {
      if (!fence.includes("export function update(")) continue;
      cores += 1;
      const result = transpile(fence);
      const details = [
        ...result.typeErrors,
        ...result.diagnostics.map((d) => `${d.id} ${d.title}: ${d.message}`),
      ].join("\n");
      assert.ok(
        result.ok && result.zig !== null,
        `${path.relative(docsAppDir, page)} has a core sample that fails the transpiler:\n${details}\n--- sample\n${fence}`,
      );
    }
  }
  // The flagship pages carry complete cores; losing them all silently would
  // make this test vacuous, so pin a floor.
  assert.ok(cores >= 5, `expected at least 5 complete core samples in the docs, found ${cores}`);
});
