// <video> playback: a generated clip decodes, the element reports its picture size and duration,
// play/pause and a seek move the playhead, and the clip ends. On macOS the host is AVFoundation
// and the clip is written by AVAssetWriter (a Swift program); on Linux the host is the FFmpeg
// build in host/ffmpeg and the clip is made by the ffmpeg command. Hosts without either skip.
//   npm test

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { decodePng } from "./png.ts";
import { tmpdir } from "node:os";

const MACOS = process.platform === "darwin";
const LINUX = process.platform === "linux";
const CLIP_FORMAT = MACOS ? "mp4" : "webm";
if (!MACOS && !LINUX) {
  console.log("ok   <video> playback needs the macOS or Linux host (skipped)");
  console.log("\nall passed");
  process.exit(0);
}
if (LINUX && (!existsSync("host/ffmpeg/prefix/include/libavformat/avformat.h") ||
    spawnSync("ffmpeg", ["-version"], { encoding: "utf8" }).status !== 0)) {
  console.log("ok   <video> playback needs host/ffmpeg/build.sh and the ffmpeg command (skipped)");
  console.log("\nall passed");
  process.exit(0);
}

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=200, height=160"><style>
body { margin: 0; background: white; }
video { display: block; width: 160px; height: 120px; }
</style></head><body>
<video id="v" src="clip.${CLIP_FORMAT}" preload="auto" autoplay muted></video>
<script src="app.ts"></script>
</body></html>`;

const SCRIPT = `
const log = (s: string): void => { console.log(s); };
const v = document.getElementById("v") as HTMLVideoElement;
function wait(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
async function main(): Promise<void> {
  log("init " + v.paused + " " + v.readyState + " " + (v.currentSrc === ""));
  await new Promise<void>((resolve, reject) => {
    v.addEventListener("loadedmetadata", () => resolve());
    v.addEventListener("error", () => reject(new Error("load failed: " + (v.error === null ? "no error" : v.error.message))));
  });
  log("meta " + v.videoWidth + "x" + v.videoHeight + " " + (v.duration > 0.3 && v.duration < 0.5) + " " + v.readyState);
  v.muted = true;
  await v.play();
  log("play " + v.paused + " " + v.ended);
  await wait(150);
  log("time " + (v.currentTime > 0.05));
  v.pause();
  log("pause " + v.paused + " " + (v.currentTime > 0.02));
  v.currentTime = 0.05;
  log("seek " + (v.currentTime > 0.04 && v.currentTime < 0.08));
  const ended = new Promise<void>((resolve, reject) => {
    v.addEventListener("ended", () => resolve());
    setTimeout(() => reject(new Error("no ended")), 4000);
  });
  await v.play();
  await ended;
  log("ended " + v.ended + " " + v.paused + " " + (v.currentTime > v.duration - 0.05));
  log("canplay " + JSON.stringify(v.canPlayType('video/webm; codecs="vp8"')) + " " +
    JSON.stringify(v.canPlayType('video/mp4; codecs="avc1.42E01E"')));
  log("done");
}
main().catch((e: any) => log("fail " + String(e && e.message ? e.message : e)));
`;

const SWIFT = `
import AVFoundation
import CoreVideo

let url = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: url)
let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
let settings: [String: Any] = [
  AVVideoCodecKey: AVVideoCodecType.h264,
  AVVideoWidthKey: 160,
  AVVideoHeightKey: 120,
]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: 160,
  kCVPixelBufferHeightKey as String: 120,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
func frame() -> CVPixelBuffer {
  var pb: CVPixelBuffer?
  CVPixelBufferCreate(nil, 160, 120, kCVPixelFormatType_32BGRA, nil, &pb)
  let buffer = pb!
  CVPixelBufferLockBaseAddress(buffer, [])
  let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
  let stride = CVPixelBufferGetBytesPerRow(buffer)
  for y in 0..<120 {
    for x in 0..<160 {
      let o = y * stride + x * 4
      base[o] = 30
      base[o + 1] = 30
      base[o + 2] = 220
      base[o + 3] = 255
    }
  }
  CVPixelBufferUnlockBaseAddress(buffer, [])
  return buffer
}
for i in 0..<12 {
  while !input.isReadyForMoreMediaData { usleep(1000) }
  _ = adaptor.append(frame(), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status != .completed { exit(1) }
`;

const EXPECTED = [
  "init true 0 true",
  "meta 160x120 true 4",
  "play false false",
  "time true",
  "pause true true",
  "seek true",
  "ended true true true",
  MACOS ? "canplay \"\" \"probably\"" : "canplay \"probably\" \"\"",
  "done",
];

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const dir = mkdtempSync(join(tmpdir(), "native-media-video-"));
writeFileSync(join(dir, "index.html"), PAGE);
writeFileSync(join(dir, "app.ts"), SCRIPT);
const clip = join(dir, "clip." + CLIP_FORMAT);
if (MACOS) {
  writeFileSync(join(dir, "makeclip.swift"), SWIFT);
  const swift = spawnSync("xcrun", ["swiftc", "-O", join(dir, "makeclip.swift"), "-o", join(dir, "makeclip")], { encoding: "utf8", cwd: dir });
  if (swift.status !== 0) throw new Error(`swiftc failed\n${swift.stderr}`);
  const made = spawnSync(join(dir, "makeclip"), [clip], { encoding: "utf8" });
  if (made.status !== 0) throw new Error(`clip writer failed\n${made.stderr}`);
} else {
  const made = spawnSync("ffmpeg", [
    "-y", "-f", "lavfi", "-i", "color=c=red:s=160x120:d=0.4:r=30",
    "-c:v", "libvpx", "-b:v", "300k", clip,
  ], { encoding: "utf8" });
  if (made.status !== 0) throw new Error(`ffmpeg clip writer failed\n${made.stderr}`);
}

const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);

const ffmpegLib = LINUX ? join(process.cwd(), "host", "ffmpeg", "prefix", "lib") : "";
const env: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "wait 2000" };
if (LINUX) env.NATIVE_FFMPEG_LIB = ffmpegLib;
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

// A second run paints the frame: the snapshot is taken while the clip plays, and the video's box
// in it is the clip's solid red.
const shot = join(dir, "shot.png");
const snapEnv: NodeJS.ProcessEnv = { ...process.env, NATIVE_STEPS: "wait 300", NATIVE_SNAPSHOT: shot };
if (LINUX) snapEnv.NATIVE_FFMPEG_LIB = ffmpegLib;
const snap = spawnSync(exe, [], { encoding: "utf8", env: snapEnv });
if (snap.status !== 0) throw new Error(`snapshot run failed\n${snap.stderr}`);
const image = decodePng(shot);
const sx = image.w / 200;
const sy = image.h / 160;
let red = 0;
for (let y = 0; y < Math.floor(120 * sy); y++) {
  for (let x = 0; x < Math.floor(160 * sx); x++) {
    const at = (y * image.w + x) * 4;
    if (image.rgba[at] > 180 && image.rgba[at + 1] < 80 && image.rgba[at + 2] < 80) red++;
  }
}
check("the frame is painted in the video's box", red > 1000, `${red} red pixels of ${image.w}x${image.h}`);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
