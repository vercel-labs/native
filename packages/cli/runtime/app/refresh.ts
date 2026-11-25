// Whether the frame loop waits for the display's refresh or runs on its own frame period.

/**
 * A rate asked for by hand (NATIVE_REFRESH_HZ), the free-running timer, and a GL window (whose
 * present already waits for the display) all keep the period schedule. A positive forced rate
 * must win even when the display link reports a future refresh target.
 */
export function usesDisplaySchedule(forced: number, frameTimer: boolean, glWindow: number): boolean {
  return forced <= 0 && !frameTimer && glWindow === 0;
}
