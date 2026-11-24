// A public directory is the app's site root: every file in it is copied into the bundle as it is,
// so a URL the build never sees as a literal still names a file at runtime. Here an image's src
// and an audio's src are built from data, and the app keeps drawing and playing after its output
// moves and its source is deleted. A file the scripts fetch by a literal path beside the page is
// still collected as it was, and a public file nothing refers to is shipped too.
//   npm test

import { spawnSync } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng, encodePng } from "./png.ts";
import type { Image } from "./png.ts";
import { outputPaths } from "../compiler/build.ts";

const dir = mkdtempSync(join(tmpdir(), "native-public-"));
const app = join(dir, "app");
mkdirSync(join(app, "public", "covers"), { recursive: true });
mkdirSync(join(app, "public", "sounds"), { recursive: true });
mkdirSync(join(app, "public", "notes"), { recursive: true });
mkdirSync(join(app, "loose"), { recursive: true });

/** A 4x4 solid-colour PNG. */
const solid = (colour: number[]): Buffer => encodePng(4, 4, () => [...colour, 255]);
const RED = [255, 0, 0], WHITE = [255, 255, 255];

/** A mono 16-bit PCM WAV of a sine tone, which the engine's decoder reads. */
function toneWav(seconds: number, rate: number, frequency: number): Buffer {
  const samples = Math.floor(seconds * rate);
  const data = Buffer.alloc(44 + samples * 2);
  data.write("RIFF", 0);
  data.writeUInt32LE(36 + samples * 2, 4);
  data.write("WAVE", 8);
  data.write("fmt ", 12);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(rate, 24);
  data.writeUInt32LE(rate * 2, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write("data", 36);
  data.writeUInt32LE(samples * 2, 40);
  for (let i = 0; i < samples; i++) {
    data.writeInt16LE(Math.round(Math.sin((2 * Math.PI * frequency * i) / rate) * 8000), 44 + i * 2);
  }
  return data;
}

// The public directory: the cover and the audio are named only by the data below.
writeFileSync(join(app, "public", "covers", "red.png"), solid(RED));
writeFileSync(join(app, "public", "sounds", "tone.wav"), toneWav(0.3, 8000, 440));
// Nothing names this file; a public directory is shipped whole.
writeFileSync(join(app, "public", "notes", "unused.txt"), "nobody fetches me\n");
// Outside public/, the literal-reference detection still collects the file.
writeFileSync(join(app, "loose", "note.txt"), "fetched by a literal\n");

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=120, height=90"><style>
body { margin: 0; background: #ffffff; }
#cover { position: absolute; left: 0; top: 0; width: 40px; height: 40px; }
</style></head><body>
<img id="cover" alt="">
<audio id="track" preload="auto"></audio>
<script type="module" src="app.ts"></script>
</body></html>
`;
writeFileSync(join(app, "index.html"), PAGE);
writeFileSync(join(app, "app.ts"), `
interface Track { title: string; cover: string; audio: string; }
const tracks: Track[] = [
  { title: "Night Drive", cover: "covers/red.png", audio: "sounds/tone.wav" },
];
const track = tracks[0]!;

// Both URLs are built from the data at run time, so the build has no literal naming either file.
const cover = document.getElementById("cover") as HTMLImageElement;
cover.src = "/" + track.cover;
const audio = document.getElementById("track") as HTMLAudioElement;
audio.volume = 0;
audio.addEventListener("loadedmetadata", () => {
  console.log("meta " + (audio.duration > 0.25 && audio.duration < 0.35));
});
audio.addEventListener("error", () => { console.log("audio error"); });
audio.src = "/" + track.audio;
audio.load();

// A page-relative literal fetch, outside public/, is collected as it always was.
fetch("loose/note.txt").then((r) => r.text()).then((t) => { console.log("note " + t.trim()); });
`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const built = join(dir, "out", "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", app, "-o", built], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const paths = outputPaths(built, true);
const res = paths.resources;

// The public directory's files are at the bundle's root, not under a "public" segment.
for (const file of ["covers/red.png", "sounds/tone.wav", "notes/unused.txt"]) {
  check(`the bundle holds ${file}`, existsSync(join(res, ...file.split("/"))));
}
check("the public directory isn't a path inside the bundle", !existsSync(join(res, "public")));
// A file outside public/ that a script names literally is still copied, at its own path.
check("the bundle holds the literally fetched file", existsSync(join(res, "loose", "note.txt")));

function run(file: string, snapshot: string): { stdout: string[]; png: Image } {
  const r = spawnSync(file, [], {
    encoding: "utf8",
    env: { ...process.env, NATIVE_STEPS: "wait 2000 | frame 1", NATIVE_SNAPSHOT: snapshot },
  });
  if (r.status !== 0) throw new Error(`run failed (${r.status})\n${r.stderr}\n${r.stdout}`);
  return { stdout: r.stdout.split("\n").filter((l) => l !== ""), png: decodePng(snapshot) };
}

const before = run(paths.executable, join(dir, "before.png"));
check("the audio built from data plays its file", before.stdout.includes("meta true"),
  JSON.stringify(before.stdout));
check("the literal fetch outside public/ still reads its file", before.stdout.includes("note fetched by a literal"),
  JSON.stringify(before.stdout));
check("nothing errored", !before.stdout.some((l) => l.includes("error")), JSON.stringify(before.stdout));

const scale = before.png.w / 120;
function at(cx: number, cy: number): number[] {
  const o = (Math.round(cy * scale) * before.png.w + Math.round(cx * scale)) * 4;
  return [before.png.rgba[o], before.png.rgba[o + 1], before.png.rgba[o + 2]];
}
function near(cx: number, cy: number, want: number[]): boolean {
  return at(cx, cy).every((g, i) => Math.abs(g - want[i]) <= 8);
}
check("the image behind the data-driven src draws", near(20, 20, RED), `got ${at(20, 20)}`);
check("the rest of the page stays white", near(100, 60, WHITE));

// The app keeps its files when the output moves and the source goes away.
const moved = join(dir, "moved");
mkdirSync(moved, { recursive: true });
let movedExe: string;
if (paths.bundle !== null) {
  const target = join(moved, basename(paths.bundle));
  cpSync(paths.bundle, target, { recursive: true });
  movedExe = join(target, "Contents", "MacOS", basename(built));
} else {
  movedExe = join(moved, basename(paths.executable));
  copyFileSync(paths.executable, movedExe);
  if (existsSync(paths.resources)) cpSync(paths.resources, join(moved, basename(paths.resources)), { recursive: true });
}
rmSync(app, { recursive: true, force: true });
rmSync(join(dir, "out"), { recursive: true, force: true });

const after = run(movedExe, join(dir, "after.png"));
check("the moved app prints what it did before", JSON.stringify(after.stdout) === JSON.stringify(before.stdout),
  `before ${JSON.stringify(before.stdout)}, after ${JSON.stringify(after.stdout)}`);
check("the moved app draws the cover from the bundle", after.png.rgba.every((v, i) => v === before.png.rgba[i]));

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
