// Builds and launches every app under examples/, so one that stops building or stops drawing its
// first frame fails the suite, and an example nobody wired up fails it too.
//
// Each app is built once, then run headlessly twice: once with the frame it opens on, to check the
// first frame is drawn, and once through a scripted interaction whose printed state is checked
// against what a person would see. A run saves a snapshot, and the interaction's snapshot must
// differ from the first frame's, so a page that renders and then ignores its input is caught.
//
// An app the installed compiler cannot build yet is listed in BLOCKED with the reason and the
// scriptc version its fix ships in. It is still built and its failure reported, as a known failure
// rather than a pass, and every other app's failure still fails the gate. Once the installed
// compiler is newer than that version the entry stops applying by itself.
//   npm test
//   node tests/examples.ts counter todo      (just those examples)
//   node tests/examples.ts --shard 1/4       (every fourth app, for a suite split across jobs)

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";
import type { Image } from "./png.ts";

/** One app and the way a person drives it. */
interface Example {
  /** Steps for the run that checks the app opens and draws, before any input. */
  open: string;
  /** Steps for the interaction, and the lines it must print. */
  steps: string;
  want: string[];
  /** Whether the interaction must change the picture (false where the platform draws nothing). */
  changes?: boolean;
}

/** What the WebGL example's HUD says. Both hosts back getContext("webgl2") with a real OpenGL
 *  context, so the page draws the cube and leaves the "not available" note unset. */
const WEBGL_HUD = "WEBGL2 · SPINNING LIT CUBE";

/** The version of the scriptc this build runs, from the package npm installed. */
function scriptcVersion(): string | null {
  try {
    return JSON.parse(readFileSync(join("node_modules", "scriptc", "package.json"), "utf8")).version as string;
  } catch {
    return null;
  }
}

/** Whether `version` is at most `bound`, both dotted numbers. */
function atMost(version: string, bound: string): boolean {
  const a = version.split(".").map(Number);
  const b = bound.split(".").map(Number);
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    if (x !== y) return x < y;
  }
  return true;
}

/** Apps the installed compiler cannot build yet, each with the version its fix is in and why. The
 *  gate still builds every one of them and reports the result: a listed app whose build fails on
 *  the installed compiler is a known failure, not a pass and not a surprise, and any other app's
 *  failure still fails the gate. When scriptc moves past the version named here the entry stops
 *  applying, so the app's build and its scripted interaction run like any other — and a listed app
 *  that starts building earlier is run too, with a note that the entry is stale. */
const BLOCKED: { [name: string]: { fixedAfter: string; reason: string } } = {
  "three-game": {
    fixedAfter: "0.4.14",
    reason: "scriptc 0.4.14 cannot build it: three.js 0.187's build files carry JSDoc class types " +
      "and untyped JavaScript that the 0.4.14 checker refuses (SC0001 and SC1090), which also " +
      "leaves the app's three.js members unresolved. Fixed on scriptc main, which ships as 0.4.15.",
  },
  "three-hero": {
    fixedAfter: "0.4.14",
    reason: "scriptc 0.4.14 cannot build it: three.js 0.187's build files carry JSDoc class types " +
      "and untyped JavaScript that the 0.4.14 checker refuses (SC0001 and SC1090), which also " +
      "leaves the app's three.js members unresolved. Fixed on scriptc main, which ships as 0.4.15.",
  },
  halyard: {
    fixedAfter: "0.4.15",
    reason: "scriptc 0.4.14 (and 0.4.15 on Linux, whose runtime pack does not match its compiler) " +
      "cannot build it: React 19's CommonJS builds trip the checker (SC0001 and SC1090) inside " +
      "react, react-dom and scheduler, so the app does not compile. 0.4.16 builds it.",
  },
  "ui-dashboard": {
    fixedAfter: "0.4.14",
    reason: "scriptc 0.4.14 cannot build it: React 19's CommonJS builds trip the 0.4.14 checker " +
      "(SC0001 and SC1090) inside react, react-dom and scheduler, so the app does not compile. " +
      "Fixed on scriptc main, which ships as 0.4.15.",
  },
  "ui-settings": {
    fixedAfter: "0.4.14",
    reason: "scriptc 0.4.14 cannot build it: React 19's CommonJS builds trip the 0.4.14 checker " +
      "(SC0001 and SC1090) inside react, react-dom and scheduler, so the app does not compile. " +
      "Fixed on scriptc main, which ships as 0.4.15.",
  },
  player: {
    fixedAfter: "0.4.14",
    reason: "scriptc 0.4.14 cannot build it: React 19's CommonJS builds trip the 0.4.14 checker " +
      "(SC0001 and SC1090) inside react, react-dom and scheduler, so the app does not compile. " +
      "Fixed on scriptc main, which ships as 0.4.15.",
  },
  "preact-todo": {
    fixedAfter: "0.4.14",
    reason: "scriptc 0.4.14 cannot build it: building a class's static-method table refuses a method " +
      "with an optional parameter (Response.json), and the refusal escapes as an empty SC3004. Fixed " +
      "by scriptc #3711 and #3713, which the release after 0.4.14 carries.",
  },
};

const EXAMPLES: { [name: string]: Example } = {
  article: {
    open: "frame 16",
    steps: "click #link | frame 16 | print #status",
    want: ["Clicked the link (1 total)."],
  },
  canvas: {
    open: "frame 0 | frame 400",
    steps: "frame 0 | frame 400 | click #stage | frame 400 | print #mode",
    want: ["SPIRAL"],
  },
  "css-motion": {
    open: "frame 0 | frame 800",
    steps: "frame 0 | frame 800 | click #preorder | print #preorder",
    want: ["Added to bag"],
  },
  "canvas-particles": {
    open: "frame 0 | frame 300",
    steps: "frame 0 | frame 300 | drag #field 500 300 | frame 600 | print #mode",
    want: ["CANVAS 2D · 60 FPS"],
  },
  counter: {
    open: "frame 16",
    steps: "click #inc | click #inc | click #dec | print #count | print #status",
    want: ["1", "3 clicks so far"],
  },
  dashboard: {
    open: "frame 16",
    steps: "click #resend | frame 16 | print #resend",
    want: ["Invite sent ✓"],
  },
  "preact-todo": {
    // Preact renders in a microtask and the mount effect focuses the field on the next frame, so
    // each interaction starts with a frame step.
    open: "frame 0 | print #count",
    steps: "frame 0 | print #count | type Buy milk | key Enter | frame 0 | print #count | print #list | type Walk dog | click #add | print #count",
    want: ["No todos", "1 left of 1", "Buy milkx", "2 left of 2"],
  },
  ime: {
    open: "frame 16",
    // Typing without an input method still reaches the page as an input event; the composition
    // itself is driven by tests/ime.ts, which posts the input method's own messages.
    steps: "type a | print #log",
    want: ["input value=a"],
  },
  todo: {
    open: "frame 16",
    steps: "type a | key Enter | type b | key Enter | print #left | click .item | frame 16 | print #left",
    want: ["2 items left", "1 item left"],
  },
  tickets: {
    open: "frame 16",
    // The list opens with the first ticket selected from the click, and its description fills the
    // detail pane, which is the picture the run compares against the opening frame.
    steps: "click .row | frame 16 | print #status",
    want: ["Showing NAT-1000"],
  },
  "webgl-cube": {
    open: "frame 0 | frame 200",
    // The render loop redraws the cube at the frame's own time, so the later snapshots have to
    // differ from the first.
    steps: "frame 0 | frame 200 | frame 900 | print #hud",
    want: [WEBGL_HUD],
    changes: true,
  },
  "webgl-texture": {
    open: "frame 0 | frame 200",
    // A click moves the sampling point a quarter of the way across the texture, so the frame shows
    // another quadrant and the line reports the colour that landed under the middle of the canvas.
    steps: "frame 0 | frame 200 | click #stage | frame 16 | print #sample",
    want: ["TEXTURE #2EC4B6"],
  },
  "three-game": {
    open: "frame 0 | frame 500",
    // A click starts a round, the held arrow moves the paddle, and the app reports its mode.
    steps: "frame 0 | click #stage | frame 500 | keydown ArrowLeft | frame 300 | keyup ArrowLeft | print #mode",
    want: ["PLAYING"],
    changes: true,
  },
  "three-hero": {
    open: "frame 0 | frame 500",
    // The scene turns every frame, and the HUD is the static line the app opens with.
    steps: "frame 0 | frame 900 | print #hud",
    want: ["THREE.JS · NATIVE SDK"],
    changes: true,
  },
  halyard: {
    open: "frame 0 | frame 16",
    // React renders on a microtask, so the steps that follow start with a frame. The palette's
    // search field takes focus, and Enter runs the one command whose label matches. The selected
    // issue then moves down one place with Option-Down, which the hidden line reports.
    steps: "frame 0 | frame 16 | key Meta+k | frame 16 | type cycle status | frame 16 | key Enter | frame 16 | key Alt+ArrowDown | frame 16 | print #status | print #order-first",
    want: ["HAL-1001 · In progress", "BEA-1002 HAL-1001 HAL-1003"],
  },
  "ui-dashboard": {
    open: "frame 0 | frame 16",
    // React renders on a microtask, so the steps that follow start with a frame.
    steps: "frame 0 | frame 16 | click #search | type Beacon | frame 16 | print #status",
    want: ["Searching for Beacon"],
  },
  "ui-settings": {
    open: "frame 0 | frame 16",
    steps: "frame 0 | frame 16 | click #tab-notifications | frame 16 | click #switch-weekly | frame 16 | print #state",
    want: ["Weekly digest off"],
  },
  player: {
    open: "frame 0 | frame 16",
    // A cover opens the record, which animates in, and the first song starts
    // from its row, moving the player bar's scrubber and equalizer.
    steps: "frame 0 | frame 16 | click #album-still-harbor | frame 500 | click #track-still-harbor-1 | frame 1000 | print #now-playing",
    want: ["Still Harbor · Marlow Vane"],
  },
  notes: {
    open: "frame 0 | frame 16",
    // React renders on a microtask, so the steps that follow start with a frame.
    steps: "frame 0 | frame 16 | click #search | type launch | frame 16 | print #note-count",
    want: ["1 note"],
  },
  "data-table": {
    open: "frame 0 | frame 16",
    // Sorting by Due twice puts the latest date first (INV-1103), the filter narrows 3000
    // invoices to the 750 overdue ones (the first is INV-1002), and a search that matches nothing
    // leaves the arrow keys with nothing to move to instead of throwing.
    steps: "frame 0 | frame 16 | click #sort-due | frame 16 | click #sort-due | frame 16 | print #row-INV-1103 | click #sort-invoice | frame 16 | click #filter-overdue | frame 16 | print #result-count | click #row-INV-1002 | frame 16 | print #selected | click #search | type zzzzzzzz | frame 16 | print #result-count | click #rows | frame 16 | key ArrowDown | frame 16 | print #selected",
    want: ["INV-1103KLKestrel LabsDraft$3,476.57Dec 27, 2027Priya", "750 of 3000 rows", "Selected INV-1002", "0 of 3000 rows", "Selected INV-1002"],
  },
  kanban: {
    open: "frame 0 | frame 16",
    // A drag of the card in "In progress" onto the "Next up" column.
    steps: "frame 0 | frame 16 | drag #card-k6 -280 0 | frame 16 | print #board-status | print #count-next",
    want: ["Moved “Drag a card between columns” to Next up", "3"],
  },
  chat: {
    open: "frame 0 | frame 16",
    // Enter sends; the reply streams from a timer, so the count is read once the two messages are
    // in the thread (the text keeps arriving after that). New conversation adds an empty thread
    // instead of reopening Release notes.
    steps: "frame 0 | frame 16 | click #composer | type How did the deploy go? | key Enter | wait 500 | print #message-count | click #new-thread | frame 16 | print #message-count",
    want: ["5 messages", "0 messages"],
  },
  places: {
    open: "frame 0 | wait 200",
    // The first run fills the store from public/seed.json; the editor adds one more.
    steps: "frame 0 | wait 200 | print #count | click #add | type A small site | click #field-url | type https://example.com | click #save | wait 200 | print #count",
    want: ["8 places", "9 places"],
  },
  pulse: {
    open: "frame 0 | frame 16",
    // The metrics tick on a timer; `wait` lets the timer and the state update land.
    steps: "frame 0 | frame 16 | print #tick | wait 2200 | print #tick | click #pause | frame 16 | print #live-state | wait 1500 | print #tick",
    want: ["tick 0", "tick 2", "Paused", "tick 2"],
  },
  quarry: {
    open: "frame 0 | frame 16",
    // A save with valid defaults, the appearance tab's range at its default size, then the reset
    // dialog.
    steps: "frame 0 | frame 16 | click #save | frame 16 | print #saved | click #tab-appearance | frame 16 | print #text-size | click #tab-advanced | frame 16 | click #reset-open | frame 100 | print #reset-dialog | click #reset-confirm | frame 100 | print #saved",
    want: ["Saved just now", "16", "Restore every default?This puts the profile, appearance, notifications and privacy settings back to their defaults. Forwarding addresses are cleared too.CancelRestore defaults", "Defaults restored"],
  },
  editor: {
    open: "frame 0 | frame 16",
    // The sample draft's counts, then the link dialog: a URL with nothing selected says what it
    // needs. (A selection's toolbar state depends on the selectionchange change that lands in
    // another branch.)
    steps: "frame 0 | frame 16 | print #word-count | click #link-open | frame 16 | click #link-url | type https://example.com | click #link-apply | frame 16 | print #saved",
    want: ["54 words", "Select a word first"],
  },
};

const APP = "../../examples";
const out = mkdtempSync(join(tmpdir(), "native-examples-"));
const results: { name: string; build: number; first: number; steps: number; frame: string; printed: string[] }[] = [];
let failed = 0;

function check(name: string, ok: boolean, detail = ""): boolean {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
  return ok;
}

/** The examples the app's package.json declares, and whether they're installed. */
function needsInstall(dir: string): boolean {
  const manifest = join(dir, "package.json");
  if (!existsSync(manifest)) return false;
  const pkg = JSON.parse(readFileSync(manifest, "utf8")) as { dependencies?: object };
  const deps = Object.keys(pkg.dependencies ?? {});
  return deps.length > 0 && !existsSync(join(dir, "node_modules"));
}

/** How many distinct colours the snapshot holds: a page that drew nothing is one flat colour. */
function colours(img: Image): number {
  const seen = new Set<number>();
  for (let i = 0; i < img.rgba.length; i += 4) {
    seen.add((img.rgba[i] << 24) | (img.rgba[i + 1] << 16) | (img.rgba[i + 2] << 8) | img.rgba[i + 3]);
  }
  return seen.size;
}

function hash(img: Image): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < img.rgba.length; i++) h = Math.imul(h ^ img.rgba[i], 0x01000193);
  return h >>> 0;
}

interface Run {
  lines: string[];
  img: Image;
  ms: number;
}

function run(exe: string, name: string, steps: string): Run {
  const png = join(out, `${name}.png`);
  // Each run starts from empty local storage, so an app that remembers a mode (the canvas does)
  // reads what the build wrote in, not what an earlier run of this test left behind.
  const storage = join(out, `${name}.storage.json`);
  // The settings a snapshot must not depend on. A macOS CI runner can report that it wants
  // reduced motion, and the examples that animate through it (webgl-cube, three-hero) then hold
  // still, so both runs draw the same picture and the interaction check fails on a machine whose
  // only difference is that accessibility setting. Pin the preference off so the same steps draw
  // the same pages here and on every host.
  const env: NodeJS.ProcessEnv = {
    ...process.env, NATIVE_STEPS: steps, NATIVE_SNAPSHOT: png, NATIVE_STORAGE: storage,
    NATIVE_REDUCED_MOTION: "0",
  };
  const started = performance.now();
  const r = spawnSync(exe, [], { encoding: "utf8", env, timeout: 120_000 });
  const ms = performance.now() - started;
  if (r.status !== 0) {
    console.error(r.stderr);
    throw new Error(`${name}: run failed (exit ${r.status})`);
  }
  const lines = r.stdout.split("\n").slice(0, -1);
  if (!existsSync(png)) throw new Error(`${name}: no snapshot was written`);
  return { lines, img: decodePng(png), ms };
}

// The examples on disk, and the ones this file knows how to drive. A new example has to be added
// here with the steps that show what it does; that's the point of the list.
const found = readdirSync(APP, { withFileTypes: true })
  .filter((e) => e.isDirectory() && existsSync(join(APP, e.name, "index.html")))
  .map((e) => e.name)
  .sort();
const known = Object.keys(EXAMPLES).sort();
// `--shard <index>/<count>` runs every `count`th app from `index`, so a suite whose builds cost
// hours can be built and run side by side in jobs of a quarter the work. Every shard still walks
// the whole list above, so an example missing from EXAMPLES fails every job that runs one.
const argv = process.argv.slice(2);
let shardIndex = 0, shardCount = 1;
{
  const at = argv.indexOf("--shard");
  if (at >= 0) {
    const spec = argv[at + 1] ?? "";
    const parts = /^(\d+)\/(\d+)$/.exec(spec);
    const index = parts === null ? 0 : Number(parts[1]);
    const count = parts === null ? 0 : Number(parts[2]);
    if (index < 1 || count < 1 || index > count) {
      console.error(`native: --shard takes <index>/<count>, as 1/4; got '${spec}'`);
      process.exit(2);
    }
    shardIndex = index - 1;
    shardCount = count;
    argv.splice(at, 2);
  }
}
const wanted = argv;
for (const name of found) {
  check(`${name}: is driven by tests/examples.ts`, known.includes(name), "add it to EXAMPLES");
}
for (const name of known) {
  check(`${name}: has an app under examples/`, found.includes(name), `examples/${name}/index.html is missing`);
}

const missing = wanted.filter((name) => !known.includes(name));
if (missing.length > 0) {
  console.error(`no such example: ${missing.join(", ")}`);
  process.exit(2);
}
const apps = found
  .filter((name) => known.includes(name) && (wanted.length === 0 || wanted.includes(name)))
  .filter((_, at) => at % shardCount === shardIndex);
const version = scriptcVersion();
const knownFailures: { name: string; build: number; reason: string }[] = [];

for (const name of apps) {
  const dir = join(APP, name);
  const example = EXAMPLES[name];
  const blocked = BLOCKED[name];
  // A listed app is only let off the build on a compiler older than its fix. On a newer one the
  // entry no longer applies, so the build must succeed and its checks must pass.
  const exempt = blocked !== undefined && version !== null && atMost(version, blocked.fixedAfter);

  // A dependency is installed the way an app installs one.
  if (needsInstall(dir)) {
    // Windows spells the command with its extension, and a .cmd needs a shell to run at all.
    const win = process.platform === "win32";
    const npm = win ? "npm.cmd" : "npm";
    const r = spawnSync(npm, ["install", "--no-audit", "--no-fund"], { cwd: dir, encoding: "utf8", shell: win });
    if (r.status !== 0) {
      console.error(r.stderr);
      throw new Error(`${name}: npm install failed`);
    }
  }

  // Windows runs an executable by its .exe name; the built path carries it there.
  const exe = join(out, process.platform === "win32" ? `${name}.exe` : name);
  const started = performance.now();
  const b = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
  const buildMs = performance.now() - started;
  if (b.status !== 0) {
    if (exempt) {
      knownFailures.push({ name, build: buildMs, reason: blocked.reason });
      console.log(`KNOWN ${name}: does not build on scriptc ${version} — ${blocked.reason}`);
      continue;
    }
    // A failed build's whole output is worth seeing: the last line rarely names the cause.
    if (b.stderr.trim() !== "") console.error(b.stderr.trim());
    check(`${name}: builds`, false, b.stderr.trim().split("\n").slice(-1)[0]);

    continue;
  }
  if (exempt) console.log(`note ${name}: built on scriptc ${version}, which its entry in BLOCKED says cannot; the entry is stale and its checks run`);
  check(`${name}: builds`, true);
  check(`${name}: writes an executable`, existsSync(exe));

  let first: Run;
  try {
    first = run(exe, `${name}-open`, example.open);
  } catch (err) {
    check(`${name}: opens`, false, (err as Error).message);
    continue;
  }
  const drawn = colours(first.img);
  check(`${name}: draws its first frame`, drawn > 4, `${drawn} colours at ${first.img.w}x${first.img.h}`);

  let stepped: Run;
  try {
    stepped = run(exe, `${name}-steps`, example.steps);
  } catch (err) {
    check(`${name}: takes the scripted interaction`, false, (err as Error).message);
    continue;
  }
  check(`${name}: prints what the interaction did`, JSON.stringify(stepped.lines) === JSON.stringify(example.want),
    `expected ${JSON.stringify(example.want)}, got ${JSON.stringify(stepped.lines)}`);
  if (example.changes !== false) {
    check(`${name}: the interaction changes the picture`, hash(first.img) !== hash(stepped.img),
      "the snapshot after the interaction is the first frame");
  }

  results.push({ name, build: buildMs, first: first.ms, steps: stepped.ms, frame: `${stepped.img.w}x${stepped.img.h}`, printed: stepped.lines });
}

// One line per app: what it costs to build and run, and what the interaction printed.
console.log("\nexample          build     open     steps    frame         printed");
for (const r of results) {
  console.log(`${r.name.padEnd(16)}${(r.build / 1000).toFixed(1).padStart(5)}s ${(r.first / 1000).toFixed(2).padStart(7)}s ${(r.steps / 1000).toFixed(2).padStart(7)}s  ${r.frame.padEnd(13)} ${r.printed.join(" | ")}`);
}
for (const k of knownFailures) {
  console.log(`${k.name.padEnd(16)}${(k.build / 1000).toFixed(1).padStart(5)}s ${"—".padStart(7)} ${"—".padStart(7)}   ${`known build failure on scriptc ${version}`}`);
}

if (failed > 0) {
  console.error(`\n${failed} example check${failed === 1 ? "" : "s"} failed`);
  process.exit(1);
}
if (knownFailures.length > 0) {
  console.log(`\nknown build failures on scriptc ${version} (built and reported, not counted as passes; the entry in BLOCKED names the fix that ends each one):`);
  for (const k of knownFailures) console.log(`  ${k.name}: ${k.reason}`);
}
const ran = apps.length - knownFailures.length;
const knownSuffix = knownFailures.length > 0 ? `; ${knownFailures.length} known build failure${knownFailures.length === 1 ? "" : "s"}` : "";
console.log(ran === 0 ? `\nno example the installed compiler builds was selected${knownSuffix}` : `\nall ${ran} examples the installed compiler builds ran${knownSuffix}`);
