// Which examples a pull request runs. A change to a runtime area selects the examples whose
// declared coverage tags include that area, so a PR builds the apps that exercise what it touched;
// a change to shared ground (the compiler, the DOM core, the gate itself) selects every example.
// The full set is what a post-merge run uses; this selection applies to pull requests only.
//
// The tags each example covers live in examples/coverage.json, beside the apps.

import { appendFileSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export interface CoverageManifest {
  tags: { [tag: string]: string };
  examples: { [name: string]: string[] };
  /** The representative examples a pull request runs when a change reaches everything. */
  smoke?: string[];
}

export interface SelectionRule {
  /** A path prefix ending in `*`, or a full path. */
  pattern: string;
  /** Coverage tags a change to this path calls for. */
  tags?: string[];
  /** Every example, for changes whose reach can't be narrowed. */
  all?: boolean;
}

/** Examples every pull request runs when nothing more specific matches. */
export const BASELINE: readonly string[] = ["counter"];

/** The examples the Windows host draws; selection is intersected with this list there. */
export const WINDOWS_EXAMPLES: readonly string[] = [
  "counter", "article", "todo", "dashboard", "canvas", "webgl-cube", "webgl-texture",
];

/**
 * Paths to the coverage they exercise. The first specific rule wins for a path; a path that falls
 * through to the broad runtime and shared rules selects every example, because the change can
 * reach anything.
 */
export const SELECTION_RULES: readonly SelectionRule[] = [
  // Shared ground: the compiler, the host, the DOM core and the gate itself can affect any app.
  { pattern: "packages/cli/compiler/*", all: true },
  { pattern: "packages/cli/host/*", all: true },
  { pattern: "packages/cli/runtime/dom.ts", all: true },
  { pattern: "packages/cli/runtime/window.ts", all: true },
  { pattern: "packages/cli/runtime/app.ts", all: true },
  { pattern: "packages/cli/runtime/app/mount.ts", all: true },
  { pattern: "packages/cli/shared/props.ts", all: true },
  { pattern: "packages/cli/tests/examples.ts", all: true },
  { pattern: "examples/coverage.json", all: true },
  { pattern: "packages/cli/scripts/example-*", all: true },
  { pattern: "packages/cli/package.json", all: true },
  { pattern: "pnpm-lock.yaml", all: true },

  // Paint and the compositor.
  { pattern: "packages/cli/runtime/paint.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/paint-damage.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/background.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/gradient.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/shadows.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/radius.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/border-image.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/filters.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/mask.ts", tags: ["paint"] },
  { pattern: "packages/cli/runtime/clip.ts", tags: ["paint", "compositing"] },
  { pattern: "packages/cli/runtime/layers.ts", tags: ["compositing"] },
  { pattern: "packages/cli/runtime/compositor.ts", tags: ["compositing"] },
  { pattern: "packages/cli/runtime/transform.ts", tags: ["compositing"] },
  { pattern: "packages/cli/runtime/svg-paint.ts", tags: ["svg", "paint"] },

  // Text.
  { pattern: "packages/cli/runtime/text-runs.ts", tags: ["text"] },
  { pattern: "packages/cli/runtime/target-text.ts", tags: ["text"] },
  { pattern: "packages/cli/runtime/layout/inline.ts", tags: ["text", "layout"] },
  { pattern: "packages/cli/runtime/composition.ts", tags: ["ime", "text", "forms"] },

  // Layout.
  { pattern: "packages/cli/runtime/layout/*", tags: ["layout"] },
  { pattern: "packages/cli/runtime/layout.ts", tags: ["layout"] },
  { pattern: "packages/cli/runtime/layout-flush-hook.ts", tags: ["layout"] },
  { pattern: "packages/cli/runtime/container.ts", tags: ["layout"] },
  { pattern: "packages/cli/runtime/grid.ts", tags: ["layout"] },

  // CSS.
  { pattern: "packages/cli/runtime/style.ts", tags: ["css", "layout", "paint"] },
  { pattern: "packages/cli/runtime/sheets.ts", tags: ["css"] },
  { pattern: "packages/cli/runtime/cssom.ts", tags: ["css"] },
  { pattern: "packages/cli/shared/css/colors.ts", tags: ["css", "paint"] },
  { pattern: "packages/cli/shared/css/properties/*", tags: ["css", "paint", "layout", "compositing", "animation"] },
  { pattern: "packages/cli/shared/css/*", tags: ["css"] },

  // Animation.
  { pattern: "packages/cli/runtime/animation.ts", tags: ["animation", "compositing"] },
  { pattern: "packages/cli/runtime/frame-times.ts", tags: ["animation"] },
  { pattern: "packages/cli/runtime/app/loop.ts", tags: ["animation"] },
  { pattern: "packages/cli/runtime/app/refresh.ts", tags: ["animation"] },
  { pattern: "packages/cli/runtime/smooth.ts", tags: ["animation", "scrolling"] },
  { pattern: "packages/cli/runtime/smooth-hook.ts", tags: ["animation", "scrolling"] },

  // Events, fields and focus.
  { pattern: "packages/cli/runtime/events.ts", tags: ["events"] },
  { pattern: "packages/cli/runtime/app/pointer.ts", tags: ["events"] },
  { pattern: "packages/cli/runtime/app/keyboard.ts", tags: ["events", "forms", "ime", "editing"] },
  { pattern: "packages/cli/runtime/app/timers.ts", tags: ["events", "animation"] },
  { pattern: "packages/cli/runtime/focusgroup.ts", tags: ["events", "forms"] },
  { pattern: "packages/cli/runtime/controls.ts", tags: ["forms"] },
  { pattern: "packages/cli/runtime/date-picker.ts", tags: ["forms", "dialogs"] },
  { pattern: "packages/cli/runtime/date-times.ts", tags: ["forms"] },
  { pattern: "packages/cli/runtime/select-popup.ts", tags: ["forms", "dialogs"] },
  { pattern: "packages/cli/runtime/menus.ts", tags: ["dialogs", "forms", "events"] },

  // Scrolling, virtual lists and drag and drop.
  { pattern: "packages/cli/runtime/app/scroll.ts", tags: ["scrolling", "virtual-list"] },
  { pattern: "packages/cli/runtime/app/scrollbar.ts", tags: ["scrolling"] },
  { pattern: "packages/cli/runtime/sticky-hook.ts", tags: ["scrolling", "layout"] },
  { pattern: "packages/cli/runtime/snap-hook.ts", tags: ["scrolling"] },
  { pattern: "packages/cli/runtime/viewport.ts", tags: ["scrolling", "layout"] },
  { pattern: "packages/cli/runtime/app/dnd.ts", tags: ["drag-drop", "events"] },

  // Drawing APIs.
  { pattern: "packages/cli/runtime/canvas.ts", tags: ["canvas2d", "images", "paint"] },
  { pattern: "packages/cli/runtime/webgl.ts", tags: ["webgl"] },
  { pattern: "packages/cli/runtime/svg*.ts", tags: ["svg", "paint"] },
  { pattern: "packages/cli/shared/svg*.ts", tags: ["svg", "paint"] },

  // Media, images and networking.
  { pattern: "packages/cli/runtime/media*.ts", tags: ["media"] },
  { pattern: "packages/cli/runtime/audio/*", tags: ["media"] },
  { pattern: "packages/cli/runtime/images.ts", tags: ["images", "paint"] },
  { pattern: "packages/cli/runtime/image-fit.ts", tags: ["images", "paint"] },
  { pattern: "packages/cli/runtime/svg-image.ts", tags: ["images", "svg"] },
  { pattern: "packages/cli/runtime/fetch.ts", tags: ["networking"] },
  { pattern: "packages/cli/runtime/xhr.ts", tags: ["networking"] },
  { pattern: "packages/cli/runtime/websocket.ts", tags: ["networking"] },
  { pattern: "packages/cli/runtime/eventsource.ts", tags: ["networking"] },
  { pattern: "packages/cli/runtime/worker*.ts", tags: ["networking"] },

  // Editing, selection and storage.
  { pattern: "packages/cli/runtime/editable.ts", tags: ["editing", "text"] },
  { pattern: "packages/cli/runtime/editing.ts", tags: ["editing", "text"] },
  { pattern: "packages/cli/runtime/editing-history.ts", tags: ["editing", "text"] },
  { pattern: "packages/cli/runtime/selection.ts", tags: ["editing", "text"] },
  { pattern: "packages/cli/runtime/storage.ts", tags: ["storage"] },
  { pattern: "packages/cli/runtime/indexeddb.ts", tags: ["storage"] },
  { pattern: "packages/cli/runtime/sqlite.ts", tags: ["storage"] },

  // Accessibility reaches every app.
  { pattern: "packages/cli/runtime/a11y.ts", all: true },
  { pattern: "packages/cli/runtime/ax-tree.ts", all: true },
  { pattern: "packages/cli/runtime/app/ax-actions.ts", all: true },

  // Anything else in the runtime or the shared layer can reach any app.
  { pattern: "packages/cli/runtime/*", all: true },
  { pattern: "packages/cli/shared/*", all: true },
];

export interface Selection {
  examples: string[];
  tags: string[];
  reasons: string[];
  /** True when a rule selects every example (a change to shared ground). */
  all: boolean;
}

export function matchesPath(pattern: string, path: string): boolean {
  if (pattern.indexOf("*") < 0) return path === pattern;
  const pattern_ = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp("^" + pattern_ + "$").test(path);
}

/** The example directory a path belongs to, or null when it is not under examples/. */
export function exampleInPath(path: string, examples: readonly string[]): string | null {
  for (const name of examples) {
    if (path === "examples/" + name || path.startsWith("examples/" + name + "/")) return name;
  }
  return null;
}

/**
 * The examples a changed-file list selects. A path under an example selects that example; a path
 * matching a rule adds its tags; a rule with `all` selects the full suite. With nothing selected
 * the baseline runs.
 */
export function selectExamples(
  changed: readonly string[],
  manifest: CoverageManifest,
  rules: readonly SelectionRule[] = SELECTION_RULES,
  baseline: readonly string[] = BASELINE,
): Selection {
  const examples = Object.keys(manifest.examples).sort();
  const selected = new Set<string>();
  const tags = new Set<string>();
  const reasons: string[] = [];
  let all = false;
  for (const path of changed) {
    const own = exampleInPath(path, examples);
    if (own !== null) {
      selected.add(own);
      reasons.push(`${path} selects ${own} (the example itself)`);
      continue;
    }
    for (const rule of rules) {
      if (!matchesPath(rule.pattern, path)) continue;
      if (rule.all === true) {
        all = true;
        reasons.push(`${path} selects every example (${rule.pattern})`);
        break;
      }
      const ruleTags = rule.tags ?? [];
      if (ruleTags.length === 0) continue;
      let added = false;
      for (const tag of ruleTags) {
        if (!tags.has(tag)) {
          tags.add(tag);
          added = true;
        }
      }
      if (added) reasons.push(`${path} selects ${ruleTags.join(", ")} (${rule.pattern})`);
      break;
    }
  }
  if (all) {
    return { examples: examples, tags: Object.keys(manifest.tags).sort(), reasons, all: true };
  }
  for (const name of examples) {
    const own = manifest.examples[name];
    if (own.some((tag: string) => tags.has(tag))) selected.add(name);
  }
  if (selected.size === 0) {
    for (const name of baseline) if (examples.indexOf(name) >= 0) selected.add(name);
    if (selected.size > 0) reasons.push("no rule selected an example; running the baseline");
  }
  return { examples: Array.from(selected).sort(), tags: Array.from(tags).sort(), reasons, all: false };
}

/**
 * The examples each shard of a pull request runs. A change with unfocused reach runs the manifest's
 * smoke set, one app per shard. A targeted selection keeps up to `perShard` apps for each of
 * `shards` shards, most relevant first (an app whose declared tags match more of the change's tags),
 * and spreads them round-robin. Apps beyond the cap are returned as dropped.
 */
export function shardSelection(
  selection: Selection,
  manifest: CoverageManifest,
  shards: number,
  perShard: number,
): { shards: string[][]; dropped: string[] } {
  const picked = selection.all ? (manifest.smoke ?? selection.examples).slice() : selection.examples.slice();
  if (!selection.all) {
    const relevance = (name: string): number => {
      const own = manifest.examples[name] ?? [];
      let count = 0;
      for (const tag of own) if (selection.tags.indexOf(tag) >= 0) count++;
      return count;
    };
    picked.sort((a, b) => {
      const byRelevance = relevance(b) - relevance(a);
      return byRelevance !== 0 ? byRelevance : (a < b ? -1 : a > b ? 1 : 0);
    });
  }
  const cap = shards * perShard;
  const kept = picked.slice(0, cap);
  const dropped = picked.slice(cap);
  const out: string[][] = [];
  for (let i = 0; i < shards; i++) out.push([]);
  if (selection.all) {
    for (let i = 0; i < kept.length && i < shards; i++) out[i].push(kept[i]);
  } else {
    for (let i = 0; i < kept.length; i++) out[i % shards].push(kept[i]);
  }
  return { shards: out, dropped };
}

/** Reads examples/coverage.json and checks it against the apps on disk. */
export function loadManifest(root: string): CoverageManifest {
  const manifest = JSON.parse(readFileSync(join(root, "examples", "coverage.json"), "utf8")) as CoverageManifest;
  return manifest;
}

export function exampleNames(root: string): string[] {
  return readdirSync(join(root, "examples"), { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(join(root, "examples", entry.name, "index.html")))
    .map((entry) => entry.name)
    .sort();
}

export function repoRootFromScript(): string {
  return dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))));
}

function main(argv: string[]): void {
  const root = repoRootFromScript();
  const manifest = loadManifest(root);
  let changed: string[] = [];
  let only: string[] | null = null;
  let githubOutput: string | null = null;
  let json = false;
  let all = false;
  let shards = 4;
  let perShard = 2;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--changed") {
      const file = argv[++i] ?? "";
      changed = changed.concat(readFileSync(file, "utf8").split("\n").map((line) => line.trim()).filter((line) => line !== ""));
    } else if (arg === "--only") {
      only = (argv[++i] ?? "").split(/[\s,]+/).filter((name) => name !== "");
    } else if (arg === "--github-output") {
      githubOutput = argv[++i] ?? null;
    } else if (arg === "--shards") {
      shards = Math.max(1, Number(argv[++i] ?? "4"));
    } else if (arg === "--per-shard") {
      perShard = Math.max(1, Number(argv[++i] ?? "2"));
    } else if (arg === "--json") {
      json = true;
    } else if (arg === "--all") {
      all = true;
    } else {
      console.error(`example-selection: unknown argument ${arg}`);
      process.exit(2);
    }
  }
  const selection: Selection = all
    ? { examples: exampleNames(root), tags: Object.keys(manifest.tags).sort(), reasons: ["--all"], all: false }
    : selectExamples(changed, manifest);
  let examples = selection.examples;
  if (only !== null) examples = examples.filter((name) => only.indexOf(name) >= 0);
  const distributed = shardSelection({ ...selection, examples }, manifest, shards, perShard);
  if (githubOutput !== null) {
    const lines = distributed.shards.map((list) => list.join(" "));
    appendFileSync(githubOutput, "shards<<EXAMPLE_SHARDS\n" + lines.join("\n") + "\nEXAMPLE_SHARDS\n");
  }
  if (json) {
    console.log(JSON.stringify({
      examples,
      shards: distributed.shards,
      dropped: distributed.dropped,
      tags: selection.tags,
      reasons: selection.reasons,
      all: selection.all,
    }, null, 2));
  } else if (githubOutput !== null) {
    for (let i = 0; i < distributed.shards.length; i++) {
      console.log(`shard ${i + 1}: ${distributed.shards[i].length === 0 ? "(none)" : distributed.shards[i].join(" ")}`);
    }
    if (distributed.dropped.length > 0) console.log(`beyond the cap: ${distributed.dropped.join(" ")}`);
  } else {
    console.log(examples.join(" "));
  }
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
