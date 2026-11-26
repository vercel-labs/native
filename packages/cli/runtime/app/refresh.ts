// Whether the frame loop waits for the display's refresh or runs on its own frame period.

/**
 * A rate asked for by hand (NATIVE_REFRESH_HZ), the free-running timer, and a GL window (whose
 * present already waits for the display) all keep the period schedule. A positive forced rate
 * must win even when the display link reports a future refresh target.
 */
export function usesDisplaySchedule(forced: number, frameTimer: boolean, glWindow: number): boolean {
  // An unset NATIVE_REFRESH_HZ is not a number, and a comparison against one is false either way
  // round: `forced > 0` reads a missing rate as none, which is what an absent setting means.
  return !(forced > 0) && !frameTimer && glWindow === 0;
}
