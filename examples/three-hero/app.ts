// A lit, textured, spinning three.js scene: a torus knot over a shadowed floor,
// orbited by a pointer drag, resized with the window, drawn on
// requestAnimationFrame. Everything goes through the standard web APIs the
// Native SDK runtime provides: canvas.getContext("webgl2"), typed-array
// textures, pointer events, resize events and requestAnimationFrame.

import {
  ACESFilmicToneMapping,
  DataTexture,
  DirectionalLight,
  Fog,
  HemisphereLight,
  Mesh,
  MeshStandardMaterial,
  PCFShadowMap,
  PerspectiveCamera,
  PlaneGeometry,
  PointLight,
  RGBAFormat,
  Scene,
  SRGBColorSpace,
  TorusKnotGeometry,
  Vector3,
  WebGLRenderer,
} from "three";

const canvas = document.getElementById("stage") as HTMLCanvasElement;
const renderer = new WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setSize(window.innerWidth, window.innerHeight, false);
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = PCFShadowMap;
renderer.toneMapping = ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.15;
renderer.outputColorSpace = SRGBColorSpace;

const scene = new Scene();
renderer.setClearColor(0x0a0e17, 1);
// Fade the floor into the clear colour well before its edge, so there's no horizon seam.
scene.fog = new Fog(0x0a0e17, 9, 18);

const camera = new PerspectiveCamera(42, window.innerWidth / window.innerHeight, 0.1, 100);
camera.position.set(2.6, 2.2, 4.6);

// --- Lights -----------------------------------------------------------------

scene.add(new HemisphereLight(0x88aaff, 0x0a0e17, 0.55));

const key = new DirectionalLight(0xffffff, 3.2);
key.position.set(3.5, 6, 4);
key.castShadow = true;
key.shadow.mapSize.set(1024, 1024);
key.shadow.camera.near = 1;
key.shadow.camera.far = 18;
key.shadow.camera.left = -5;
key.shadow.camera.right = 5;
key.shadow.camera.top = 5;
key.shadow.camera.bottom = -5;
key.shadow.radius = 4;
key.shadow.bias = -0.0004;
scene.add(key);

const rim = new PointLight(0x3d7bff, 42, 14, 2);
rim.position.set(-3.4, 1.8, -2.6);
scene.add(rim);

const warm = new PointLight(0xff5533, 26, 12, 2);
warm.position.set(3.2, 0.9, -2.2);
scene.add(warm);

// --- A procedural texture ---------------------------------------------------

// A 512² RGBA texture built in script: a heated banded gradient with a fine
// speckle, uploaded as a DataTexture (the path three uses for typed pixels).
const SIZE = 512;
const pixels = new Uint8Array(SIZE * SIZE * 4);
for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const u = x / SIZE;
    const v = y / SIZE;
    const band = 0.5 + 0.5 * Math.sin(u * 22 + Math.sin(v * 9) * 2.2);
    const glow = Math.max(0, 1 - Math.sqrt((u - 0.32) * (u - 0.32) + (v - 0.28) * (v - 0.28)) * 1.9);
    const speck = ((x * 73856093) ^ (y * 19349663)) % 1000 / 1000;
    const o = (y * SIZE + x) * 4;
    pixels[o] = 255 * Math.min(1, 0.35 + 0.55 * band + 0.35 * glow);
    pixels[o + 1] = 255 * Math.min(1, 0.12 + 0.22 * band + 0.5 * glow + speck * 0.08);
    pixels[o + 2] = 255 * Math.min(1, 0.2 + 0.18 * (1 - band) + 0.65 * glow);
    pixels[o + 3] = 255;
  }
}
const texture = new DataTexture(pixels, SIZE, SIZE, RGBAFormat);
texture.colorSpace = SRGBColorSpace;
texture.anisotropy = 4;
texture.needsUpdate = true;

// --- The scene --------------------------------------------------------------

const knotGeometry = new TorusKnotGeometry(0.95, 0.3, 220, 36);
const knotMaterial = new MeshStandardMaterial({
  map: texture,
  metalness: 0.65,
  roughness: 0.22,
  dithering: true,
});
const knot = new Mesh(knotGeometry, knotMaterial);
knot.position.y = 1.55;
knot.castShadow = true;
knot.receiveShadow = true;
scene.add(knot);

const floor = new Mesh(
  new PlaneGeometry(40, 40),
  new MeshStandardMaterial({ color: 0x111726, metalness: 0.35, roughness: 0.55, dithering: true }),
);
floor.rotation.x = -Math.PI / 2;
floor.receiveShadow = true;
scene.add(floor);

// A small orbit control: a pointer drag turns the camera around the target, the
// wheel changes the distance, and both ease toward the requested values.
const target = new Vector3(0, 1.5, 0);
let yaw = 0.55;
let pitch = 0.38;
let distance = 6.2;
let yawGoal = yaw;
let pitchGoal = pitch;
let distanceGoal = distance;
let dragging = false;
let lastX = 0;
let lastY = 0;

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

canvas.addEventListener("pointerdown", (event: Event) => {
  const e = event as PointerEvent;
  dragging = true;
  lastX = e.clientX;
  lastY = e.clientY;
  canvas.setPointerCapture(e.pointerId);
});
canvas.addEventListener("pointermove", (event: Event) => {
  if (!dragging) return;
  const e = event as PointerEvent;
  yawGoal = yawGoal - (e.clientX - lastX) * 0.008;
  pitchGoal = clamp(pitchGoal + (e.clientY - lastY) * 0.006, 0.06, Math.PI * 0.5);
  lastX = e.clientX;
  lastY = e.clientY;
});
function endDrag(): void {
  dragging = false;
}
canvas.addEventListener("pointerup", endDrag);
canvas.addEventListener("pointercancel", endDrag);
canvas.addEventListener("wheel", (event: Event) => {
  const e = event as WheelEvent;
  distanceGoal = clamp(distanceGoal + e.deltaY * 0.002, 2.6, 11);
});

// --- Resize -----------------------------------------------------------------

function resizeToWindow(): void {
  const width = window.innerWidth;
  const height = window.innerHeight;
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(width, height, false);
}
window.addEventListener("resize", resizeToWindow);

// --- Frame loop -------------------------------------------------------------

const still = matchMedia("(prefers-reduced-motion: reduce)");
const clock = { last: 0 };

function frame(time: number): void {
  requestAnimationFrame(frame);
  const dt = clock.last === 0 ? 0 : Math.min((time - clock.last) / 1000, 0.05);
  clock.last = time;
  knot.rotation.y += still.matches ? 0 : dt * 0.6;
  knot.rotation.x = still.matches ? 0.35 : Math.sin(time / 2600) * 0.28;
  knot.position.y = 1.55 + (still.matches ? 0 : Math.sin(time / 900) * 0.08);
  rim.intensity = 34 + (still.matches ? 0 : Math.sin(time / 700) * 8);

  yaw = yaw + (yawGoal - yaw) * 0.12;
  pitch = pitch + (pitchGoal - pitch) * 0.12;
  distance = distance + (distanceGoal - distance) * 0.12;
  const horizontal = Math.cos(pitch) * distance;
  camera.position.x = target.x + horizontal * Math.sin(yaw);
  camera.position.y = target.y + distance * Math.sin(pitch);
  camera.position.z = target.z + horizontal * Math.cos(yaw);
  camera.lookAt(target);

  renderer.render(scene, camera);
}

requestAnimationFrame(frame);
