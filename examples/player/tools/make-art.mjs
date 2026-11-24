// Draws the album covers in ../art as JPEG files, from SVG sources in ../art/src.
// The artwork is abstract and generated from each album's palette, so the app
// carries no third-party art. Rasterizing uses `rsvg-convert` from librsvg and
// ImageMagick's `convert` for the JPEG encoding.
//   node tools/make-art.mjs

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "art");
const src = join(out, "src");
mkdirSync(src, { recursive: true });

const ALBUMS = [
  { id: "still-harbor", pattern: "horizon", colors: ["#08131f", "#123b52", "#e0945a", "#f6e0ba"] },
  { id: "neon-orchard", pattern: "orchard", colors: ["#120d2b", "#4b238d", "#ff4f9a", "#48dfc0"] },
  { id: "paper-planes", pattern: "planes", colors: ["#e8f0f7", "#a9c8de", "#fbf6ec", "#d9694f"] },
  { id: "low-tide", pattern: "tide", colors: ["#052427", "#0d5656", "#8ccfc2", "#d9b06a"] },
  { id: "glasshouse", pattern: "glass", colors: ["#0d1115", "#26323c", "#c9dae7", "#82b3d8"] },
  { id: "superbloom", pattern: "petals", colors: ["#260b19", "#8f2549", "#ff7a52", "#ffd166"] },
  { id: "night-bus", pattern: "bus", colors: ["#060915", "#182050", "#6a7bff", "#ffb35c"] },
  { id: "static-bloom", pattern: "static", colors: ["#0a0a0e", "#232434", "#c6ff4a", "#ff5db1"] },
  { id: "copper-sky", pattern: "copper", colors: ["#241006", "#7f3314", "#d4762c", "#f5cf95"] },
  { id: "satellite-hearts", pattern: "orbit", colors: ["#080d28", "#232a63", "#9aa8ff", "#ff8fa3"] },
  { id: "evergreen", pattern: "evergreen", colors: ["#09170f", "#153b27", "#6dac7b", "#e7daa9"] },
  { id: "midnight-garden", pattern: "garden", colors: ["#0d0818", "#271745", "#8f6bff", "#7ee0c3"] },
];

/** A small deterministic random generator so a cover is the same on every run. */
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

const W = 640;
const H = 640;

function defs(id, colors) {
  const [dark, mid, warm, pale] = colors;
  return `<defs>
    <linearGradient id="bg-${id}" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="${dark}"/>
      <stop offset="1" stop-color="${mid}"/>
    </linearGradient>
    <radialGradient id="glow-${id}" cx="50%" cy="38%" r="62%">
      <stop offset="0" stop-color="${warm}" stop-opacity="0.72"/>
      <stop offset="1" stop-color="${warm}" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="vignette-${id}" cx="50%" cy="50%" r="72%">
      <stop offset="0.55" stop-color="#000000" stop-opacity="0"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.36"/>
    </radialGradient>
    <linearGradient id="pale-${id}" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="${pale}" stop-opacity="0.95"/>
      <stop offset="1" stop-color="${pale}" stop-opacity="0.35"/>
    </linearGradient>
  </defs>`;
}

function frame(id, colors, inner) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  ${defs(id, colors)}
  <rect width="${W}" height="${H}" fill="url(#bg-${id})"/>
  ${inner}
  <rect width="${W}" height="${H}" fill="url(#vignette-${id})"/>
</svg>
`;
}

function horizon(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let lines = "";
  for (let i = 0; i < 7; i++) {
    const y = 400 + i * 26;
    lines += `<rect x="${30 - i * 3}" y="${y}" width="${580 + i * 6}" height="2" fill="${pale}" opacity="${0.5 - i * 0.055}"/>`;
  }
  let reflection = "";
  for (let i = 0; i < 9; i++) {
    const w = 150 - i * 13;
    reflection += `<rect x="${320 - w / 2}" y="${436 + i * 15}" width="${w}" height="3" rx="1.5" fill="${warm}" opacity="${0.55 - i * 0.05}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="460" fill="url(#glow-${id})"/>
    <circle cx="320" cy="300" r="118" fill="${warm}" opacity="0.92"/>
    <circle cx="320" cy="300" r="148" fill="none" stroke="${pale}" stroke-width="1.5" opacity="0.5"/>
    ${lines}
    ${reflection}
    <path d="M0 470 C 120 440 210 452 320 470 C 430 488 520 448 640 466 L640 640 L0 640 Z" fill="${dark}" opacity="0.55"/>
  `);
}

function orchard(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let trees = "";
  const spots = [
    [120, 500, 92, -8], [300, 545, 120, 4], [500, 495, 86, 10],
  ];
  for (let i = 0; i < spots.length; i++) {
    const [x, y, h, lean] = spots[i];
    trees += `<path d="M${x} ${y} C ${x + lean} ${y - h * 0.4} ${x + lean * 2} ${y - h * 0.72} ${x + lean * 2.6} ${y - h}" stroke="${pale}" stroke-width="5" fill="none" opacity="0.75"/>`;
    for (let b = 0; b < 4; b++) {
      const t = 0.3 + b * 0.16;
      trees += `<path d="M${x + lean * 2.6 * t} ${y - h * t} l ${34 + b * 6} ${-26 - b * 4}" stroke="${pale}" stroke-width="3" fill="none" opacity="0.6"/>`;
      trees += `<path d="M${x + lean * 2.6 * t} ${y - h * t} l ${-30 - b * 5} ${-30 - b * 3}" stroke="${pale}" stroke-width="3" fill="none" opacity="0.6"/>`;
    }
  }
  let fruit = "";
  const colors = [warm, pale];
  for (let i = 0; i < 26; i++) {
    const x = 60 + rnd() * 520;
    const y = 150 + rnd() * 360;
    const r = 4 + rnd() * 7;
    fruit += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${r.toFixed(1)}" fill="${colors[i % 2]}" opacity="${(0.45 + rnd() * 0.45).toFixed(2)}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})"/>
    <circle cx="500" cy="180" r="96" fill="none" stroke="${warm}" stroke-width="2" opacity="0.65"/>
    <circle cx="500" cy="180" r="70" fill="none" stroke="${pale}" stroke-width="1.5" opacity="0.5"/>
    ${trees}
    ${fruit}
    <circle cx="500" cy="180" r="13" fill="${warm}"/>
  `);
}

function planes(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let planes = "";
  const pos = [[140, 420, 1.15, -8], [350, 300, 0.8, 15], [470, 480, 1.35, 4], [250, 520, 0.6, -20], [530, 220, 0.55, 24]];
  for (let i = 0; i < pos.length; i++) {
    const [x, y, s, rot] = pos[i];
    planes += `<g transform="translate(${x} ${y}) rotate(${rot}) scale(${s})">
      <path d="M0 0 L 120 -38 L 96 6 L 110 34 L 62 20 Z" fill="${i % 2 === 0 ? pale : "#ffffff"}" opacity="${i % 2 === 0 ? 0.92 : 0.78}"/>
      <path d="M0 0 L 120 -38 L 104 2 Z" fill="${warm}" opacity="0.35"/>
    </g>`;
  }
  let routes = "";
  for (let i = 0; i < 3; i++) {
    routes += `<path d="M${-40 + i * 60} ${620 - i * 40} C 200 ${480 - i * 30} 420 ${380 - i * 20} 700 ${250 - i * 30}" stroke="${pale}" stroke-width="1.5" fill="none" stroke-dasharray="7 11" opacity="0.5"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})" opacity="0.7"/>
    <circle cx="170" cy="170" r="86" fill="${warm}" opacity="0.22"/>
    ${routes}
    ${planes}
  `);
}

function tide(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let bands = "";
  for (let i = 0; i < 8; i++) {
    const y = 150 + i * 56;
    let d = `M0 ${y}`;
    for (let x = 0; x <= 640; x += 32) {
      d += ` L ${x} ${(y + Math.sin(x / 90 + i * 0.8) * (18 + i * 3)).toFixed(1)}`;
    }
    d += " L640 640 L0 640 Z";
    bands += `<path d="${d}" fill="${i % 3 === 0 ? warm : pale}" opacity="${(0.06 + i * 0.035).toFixed(2)}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})"/>
    <circle cx="320" cy="196" r="76" fill="${pale}" opacity="0.18"/>
    <circle cx="320" cy="196" r="52" fill="none" stroke="${pale}" stroke-width="1.5" opacity="0.55"/>
    ${bands}
    <path d="M0 470 C 140 430 230 500 360 470 C 470 444 560 480 640 452" stroke="${warm}" stroke-width="3" fill="none" opacity="0.8"/>
  `);
}

function glass(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let panes = "";
  for (let gy = 0; gy < 4; gy++) {
    for (let gx = 0; gx < 4; gx++) {
      const x = 84 + gx * 124;
      const y = 110 + gy * 124;
      const shade = (gx + gy) % 3;
      panes += `<path d="M${x} ${y} l 100 0 l 0 100 l -100 0 Z" fill="${shade === 0 ? warm : pale}" opacity="${(0.05 + shade * 0.045 + (gx === 2 && gy === 1 ? 0.14 : 0)).toFixed(2)}"/>`;
      panes += `<path d="M${x} ${y} l 100 0 l 0 100 l -100 0 Z" fill="none" stroke="${pale}" stroke-width="1.4" opacity="0.35"/>`;
    }
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})" opacity="0.8"/>
    <g transform="rotate(-18 320 320)">
      <rect x="60" y="60" width="520" height="520" fill="none" stroke="${pale}" stroke-width="2" opacity="0.5"/>
      ${panes}
    </g>
    <path d="M120 640 L 420 120 L 500 120 L 220 640 Z" fill="${pale}" opacity="0.1"/>
    <path d="M300 640 L 520 220 L 548 220 L 340 640 Z" fill="${warm}" opacity="0.14"/>
  `);
}

function petals(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let petals = "";
  for (let ring = 0; ring < 3; ring++) {
    const count = 8 + ring * 4;
    const rad = 70 + ring * 62;
    for (let i = 0; i < count; i++) {
      const a = (i / count) * Math.PI * 2 + ring * 0.3;
      const x = 320 + Math.cos(a) * rad;
      const y = 320 + Math.sin(a) * rad;
      petals += `<ellipse cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" rx="${(54 - ring * 9).toFixed(1)}" ry="${(20 - ring * 3).toFixed(1)}" transform="rotate(${((a * 180) / Math.PI).toFixed(1)} ${x.toFixed(1)} ${y.toFixed(1)})" fill="${ring === 1 ? warm : pale}" opacity="${(0.32 - ring * 0.06).toFixed(2)}"/>`;
    }
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})"/>
    ${petals}
    <circle cx="320" cy="320" r="58" fill="${warm}" opacity="0.92"/>
    <circle cx="320" cy="320" r="76" fill="none" stroke="${pale}" stroke-width="1.5" opacity="0.6"/>
    <circle cx="320" cy="320" r="16" fill="${dark}"/>
  `);
}

function bus(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let streaks = "";
  for (let i = 0; i < 9; i++) {
    const x = 40 + i * 70 + rnd() * 10;
    const h = 100 + rnd() * 240;
    streaks += `<rect x="${x.toFixed(1)}" y="${(640 - h).toFixed(1)}" width="${(8 + rnd() * 12).toFixed(1)}" height="${h.toFixed(1)}" fill="${i % 4 === 0 ? warm : pale}" opacity="${(0.08 + rnd() * 0.13).toFixed(2)}" rx="6"/>`;
  }
  let lights = "";
  for (let i = 0; i < 12; i++) {
    lights += `<circle cx="${(40 + rnd() * 560).toFixed(1)}" cy="${(80 + rnd() * 220).toFixed(1)}" r="${(2 + rnd() * 4).toFixed(1)}" fill="${warm}" opacity="${(0.3 + rnd() * 0.6).toFixed(2)}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#bg-${id})"/>
    <rect y="360" width="640" height="280" fill="url(#glow-${id})" opacity="0.5"/>
    ${streaks}
    ${lights}
    <path d="M-20 420 L 660 330" stroke="${warm}" stroke-width="2" opacity="0.5"/>
    <path d="M-20 470 L 660 392" stroke="${pale}" stroke-width="1.4" opacity="0.35"/>
    <rect x="88" y="120" width="464" height="130" rx="18" fill="${dark}" opacity="0.72"/>
    <rect x="104" y="136" width="432" height="98" rx="10" fill="none" stroke="${pale}" stroke-width="1.5" opacity="0.25"/>
  `);
}

function staticArt(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let blocks = "";
  for (let i = 0; i < 90; i++) {
    const s = 4 + rnd() * 14;
    blocks += `<rect x="${(24 + rnd() * 592).toFixed(1)}" y="${(24 + rnd() * 592).toFixed(1)}" width="${s.toFixed(1)}" height="${s.toFixed(1)}" fill="${i % 5 === 0 ? warm : pale}" opacity="${(0.05 + rnd() * 0.16).toFixed(2)}"/>`;
  }
  let ring = "";
  for (let i = 0; i < 6; i++) {
    const a = (i / 6) * Math.PI * 2;
    const x = 320 + Math.cos(a) * 86;
    const y = 320 + Math.sin(a) * 86;
    ring += `<ellipse cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" rx="46" ry="18" transform="rotate(${((a * 180) / Math.PI).toFixed(1)} ${x.toFixed(1)} ${y.toFixed(1)})" fill="${warm}" opacity="0.8"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#bg-${id})"/>
    ${blocks}
    <circle cx="320" cy="320" r="132" fill="none" stroke="${pale}" stroke-width="1.2" opacity="0.3"/>
    ${ring}
    <circle cx="320" cy="320" r="42" fill="${pale}"/>
    <circle cx="320" cy="320" r="18" fill="${dark}"/>
  `);
}

function copper(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let ridges = "";
  const layers = [[0.42, "#4a180a"], [0.56, "#66230d"], [0.7, "#873516"], [0.84, "#a94a1d"]];
  for (let i = 0; i < layers.length; i++) {
    const base = layers[i][0] * 640;
    let d = `M0 ${base}`;
    for (let x = 0; x <= 640; x += 40) {
      d += ` L ${x} ${(base - Math.sin(x / 110 + i * 1.7) * (46 - i * 8) - rnd() * 10).toFixed(1)}`;
    }
    d += " L640 640 L0 640 Z";
    ridges += `<path d="${d}" fill="${layers[i][1]}" opacity="${0.9}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})"/>
    <circle cx="320" cy="330" r="150" fill="${warm}" opacity="0.55"/>
    <circle cx="320" cy="330" r="186" fill="none" stroke="${pale}" stroke-width="1.5" opacity="0.4"/>
    ${ridges}
    <path d="M0 560 C 160 520 300 570 480 540 C 560 528 610 534 640 542" stroke="${pale}" stroke-width="2" fill="none" opacity="0.45"/>
  `);
}

function orbit(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let rings = "";
  for (let i = 0; i < 5; i++) {
    rings += `<ellipse cx="320" cy="330" rx="${120 + i * 46}" ry="${36 + i * 18}" transform="rotate(${-18 + i * 7} 320 330)" fill="none" stroke="${i % 2 === 0 ? pale : warm}" stroke-width="1.4" opacity="${0.42 - i * 0.05}"/>`;
  }
  let moons = "";
  for (let i = 0; i < 7; i++) {
    const a = rnd() * Math.PI * 2;
    const rad = 120 + rnd() * 180;
    const x = 320 + Math.cos(a) * rad;
    const y = 330 + Math.sin(a) * rad * 0.36;
    moons += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(3 + rnd() * 7).toFixed(1)}" fill="${i % 3 === 0 ? warm : pale}" opacity="0.85"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#glow-${id})"/>
    ${rings}
    <circle cx="320" cy="330" r="92" fill="${warm}" opacity="0.9"/>
    <path d="M228 330 A 92 92 0 0 1 412 330 A 92 46 0 0 0 228 330 Z" fill="${dark}" opacity="0.35"/>
    <circle cx="320" cy="330" r="116" fill="none" stroke="${pale}" stroke-width="1.2" opacity="0.5"/>
    ${moons}
  `);
}

function evergreen(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let trees = "";
  const treesPos = [[110, 470, 150], [250, 500, 210], [400, 470, 170], [540, 510, 130], [320, 520, 120]];
  for (let i = 0; i < treesPos.length; i++) {
    const [x, y, h] = treesPos[i];
    for (let t = 0; t < 4; t++) {
      const w = (1 - t * 0.2) * h * 0.34;
      const yy = y - (t * h) / 4;
      trees += `<path d="M${x - w} ${yy} L ${x} ${yy - h * 0.34} L ${x + w} ${yy} Z" fill="${i % 2 === 0 ? "#153b27" : "#1d4d33"}" opacity="0.92"/>`;
    }
    trees += `<rect x="${x - 4}" y="${y - 6}" width="8" height="40" fill="${dark}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#bg-${id})"/>
    <circle cx="470" cy="160" r="120" fill="url(#glow-${id})"/>
    <circle cx="470" cy="160" r="70" fill="${pale}" opacity="0.82"/>
    <path d="M0 520 C 130 486 240 512 360 500 C 480 488 560 510 640 496 L640 640 L0 640 Z" fill="${dark}" opacity="0.6"/>
    ${trees}
    <path d="M0 560 C 160 540 280 566 430 552 C 540 542 600 560 640 552" stroke="${pale}" stroke-width="1.6" fill="none" opacity="0.3"/>
  `);
}

function garden(id, c, rnd) {
  const [dark, mid, warm, pale] = c;
  let leaves = "";
  for (let i = 0; i < 16; i++) {
    const x = 30 + rnd() * 580;
    const y = 330 + rnd() * 290;
    const s = 0.5 + rnd() * 0.9;
    const rot = rnd() * 360;
    leaves += `<path d="M0 0 C 34 -30 70 -28 96 0 C 70 28 34 30 0 0 Z" transform="translate(${x.toFixed(1)} ${y.toFixed(1)}) rotate(${rot.toFixed(0)}) scale(${s.toFixed(2)})" fill="${i % 3 === 0 ? pale : "#1f4a3b"}" opacity="${(0.35 + rnd() * 0.35).toFixed(2)}"/>`;
  }
  return frame(id, c, `
    <rect width="640" height="640" fill="url(#bg-${id})"/>
    <circle cx="320" cy="250" r="128" fill="url(#glow-${id})"/>
    <circle cx="320" cy="250" r="78" fill="${pale}" opacity="0.85"/>
    <path d="M242 250 A 78 78 0 0 0 398 250 A 78 42 0 0 1 242 250 Z" fill="${mid}" opacity="0.5"/>
    <circle cx="320" cy="250" r="104" fill="none" stroke="${warm}" stroke-width="1.4" opacity="0.45"/>
    ${leaves}
    <rect y="560" width="640" height="80" fill="${dark}" opacity="0.5"/>
  `);
}

const PATTERNS = { horizon, orchard, planes, tide, glass, petals, bus, static: staticArt, copper, orbit, evergreen, garden };

for (const [i, album] of ALBUMS.entries()) {
  const rnd = prng(1000 + i * 77);
  const svg = PATTERNS[album.pattern](album.id, album.colors, rnd);
  const file = join(src, `${album.id}.svg`);
  writeFileSync(file, svg);
  const temp = join(src, `${album.id}.png`);
  let ok = spawnSync("rsvg-convert", [file, "-o", temp], { encoding: "utf8" }).status === 0;
  if (ok) ok = spawnSync("convert", [temp, "-strip", "-quality", "85", join(out, `${album.id}.jpg`)], { encoding: "utf8" }).status === 0;
  rmSync(temp, { force: true });
  if (!ok) {
    console.error(`could not make art/${album.id}.jpg: install librsvg (rsvg-convert) and ImageMagick`);
    continue;
  }
  console.log(`art/${album.id}.jpg`);
}
