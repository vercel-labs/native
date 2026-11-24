// The perspective math a 3D box projects with: d/(d - z) scaling about perspective-origin, and
// the w <= 0 case where the plane has reached the viewer and nothing of it is drawn.
//   npm test

import { compileValue } from "../shared/css/declarations.ts";
import { listMatrix4, mulMatrix4, perspectiveMatrix, projectQuad4, transformRows, translation4 } from "../shared/css/transforms.ts";

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}
const near = (a: number, b: number): boolean => Math.abs(a - b) < 1e-9;

// perspective(100px) with the vantage point at (50, 50), over a box moved 50px towards the
// viewer: every point scales by d/(d - z) = 2 about the origin.
const p = perspectiveMatrix(100, 50, 50);
const q = projectQuad4(mulMatrix4(translation4(0, 0, 50), p), 100, 100);
check("a box 50px nearer with d=100 doubles about the origin",
  q !== null && near(q[0], -50) && near(q[1], -50) && near(q[2], 150) && near(q[3], -50) &&
  near(q[4], 150) && near(q[5], 150) && near(q[6], -50) && near(q[7], 150),
  JSON.stringify(q));

// The same box at z = 1 with d = 3 scales by 3/2, the perspective-translateZ-positive case.
const p3 = perspectiveMatrix(3, 0, 0);
const q3 = projectQuad4(mulMatrix4(translation4(0, 0, 1), p3), 100, 100);
check("d/(d - z) is the scale", q3 !== null && near(q3[2], 150) && near(q3[5], 150), JSON.stringify(q3));

// Moving away shrinks it.
const away = projectQuad4(mulMatrix4(translation4(0, 0, -50), p), 100, 100);
check("a box 50px further keeps the origin and shrinks", away !== null && near(away[0], 50 - 50 / 1.5) &&
  near(away[2], 50 + 50 / 1.5), JSON.stringify(away));

// A plane that reaches the viewer has w <= 0 and is not drawn.
check("a box at the perspective distance vanishes",
  projectQuad4(mulMatrix4(translation4(0, 0, 100), p), 100, 100) === null);
check("a box past it vanishes too",
  projectQuad4(mulMatrix4(translation4(0, 0, 120), p), 100, 100) === null);

// No perspective: the box is where it was.
const flat = projectQuad4(translation4(0, 0, 0), 100, 100);
check("an identity matrix leaves the box", flat !== null && near(flat[2], 100) && near(flat[5], 100), JSON.stringify(flat));

// The perspective() function takes a non-negative length; a distance under 1px draws as 1px and
// the computed value keeps what was written. A negative distance is invalid.
const ctx = { w: 100, h: 100, fontSize: 16, lh: 19, rem: 16, ex: 8, ch: 8, viewportW: 800, viewportH: 600, cqw: 0, cqh: 0 };
const set = (text: string): any[] => { const out: any[] = []; compileValue("transform", text, out); return out; };
const zero = set("perspective(0)");
const zeroRow = zero.length > 0 ? transformRows.row(zero[0].v) : null;
const zeroM = zeroRow ? listMatrix4(zeroRow, ctx) : null;
check("perspective(0) draws at 1px", zeroM !== null && near(zeroM[11], -1), JSON.stringify(zeroM && zeroM[11]));
const half = set("perspective(0.5px)");
const halfRow = half.length > 0 ? transformRows.row(half[0].v) : null;
const halfM = halfRow ? listMatrix4(halfRow, ctx) : null;
check("perspective(0.5px) draws at 1px too", halfM !== null && near(halfM[11], -1), JSON.stringify(halfM && halfM[11]));
check("a negative perspective distance is invalid", set("perspective(-1px)").length === 0);

console.log(failed === 0 ? "\nall passed" : `\n${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
