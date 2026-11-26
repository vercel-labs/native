// The device scale a run draws at, kept free of the host so a test can exercise it.

/** The scale a headless run draws its snapshot at. */
export const SNAPSHOT_SCALE = 2;

/** The snapshot scale to record for a run: the snapshot scale when headless, else none (0). */
export function recordedSnapshotScale(headless: boolean): number {
  return headless ? SNAPSHOT_SCALE : 0;
}

/** Device pixels per CSS px: the window's backing scale, a recorded snapshot scale, or the
 *  snapshot scale a headless run's environment names. */
export function chosenRasterScale(backing: number, recorded: number, headless: boolean): number {
  if (backing > 1) return backing;
  if (recorded > 1) return recorded;
  if (headless) return SNAPSHOT_SCALE;
  return backing >= 1 ? backing : 1;
}
