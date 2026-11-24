// Web Audio: an OfflineAudioContext renders the graph against analytic expectations (a sine's
// samples, a gain ramp, a biquad's impulse response, a looping buffer, an analyser's peak bin, a
// WAV decode, panning and distance, a delay, a compressor, a convolver), events end sources, and a
// real-time AudioContext runs on the host's null sink.
// The page prints one "ok" line per check and a final "done".
//   npm test

import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const dir = mkdtempSync(join(tmpdir(), "native-audio-"));
mkdirSync(join(dir, "app"));
mkdirSync(join(dir, "bin"));
cpSync(join(FIXTURES, "tone.mp3"), join(dir, "app", "tone.mp3"));
cpSync(join(FIXTURES, "tone.ogg"), join(dir, "app", "tone.ogg"));

const PAGE = `<!doctype html>
<html><head><title>audio</title></head><body><h1>audio</h1>
<script type="module" src="app.ts"></script></body></html>`;

const SCRIPT = `
function ok(name: string, pass: boolean, detail: string): void {
  console.log((pass ? "ok " : "FAIL ") + name + " " + detail);
}
function near(a: number, b: number, eps: number): boolean {
  return Math.abs(a - b) <= eps;
}
function n(v: number): string {
  return String(Math.round(v * 10000) / 10000);
}

function wavBytes(): Uint8Array {
  const count = 4, rate = 8000;
  const bytes = new Uint8Array(44 + count * 2);
  const put16 = (o: number, v: number) => { bytes[o] = v & 255; bytes[o + 1] = (v >> 8) & 255; };
  const put32 = (o: number, v: number) => { put16(o, v & 65535); put16(o + 2, v >> 16); };
  const text = (o: number, s: string) => { for (let i = 0; i < s.length; i++) bytes[o + i] = s.charCodeAt(i); };
  text(0, "RIFF"); put32(4, 36 + count * 2); text(8, "WAVE");
  text(12, "fmt "); put32(16, 16); put16(20, 1); put16(22, 1); put32(24, rate);
  put32(28, rate * 2); put16(32, 2); put16(34, 16);
  text(36, "data"); put32(40, count * 2);
  const samples = [0, 8192, -8192, 16384];
  for (let i = 0; i < count; i++) put16(44 + i * 2, samples[i] < 0 ? samples[i] + 65536 : samples[i]);
  return bytes;
}

async function main(): Promise<void> {
  // A sine through a gain, against the same sine computed here.
  const context = new OfflineAudioContext(2, 4800, 48000);
  const osc = context.createOscillator();
  const gain = context.createGain();
  osc.frequency.value = 100;
  gain.gain.value = 0.5;
  osc.connect(gain);
  gain.connect(context.destination);
  osc.start(0);
  ok("gain value", gain.gain.value === 0.5, "value=" + n(gain.gain.value));
  const buffer = await context.startRendering();
  const data = buffer.getChannelData(0);
  let error = 0;
  for (let i = 0; i < data.length; i++) {
    const want = 0.5 * Math.sin(2 * Math.PI * 100 * i / 48000);
    const diff = Math.abs(data[i] - want);
    if (diff > error) error = diff;
  }
  ok("sine", error < 0.001, "maxError=" + n(error));
  ok("buffer shape", buffer.length === 4800 && buffer.sampleRate === 48000 && buffer.numberOfChannels === 2,
    buffer.length + "/" + buffer.sampleRate + "/" + buffer.numberOfChannels);
  ok("currentTime", near(context.currentTime, 0.1, 1e-9), "time=" + n(context.currentTime));
  ok("state", context.state === "closed", context.state);

  // A linear ramp on a constant source.
  const rampContext = new OfflineAudioContext(1, 4800, 48000);
  const constant = rampContext.createConstantSource();
  const rampGain = rampContext.createGain();
  constant.offset.value = 1;
  rampGain.gain.setValueAtTime(0, 0);
  rampGain.gain.linearRampToValueAtTime(1, 0.05);
  constant.connect(rampGain);
  rampGain.connect(rampContext.destination);
  constant.start(0);
  const ramp = (await rampContext.startRendering()).getChannelData(0);
  ok("ramp quarter", near(ramp[600], 0.25, 0.001), "v=" + n(ramp[600]));
  ok("ramp middle", near(ramp[1200], 0.5, 0.001), "v=" + n(ramp[1200]));
  ok("ramp end", near(ramp[3000], 1, 0.001), "v=" + n(ramp[3000]));

  // The panner sends a signal to the side its pan names.
  const panContext = new OfflineAudioContext(2, 256, 48000);
  const panSource = panContext.createConstantSource();
  const panner = panContext.createStereoPanner();
  panner.pan.value = -1;
  panSource.connect(panner);
  panner.connect(panContext.destination);
  panSource.start(0);
  const panned = await panContext.startRendering();
  ok("pan left", Math.abs(panned.getChannelData(1)[100]) < 1e-6 && panned.getChannelData(0)[100] > 0.1,
    "L=" + n(panned.getChannelData(0)[100]) + " R=" + n(panned.getChannelData(1)[100]));

  // A looping buffer at double speed steps through every other sample.
  const loopContext = new OfflineAudioContext(1, 16, 48000);
  const four = loopContext.createBuffer(1, 4, 48000);
  const fourData = four.getChannelData(0);
  fourData[0] = 0.1; fourData[1] = 0.2; fourData[2] = 0.3; fourData[3] = 0.4;
  const loopSource = loopContext.createBufferSource();
  loopSource.buffer = four;
  loopSource.loop = true;
  loopSource.playbackRate.value = 2;
  loopSource.connect(loopContext.destination);
  loopSource.start(0);
  const looped = (await loopContext.startRendering()).getChannelData(0);
  ok("loop rate", near(looped[0], 0.1, 1e-5) && near(looped[1], 0.3, 1e-5) &&
    near(looped[2], 0.1, 1e-5) && near(looped[3], 0.3, 1e-5),
    n(looped[0]) + "," + n(looped[1]) + "," + n(looped[2]) + "," + n(looped[3]));

  // A lowpass biquad's impulse response, against the coefficients of the same filter.
  const filterContext = new OfflineAudioContext(1, 128, 48000);
  const impulse = filterContext.createBuffer(1, 128, 48000);
  impulse.getChannelData(0)[0] = 1;
  const impulseSource = filterContext.createBufferSource();
  impulseSource.buffer = impulse;
  const filter = filterContext.createBiquadFilter();
  filter.type = "lowpass";
  filter.frequency.value = 1000;
  filter.Q.value = 0.707;
  impulseSource.connect(filter);
  filter.connect(filterContext.destination);
  impulseSource.start(0);
  const filtered = (await filterContext.startRendering()).getChannelData(0);
  const w0 = 2 * Math.PI * 1000 / 48000;
  const alpha = Math.sin(w0) / (2 * 0.707);
  const a0 = 1 + alpha, b0 = (1 - Math.cos(w0)) / 2, b1 = 1 - Math.cos(w0), b2 = b0;
  const a1 = -2 * Math.cos(w0), a2 = 1 - alpha;
  const nb0 = b0 / a0, nb1 = b1 / a0, na1 = a1 / a0;
  ok("biquad first", near(filtered[0], nb0, 1e-6), n(filtered[0]) + " want " + n(nb0));
  ok("biquad second", near(filtered[1], nb1 - na1 * nb0, 1e-6), n(filtered[1]));

  // The analyser reports the oscillator's frequency at the bin it belongs to.
  const analyserContext = new OfflineAudioContext(1, 4096, 48000);
  const analyserOsc = analyserContext.createOscillator();
  analyserOsc.frequency.value = 1000;
  const analyser = analyserContext.createAnalyser();
  analyser.fftSize = 2048;
  analyser.smoothingTimeConstant = 0;
  analyserOsc.connect(analyser);
  analyser.connect(analyserContext.destination);
  analyserOsc.start(0);
  await analyserContext.startRendering();
  const bins = new Float32Array(analyser.frequencyBinCount);
  analyser.getFloatFrequencyData(bins);
  let peakBin = 0;
  for (let i = 1; i < bins.length; i++) if (bins[i] > bins[peakBin]) peakBin = i;
  ok("analyser peak", Math.abs(peakBin - 43) <= 1, "bin=" + peakBin);
  const wave = new Float32Array(2048);
  analyser.getFloatTimeDomainData(wave);
  let nonzero = false;
  for (let i = 0; i < wave.length; i++) if (wave[i] !== 0) nonzero = true;
  ok("analyser time", nonzero, "nonzero=" + nonzero);

  // A WAV decode, and the samples it decoded played back.
  const decodeContext = new OfflineAudioContext(1, 8, 8000);
  const wav = wavBytes();
  const decoded = await decodeContext.decodeAudioData(wav.buffer as ArrayBuffer);
  ok("decode shape", decoded.length === 4 && decoded.sampleRate === 8000 && decoded.numberOfChannels === 1,
    decoded.length + "/" + decoded.sampleRate + "/" + decoded.numberOfChannels);
  const decodedData = decoded.getChannelData(0);
  ok("decode samples", near(decodedData[1], 0.25, 1e-6) && near(decodedData[2], -0.25, 1e-6),
    n(decodedData[1]) + "," + n(decodedData[2]));
  const decodedSource = decodeContext.createBufferSource();
  decodedSource.buffer = decoded;
  decodedSource.connect(decodeContext.destination);
  decodedSource.start(0);
  const played = (await decodeContext.startRendering()).getChannelData(0);
  ok("decode plays", near(played[1], 0.25, 1e-5), "v=" + n(played[1]));

  // The compressed decoders, through fetch so the app's bundled file reaches decodeAudioData.
  const fileContext = new OfflineAudioContext(1, 1, 44100);
  const mp3 = await fileContext.decodeAudioData(await (await fetch("tone.mp3")).arrayBuffer());
  const ogg = await fileContext.decodeAudioData(await (await fetch("tone.ogg")).arrayBuffer());
  ok("decode mp3", mp3.numberOfChannels === 1 && near(mp3.sampleRate, 44100, 1) && mp3.length > 4000,
    mp3.numberOfChannels + "/" + n(mp3.sampleRate) + "/" + mp3.length);
  const oggData = ogg.getChannelData(0);
  let oggPeak = 0, oggCross = 0;
  let previous = oggData[0];
  for (let i = 0; i < oggData.length; i++) {
    const v = oggData[i];
    if (Math.abs(v) > oggPeak) oggPeak = Math.abs(v);
    if ((previous < 0 && v >= 0) || (previous > 0 && v <= 0)) oggCross++;
    previous = v;
  }
  ok("decode ogg", ogg.numberOfChannels === 1 && near(ogg.sampleRate, 44100, 1) &&
    near(ogg.length, 4410, 2) && oggPeak > 0.05 && Math.abs(oggCross - 88) <= 2,
    ogg.length + "/" + n(oggPeak) + "/" + oggCross);

  // A stopped source reports that it ended.
  const endedContext = new OfflineAudioContext(1, 4096, 48000);
  const endedOsc = endedContext.createOscillator();
  let ended = 0;
  endedOsc.onended = () => { ended++; };
  endedOsc.connect(endedContext.destination);
  endedOsc.start(0);
  endedOsc.stop(0.05);
  await endedContext.startRendering();
  ok("onended", ended === 1, "ended=" + ended);

  // Both channels of a script-filled buffer reach the destination.
  const stereoContext = new OfflineAudioContext(2, 8, 48000);
  const stereoBuffer = stereoContext.createBuffer(2, 4, 48000);
  stereoBuffer.getChannelData(0)[0] = 0.5;
  stereoBuffer.getChannelData(1)[0] = -0.5;
  const stereoSource = stereoContext.createBufferSource();
  stereoSource.buffer = stereoBuffer;
  stereoSource.connect(stereoContext.destination);
  stereoSource.start(0);
  const stereo = await stereoContext.startRendering();
  ok("stereo buffer", near(stereo.getChannelData(0)[0], 0.5, 1e-6) && near(stereo.getChannelData(1)[0], -0.5, 1e-6),
    n(stereo.getChannelData(0)[0]) + "/" + n(stereo.getChannelData(1)[0]));

  // A panner places a mono source to the listener's right, at the reference distance.
  const pannerContext = new OfflineAudioContext(2, 256, 48000);
  const pannerSource = pannerContext.createConstantSource();
  const spatial = pannerContext.createPanner();
  pannerSource.offset.value = 1;
  spatial.positionX.value = 1;
  spatial.connect(pannerContext.destination);
  pannerSource.connect(spatial);
  pannerSource.start(0);
  const placed = await pannerContext.startRendering();
  ok("panner right", Math.abs(placed.getChannelData(0)[200]) < 1e-5 && placed.getChannelData(1)[200] > 0.9,
    "L=" + n(placed.getChannelData(0)[200]) + " R=" + n(placed.getChannelData(1)[200]));

  // The inverse distance model halves a source two reference distances away.
  const distanceContext = new OfflineAudioContext(2, 256, 48000);
  const farSource = distanceContext.createConstantSource();
  const farPanner = distanceContext.createPanner();
  farSource.offset.value = 1;
  farPanner.positionZ.value = -2;
  farSource.connect(farPanner);
  farPanner.connect(distanceContext.destination);
  farSource.start(0);
  const far = await distanceContext.startRendering();
  ok("panner distance", near(far.getChannelData(0)[200], 0.35355, 0.001) && near(far.getChannelData(1)[200], 0.35355, 0.001),
    n(far.getChannelData(0)[200]) + "/" + n(far.getChannelData(1)[200]));

  // Turning the listener makes a source on its left arrive on the left channel.
  const turnContext = new OfflineAudioContext(2, 256, 48000);
  const turnSource = turnContext.createConstantSource();
  const turnPanner = turnContext.createPanner();
  turnSource.offset.value = 1;
  turnPanner.positionZ.value = -1;
  turnContext.listener.forwardX.value = 1;
  turnContext.listener.forwardZ.value = 0;
  turnSource.connect(turnPanner);
  turnPanner.connect(turnContext.destination);
  turnSource.start(0);
  const turned = await turnContext.startRendering();
  ok("listener turn", turned.getChannelData(0)[200] > 0.9 && Math.abs(turned.getChannelData(1)[200]) < 1e-5,
    "L=" + n(turned.getChannelData(0)[200]) + " R=" + n(turned.getChannelData(1)[200]));

  // A delay of 48 frames puts the impulse at sample 48.
  const delayContext = new OfflineAudioContext(1, 128, 48000);
  const click = delayContext.createBuffer(1, 1, 48000);
  click.getChannelData(0)[0] = 1;
  const clickSource = delayContext.createBufferSource();
  clickSource.buffer = click;
  const delay = delayContext.createDelay(1);
  delay.delayTime.value = 48 / 48000;
  clickSource.connect(delay);
  delay.connect(delayContext.destination);
  clickSource.start(0);
  const delayed = (await delayContext.startRendering()).getChannelData(0);
  let before = 0;
  for (let i = 0; i < 48; i++) if (Math.abs(delayed[i]) > before) before = Math.abs(delayed[i]);
  ok("delay", before < 1e-6 && near(delayed[48], 1, 1e-5), "before=" + n(before) + " at48=" + n(delayed[48]));

  // The compressor pulls a full-scale constant down towards its threshold and ratio.
  const compressorContext = new OfflineAudioContext(1, 4800, 48000);
  const loud = compressorContext.createConstantSource();
  const compressor = compressorContext.createDynamicsCompressor();
  loud.offset.value = 1;
  compressor.threshold.value = -20;
  compressor.knee.value = 0;
  compressor.ratio.value = 20;
  compressor.attack.value = 0.001;
  loud.connect(compressor);
  compressor.connect(compressorContext.destination);
  loud.start(0);
  const compressed = (await compressorContext.startRendering()).getChannelData(0);
  ok("compressor", compressed[4799] > 0.08 && compressed[4799] < 0.15 && compressor.reduction < -15,
    "v=" + n(compressed[4799]) + " reduction=" + n(compressor.reduction));

  // A convolver with a two-tap impulse passes the impulse and its half-amplitude echo.
  const convolverContext = new OfflineAudioContext(1, 64, 48000);
  const impulseResponse = convolverContext.createBuffer(1, 2, 48000);
  impulseResponse.getChannelData(0)[0] = 1;
  impulseResponse.getChannelData(0)[1] = 0.5;
  const convolver = convolverContext.createConvolver();
  convolver.normalize = false;
  convolver.buffer = impulseResponse;
  const convolverSource = convolverContext.createBuffer(1, 1, 48000);
  convolverSource.getChannelData(0)[0] = 1;
  const convolverInput = convolverContext.createBufferSource();
  convolverInput.buffer = convolverSource;
  convolverInput.connect(convolver);
  convolver.connect(convolverContext.destination);
  convolverInput.start(0);
  const echoed = (await convolverContext.startRendering()).getChannelData(0);
  ok("convolver", near(echoed[0], 1, 1e-6) && near(echoed[1], 0.5, 1e-6) && Math.abs(echoed[2]) < 1e-6,
    n(echoed[0]) + "," + n(echoed[1]) + "," + n(echoed[2]));

  // The real-time context's clock runs, freezes on suspend, and stops for good on close.
  const live = new AudioContext();
  const liveOsc = live.createOscillator();
  liveOsc.connect(live.destination);
  liveOsc.start();
  ok("real-time running", live.state === "running", live.state);
  setTimeout(() => {
    const before = live.currentTime;
    ok("real-time clock", before > 0.02, "time=" + n(before));
    live.suspend().then(() => {
      const held = live.currentTime;
      setTimeout(() => {
        ok("suspend freezes", live.state === "suspended" && near(held, live.currentTime, 1e-9),
          n(held) + " -> " + n(live.currentTime));
        live.close().then(() => {
          ok("closed", live.state === "closed", live.state);
          console.log("done");
        });
      }, 60);
    });
  }, 120);
}

main().catch((error) => { console.log("FAIL threw " + String(error)); });
`;

writeFileSync(join(dir, "app", "index.html"), PAGE);
writeFileSync(join(dir, "app", "app.ts"), SCRIPT);

const exe = join(dir, "bin", "audio");
const build = spawnSync("node", ["compiler/cli.ts", "build", join(dir, "app"), "-o", exe], { encoding: "utf8" });
if (build.status !== 0) {
  console.error(build.stdout);
  console.error(build.stderr);
  process.exit(1);
}

const run = spawnSync(exe, [], {
  encoding: "utf8",
  env: { ...process.env, NATIVE_STEPS: "wait 500" },
});
if (run.status !== 0) {
  console.error(run.stdout);
  console.error(run.stderr);
  console.error(`audio app exited ${run.status}`);
  process.exit(1);
}
const lines = run.stdout.split("\n").map((line) => line.trim()).filter((line) => line !== "");
let failed = 0;
for (const line of lines) {
  if (line === "done") continue;
  if (!line.startsWith("ok ")) failed++;
  console.log(line);
}
if (!lines.includes("done")) {
  console.error("audio app did not reach done");
  failed++;
}
if (failed > 0) {
  console.error(`audio: ${failed} checks failed`);
  process.exit(1);
}
console.log("audio: all checks passed");
