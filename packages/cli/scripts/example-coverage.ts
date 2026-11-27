// Checks the example coverage manifest: every app declares the areas it exercises, every tag is
// one the catalog names, and a NEW example adds at least one area no example already on the base
// branch covers. An app that only repeats existing coverage is an overlap to fold into the app it
// duplicates; the error names the examples that already declare each of its tags.

import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import type { CoverageManifest } from "./example-selection.ts";
import { exampleNames, loadManifest, repoRootFromScript } from "./example-selection.ts";

export interface CoverageReport {
  errors: string[];
  /** For each new example, the tags it introduces beyond the examples before it. */
  introduced: { [name: string]: string[] };
}

/** The example names a git revision has under examples/ (as directories). */
export function examplesAtRevision(root: string, ref: string): string[] {
  const out = execFileSync("git", ["-C", root, "ls-tree", "-d", "--name-only", ref, "examples/"], { encoding: "utf8" });
  return out.split("\n")
    .map((line) => line.trim())
    .filter((line) => line.startsWith("examples/"))
    .map((line) => line.slice("examples/".length))
    .filter((name) => name !== "")
    .sort();
}

/**
 * Checks the manifest and, when `baseExamples` is given, that every example absent from it adds a
 * tag the examples before it do not declare. `baseExamples` are the apps on the base branch;
 * examples added by the same change are checked in order against the base plus the new ones
 * accepted before them.
 */
export function checkCoverage(
  manifest: CoverageManifest,
  diskExamples: readonly string[],
  baseExamples: readonly string[] | null,
): CoverageReport {
  const errors: string[] = [];
  const introduced: { [name: string]: string[] } = {};
  const tags = manifest.tags;
  const declared = manifest.examples;

  for (const name of diskExamples) {
    const own = declared[name];
    if (own === undefined) {
      errors.push(`examples/${name}: no coverage tags in examples/coverage.json`);
      continue;
    }
    if (own.length === 0) errors.push(`examples/${name}: declares no coverage tags`);
    for (const tag of own) {
      if (tags[tag] === undefined) errors.push(`examples/${name}: unknown coverage tag "${tag}"`);
    }
    if (new Set(own).size !== own.length) errors.push(`examples/${name}: duplicate coverage tag`);
  }
  for (const name of Object.keys(declared)) {
    if (diskExamples.indexOf(name) < 0) {
      errors.push(`examples/coverage.json names examples/${name}, which does not exist`);
    }
  }
  if (baseExamples === null) return { errors, introduced };

  const existing = new Set(baseExamples.filter((name) => diskExamples.indexOf(name) >= 0));
  const added = diskExamples.filter((name) => !existing.has(name)).sort();
  for (const name of added) {
    const own = declared[name] ?? [];
    const fresh = own.filter((tag) => {
      for (const other of existing) {
        if ((declared[other] ?? []).indexOf(tag) >= 0) return false;
      }
      return true;
    });
    introduced[name] = fresh;
    if (own.length > 0 && fresh.length === 0) {
      const overlaps: string[] = [];
      for (const tag of own) {
        const owners = Array.from(existing)
          .filter((other) => (declared[other] ?? []).indexOf(tag) >= 0)
          .sort();
        if (owners.length > 0) {
          overlaps.push(`${tag} by ${owners.slice(0, 3).map((other) => "examples/" + other).join(", ")}`);
        }
      }
      errors.push(
        `examples/${name} overlaps the suite (${overlaps.join("; ")}) and adds no coverage tag ` +
        "that the examples before it do not already cover; fold it into one of those examples or " +
        "declare the area it adds in examples/coverage.json",
      );
    }
    existing.add(name);
  }
  return { errors, introduced };
}

export function coverageReport(root: string, baseRef: string | null): CoverageReport {
  const manifest = loadManifest(root);
  const disk = exampleNames(root);
  const base = baseRef === null ? null : examplesAtRevision(root, baseRef);
  return checkCoverage(manifest, disk, base);
}

function main(argv: string[]): void {
  const root = repoRootFromScript();
  let base: string | null = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--base") base = argv[++i] ?? null;
    else {
      console.error(`example-coverage: unknown argument ${argv[i]}`);
      process.exit(2);
    }
  }
  const report = coverageReport(root, base);
  if (report.errors.length > 0) {
    for (const error of report.errors) console.error("example coverage: " + error);
    process.exit(1);
  }
  const manifest = loadManifest(root);
  console.log(
    `example coverage ok: ${exampleNames(root).length} examples, ` +
    `${Object.keys(manifest.tags).length} tags` +
    (base === null ? "" : `, new examples checked against ${base}`),
  );
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
