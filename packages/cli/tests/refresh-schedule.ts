// The display-refresh schedule is used only when no rate was forced and the window isn't GL or on
// the free-running timer.
//   npm test

import { usesDisplaySchedule } from "../runtime/app/refresh.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

// The old condition (`!frameTimer && glWindow === 0`) let the display link override a forced
// rate; the fix adds the forced-rate guard.
check("a forced rate keeps the frame period", usesDisplaySchedule(120, false, 0) === false);
check("an auto-rate non-GL window waits for the display", usesDisplaySchedule(0, false, 0) === true);
check("a GL window keeps the frame period", usesDisplaySchedule(0, false, 1) === false);
check("NATIVE_FRAME_TIMER keeps the frame period", usesDisplaySchedule(0, true, 0) === false);
check("a forced rate with the timer keeps the frame period", usesDisplaySchedule(30, true, 0) === false);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
