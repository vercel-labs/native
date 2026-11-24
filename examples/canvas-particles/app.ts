// Canvas 2D showcase: a dense star field with soft, round motes of light.
// Stars are 1 px rectangles batched into six palette/brightness passes. Motes are
// round cores with layered circular halos and a short motion trail; the pointer
// pulls the whole field and heats the motes it comes near.

const canvas = document.getElementById("field") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;

const STARS = 1800;
const MOTES = 85;
const COUNT = STARS + MOTES;

const xs = new Float32Array(COUNT);
const ys = new Float32Array(COUNT);
const vx = new Float32Array(COUNT);
const vy = new Float32Array(COUNT);
const group = new Uint8Array(COUNT);
const tier = new Uint8Array(COUNT);
const heat = new Float32Array(MOTES);
const scale = new Float32Array(MOTES);

let width = 1;
let height = 1;

const RGB: number[][] = [[56, 217, 255], [139, 108, 255], [255, 158, 61]];
// Alpha lives in the colour, not in globalAlpha: the host draws a translucent globalAlpha
// operation through a whole-canvas group, which a per-op alpha would turn into one group per
// particle.
function tint(g: number, alpha: number): string {
  const c = RGB[g];
  return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha.toFixed(3) + ")";
}

// One radial gradient per palette, in the unit circle: a mote draws it under a translate and
// scale, so the falloff is smooth and no gradient object is made per frame.
let GLOW: any[] = [];

// The field comes from a seeded generator rather than Math.random, so the same frame is drawn on
// every run and in every engine that draws it: two screenshots of the page can be compared.
// `?seed=N` asks for another field; without it the field is the same one every time.
function fieldSeed(): number {
  const m = /[?&]seed=(\d+)/.exec(location.search);
  return m === null ? 0x5eed : parseInt(m[1], 10) >>> 0;
}

/** mulberry32: 32 bits of state, and a uniform draw in [0, 1). */
function prng(seedValue: number): () => number {
  let a = seedValue >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), a | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seed(): void {
  const next = prng(fieldSeed());
  for (let i = 0; i < COUNT; i++) {
    xs[i] = next() * width;
    ys[i] = next() * height;
    const a = next() * Math.PI * 2;
    const speed = 3 + next() * (i < STARS ? 11 : 9);
    vx[i] = Math.cos(a) * speed;
    vy[i] = Math.sin(a) * speed;
    group[i] = Math.floor(next() * 3) % 3;
    tier[i] = next() < 0.3 ? 1 : 0;
    if (i >= STARS) scale[i - STARS] = 0.55 + next() * 1.0;
  }
}

function resize(): void {
  const dpr = window.devicePixelRatio;
  width = window.innerWidth;
  height = window.innerHeight;
  canvas.width = Math.max(1, Math.round(width * dpr));
  canvas.height = Math.max(1, Math.round(height * dpr));
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  seed();
}

window.addEventListener("resize", resize);
resize();

function buildGlows(): void {
  GLOW = [];
  for (let g = 0; g < 3; g++) {
    const grad = ctx.createRadialGradient(0, 0, 0, 0, 0, 15);
    grad.addColorStop(0, tint(g, 0.95));
    grad.addColorStop(0.16, tint(g, 0.42));
    grad.addColorStop(0.45, tint(g, 0.11));
    grad.addColorStop(1, tint(g, 0));
    GLOW.push(grad);
  }
}
buildGlows();

// --- Pointer ---------------------------------------------------------------

let pointerX = -9999;
let pointerY = -9999;
let pull = 0;

window.addEventListener("pointermove", (event: Event) => {
  const pointer = event as PointerEvent;
  pointerX = pointer.clientX;
  pointerY = pointer.clientY;
  pull = 1;
});
window.addEventListener("pointerleave", () => {
  pull = 0;
});

// --- Frame -----------------------------------------------------------------

const calm = matchMedia("(prefers-reduced-motion: reduce)");
let last = 0;

function frame(now: number): void {
  requestAnimationFrame(frame);
  if (last === 0) last = now;
  let dt = Math.min((now - last) / 1000, 0.05);
  last = now;
  if (calm.matches) dt *= 0.35;

  // The trail: the field fades rather than clearing.
  ctx.fillStyle = "rgba(5, 7, 13, 0.10)";
  ctx.fillRect(0, 0, width, height);

  const radius2 = 190 * 190;
  for (let i = 0; i < COUNT; i++) {
    let px = xs[i];
    let py = ys[i];
    const dx = pointerX - px;
    const dy = pointerY - py;
    const d2 = dx * dx + dy * dy;
    if (pull > 0 && d2 < radius2 && d2 > 1) {
      const d = Math.sqrt(d2);
      const strength = (i < STARS ? 2600 : 5200) / (d2 + 700);
      vx[i] += (dx / d) * strength * dt;
      vy[i] += (dy / d) * strength * dt;
      if (i >= STARS && heat[i - STARS] < 1) heat[i - STARS] = Math.min(1, heat[i - STARS] + dt * 8);
    }
    // A gentle swirl keeps the field alive without the pointer.
    vx[i] += -dy * 0.0000005 * dt * 60;
    vy[i] += dx * 0.0000005 * dt * 60;
    vx[i] *= 0.996;
    vy[i] *= 0.996;
    px += vx[i] * dt;
    py += vy[i] * dt;
    if (px < -12) px += width + 24;
    else if (px > width + 12) px -= width + 24;
    if (py < -12) py += height + 24;
    else if (py > height + 12) py -= height + 24;
    xs[i] = px;
    ys[i] = py;
  }
  pull *= 0.985;

  // Stars: six passes (three colours, two brightnesses), one style change each.
  for (let g = 0; g < 3; g++) {
    for (let t = 0; t < 2; t++) {
      ctx.fillStyle = tint(g, t === 1 ? 0.9 : 0.42);
      for (let i = 0; i < STARS; i++) {
        if (group[i] !== g || tier[i] !== t) continue;
        ctx.fillRect(xs[i], ys[i], 1, 1);
      }
    }
  }

  // Motes: a short trail, then one radial-gradient glow per mote drawn in local coordinates.
  for (let g = 0; g < 3; g++) {
    ctx.strokeStyle = tint(g, 0.2);
    for (let m = 0; m < MOTES; m++) {
      const i = STARS + m;
      if (group[i] !== g) continue;
      const h = heat[m];
      const size = scale[m] * (1 + h * 0.9);
      ctx.lineWidth = 0.8 * size + h;
      ctx.beginPath();
      ctx.moveTo(xs[i] - vx[i] * 0.22, ys[i] - vy[i] * 0.22);
      ctx.lineTo(xs[i], ys[i]);
      ctx.stroke();
    }
  }

  for (let g = 0; g < 3; g++) {
    for (let m = 0; m < MOTES; m++) {
      const i = STARS + m;
      if (group[i] !== g) continue;
      const h = heat[m];
      const size = scale[m] * (1 + h * 0.9);
      ctx.save();
      ctx.translate(xs[i], ys[i]);
      ctx.scale(size, size);
      ctx.fillStyle = GLOW[g];
      ctx.beginPath();
      ctx.arc(0, 0, 15, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = tint(g, 0.55 + h * 0.35);
      ctx.beginPath();
      ctx.arc(0, 0, 1.4, 0, Math.PI * 2);
      ctx.fill();
      ctx.restore();
    }
  }

  for (let m = 0; m < MOTES; m++) {
    const h = heat[m];
    if (h > 0.01) heat[m] = Math.max(0, h - dt * 0.4);
  }
}

requestAnimationFrame(frame);
