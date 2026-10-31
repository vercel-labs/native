/** Ordered policies compiled in the same module as every Native view. Paths
 * are relative to packages/core; the build graphs consume the same manifest.
 */
import { readFileSync } from "node:fs";

const manifest: unknown = JSON.parse(readFileSync(new URL("./portable_sources.json", import.meta.url), "utf8"));
if (!Array.isArray(manifest) || manifest.length === 0 ||
  manifest.some(source => typeof source !== "string" || !/^(?:src|sdk\/internal)\/(?:[a-z0-9_]+\/)*[a-z0-9_]+\.ts$/.test(source)) ||
  new Set(manifest).size !== manifest.length) {
  throw new Error("invalid portable source inventory: expected unique package-relative TypeScript paths");
}

export const portableSourcePaths: readonly string[] = Object.freeze(manifest);
// Preserve the source files verbatim, including their own trailing newlines.
export const portableSourceText = portableSourcePaths
  .map(source => readFileSync(new URL(`../${source}`, import.meta.url), "utf8"))
  .join("");
