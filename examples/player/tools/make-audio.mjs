// Renders the album audio in ../audio as short mono Ogg Vorbis files,
// synthesized here so every note is ours. Every album gets its own key, tempo
// and chords; each of its three tracks is a variation on them. Encoding uses
// ffmpeg.
//   node tools/make-audio.mjs

import { mkdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "audio");
mkdirSync(out, { recursive: true });

const RATE = 22050;
const TAU = Math.PI * 2;

const ALBUMS = [
  { id: "still-harbor", root: 50, scale: [0, 2, 3, 7, 9], bpm: 74, progression: [0, 3, 2, 1], mood: "pad" },
  { id: "neon-orchard", root: 57, scale: [0, 2, 3, 5, 7, 10], bpm: 112, progression: [0, 4, 1, 5], mood: "arp" },
  { id: "paper-planes", root: 55, scale: [0, 2, 4, 7, 9], bpm: 104, progression: [0, 1, 4, 3], mood: "pluck" },
  { id: "low-tide", root: 48, scale: [0, 3, 5, 7, 10], bpm: 88, progression: [0, 2, 1, 3], mood: "jazz" },
  { id: "glasshouse", root: 53, scale: [0, 2, 3, 7, 8], bpm: 96, progression: [0, 3, 1, 2], mood: "pad" },
  { id: "superbloom", root: 52, scale: [0, 2, 4, 5, 7, 9], bpm: 118, progression: [0, 4, 5, 3], mood: "arp" },
  { id: "night-bus", root: 45, scale: [0, 2, 3, 5, 7, 10], bpm: 84, progression: [0, 3, 4, 2], mood: "pluck" },
  { id: "static-bloom", root: 50, scale: [0, 1, 5, 7, 10], bpm: 122, progression: [0, 2, 3, 1], mood: "arp" },
  { id: "copper-sky", root: 47, scale: [0, 2, 4, 7, 9], bpm: 92, progression: [0, 3, 2, 1], mood: "jazz" },
  { id: "satellite-hearts", root: 54, scale: [0, 2, 4, 7, 11], bpm: 100, progression: [0, 4, 2, 5], mood: "pad" },
  { id: "evergreen", root: 43, scale: [0, 2, 3, 7, 9], bpm: 80, progression: [0, 1, 3, 2], mood: "pluck" },
  { id: "midnight-garden", root: 49, scale: [0, 3, 5, 6, 10], bpm: 78, progression: [0, 2, 1, 3], mood: "jazz" },
];

function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const midiToHz = (n) => 440 * Math.pow(2, (n - 69) / 12);

/** Adds a note to the mix: `voice` shapes the waveform, `env` the envelope. */
function addNote(mix, start, seconds, hz, gain, voice, env) {
  const begin = Math.floor(start * RATE);
  const length = Math.floor(seconds * RATE);
  for (let i = 0; i < length && begin + i < mix.length; i++) {
    const t = i / RATE;
    const e = env(t, seconds);
    if (e <= 0) continue;
    let s;
    if (voice === "sine") s = Math.sin(TAU * hz * t);
    else if (voice === "soft") s = Math.sin(TAU * hz * t) * 0.8 + Math.sin(TAU * hz * 2 * t) * 0.14 + Math.sin(TAU * hz * 3 * t) * 0.04;
    else if (voice === "pluck") s = Math.sin(TAU * hz * t) + 0.35 * Math.sin(TAU * hz * 2 * t + 0.2) + 0.12 * Math.sin(TAU * hz * 3 * t);
    else s = Math.sin(TAU * hz * t) + 0.5 * Math.sin(TAU * hz * 2.01 * t) + 0.22 * Math.sin(TAU * hz * 3.02 * t);
    mix[begin + i] += s * e * gain;
  }
}

const attackRelease = (attack, release) => (t, total) => {
  const a = attack <= 0 ? 1 : Math.min(1, t / attack);
  const r = Math.min(1, Math.max(0, (total - t) / release));
  return a * r;
};
const decay = (length) => (t) => Math.exp(-t / length) * (t < 0.004 ? t / 0.004 : 1);
const pluckEnv = (t) => Math.exp(-t * 5.5) * (t < 0.006 ? t / 0.006 : 1);

function render(album, index, track, target) {
  const bpm = album.bpm + (track - 1) * 5;
  const beat = 60 / bpm;
  const bar = beat * 4;
  const length = Math.ceil(target * RATE);
  const mix = new Float32Array(length);
  const rnd = prng(900 + index * 311 + track * 41);
  const scale = album.scale;
  const root = album.root + (track === 2 ? 2 : track === 3 ? -3 : 0);
  const progression = album.progression.map((d, i) => album.progression[(i + track - 1) % album.progression.length]);

  const degree = (d) => {
    const octave = Math.floor(d / scale.length);
    return root + octave * 12 + scale[((d % scale.length) + scale.length) % scale.length];
  };

  const bars = Math.ceil((target - 0.8) / bar);
  for (let b = 0; b < bars; b++) {
    const start = b * bar;
    const chordRoot = progression[b % progression.length];
    const chord = [degree(chordRoot), degree(chordRoot + 2), degree(chordRoot + 4)];

    // A held pad under every bar.
    for (const note of chord) {
      addNote(mix, start, bar + 0.35, midiToHz(note), 0.11, "soft", attackRelease(0.9, 0.9));
      addNote(mix, start, bar + 0.35, midiToHz(note + 12), 0.03, "sine", attackRelease(1.1, 0.9));
    }

    // Bass: the root on the first and third beat.
    for (let beatIndex = 0; beatIndex < 4; beatIndex += 2) {
      addNote(mix, start + beatIndex * beat, beat * 1.5, midiToHz(chord[0] - 12), 0.34, "sine", decay(0.42));
    }

    // The melody voice.
    if (album.mood === "arp" || album.mood === "pluck") {
      const steps = album.mood === "arp" ? 8 : 6;
      for (let s = 0; s < steps; s++) {
        if (rnd() < 0.18) continue;
        const pick = s % 2 === 0 ? chord[(s / 2) % 3] : chord[0] + 12;
        const note = pick + (rnd() < 0.24 ? 12 : 0);
        const at = start + (s * bar) / steps;
        addNote(mix, at, 0.9, midiToHz(note), 0.1, album.mood === "arp" ? "pluck" : "bell", pluckEnv);
        addNote(mix, at + 0.27, 0.7, midiToHz(note), 0.035, "sine", pluckEnv);
      }
    } else if (album.mood === "jazz") {
      // A wandering line over the chord, in quarters and eighths.
      let cursor = 0;
      for (let s = 0; s < 4; s++) {
        cursor += rnd() < 0.4 ? 1 : 0;
        const note = chord[(s + cursor) % 3] + (rnd() < 0.3 ? 12 : 0);
        addNote(mix, start + s * beat + (rnd() < 0.25 ? beat / 2 : 0), 0.8, midiToHz(note), 0.09, "bell", pluckEnv);
      }
    } else {
      // A slow pad piece: one long note per bar, the fifth above.
      addNote(mix, start, bar, midiToHz(chord[2] + 12), 0.05, "bell", attackRelease(0.7, 1.2));
    }

    // Percussion: a soft kick on one and three, a shaker on the offbeats.
    for (let beatIndex = 0; beatIndex < 4; beatIndex += 2) {
      const begin = Math.floor((start + beatIndex * beat) * RATE);
      for (let i = 0; i < RATE * 0.22 && begin + i < mix.length; i++) {
        const t = i / RATE;
        const hz = 110 * Math.exp(-t * 22) + 42;
        mix[begin + i] += Math.sin(TAU * hz * t) * Math.exp(-t * 16) * 0.32;
      }
    }
    for (let beatIndex = 0; beatIndex < 4; beatIndex++) {
      const at = start + (beatIndex + 0.5) * beat;
      const begin = Math.floor(at * RATE);
      let previous = 0;
      for (let i = 0; i < RATE * 0.06 && begin + i < mix.length; i++) {
        const t = i / RATE;
        const n = rnd() * 2 - 1;
        const high = n - previous;
        previous = n;
        mix[begin + i] += high * Math.exp(-t * 52) * 0.05;
      }
    }
  }

  // One delayed copy, so the melody has a little room around it.
  const delay = Math.floor(0.27 * RATE);
  for (let i = mix.length - 1; i >= delay; i--) mix[i] += mix[i - delay] * 0.16;

  // Fade the last second out, then normalize.
  const fade = Math.floor(0.9 * RATE);
  for (let i = 0; i < fade; i++) mix[mix.length - fade + i] *= 1 - i / fade;
  let peak = 0;
  for (let i = 0; i < mix.length; i++) peak = Math.max(peak, Math.abs(mix[i]));
  const scaleTo = peak > 0 ? 0.82 / peak : 0;
  const pcm = Buffer.alloc(mix.length * 2);
  for (let i = 0; i < mix.length; i++) {
    let s = mix[i] * scaleTo;
    s = Math.tanh(s * 1.25) / Math.tanh(1.25);
    const v = Math.max(-1, Math.min(1, s));
    pcm.writeInt16LE(Math.round(v * 32767), i * 2);
  }

  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(RATE, 24);
  header.writeUInt32LE(RATE * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

const durations = {};
for (const [i, album] of ALBUMS.entries()) {
  for (let track = 1; track <= 3; track++) {
    const target = 12 + ((i * 3 + track) % 7);
    const wav = render(album, i, track, target);
    const name = `${album.id}-${track}`;
    const wavPath = join(out, `${name}.wav`);
    const oggPath = join(out, `${name}.ogg`);
    writeFileSync(wavPath, wav);
    const enc = spawnSync("ffmpeg", ["-y", "-loglevel", "error", "-i", wavPath, "-c:a", "libvorbis", "-q:a", "2", oggPath], { encoding: "utf8" });
    rmSync(wavPath, { force: true });
    if (enc.status !== 0) {
      console.error(`could not encode audio/${name}.ogg: install ffmpeg`);
      continue;
    }
    durations[name] = target;
    console.log(`audio/${name}.ogg ${target}s ${(statSync(oggPath).size / 1024).toFixed(0)}KB`);
  }
}
writeFileSync(join(out, "durations.json"), JSON.stringify(durations, null, 2) + "\n");
