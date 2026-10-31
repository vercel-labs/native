import assert from "node:assert/strict";
import test from "node:test";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

async function loadInventory(manifest: unknown, files: Record<string, string> = {}) {
  const root = mkdtempSync(join(tmpdir(), "native-portable-sources-"));
  try {
    mkdirSync(join(root, "src"));
    copyFileSync(new URL("../src/portable_sources.ts", import.meta.url), join(root, "src/portable_sources.ts"));
    writeFileSync(join(root, "src/portable_sources.json"), JSON.stringify(manifest));
    for (const [name, text] of Object.entries(files)) {
      mkdirSync(join(root, name, ".."), { recursive: true });
      writeFileSync(join(root, name), text);
    }
    return await import(pathToFileURL(join(root, "src/portable_sources.ts")).href);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("portable compilation preserves manifest order and exact source bytes across SDK directories", async () => {
  const paths = ["src/z.ts", "sdk/internal/shared.ts", "src/a.ts"];
  const result = await loadInventory(paths, {
    "src/z.ts": "first\r\n", "sdk/internal/shared.ts": "middle", "src/a.ts": "last\n",
  });
  assert.deepEqual(result.portableSourcePaths, paths);
  assert.equal(result.portableSourceText, "first\r\nmiddlelast\n");
  assert.equal(Object.isFrozen(result.portableSourcePaths), true);
});

test("portable compilation refuses ambiguous or invalid inventories before reading policy files", async () => {
  for (const value of [null, {}, [], [42], ["src/a.ts", "src/a.ts"],
    ["/src/a.ts"], ["src/../a.ts"], ["src\\a.ts"], ["src/a.js"], ["sdk/core.ts"]]) {
    await assert.rejects(loadInventory(value), /invalid portable source inventory/);
  }
});

test("an absent portable policy fails compilation instead of silently dropping an input", async () => {
  await assert.rejects(loadInventory(["src/missing.ts"]), { code: "ENOENT" });
});
