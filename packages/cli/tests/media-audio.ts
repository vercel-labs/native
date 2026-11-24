// <audio> element playback through the Web Audio engine: a generated tone file loads and decodes,
// play/pause, the playhead, a seek, and the ended state, with the events a browser sends.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const PAGE = `<!doctype html>
<html><head><style>body { margin: 0; }</style></head><body>
<audio id="a" src="tone.wav" preload="auto"></audio>
<audio id="b" src="tone.wav" preload="auto"></audio>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const a = document.getElementById("a") as HTMLAudioElement;
const seen: string[] = [];
for (const type of ["loadedmetadata", "play", "playing", "pause", "seeking", "seeked", "ended", "error",
  "durationchange", "canplay", "emptied", "volumechange"]) {
  a.addEventListener(type, () => { seen.push(type); });
}
a.volume = 0;
function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function main(): Promise<void> {
  log("init " + a.paused + " " + a.readyState + " " + (a.currentSrc === ""));
  a.addEventListener("error", () => log("media error " + (a.error === null ? "none" : a.error.message)));
  await new Promise<void>((resolve, reject) => {
    a.addEventListener("loadedmetadata", () => resolve());
    a.addEventListener("error", () => reject(new Error("load failed")));
    a.load();
  });
  log("meta " + a.readyState + " " + (a.duration > 0.25 && a.duration < 0.35) + " " + (a.currentSrc === "tone.wav"));
  await a.play();
  log("play " + a.paused + " " + a.ended);
  await wait(120);
  log("time " + (a.currentTime > 0.05));
  a.pause();
  log("pause " + a.paused + " " + (a.currentTime > 0.03));
  a.currentTime = 0.1;
  log("seek " + (a.currentTime > 0.09 && a.currentTime < 0.12) + " " + a.ended);
  const ended = new Promise<void>((resolve, reject) => {
    a.addEventListener("ended", () => resolve());
    setTimeout(() => reject(new Error("no ended")), 2000);
  });
  await a.play();
  await ended;
  log("ended " + a.ended + " " + a.paused + " " + (a.currentTime > 0.28));
  log("canplay " + a.canPlayType("audio/wav") + " " + (a.canPlayType("video/x-unknown") === ""));
  log("events " + seen.join(","));

  // A source node takes the element's sound into the app's own graph.
  const b = document.getElementById("b") as HTMLAudioElement;
  b.volume = 0;
  const ctx = new AudioContext();
  const node = ctx.createMediaElementSource(b);
  node.connect(ctx.destination);
  log("node " + (node.mediaElement === b) + " " + (node instanceof MediaElementAudioSourceNode));
  let twice = false;
  try { ctx.createMediaElementSource(b); } catch (e: any) { twice = e.message.startsWith("InvalidStateError"); }
  log("node twice " + twice);
  await new Promise<void>((resolve, reject) => {
    b.addEventListener("loadedmetadata", () => resolve());
    b.addEventListener("error", () => reject(new Error("b load failed")));
    b.load();
  });
  await b.play();
  await wait(100);
  log("node time " + (b.currentTime > 0.05));
  const endedB = new Promise<void>((resolve, reject) => {
    b.addEventListener("ended", () => resolve());
    setTimeout(() => reject(new Error("b no ended")), 2000);
  });
  await endedB;
  log("node ended " + b.ended + " " + b.paused);
  await ctx.close();
}
main().catch((e: any) => log("fail " + String(e && e.message ? e.message : e)));
`;

const EXPECTED = [
  "init true 0 true",
  "meta 4 true true",
  "play false false",
  "time true",
  "pause true true",
  "seek true false",
  "ended true true true",
  "canplay probably true",
  "events volumechange,durationchange,loadedmetadata,canplay,play,playing,pause,seeking,seeked,play,playing,ended",
  "node true true",
  "node twice true",
  "node time true",
  "node ended true true",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

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

const dir = mkdtempSync(join(tmpdir(), "native-media-audio-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
writeFileSync(join(dir, "tone.wav"), toneWav(0.3, 8000, 440));
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "wait 2500" };
delete env.NATIVE_SNAPSHOT;
const r = spawnSync(exe, [], { encoding: "utf8", env });
if (r.stderr !== "") console.log("     stderr " + JSON.stringify(r.stderr));
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
for (const line of got) console.log(`     got ${JSON.stringify(line)}`);
check(`log lines (${EXPECTED.length})`, got.length === EXPECTED.length, `got ${got.length}: ${JSON.stringify(got.slice(EXPECTED.length))}`);
for (let i = 0; i < Math.min(got.length, EXPECTED.length); i++) {
  check(EXPECTED[i], got[i] === EXPECTED[i], `got ${JSON.stringify(got[i])}`);
}

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
