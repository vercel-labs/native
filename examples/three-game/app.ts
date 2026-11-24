// Starfall: a small arcade game drawn with three.js. Orbs fall toward a paddle
// that moves with the arrow keys, A and D, or the pointer; each catch scores a
// point, each miss costs one of three lives. Everything runs on requestAnimationFrame
// through the standard web APIs the Native SDK runtime provides.

import {
  AdditiveBlending,
  BoxGeometry,
  BufferAttribute,
  BufferGeometry,
  Color,
  DataTexture,
  DirectionalLight,
  Fog,
  HemisphereLight,
  Mesh,
  MeshBasicMaterial,
  MeshStandardMaterial,
  PerspectiveCamera,
  PlaneGeometry,
  PointLight,
  RGBAFormat,
  RepeatWrapping,
  Scene,
  SphereGeometry,
  Vector3,
  WebGLRenderer,
} from "three";

const canvas = document.getElementById("stage") as HTMLCanvasElement;
const scoreLabel = document.getElementById("score") as HTMLElement;
const livesLabel = document.getElementById("lives") as HTMLElement;
const banner = document.getElementById("banner") as HTMLElement;
const modeLabel = document.getElementById("mode") as HTMLElement;

const BACKGROUND = 0x070816;
const PADDLE_Y = 0.62;
const PADDLE_HALF = 1.3;
const ORB_RADIUS = 0.3;
const SPAWN_Y = 9.6;

const renderer = new WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setSize(window.innerWidth, window.innerHeight, false);

const scene = new Scene();
scene.background = new Color(BACKGROUND);
// The floor fades into the background long before its far edge, so floor and sky read as one space.
scene.fog = new Fog(BACKGROUND, 7, 19);

// The camera looks almost level at the middle of the playfield, which runs from the floor to a
// little above the spawn height; the paddle sits near the bottom of the frame.
const CAMERA_DISTANCE = 11.8;
const camera = new PerspectiveCamera(46, window.innerWidth / window.innerHeight, 0.1, 80);
camera.position.set(0, 4.7, CAMERA_DISTANCE);
camera.lookAt(new Vector3(0, 4.35, 0));

// Half the width of the playfield that is in view at the paddle's depth. The paddle and the orbs
// stay inside it, so nothing leaves the frame whatever the window's shape.
let viewHalf = 5;
let paddleBound = 3.5;
let orbBound = 4.4;
function measureView(): void {
  const halfHeight = CAMERA_DISTANCE * Math.tan((camera.fov * Math.PI) / 360);
  viewHalf = halfHeight * camera.aspect;
  paddleBound = Math.max(0.5, viewHalf - PADDLE_HALF - 0.25);
  orbBound = Math.max(0.5, viewHalf - ORB_RADIUS - 0.45);
}
measureView();

scene.add(new HemisphereLight(0x93c5fd, BACKGROUND, 1.1));

const key = new DirectionalLight(0xffffff, 2.2);
key.position.set(4, 9, 6);
scene.add(key);

const cyan = new PointLight(0x22d3ee, 40, 20, 2);
cyan.position.set(-5, 3.0, 3.0);
scene.add(cyan);

const magenta = new PointLight(0xf472b6, 36, 20, 2);
magenta.position.set(5, 2.6, 2.0);
scene.add(magenta);

// A red light under the floor's surface that flares where an orb lands.
const missLight = new PointLight(0xef4444, 0, 9, 2);
missLight.position.set(0, 0.6, 0.5);
scene.add(missLight);

// --- Textures built in script -------------------------------------------------

function radialTexture(size: number, falloff: number): DataTexture {
  const data = new Uint8Array(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = (x + 0.5) / size * 2 - 1;
      const dy = (y + 0.5) / size * 2 - 1;
      const d = Math.min(1, Math.sqrt(dx * dx + dy * dy));
      const a = Math.pow(1 - d, falloff);
      const o = (y * size + x) * 4;
      data[o] = 255;
      data[o + 1] = 255;
      data[o + 2] = 255;
      data[o + 3] = Math.round(255 * a);
    }
  }
  const texture = new DataTexture(data, size, size, RGBAFormat);
  texture.needsUpdate = true;
  return texture;
}

// A streak: bright at the bottom, fading out upward, soft at the sides.
function streakTexture(width: number, height: number): DataTexture {
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const u = (x + 0.5) / width * 2 - 1;
      const v = (y + 0.5) / height;
      const a = Math.pow(1 - v, 2.2) * Math.exp(-u * u * 6) * Math.min(1, v / 0.18);
      const o = (y * width + x) * 4;
      data[o] = 255;
      data[o + 1] = 255;
      data[o + 2] = 255;
      data[o + 3] = Math.round(255 * Math.min(1, a));
    }
  }
  const texture = new DataTexture(data, width, height, RGBAFormat);
  texture.needsUpdate = true;
  return texture;
}

const sparkTexture = radialTexture(32, 1.6);
const trailTexture = streakTexture(16, 64);

// "+1", drawn into a small bitmap: a plus and a one made of soft-edged bars.
function plusOneTexture(): DataTexture {
  const w = 64;
  const h = 32;
  const data = new Uint8Array(w * h * 4);
  // Bars as [x0, y0, x1, y1] in pixels, y up.
  const bars = [
    [6, 13, 26, 19], [13, 6, 19, 26],
    [38, 4, 44, 28], [32, 22, 40, 28], [32, 4, 50, 9],
  ];
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let a = 0;
      for (const b of bars) {
        const dx = Math.max(b[0] - x - 0.5, 0, x + 0.5 - b[2]);
        const dy = Math.max(b[1] - y - 0.5, 0, y + 0.5 - b[3]);
        a = Math.max(a, Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy) / 1.5));
      }
      const o = (y * w + x) * 4;
      data[o] = 255;
      data[o + 1] = 255;
      data[o + 2] = 255;
      data[o + 3] = Math.round(255 * a);
    }
  }
  const texture = new DataTexture(data, w, h, RGBAFormat);
  texture.needsUpdate = true;
  return texture;
}

const plusTexture = plusOneTexture();


// --- The floor: a dark plane with a glowing grid in a data texture. ----------

const GRID = 128;
const gridPixels = new Uint8Array(GRID * GRID * 4);
for (let y = 0; y < GRID; y++) {
  for (let x = 0; x < GRID; x++) {
    const line = x % 32 === 0 || y % 32 === 0;
    const edge = x % 32 < 2 || y % 32 < 2;
    const o = (y * GRID + x) * 4;
    gridPixels[o] = line ? (edge ? 70 : 30) : 8;
    gridPixels[o + 1] = line ? (edge ? 84 : 36) : 10;
    gridPixels[o + 2] = line ? (edge ? 170 : 80) : 22;
    gridPixels[o + 3] = 255;
  }
}
const gridTexture = new DataTexture(gridPixels, GRID, GRID, RGBAFormat);
gridTexture.wrapS = RepeatWrapping;
gridTexture.wrapT = RepeatWrapping;
gridTexture.repeat.set(12, 12);
gridTexture.needsUpdate = true;

const floor = new Mesh(
  new PlaneGeometry(48, 48),
  new MeshStandardMaterial({ map: gridTexture, roughness: 0.8, metalness: 0.2, dithering: true }),
);
floor.rotation.x = -Math.PI / 2;
floor.position.set(0, 0, -12);
scene.add(floor);

// --- Stars: a far field of faint quads in one mesh, outside the fog. -----------

const STAR_COUNT = 220;
const starPositions = new Float32Array(STAR_COUNT * 4 * 3);
const starUVs = new Float32Array(STAR_COUNT * 4 * 2);
const starIndex: number[] = [];
let starSeed = 7;
function starRandom(): number {
  starSeed = (starSeed * 16807) % 2147483647;
  return starSeed / 2147483647;
}
for (let i = 0; i < STAR_COUNT; i++) {
  const x = (starRandom() * 2 - 1) * 30;
  const y = 3 + starRandom() * 26;
  const z = -32 - starRandom() * 4;
  const r = 0.07 + starRandom() * starRandom() * 0.26;
  const corners = [-1, -1, 1, -1, 1, 1, -1, 1];
  for (let c = 0; c < 4; c++) {
    const o = (i * 4 + c) * 3;
    starPositions[o] = x + corners[c * 2] * r;
    starPositions[o + 1] = y + corners[c * 2 + 1] * r;
    starPositions[o + 2] = z;
    starUVs[(i * 4 + c) * 2] = (corners[c * 2] + 1) / 2;
    starUVs[(i * 4 + c) * 2 + 1] = (corners[c * 2 + 1] + 1) / 2;
  }
  const b = i * 4;
  starIndex.push(b, b + 1, b + 2, b, b + 2, b + 3);
}
const starGeometry = new BufferGeometry();
starGeometry.setAttribute("position", new BufferAttribute(starPositions, 3));
starGeometry.setAttribute("uv", new BufferAttribute(starUVs, 2));
starGeometry.setIndex(starIndex);
const starMaterial = new MeshBasicMaterial({
  color: 0xc7d2fe,
  map: sparkTexture,
  transparent: true,
  opacity: 0.8,
  depthWrite: false,
  blending: AdditiveBlending,
  fog: false,
});
scene.add(new Mesh(starGeometry, starMaterial));

// --- Billboards: flat quads that always face the fixed camera. ---------------

const billboards: Mesh[] = [];
function billboard(width: number, height: number, texture: DataTexture, color: number, opacity: number): Mesh {
  const material = new MeshBasicMaterial({
    color: color,
    map: texture,
    transparent: true,
    opacity: opacity,
    depthWrite: false,
    // A glow is light, not a surface: it must not be cut where the floor's plane crosses it.
    depthTest: false,
    blending: AdditiveBlending,
    fog: false,
    dithering: true,
  });
  const mesh = new Mesh(new PlaneGeometry(width, height), material);
  mesh.quaternion.copy(camera.quaternion);
  billboards.push(mesh);
  scene.add(mesh);
  return mesh;
}

// --- The paddle -------------------------------------------------------------

const paddleMaterial = new MeshStandardMaterial({
  color: 0x6366f1,
  emissive: 0x3730a3,
  emissiveIntensity: 1.4,
  roughness: 0.3,
  metalness: 0.4,
  dithering: true,
});
const paddle = new Mesh(new BoxGeometry(PADDLE_HALF * 2, 0.26, 0.7), paddleMaterial);
paddle.position.set(0, PADDLE_Y, 0);
scene.add(paddle);

// --- Orbs -------------------------------------------------------------------

const ORB_COLORS = [0x22d3ee, 0xa78bfa, 0xf472b6, 0xfbbf24, 0x34d399];
const ORB_COUNT = 20;
const orbGeometry = new SphereGeometry(ORB_RADIUS, 24, 16);
const orbMaterials: MeshStandardMaterial[] = [];
for (const color of ORB_COLORS) {
  orbMaterials.push(new MeshStandardMaterial({
    color: color,
    emissive: color,
    emissiveIntensity: 1.6,
    roughness: 0.25,
    metalness: 0.15,
    dithering: true,
  }));
}

// A halo: two soft additive shells around each orb. (More shells look smoother but cost frames on
// the M1.)
const haloGeometry = new SphereGeometry(ORB_RADIUS * 1.9, 24, 16);
const haloOuterGeometry = new SphereGeometry(ORB_RADIUS * 3.0, 24, 16);
const haloMaterials: MeshBasicMaterial[] = [];
const haloOuterMaterials: MeshBasicMaterial[] = [];
for (const color of ORB_COLORS) {
  haloMaterials.push(new MeshBasicMaterial({ color: color, transparent: true, opacity: 0.2, depthWrite: false, depthTest: false, blending: AdditiveBlending, fog: false, dithering: true }));
  haloOuterMaterials.push(new MeshBasicMaterial({ color: color, transparent: true, opacity: 0.07, depthWrite: false, depthTest: false, blending: AdditiveBlending, fog: false, dithering: true }));
}

const orbs: Mesh[] = [];
const orbGlows: Mesh[] = [];
const orbTrails: Mesh[] = [];
const orbSpeeds: number[] = [];
for (let i = 0; i < ORB_COUNT; i++) {
  const color = ORB_COLORS[i % ORB_COLORS.length];
  const orb = new Mesh(orbGeometry, orbMaterials[i % orbMaterials.length]);
  orb.visible = false;
  scene.add(orb);
  orbs.push(orb);
  const glow = new Mesh(haloGeometry, haloMaterials[i % haloMaterials.length]);
  glow.add(new Mesh(haloOuterGeometry, haloOuterMaterials[i % haloOuterMaterials.length]));
  glow.visible = false;
  scene.add(glow);
  orbGlows.push(glow);
  const trail = billboard(0.62, 2.4, trailTexture, color, 0.55);
  trail.visible = false;
  orbTrails.push(trail);
  orbSpeeds.push(0);
}

// --- Sparks: a pool of small glowing quads for catch and miss bursts. --------

const SPARK_COUNT = 140;
const sparks: Mesh[] = [];
const sparkMaterials: MeshBasicMaterial[] = [];
const sparkVX: number[] = [];
const sparkVY: number[] = [];
const sparkLife: number[] = [];
const sparkSpan: number[] = [];
let nextSpark = 0;
for (let i = 0; i < SPARK_COUNT; i++) {
  const spark = billboard(0.34, 0.34, sparkTexture, 0xffffff, 1);
  spark.visible = false;
  sparks.push(spark);
  sparkMaterials.push(spark.material as MeshBasicMaterial);
  sparkVX.push(0);
  sparkVY.push(0);
  sparkLife.push(0);
  sparkSpan.push(1);
}

// "+1" pops that rise from the paddle and fade.
const POP_COUNT = 4;
const pops: Mesh[] = [];
const popAge: number[] = [];
let nextPop = 0;
for (let i = 0; i < POP_COUNT; i++) {
  const p = billboard(1.1, 0.55, plusTexture, 0xffffff, 1);
  p.visible = false;
  pops.push(p);
  popAge.push(1);
}
// A miss tints the whole background and the fog red for a moment.
const calmColor = new Color(BACKGROUND);
const missColor = new Color(0x3b0a16);
const skyColor = new Color(BACKGROUND);

function popAt(x: number, y: number, color: number): void {
  const i = nextPop;
  nextPop = (nextPop + 1) % POP_COUNT;
  popAge[i] = 0;
  pops[i].position.set(x, y, 0.6);
  pops[i].visible = true;
  (pops[i].material as MeshBasicMaterial).color.setHex(color).lerp(new Color(0xffffff), 0.6);
}

function updatePops(dt: number): void {
  for (let i = 0; i < POP_COUNT; i++) {
    if (popAge[i] >= 1) continue;
    popAge[i] = Math.min(1, popAge[i] + dt * 1.5);
    if (popAge[i] >= 1) {
      pops[i].visible = false;
      continue;
    }
    pops[i].position.y = pops[i].position.y + dt * 1.6;
    (pops[i].material as MeshBasicMaterial).opacity = 1 - popAge[i] * popAge[i];
    pops[i].scale.setScalar(0.8 + Math.min(1, popAge[i] * 6) * 0.4);
  }
}

// Effects draw from their own generator, so they never change where the orbs fall.
let fxSeed = 12345;
function fxRandom(): number {
  fxSeed = (fxSeed * 48271) % 2147483647;
  return fxSeed / 2147483647;
}

function burst(x: number, y: number, color: number, count: number, up: number): void {
  for (let n = 0; n < count; n++) {
    const i = nextSpark;
    nextSpark = (nextSpark + 1) % SPARK_COUNT;
    const angle = Math.PI * (0.08 + 0.84 * fxRandom());
    const speed = 2.6 + fxRandom() * 3.6;
    sparkVX[i] = Math.cos(angle) * speed;
    sparkVY[i] = Math.sin(angle) * speed * up;
    sparkSpan[i] = 0.45 + fxRandom() * 0.4;
    sparkLife[i] = sparkSpan[i];
    sparks[i].position.set(x, y, 0.4);
    sparks[i].visible = true;
    sparkMaterials[i].color.setHex(color);
  }
}

function updateSparks(dt: number): void {
  for (let i = 0; i < SPARK_COUNT; i++) {
    if (sparkLife[i] <= 0) continue;
    sparkLife[i] = sparkLife[i] - dt;
    if (sparkLife[i] <= 0) {
      sparks[i].visible = false;
      continue;
    }
    sparkVY[i] = sparkVY[i] - 9 * dt;
    sparks[i].position.x = sparks[i].position.x + sparkVX[i] * dt;
    sparks[i].position.y = sparks[i].position.y + sparkVY[i] * dt;
    const k = sparkLife[i] / sparkSpan[i];
    sparkMaterials[i].opacity = k;
    sparks[i].scale.setScalar(0.4 + 0.8 * k);
  }
}

// --- State ------------------------------------------------------------------

type Mode = "READY" | "PLAYING" | "OVER";
let mode: Mode = "READY";
let score = 0;
let lives = 3;
let paddleX = 0;
let paddleGoal = 0;
let spawnIn = 0.6;
let elapsed = 0;
let last = 0;
let heldLeft = false;
let heldRight = false;
let seed = 0x9e3779b9;
let missFlash = 0;

function random(): number {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

function setMode(next: Mode): void {
  mode = next;
  modeLabel.textContent = next;
  if (next === "READY") banner.textContent = "CLICK TO PLAY · ARROWS OR A / D TO MOVE";
  if (next === "PLAYING") banner.textContent = "CATCH THE ORBS · DON'T LET THEM LAND";
  if (next === "OVER") banner.textContent = "GAME OVER · CLICK TO PLAY AGAIN";
}

function reset(): void {
  score = 0;
  lives = 3;
  paddleX = 0;
  paddleGoal = 0;
  spawnIn = 0.6;
  elapsed = 0;
  for (let i = 0; i < ORB_COUNT; i++) {
    orbs[i].visible = false;
    orbGlows[i].visible = false;
    orbTrails[i].visible = false;
  }
  scoreLabel.textContent = "0";
  livesLabel.textContent = "3";
  setMode("PLAYING");
}

function spawnOrb(): void {
  for (let i = 0; i < orbs.length; i++) {
    if (!orbs[i].visible) {
      const orb = orbs[i];
      orb.visible = true;
      orbGlows[i].visible = true;
      orbTrails[i].visible = true;
      orb.position.set((random() * 2 - 1) * orbBound, SPAWN_Y + random() * 0.8, (random() * 2 - 1) * 0.3);
      orb.scale.setScalar(0.9 + random() * 0.35);
      orbSpeeds[i] = 3.6 + random() * 2.0 + Math.min(2.6, score * 0.08);
      return;
    }
  }
}

function movePaddle(dt: number): void {
  const speed = 10.5;
  if (heldLeft) paddleGoal = paddleGoal - speed * dt;
  if (heldRight) paddleGoal = paddleGoal + speed * dt;
  if (paddleGoal < -paddleBound) paddleGoal = -paddleBound;
  if (paddleGoal > paddleBound) paddleGoal = paddleBound;
  paddleX = paddleX + (paddleGoal - paddleX) * Math.min(1, dt * 18);
  paddle.position.x = paddleX;
}

function hideOrb(i: number): void {
  orbs[i].visible = false;
  orbGlows[i].visible = false;
  orbTrails[i].visible = false;
}

function updateOrbs(dt: number): void {
  for (let i = 0; i < orbs.length; i++) {
    const orb = orbs[i];
    if (!orb.visible) continue;
    orb.position.y = orb.position.y - orbSpeeds[i] * dt;
    orb.rotation.x = orb.rotation.x + dt * 1.6;
    orb.rotation.y = orb.rotation.y + dt * 2.2;
    if (orb.position.y < PADDLE_Y + 0.32) {
      const dx = orb.position.x - paddleX;
      if (dx < PADDLE_HALF + 0.18 && dx > -PADDLE_HALF - 0.18) {
        const color = ORB_COLORS[i % ORB_COLORS.length];
        hideOrb(i);
        score = score + 1;
        scoreLabel.textContent = String(score);
        paddleMaterial.emissiveIntensity = 3.2;
        burst(orb.position.x, PADDLE_Y + 0.25, color, 18, 1);
        popAt(orb.position.x, PADDLE_Y + 0.9, color);
        // The score label pops once; two style writes, not one per frame.
        scoreLabel.style.transform = "scale(1.35)";
        setTimeout(() => { scoreLabel.style.transform = ""; }, 160);
        continue;
      }
    }
    if (orb.position.y < 0.2) {
      hideOrb(i);
      lives = lives - 1;
      livesLabel.textContent = String(lives);
      burst(orb.position.x, 0.25, 0xef4444, 14, 0.7);
      missLight.position.x = orb.position.x;
      missLight.intensity = 60;
      missFlash = 1;
      if (lives <= 0) {
        setMode("OVER");
      }
    }
  }
}

// Glows and trails follow their orbs; the trail stretches with the orb's speed.
function placeOrbEffects(): void {
  for (let i = 0; i < ORB_COUNT; i++) {
    if (!orbs[i].visible) continue;
    const p = orbs[i].position;
    orbGlows[i].position.set(p.x, p.y, p.z);
    orbGlows[i].scale.copy(orbs[i].scale);
    const stretch = 0.65 + orbSpeeds[i] * 0.12;
    orbTrails[i].scale.set(1, stretch, 1);
    orbTrails[i].position.set(p.x, p.y + 1.2 * stretch - 0.1, p.z - 0.05);
  }
}

function updateFlash(dt: number): void {
  if (missFlash > 0) {
    missFlash = Math.max(0, missFlash - dt * 2.4);
    skyColor.copy(calmColor).lerp(missColor, missFlash);
    (scene.background as Color).copy(skyColor);
    if (scene.fog !== null) scene.fog.color.copy(skyColor);
  }
  missLight.intensity = missLight.intensity * Math.max(0, 1 - dt * 5);
}

function frame(time: number): void {
  requestAnimationFrame(frame);
  const dt = last === 0 ? 0 : Math.min((time - last) / 1000, 0.05);
  last = time;
  if (mode === "PLAYING") {
    elapsed = elapsed + dt;
    movePaddle(dt);
    updateOrbs(dt);
    spawnIn = spawnIn - dt;
    if (spawnIn <= 0) {
      spawnOrb();
      spawnIn = Math.max(0.42, 1.05 - Math.min(0.4, elapsed * 0.006));
    }
  }
  if (paddleMaterial.emissiveIntensity > 1.4) {
    paddleMaterial.emissiveIntensity = Math.max(1.4, paddleMaterial.emissiveIntensity - dt * 5);
  }
  placeOrbEffects();
  updateSparks(dt);
  updatePops(dt);
  updateFlash(dt);
  cyan.intensity = 40 + Math.sin(time / 640) * 9;
  magenta.intensity = 36 + Math.cos(time / 520) * 8;
  starMaterial.opacity = 0.7 + Math.sin(time / 900) * 0.15;
  renderer.render(scene, camera);
}

// --- Input ------------------------------------------------------------------

function setHeld(event: KeyboardEvent, down: boolean): void {
  if (event.key === "ArrowLeft" || event.key === "a" || event.key === "A") {
    heldLeft = down;
    event.preventDefault();
  } else if (event.key === "ArrowRight" || event.key === "d" || event.key === "D") {
    heldRight = down;
    event.preventDefault();
  }
}
window.addEventListener("keydown", (event: Event) => setHeld(event as KeyboardEvent, true));
window.addEventListener("keyup", (event: Event) => setHeld(event as KeyboardEvent, false));

canvas.addEventListener("click", () => {
  if (mode === "PLAYING") return;
  reset();
});
canvas.addEventListener("pointermove", (event: Event) => {
  if (mode !== "PLAYING") return;
  const e = event as PointerEvent;
  const t = (e.clientX / window.innerWidth) * 2 - 1;
  paddleGoal = Math.max(-paddleBound, Math.min(paddleBound, t * viewHalf));
});

function resizeToWindow(): void {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  measureView();
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(window.innerWidth, window.innerHeight, false);
}
window.addEventListener("resize", resizeToWindow);

setMode("READY");
requestAnimationFrame(frame);
