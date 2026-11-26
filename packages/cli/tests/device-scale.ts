// An ordinary window records no snapshot scale, so devicePixelRatio stays the window's backing
// scale; a headless run alone records (and uses) the snapshot scale.
//   npm test

import { SNAPSHOT_SCALE, chosenRasterScale, recordedSnapshotScale } from "../runtime/device-scale.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

check("an ordinary window records no snapshot scale", recordedSnapshotScale(false) === 0);
check("a headless run records the snapshot scale", recordedSnapshotScale(true) === SNAPSHOT_SCALE);
check("a 1x ordinary window reports 1", chosenRasterScale(1, recordedSnapshotScale(false), false) === 1);
check("a 2x window keeps its backing scale", chosenRasterScale(2, recordedSnapshotScale(false), false) === 2);
check("a headless run draws at the snapshot scale", chosenRasterScale(1, recordedSnapshotScale(true), true) === SNAPSHOT_SCALE);
check("a headless run without a recorded scale still uses it", chosenRasterScale(1, 0, true) === SNAPSHOT_SCALE);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
