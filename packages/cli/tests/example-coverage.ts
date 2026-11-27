// The example coverage check: every app on disk declares tags from the catalog, and a new example
// must introduce a tag no example before it declares; otherwise the error names the examples it
// overlaps.   npm test

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkCoverage, coverageReport } from "../scripts/example-coverage.ts";
import { loadManifest, type CoverageManifest } from "../scripts/example-selection.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const base: CoverageManifest = {
  tags: { paint: "paint", text: "text", canvas: "canvas" },
  examples: { alpha: ["paint"], beta: ["text"] },
};

const clean = checkCoverage(base, ["alpha", "beta"], ["alpha", "beta"]);
check("a manifest whose apps are all base apps is clean", clean.errors.length === 0, clean.errors.join(" | "));

const duplicate: CoverageManifest = {
  tags: base.tags,
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["paint"] },
};
const overlap = checkCoverage(duplicate, ["alpha", "beta", "gamma"], ["alpha", "beta"]);
check("a new example that repeats paint fails", overlap.errors.length === 1, overlap.errors.join(" | "));
check("the failure names the overlapping examples and tag", overlap.errors[0].indexOf("examples/gamma") >= 0 && overlap.errors[0].indexOf("paint by examples/alpha") >= 0, overlap.errors[0]);

const fresh: CoverageManifest = {
  tags: base.tags,
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["paint", "canvas"] },
};
const introduced = checkCoverage(fresh, ["alpha", "beta", "gamma"], ["alpha", "beta"]);
check("a new example with a new tag passes", introduced.errors.length === 0, introduced.errors.join(" | "));
check("the new tag is reported as introduced", JSON.stringify(introduced.introduced.gamma) === JSON.stringify(["canvas"]), JSON.stringify(introduced.introduced));

const twoDuplicates: CoverageManifest = {
  tags: base.tags,
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["canvas"], delta: ["canvas"] },
};
const second = checkCoverage(twoDuplicates, ["alpha", "beta", "gamma", "delta"], ["alpha", "beta"]);
check("two new examples with the same new tag fail on the second", second.errors.length === 1 && second.errors[0].indexOf("examples/delta") >= 0, second.errors.join(" | "));

const missing: CoverageManifest = { tags: base.tags, examples: { alpha: ["paint"] } };
const missingErrors = checkCoverage(missing, ["alpha", "beta"], null);
check("a disk app with no manifest entry fails", missingErrors.errors.some((e) => e.indexOf("examples/beta") >= 0 && e.indexOf("no coverage tags") >= 0), missingErrors.errors.join(" | "));

const emptyTags: CoverageManifest = { tags: base.tags, examples: { alpha: ["paint"], beta: [] } };
const emptyErrors = checkCoverage(emptyTags, ["alpha", "beta"], null);
check("a manifest entry with no tags fails", emptyErrors.errors.some((e) => e.indexOf("examples/beta") >= 0 && e.indexOf("declares no coverage tags") >= 0), emptyErrors.errors.join(" | "));

const ghost: CoverageManifest = { tags: base.tags, examples: { alpha: ["paint"], beta: ["text"], ghost: ["canvas"] } };
const ghostErrors = checkCoverage(ghost, ["alpha", "beta"], null);
check("a manifest entry with no app on disk fails", ghostErrors.errors.some((e) => e.indexOf("examples/ghost") >= 0 && e.indexOf("does not exist") >= 0), ghostErrors.errors.join(" | "));

const unknown: CoverageManifest = { tags: base.tags, examples: { alpha: ["paint", "sparkle"], beta: ["text"] } };
const unknownErrors = checkCoverage(unknown, ["alpha", "beta"], null);
check("an unknown tag fails", unknownErrors.errors.some((e) => e.indexOf("sparkle") >= 0), unknownErrors.errors.join(" | "));

const real = coverageReport(ROOT, null);
check("the real coverage manifest is complete", real.errors.length === 0, real.errors.join(" | "));
const realBase = coverageReport(ROOT, "HEAD");
check("the real apps are all base apps at HEAD", realBase.errors.length === 0, realBase.errors.join(" | "));
check("loading the real manifest agrees with the report", loadManifest(ROOT).examples.article !== undefined);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
