// A <video> whose frames change resolution partway through: two clips of different sizes are
// concatenated into one stream, and the element plays it to the end with the last frame painted.
// Linux only: it needs the FFmpeg build in host/ffmpeg and the ffmpeg command for the clip.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { decodePng } from "./png.ts";
import { tmpdir } from "node:os";

const LINUX = process.platform === "linux";
if (!LINUX || !existsSync("host/ffmpeg/prefix/include/libavformat/avformat.h") ||
    spawnSync("ffmpeg", ["-version"], { encoding: "utf8" }).status !== 0) {
  console.log("ok   <video> resize decoding needs the Linux host, host/ffmpeg/build.sh and ffmpeg (skipped)");
  console.log("\nall passed");
  process.exit(0);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=160"><style>
body { margin: 0; background: white; }
video { display: block; width: 160px; height: 120px; }
</style></head><body>
<video id="v" src="resize.webm" preload="auto" autoplay muted></video>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const v = document.getElementById("v") as HTMLVideoElement;
async function main(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    v.addEventListener("loadedmetadata", () => resolve());
    v.addEventListener("error", () => reject(new Error("load failed: " + (v.error === null ? "no error" : v.error.message))));
  });
  log("meta " + v.videoWidth + "x" + v.videoHeight + " " + (v.duration > 0.5 && v.duration < 0.7) + " " + (v.currentSrc === "resize.webm"));
  const ended = new Promise<void>((resolve, reject) => {
    v.addEventListener("ended", () => resolve());
    setTimeout(() => reject(new Error("no ended")), 4000);
  });
  await ended;
  log("ended " + v.ended + " " + v.paused + " " + (v.currentTime > v.duration - 0.05));
  log("done");
}
main().catch((e: any) => log("fail " + String(e && e.message ? e.message : e)));
`;

const dir = mkdtempSync(join(tmpdir(), "native-media-video-resize-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const clip = join(dir, "resize.webm");
// Two solid clips of different sizes, concatenated without re-encoding: the frames in the second
// half are 80x60 in a stream whose header says 160x120.
for (const [name, color, size, seconds] of [["a", "red", "160x120", "0.3"], ["b", "blue", "80x60", "0.3"]]) {
  const made = spawnSync("ffmpeg", [
    "-y", "-f", "lavfi", "-i", `color=c=${color}:s=${size}:d=${seconds}:r=30`,
    "-c:v", "libvpx", "-b:v", "300k", join(dir, name + ".webm"),
  ], { encoding: "utf8" });
  if (made.status !== 0) throw new Error(`ffmpeg clip writer failed\n${made.stderr}`);
}
writeFileSync(join(dir, "list.txt"), `file 'a.webm'\nfile 'b.webm'\n`);
const joined = spawnSync("ffmpeg", ["-y", "-f", "concat", "-safe", "0", "-i", join(dir, "list.txt"), "-c", "copy", clip],
  { encoding: "utf8" });
if (joined.status !== 0) throw new Error(`ffmpeg concat failed\n${joined.stderr}`);

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const shot = join(dir, "shot.png");
const env: NodeJS.ProcessEnv = {
  ...process.env,
  NATIVE_STEPS: "wait 1200",
  NATIVE_SNAPSHOT: shot,
  NATIVE_FFMPEG_LIB: join(process.cwd(), "host", "ffmpeg", "prefix", "lib"),
};
const r = spawnSync(exe, [], { encoding: "utf8", env, timeout: 60000 });
if (r.status !== 0) throw new Error(`render failed\n${r.stderr}`);
const got = r.stdout.split("\n").slice(0, -1);
const want = ["meta 160x120 true true", "ended true true true", "done"];

let failed = 0;
const check = (name: string, ok: boolean, detail = ""): void => {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
};
check("log lines", got.length === want.length, `got ${JSON.stringify(got)}`);
for (let i = 0; i < Math.min(got.length, want.length); i++) check(want[i], got[i] === want[i], `got ${JSON.stringify(got[i])}`);

// The last frame (80x60 blue) is scaled into the element's 160x120 box.
const image = decodePng(shot);
const sx = image.w / 200, sy = image.h / 160;
const at = (cx: number, cy: number): number[] => {
  const o = (Math.floor(cy * sy) * image.w + Math.floor(cx * sx)) * 4;
  return [image.rgba[o], image.rgba[o + 1], image.rgba[o + 2]];
};
const blue = (c: number[]): boolean => c[2] > 180 && c[0] < 80 && c[1] < 80;
check("the resized frame is painted", blue(at(40, 30)) && blue(at(80, 60)) && blue(at(120, 90)),
  `got ${at(40, 30)} ${at(80, 60)} ${at(120, 90)}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
