// Which examples a pull request runs, from the files it changes. These fixtures pin the mapping
// from a changed path to coverage tags, the baseline when nothing matches, and the example-own
// rule, then check the real coverage manifest against the apps on disk.   npm test

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BASELINE,
  SELECTION_RULES,
  WINDOWS_EXAMPLES,
  exampleInPath,
  exampleNames,
  loadManifest,
  matchesPath,
  selectExamples,
  shardSelection,
  type CoverageManifest,
  type Selection,
  type SelectionRule,
} from "../scripts/example-selection.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const manifest: CoverageManifest = {
  tags: { paint: "paint", text: "text", events: "events" },
  examples: { alpha: ["paint"], beta: ["text"], gamma: ["events"], delta: ["paint", "text"] },
  smoke: ["alpha", "beta"],
};
const rules: SelectionRule[] = [
  { pattern: "src/paint.ts", tags: ["paint"] },
  { pattern: "src/text/*", tags: ["text"] },
  { pattern: "src/all.ts", all: true },
];

check("a path without a star matches itself", matchesPath("src/paint.ts", "src/paint.ts") && !matchesPath("src/paint.ts", "src/paint2.ts"));
check("a trailing star matches a prefix", matchesPath("src/text/*", "src/text/run.ts") && !matchesPath("src/text/*", "src/text2/run.ts"));
check("a star inside a name matches between its ends", matchesPath("runtime/svg*.ts", "runtime/svg.ts") && matchesPath("runtime/svg*.ts", "runtime/svg-paint.ts") && !matchesPath("runtime/svg*.ts", "runtime/svg.png"));
check("a path under an example belongs to it", exampleInPath("examples/alpha/app.ts", ["alpha", "beta"]) === "alpha");
check("a name that only shares a prefix is not the example", exampleInPath("examples/alphabet/app.ts", ["alpha", "beta"]) === null);

const paint = selectExamples(["src/paint.ts"], manifest, rules);
check("a paint change selects the paint examples", JSON.stringify(paint.examples) === JSON.stringify(["alpha", "delta"]), JSON.stringify(paint.examples));
check("the reason names the path and tag", paint.reasons.some((r) => r.indexOf("src/paint.ts") >= 0 && r.indexOf("paint") >= 0), paint.reasons.join(" | "));

const text = selectExamples(["src/text/run.ts"], manifest, rules);
check("a text change selects the text examples", JSON.stringify(text.examples) === JSON.stringify(["beta", "delta"]), JSON.stringify(text.examples));

const all = selectExamples(["src/all.ts"], manifest, rules);
check("an all rule selects every example", all.examples.length === 4 && all.all, JSON.stringify(all.examples));
check("an all rule reports every catalog tag", all.tags.length === 3, JSON.stringify(all.tags));
const smoke = shardSelection(all, manifest, 2, 1);
check("an all rule's pull-request shards run the smoke set", JSON.stringify(smoke.shards) === JSON.stringify([["alpha"], ["beta"]]), JSON.stringify(smoke.shards));

const own = selectExamples(["examples/beta/app.ts"], manifest, rules);
check("an example's own file selects only that example", JSON.stringify(own.examples) === JSON.stringify(["beta"]), JSON.stringify(own.examples));

const docs = selectExamples(["docs/readme.md"], manifest, rules);
check("a change no rule matches selects nothing from these fixtures", docs.examples.length === 0, JSON.stringify(docs.examples));
const baseline = selectExamples(["docs/readme.md"], manifest, rules, ["gamma"]);
check("the baseline runs when nothing matches", JSON.stringify(baseline.examples) === JSON.stringify(["gamma"]), JSON.stringify(baseline.examples));

const real = loadManifest(ROOT);
const disk = exampleNames(ROOT);
const realPaint = selectExamples(["packages/cli/runtime/paint.ts"], real);
check("a paint change selects paint-heavy apps", realPaint.examples.indexOf("gallery") >= 0 && realPaint.examples.indexOf("animation") >= 0 && realPaint.examples.indexOf("webgl-cube") < 0, JSON.stringify(realPaint.examples));
const realText = selectExamples(["packages/cli/runtime/text-runs.ts"], real);
check("a text change selects text-heavy apps", ["editor", "chat", "tickets", "article", "ime", "notes"].every((name) => realText.examples.indexOf(name) >= 0), JSON.stringify(realText.examples));
const realAll = selectExamples(["packages/cli/compiler/build.ts"], real);
check("a compiler change selects every app", realAll.examples.length === disk.length && realAll.all, `${realAll.examples.length} of ${disk.length}`);
const realSmoke = shardSelection(realAll, real, 4, 2);
check("a compiler change's pull-request shards run the smoke set", JSON.stringify(realSmoke.shards) === JSON.stringify([["counter"], ["ui-dashboard"], ["canvas-particles"], ["webgl-cube"]]), JSON.stringify(realSmoke.shards));
const realOwn = selectExamples(["examples/gallery/app.tsx"], real);
check("an example's own change selects only it", JSON.stringify(realOwn.examples) === JSON.stringify(["gallery"]), JSON.stringify(realOwn.examples));
const realDocs = selectExamples(["README.md"], real);
check("a docs-only change runs the baseline", JSON.stringify(realDocs.examples) === JSON.stringify([...BASELINE].filter((n) => disk.indexOf(n) >= 0)), JSON.stringify(realDocs.examples));
const docsShards = shardSelection(realDocs, real, 4, 2);
check("a docs-only change runs the baseline in one shard", JSON.stringify(docsShards.shards) === JSON.stringify([["counter"], [], [], []]), JSON.stringify(docsShards.shards));
check("every Windows example is in the selection catalog", WINDOWS_EXAMPLES.every((name) => disk.indexOf(name) >= 0), WINDOWS_EXAMPLES.join(" "));
check("the real manifest names exactly the apps on disk", Object.keys(real.examples).sort().join(" ") === disk.join(" "), Object.keys(real.examples).sort().join(" "));
check("every rule tag is in the real catalog", SELECTION_RULES.every((rule) => (rule.tags ?? []).every((tag) => real.tags[tag] !== undefined)));

const targeted: Selection = { examples: ["alpha", "beta", "gamma", "delta"], tags: ["paint", "text"], reasons: [], all: false };
const capped = shardSelection(targeted, manifest, 2, 1);
check("the shard cap keeps the most relevant apps", JSON.stringify(capped.shards) === JSON.stringify([["delta"], ["alpha"]]), JSON.stringify(capped.shards));
check("apps beyond the cap are reported as dropped", JSON.stringify(capped.dropped) === JSON.stringify(["beta", "gamma"]), JSON.stringify(capped.dropped));
const realPaintShards = shardSelection(realPaint, real, 4, 2);
check("a paint change runs two apps in each shard", realPaintShards.shards.every((list) => list.length === 2) && realPaintShards.dropped.length === 0, JSON.stringify(realPaintShards.shards));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
