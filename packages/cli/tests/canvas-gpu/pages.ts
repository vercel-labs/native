// The canvas pages the GPU canvas raster is held to, and the Chrome screenshots of them.
// Each page is drawn in CSS px into a 2x bitmap, so a 2x screenshot of the page is the bitmap
// pixel for pixel.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const W = 200, H = 150;
/** The page's setup. The app's copy is TypeScript, so it casts what getElementById and
 *  getContext return; the Chrome copy is plain JavaScript. */
function prelude(ts: boolean): string {
  return `
const TAU = Math.PI * 2;
const canvas = document.getElementById("c")${ts ? " as HTMLCanvasElement" : ""};
const c = canvas.getContext("2d")${ts ? "!" : ""};
c.setTransform(2, 0, 0, 2, 0, 0);
c.fillStyle = "#ffffff";
c.fillRect(0, 0, ${W}, ${H});
`;
}

/** name -> the page's drawing, in CSS px on a white background. */
export const PAGES: Record<string, string> = {
  circle: `
c.fillStyle = "#ff3b24";
c.beginPath(); c.arc(30.25, 30.5, 20.5, 0, TAU); c.fill();
c.fillStyle = "rgba(0, 90, 200, 0.55)";
c.beginPath(); c.arc(70.75, 34.25, 12.3, 0, TAU); c.fill();
c.fillStyle = "rgba(20, 160, 90, 0.8)";
c.beginPath(); c.arc(110.5, 38.75, 4.4, 0, TAU); c.fill();
c.fillStyle = "#331a66";
c.beginPath(); c.arc(130.3, 40.6, 1.7, 0, TAU); c.fill();
c.beginPath(); c.arc(136.4, 44.9, 0.9, 0, TAU); c.fill();
c.fillStyle = "rgba(255, 140, 0, 0.4)";
c.beginPath(); c.arc(35.5, 90.25, 28.75, 0, TAU); c.fill();
c.fillStyle = "rgba(255, 140, 0, 0.4)";
c.beginPath(); c.arc(52.75, 96.5, 18.2, 0, TAU); c.fill();
c.fillStyle = "#111111";
c.beginPath(); c.arc(100.5, 100.5, 30.5, 0, TAU); c.fill();
c.globalAlpha = 0.5;
c.fillStyle = "#1480ff";
c.beginPath(); c.arc(125.25, 108.75, 22.5, 0, TAU); c.fill();
c.globalAlpha = 1;
// A ring of small circles, one path each.
for (let i = 0; i < 24; i++) {
  const a = (i / 24) * TAU;
  c.fillStyle = i % 2 ? "rgba(0,0,0,0.7)" : "rgba(200,30,90,0.35)";
  c.beginPath();
  c.arc(165.5 + Math.cos(a) * 22.75, 45.25 + Math.sin(a) * 22.75, 2.35 + (i % 5) * 0.4, 0, TAU);
  c.fill();
}
`,
  ellipse: `
c.fillStyle = "#1f6feb";
c.beginPath(); c.ellipse(45.5, 40.25, 30.5, 14.25, 0, 0, TAU); c.fill();
c.fillStyle = "rgba(230, 50, 30, 0.55)";
c.beginPath(); c.ellipse(105.75, 45.5, 12.4, 30.6, 0.4, 0, TAU); c.fill();
c.fillStyle = "#0a7f46";
c.save();
c.translate(150.5, 40.25);
c.scale(2.4, 0.8);
c.beginPath(); c.arc(0, 0, 12.3, 0, TAU); c.fill();
c.restore();
c.fillStyle = "rgba(90, 20, 160, 0.6)";
c.beginPath(); c.ellipse(50.3, 110.4, 40.7, 8.1, -0.3, 0, TAU); c.fill();
c.fillStyle = "#000000";
c.beginPath(); c.ellipse(120.2, 105.6, 20.5, 20.5, 0, 0, TAU); c.fill();
c.fillStyle = "rgba(255, 59, 36, 0.45)";
c.beginPath(); c.ellipse(165.4, 112.7, 3.2, 6.9, 1.1, 0, TAU); c.fill();
`,
  rects: `
c.fillStyle = "#c8102e";
c.fillRect(10.25, 10.5, 40.3, 20.75);
c.fillStyle = "rgba(0, 100, 200, 0.5)";
c.fillRect(30.5, 20.25, 40.5, 25.5);
c.fillStyle = "rgba(0, 160, 90, 0.75)";
c.fillRect(15.75, 55.2, 0.5, 30.6);
c.fillRect(17.7, 55.2, 1.5, 30.6);
c.fillRect(21.3, 55.2, 2.5, 30.6);
c.fillStyle = "#222222";
c.fillRect(40.35, 60.75, 60.4, 0.6);
c.fillRect(40.65, 63.7, 60.1, 1.4);
c.fillStyle = "rgba(255, 150, 0, 0.6)";
c.fillRect(110.5, 55.5, 30.5, 15.25);
c.fillStyle = "rgba(120, 0, 200, 0.5)";
c.fillRect(125.25, 62.75, 30.5, 15.25);
c.fillStyle = "#101010";
for (let i = 0; i < 40; i++) c.fillRect(10.3 + i * 4.7, 120.4 + (i % 3) * 0.4, 1, 1);
`,
  roundrect: `
c.fillStyle = "#0b6e4f";
c.beginPath(); c.roundRect(10.25, 12.5, 60.5, 40.25, 12.3); c.fill();
c.fillStyle = "rgba(220, 40, 60, 0.55)";
c.beginPath(); c.roundRect(50.75, 26.25, 55.2, 35.6, 3.7); c.fill();
c.fillStyle = "#1b3fa0";
c.beginPath(); c.roundRect(115.4, 12.7, 35.3, 18.6, [2.5, 7.5, 12.25, 17.75]); c.fill();
c.fillStyle = "rgba(0, 0, 0, 0.6)";
c.beginPath(); c.roundRect(20.5, 70.25, 30.5, 30.5, 30.5); c.fill();
c.fillStyle = "rgba(240, 180, 0, 0.65)";
c.beginPath(); c.roundRect(60.3, 72.6, 40.4, 25.2, 0.6); c.fill();
c.fillStyle = "#440044";
c.beginPath(); c.roundRect(115.75, 70.5, 60.4, 50.25, 8.9); c.fill();
c.fillStyle = "rgba(255, 255, 255, 0.5)";
c.beginPath(); c.roundRect(118.25, 73.25, 55.4, 44.75, 6.4); c.fill();
`,
  glow: `
// Tempo's grain canvas: per brightness bucket, one path of many circles filled once.
const grains = [];
for (let i = 0; i < 900; i++) {
  const a = i * 0.47, r = Math.sqrt(i / 900) * 52;
  grains.push({ x: 100.5 + Math.cos(a) * r * 1.35, y: 75.4 + Math.sin(a) * r * 0.9, s: 0.6 + (i % 7) * 0.35, b: i % 3 });
}
const inks = ["rgba(255, 59, 36, 0.16)", "rgba(255, 59, 36, 0.30)", "rgba(255, 59, 36, 0.55)"];
for (let b = 0; b < 3; b++) {
  c.fillStyle = inks[b];
  c.beginPath();
  for (const g of grains) if (g.b === b) { c.moveTo(g.x + g.s, g.y); c.arc(g.x, g.y, g.s, 0, TAU); }
  c.fill();
}
// The glow: a 2x2 rect under a scale, filled with a radial gradient built once.
const glow = c.createRadialGradient(0, 0, 0, 0, 0, 1);
glow.addColorStop(0, "rgba(255, 80, 40, 0.85)");
glow.addColorStop(0.35, "rgba(255, 50, 30, 0.35)");
glow.addColorStop(1, "rgba(255, 40, 20, 0)");
c.save();
c.translate(100.5, 75.25);
c.scale(62.5, 62.5);
c.fillStyle = glow;
c.fillRect(-1, -1, 2, 2);
c.restore();
// The edge dot.
c.fillStyle = "rgba(255, 59, 36, 0.9)";
c.beginPath(); c.arc(100.4, 75.6, 5.3, 0, TAU); c.fill();
`,
  overlap: `
// Same colour, translucent, many circles in one path: one fill, so no double blending.
c.fillStyle = "rgba(30, 90, 200, 0.4)";
c.beginPath();
for (let i = 0; i < 12; i++) { c.moveTo(25.4 + i * 6.4 + 14.5, 40.25); c.arc(25.4 + i * 6.4, 40.25, 14.5, 0, TAU); }
c.fill();
// The same circles as separate fills: they stack.
for (let i = 0; i < 12; i++) {
  c.fillStyle = "rgba(30, 90, 200, 0.4)";
  c.beginPath(); c.arc(25.4 + i * 6.4, 100.25, 14.5, 0, TAU); c.fill();
}
`,
  saverestore: `
c.save();
c.translate(40.5, 40.25);
c.rotate(0.35);
c.fillStyle = "rgba(200, 20, 40, 0.7)";
c.fillRect(-20.5, -12.25, 40.5, 24.75);
c.save();
c.globalAlpha = 0.5;
c.scale(1.5, 0.75);
c.fillStyle = "#0a50c0";
c.beginPath(); c.arc(10.25, 10.5, 12.4, 0, TAU); c.fill();
c.restore();
c.fillStyle = "#1a7a30";
c.beginPath(); c.arc(20.5, 20.25, 6.3, 0, TAU); c.fill();
c.restore();
c.save();
c.translate(120.5, 100.25);
c.rotate(-0.2);
c.save();
c.globalAlpha = 0.35;
c.fillStyle = "#000000";
c.fillRect(0.25, 0.5, 60.4, 30.75);
c.restore();
c.fillStyle = "rgba(255, 160, 0, 0.8)";
c.fillRect(10.3, 10.4, 30.5, 20.25);
c.restore();
c.fillStyle = "#8800aa";
c.fillRect(5.25, 130.5, 20.5, 10.25);
`,
  clip: `
c.save();
c.beginPath(); c.rect(10.25, 10.5, 60.4, 40.75); c.clip();
c.fillStyle = "#d02020";
c.fillRect(0, 0, 200, 150);
c.fillStyle = "rgba(0, 80, 200, 0.6)";
c.beginPath(); c.arc(40.5, 30.25, 25.4, 0, TAU); c.fill();
c.restore();
c.save();
c.beginPath(); c.arc(130.5, 40.25, 35.4, 0, TAU); c.clip();
c.fillStyle = "#20a040";
c.fillRect(80.25, 5.5, 120.3, 80.75);
c.save();
c.beginPath(); c.ellipse(150.25, 55.5, 20.5, 10.3, 0.4, 0, TAU); c.clip();
c.fillStyle = "rgba(255, 200, 0, 0.8)";
c.fillRect(100.5, 20.75, 100.4, 70.25);
c.restore();
c.restore();
c.save();
c.beginPath(); c.rect(20.5, 90.25, 80.3, 50.4); c.clip();
c.beginPath(); c.rect(60.25, 70.5, 80.4, 90.3); c.clip();
c.fillStyle = "rgba(80, 0, 120, 0.65)";
c.fillRect(0, 0, 200, 150);
c.restore();
`,
  transforms: `
c.fillStyle = "#c02040";
c.save(); c.translate(30.25, 30.5); c.rotate(0.5); c.fillRect(-15.5, -10.25, 31.5, 20.4); c.restore();
c.fillStyle = "rgba(0, 90, 200, 0.6)";
c.save(); c.translate(90.4, 35.25); c.scale(2.25, 0.75); c.beginPath(); c.arc(0, 0, 14.5, 0, TAU); c.fill(); c.restore();
c.fillStyle = "rgba(20, 140, 60, 0.7)";
c.save(); c.translate(150.5, 40.25); c.rotate(-0.25); c.scale(1.25, 1.25); c.beginPath(); c.roundRect(-25.4, -12.5, 50.5, 25.4, 6.3); c.fill(); c.restore();
c.fillStyle = "#101040";
c.save(); c.translate(40.5, 105.25); c.rotate(0.15); c.scale(1.7, 0.9); c.beginPath(); c.arc(0, 0, 22.4, 0, TAU); c.fill(); c.restore();
c.fillStyle = "rgba(255, 120, 0, 0.65)";
c.save(); c.translate(120.25, 105.5); c.scale(0.8, 1.9); c.fillRect(-20.5, -20.25, 41.4, 40.5); c.restore();
c.fillStyle = "#330033";
c.save(); c.translate(170.5, 110.25); c.rotate(0.9); c.fillRect(-2.2, -18.4, 4.5, 36.5); c.restore();
`,
  gradients: `
const lg = c.createLinearGradient(10.25, 0, 90.75, 0);
lg.addColorStop(0, "#ff0000"); lg.addColorStop(1, "#0000ff");
c.fillStyle = lg;
c.fillRect(10.25, 10.5, 80.4, 50.25);
const rg = c.createRadialGradient(150.5, 35.25, 2.5, 150.5, 35.25, 35.4);
rg.addColorStop(0, "#ffffff"); rg.addColorStop(1, "rgba(0, 0, 0, 0)");
c.fillStyle = rg;
c.fillRect(110.4, 0, 80.3, 75.5);
const rg2 = c.createRadialGradient(60.25, 110.5, 1, 60.25, 110.5, 30.4);
rg2.addColorStop(0, "rgba(255, 59, 36, 0.9)"); rg2.addColorStop(1, "rgba(255, 59, 36, 0)");
c.fillStyle = rg2;
c.beginPath(); c.arc(60.25, 110.5, 30.4, 0, TAU); c.fill();
c.fillStyle = "rgba(0, 120, 90, 0.5)";
c.save(); c.translate(150.5, 110.5); c.rotate(0.3);
c.fillRect(-30.5, -20.25, 60.4, 40.5); c.restore();
`,
};

function html(name: string, inline: boolean): string {
  const script = inline
    ? `<script>\n${prelude(false)}\n${PAGES[name]}\n</script>`
    : `<script src="app.ts"></script>`;
  return `<!doctype html>
<html><head><meta charset="utf-8"><meta name="native-window" content="width=${W}, height=${H}">
<style>html, body { margin: 0; width: ${W}px; height: ${H}px; background: #ffffff; }
canvas { display: block; width: ${W}px; height: ${H}px; }</style>
</head><body><canvas id="c" width="${W * 2}" height="${H * 2}"></canvas>
${script}
</body></html>`;
}

/** Writes the native app directories: <out>/<name>/{index.html,app.ts}. */
export function writeApps(out: string): void {
  for (const name of Object.keys(PAGES)) {
    const dir = join(out, name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "index.html"), html(name, false));
    writeFileSync(join(dir, "app.ts"), `${prelude(true)}\n${PAGES[name]}\n`);
  }
}

/** Writes the pages Chrome opens: <out>/chrome/<name>.html. The screenshots in this directory
 *  were taken from them at 2x, and are what the parity test compares the app against. */
export function writeChromePages(out: string): void {
  const dir = join(out, "chrome");
  mkdirSync(dir, { recursive: true });
  for (const name of Object.keys(PAGES)) writeFileSync(join(dir, `${name}.html`), html(name, true));
}

export const SIZE = { width: W, height: H, scale: 2 };


