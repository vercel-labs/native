// The example coverage check: every app on disk declares tags from the catalog, and a new example
// must introduce a tag no example before it declares; otherwise the error names the examples it
// overlaps.   npm test

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkCoverage, coverageReport, examplesAtRevision, introducedByChange } from "../scripts/example-coverage.ts";
import { exampleNames, loadManifest, type CoverageManifest } from "../scripts/example-selection.ts";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";

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

const clean = checkCoverage(base, ["alpha", "beta"], null);
check("a manifest whose apps are all base apps is clean", clean.errors.length === 0, clean.errors.join(" | "));

const duplicate: CoverageManifest = {
  tags: base.tags,
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["paint"] },
};
const overlap = checkCoverage(duplicate, ["alpha", "beta", "gamma"], ["gamma"]);
check("a new example that repeats paint fails", overlap.errors.length === 1, overlap.errors.join(" | "));
check("the failure names the overlapping examples and tag", overlap.errors[0].indexOf("examples/gamma") >= 0 && overlap.errors[0].indexOf("paint by examples/alpha") >= 0, overlap.errors[0]);

const fresh: CoverageManifest = {
  tags: base.tags,
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["paint", "canvas"] },
};
const introduced = checkCoverage(fresh, ["alpha", "beta", "gamma"], ["gamma"]);
check("a new example with a new tag passes", introduced.errors.length === 0, introduced.errors.join(" | "));
check("the new tag is reported as introduced", JSON.stringify(introduced.introduced.gamma) === JSON.stringify(["canvas"]), JSON.stringify(introduced.introduced));

const twoDuplicates: CoverageManifest = {
  tags: base.tags,
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["canvas"], delta: ["canvas"] },
};
const second = checkCoverage(twoDuplicates, ["alpha", "beta", "gamma", "delta"], ["gamma", "delta"]);
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

const real = coverageReport(ROOT, null, null);
check("the real coverage manifest is complete", real.errors.length === 0, real.errors.join(" | "));
const realBase = coverageReport(ROOT, "HEAD", null);
check("the real apps are all base apps at HEAD", realBase.errors.length === 0, realBase.errors.join(" | "));
check("loading the real manifest agrees with the report", loadManifest(ROOT).examples.article !== undefined);

const staleBase: CoverageManifest = {
  tags: { paint: "paint", text: "text", canvas: "canvas", geolocation: "geolocation" },
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["canvas"], delta: ["geolocation"] },
};
const staleDisk = ["alpha", "beta", "gamma", "delta"];
const staleBaseApps = ["alpha", "beta"];
const staleNew = introducedByChange(["examples/delta/app.ts", "examples/coverage.json"], staleDisk, staleBaseApps);
check("a stale branch counts only the examples its change adds", JSON.stringify(staleNew) === JSON.stringify(["delta"]), JSON.stringify(staleNew));
check("an example added to the base after the fork is not counted", staleNew.indexOf("gamma") < 0, JSON.stringify(staleNew));
const stale = checkCoverage(staleBase, staleDisk, staleNew);
check("a stale branch with its own new tag does not fail", stale.errors.length === 0, stale.errors.join(" | "));

// A real git repository with the shape CI checks out: base F has alpha and beta, next advanced
// with gamma, a pull request branch forked at F adds delta, and the pull request's merge commit
// carries both next's gamma and the branch's delta. The change's own diff is the branch head
// against F, so only delta is its new example.
const repo = mkdtempSync(join(tmpdir(), "native-coverage-stale-"));
const writeExample = (name: string): void => {
  mkdirSync(join(repo, "examples", name), { recursive: true });
  writeFileSync(join(repo, "examples", name, "index.html"), "<!doctype html>");
};
const git = (...args: string[]): string => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" });
git("init", "-q");
git("config", "user.email", "test@example.com");
git("config", "user.name", "Test");
writeExample("alpha");
writeExample("beta");
git("add", "-A");
git("commit", "-q", "-m", "base");
const baseRev = git("rev-parse", "HEAD").trim();
const baseBranch = git("rev-parse", "--abbrev-ref", "HEAD").trim();
writeExample("gamma");
git("add", "-A");
git("commit", "-q", "-m", "next adds gamma");
const nextRev = git("rev-parse", "HEAD").trim();
git("checkout", "-q", "-b", "pr", baseRev);
writeExample("delta");
git("add", "-A");
git("commit", "-q", "-m", "branch adds delta");
const prHead = git("rev-parse", "HEAD").trim();
git("checkout", "-q", baseBranch);
git("merge", "-q", "--no-ff", "-m", "merge pr", "pr");
const secondParent = git("rev-parse", "HEAD^2").trim();
const mergeBase = git("merge-base", nextRev, secondParent).trim();
const changed = git("diff", "--name-only", mergeBase, secondParent).split("\n").filter((line) => line !== "");
check("the merge-base diff lists the branch's own file", JSON.stringify(changed) === JSON.stringify(["examples/delta/index.html"]), JSON.stringify(changed));
const staleRepoNew = introducedByChange(changed, exampleNames(repo), examplesAtRevision(repo, mergeBase));
check("a real stale checkout counts only the changed example", JSON.stringify(staleRepoNew) === JSON.stringify(["delta"]), JSON.stringify(staleRepoNew));
check("the example next added after the fork is not counted", staleRepoNew.indexOf("gamma") < 0, JSON.stringify(staleRepoNew));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
