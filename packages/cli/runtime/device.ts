// The device scale vector content rasterizes at.
//
// A headless run paints a display list in CSS px and snapshots it at a chosen scale. A bitmap
// rasterized at that scale lands on whole device pixels; one rasterized at 1 and upscaled is soft,
// with its edges bleeding a pixel wider. Only the rasters move: layout keeps hostBackingScale (see
// fontDeviceMetrics in style.ts), which is 1 in a headless run, so device-pixel rounding of line
// boxes and snapped boxes stays as it was.

import { hostBackingScale } from "./host.ts";

/** The scale a headless snapshot draws at, or 0 before one is known. */
let snapshotScale = 0;

/** Records the scale headless snapshots draw at, so their vector content rasterizes at it. */
export function setSnapshotScale(scale: number): void {
  snapshotScale = scale;
}

/**
 * The number of device pixels per CSS px the picture is drawn at: a window's backing scale, or the
 * scale a headless snapshot renders at. A canvas element is not sized by this: its bitmap is its
 * own width and height in CSS px, as on the web, and the browser enlarges it too.
 */
export function rasterScale(): number {
  const backing = hostBackingScale();
  if (backing > 1) return backing;
  return snapshotScale > 1 ? snapshotScale : backing >= 1 ? backing : 1;
}
