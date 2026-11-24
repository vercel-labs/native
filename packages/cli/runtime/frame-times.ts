// Per-stage frame timings, for the frame benchmarks and the dev inspector: with
// NATIVE_FRAME_TIMES set, every frame prints one line on stderr with the time its stages took.
// Off by default, and cheap when off: each stage tests one boolean before it reads the clock.

import { incremental } from "./invalidation.ts";
import { layoutCounts } from "./layout/incremental.ts";
import { hostTextShapeTime } from "./host.ts";

/** One frame's stage times, as the inspector's frame panel lists them. */
export interface FrameSample {
  frame: number;
  style: number;
  anim: number;
  layout: number;
  paint: number;
  /** The layers the frame painted, as the compositor counted them. */
  layers: number;
  total: number;
  /** The part of the frame the host spent shaping text, which layout waits on. */
  shape: number;
  /** Nodes computeStyles visited this frame. */
  styled: number;
  /** layoutBox calls that laid a box out. */
  laidOut: number;
  /** Boxes the paint walk visited. */
  painted: number;
  /** Whether the frame painted only damaged regions, and how many there were. */
  damaged: boolean;
  damageRects: number;
  /** The area the frame's damage covered, in CSS px². */
  damageArea: number;
  damageReason: string;
}

/**
 * The current frame's stage times in milliseconds. `style`, animations and layout are filled in
 * as the style-and-layout flush runs them; `paint` is the paint walk, host calls included; and
 * `total` is the whole frame, from the flush to the accessibility update.
 */
export const frameTimes = {
  on: false,
  print: false,
  style: 0,
  anim: 0,
  layout: 0,
  shape: 0,
  paint: 0,
  total: 0,
  layers: 0,
  styled: 0,
  laidOut: 0,
  painted: 0,
  damaged: false,
  damageRects: 0,
  damageArea: 0,
  damageReason: "start",
  frames: 0,
  /** The most recent frames, oldest first: the inspector's frame panel reads these. */
  history: [] as FrameSample[],
};

/** How many frames the inspector can look back on. */
const HISTORY = 240;

/** When the runtime started, so a frame line says how far into the run it was painted. */
const RUN_STARTED = performance.now();

const setting = process.env.NATIVE_FRAME_TIMES;
frameTimes.on = setting !== undefined && setting !== "" && setting !== "0";
frameTimes.print = frameTimes.on;

/** Starts measuring every frame without printing one, as the dev inspector asks. */
export function recordFrames(on: boolean): void {
  frameTimes.on = on;
}

/** The clock a stage is measured with; a zero when timings are off, so nothing reads it. */
export function frameClock(): number {
  return frameTimes.on ? performance.now() : 0;
}

/** Reports the frame on stderr once it is done, and starts the next frame's stages at zero. */
export function endFrame(started: number): void {
  if (!frameTimes.on) return;
  // The host's share of the frame since the last line: the text shaping layout waited on.
  frameTimes.shape = hostTextShapeTime();
  frameTimes.total = performance.now() - started;
  frameTimes.frames++;
  frameTimes.history.push({
    frame: frameTimes.frames,
    style: frameTimes.style,
    anim: frameTimes.anim,
    layout: frameTimes.layout,
    shape: frameTimes.shape,
    paint: frameTimes.paint,
    layers: frameTimes.layers,
    total: frameTimes.total,
    styled: frameTimes.styled,
    laidOut: frameTimes.laidOut,
    painted: frameTimes.painted,
    damaged: frameTimes.damaged,
    damageRects: frameTimes.damageRects,
    damageArea: frameTimes.damageArea,
    damageReason: frameTimes.damageReason,
  });
  if (frameTimes.history.length > HISTORY) frameTimes.history.shift();
  if (frameTimes.print) {
    console.error(`native: frame ${frameTimes.frames} t=${ms(performance.now() - RUN_STARTED)} style=${ms(frameTimes.style)} anim=${ms(frameTimes.anim)}` +
      ` layout=${ms(frameTimes.layout)} shape=${ms(frameTimes.shape)} paint=${ms(frameTimes.paint)}` +
      ` layers=${frameTimes.layers} total=${ms(frameTimes.total)}` +
      ` styled=${frameTimes.styled} laidOut=${frameTimes.laidOut} painted=${frameTimes.painted}` +
      (incremental.on ? ` cached=${layoutCounts.cached}` +
        (incremental.verify ? ` mismatches=${layoutCounts.mismatches}` : "") : ""));
  }
  if (process.env.NATIVE_DAMAGE_STATS !== undefined && process.env.NATIVE_DAMAGE_STATS !== "0") {
    console.error(`native: damage limited=${frameTimes.damaged ? 1 : 0} rects=${frameTimes.damageRects} reason=${frameTimes.damageReason} area=${Math.round(frameTimes.damageArea)}`);
  }
  frameTimes.style = 0;
  layoutCounts.laidOut = 0;
  layoutCounts.cached = 0;
  layoutCounts.mismatches = 0;
  frameTimes.anim = 0;
  frameTimes.layout = 0;
  frameTimes.paint = 0;
  frameTimes.styled = 0;
  frameTimes.laidOut = 0;
  frameTimes.painted = 0;
  frameTimes.damageArea = 0;
}

/** A number of milliseconds to two decimals; scriptc has no toFixed. */
function ms(v: number): string {
  return String(Math.round(v * 100) / 100);
}
