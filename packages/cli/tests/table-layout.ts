// Table layout arithmetic: a specified row height under collapsed borders, a fixed-layout table
// that its columns widen, the excess width of a fixed-layout table, and a floated table part.
//   npm test

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { decodePng } from "./png.ts";

const PAGE = `<!doctype html>
<html><head><meta name="native-window" content="width=800, height=800"><style>
body { margin: 0; font: 16px/1 monospace; }
/* A row's 96px height is its border box: from the centre of the 96px line above it to the centre
   of the line below, so the table is 144px tall rather than 192px. */
#case1 { position: absolute; left: 0; top: 0; }
#case1 table { border-collapse: collapse; background-color: #ffa500; }
#case1 tr { height: 96px; }
#case1 td { border-top: 96px solid #ffa500; padding: 0; width: 50px; }
/* A fixed-layout table is at least as wide as its column plus the border spacing: 16 + 42 + 42. */
#case2 { position: absolute; left: 200px; top: 0; }
#case2 table { table-layout: fixed; width: 9px; border-spacing: 42px 0; background-color: #eeeeee; }
#case2 td { width: 16px; height: 10px; padding: 0; background-color: #008000; }
/* A floated table-row-group is a block, and its cells get an anonymous table around them. */
#case3 { position: absolute; left: 0; top: 200px; width: 400px; }
#case3 table { width: 100%; }
#case3 .rowgroup { display: table-row-group; float: right; width: 96px; height: 96px; background-color: #0000ff; }
/* With no auto columns the extra 240px goes to the 20px and 10px columns in proportion; the 10%
   column keeps its 30px. */
#case4 { position: absolute; left: 0; top: 400px; }
#case4 table { table-layout: fixed; width: 300px; border-collapse: collapse; }
#case4 td { padding: 0; height: 20px; }
#case4 td:nth-child(1) { width: 20px; background-color: #008000; }
#case4 td:nth-child(2) { width: 10px; background-color: #0000ff; }
#case4 td:nth-child(3) { width: 10%; background-color: #ff0000; }
/* An inline-table's baseline is its first row's, so the text span beside it shares that
   baseline. The float's red background is hidden only when the span and the two rows cover
   its 60x100 box. */
#case5 { position: absolute; left: 500px; top: 480px; }
#case5 .line { float: left; font-size: 0; background-color: #ff0000; }
#case5 span { font: 50px/1 monospace; background-color: #008000; color: #008000; }
/* The two 50% inline-blocks don't fit on one line of the anonymous cell the table wraps
   them in, so the cell is two lines tall: the table's purple covers both. */
#case6 { position: absolute; left: 560px; top: 300px; }
#case6 table { width: 200px; border-spacing: 0; background-color: #800080; border: 1px solid #008000; }
#case6 .half { display: inline-block; width: 50%; background-color: #0000ff; color: #0000ff; }
#case6 .half + .half { background-color: #ffff00; color: #ffff00; }
/* The margins inside the anonymous cells collapse through the empty blocks, so the two rows above
   the empty one are 50px each and the table fills its 100px height with green. */
#case7 { position: absolute; left: 300px; top: 460px; }
#case7 table { height: 100px; border-spacing: 0; background-color: #ff0000; }
#case7 .r { display: table-row; background-color: #008000; }
#case7 .m { margin: 50px 0; }
#case7 .w { width: 100px; }
/* A collapsing cell keeps half of each grid line, so its padding box is inset by 10 rather than
   by its declared 20px border: the inset shadow's 10px frame starts there. */
#case8 { position: absolute; left: 100px; top: 60px; }
#case8 table { border-collapse: collapse; }
#case8 td { border: 20px solid #0000ff; background-color: #ff0000; padding: 0;
  box-shadow: inset 0 0 0 10px #008000; }
#case8 div { width: 60px; height: 60px; }
/* Only the first header group is the table's header: it moves above the body, while the second
   stays where it is, below the body's row. */
#case9 { position: absolute; left: 400px; top: 20px; }
#case9 table { border-collapse: collapse; }
#case9 td { width: 40px; height: 20px; }
#case9 .a { background-color: #ff0000; }
#case9 .b { background-color: #0000ff; }
#case9 .c { background-color: #ffff00; }
/* The 100px the spanning cell asks for goes to the column the table sizes: the 5px column
   stays 5px, so the green cell starts at the red box's left edge and covers it exactly. */
#case10 { position: absolute; left: 700px; top: 0; width: 100px; height: 100px;
  background-color: #ff0000; }
#case10 table { width: 110px; margin-left: -5px; border-spacing: 0; }
#case10 td { padding: 0; }
#case10 .g { background-color: #008000; }
#case10 .h { height: 100px; }
/* The 130px the table has to spare goes to the auto column, so the 20px column keeps its
   width and the blue one takes the rest. */
#case11 { position: absolute; left: 600px; top: 140px; }
#case11 table { width: 150px; border-spacing: 0; }
#case11 td { padding: 0; height: 20px; }
#case11 .a { width: 20px; background-color: #008000; }
#case11 .b { background-color: #0000ff; }
/* An out-of-line offset reaching past the containing block gives the table no extra room: it is
   still only as wide as the block, so it covers that block's 100px and no more. */
#case12 { position: absolute; left: 0; top: 480px; }
#case12 .cb { position: relative; width: 100px; height: 100px; margin-left: 100px; }
#case12 table { position: absolute; left: -100px; height: 100px; border-spacing: 0;
  color: transparent; background-color: #008000; }
/* Under collapsed borders the table's box runs out to the outer edges of its grid lines, so the
   caption's border box is that wide too. */
#case13 { position: absolute; left: 400px; top: 480px; }
#case13 table { border-collapse: collapse; }
#case13 caption { border: 4px solid #ffa500; }
#case13 td { width: 50px; height: 20px; padding: 0; border: 4px solid #0000ff; }
/* A header group's only child is not a table row, so the table wraps it in an anonymous row:
   the group still gets a box, and its background fills the table's 100px height. */
#case14 { position: absolute; left: 400px; top: 530px; }
#case14 table { width: 100px; height: 60px; border-spacing: 0; }
#case14 .g { display: table-header-group; background-color: #008000; height: 20px; }
/* A <col> width attribute sizes its grid column: 27 + 100 + 27 of a fixed-layout 154px table. */
#case15 { position: absolute; left: 0; top: 620px; }
#case15 table { table-layout: fixed; width: 154px; border-spacing: 0; }
#case15 td { padding: 0; height: 20px; }
#case15 .a { background-color: #ff0000; }
#case15 .b { background-color: #008000; }
#case15 .c { background-color: #0000ff; }
/* A cell's 20px height is a minimum: its 60px content stretches the row. */
#case16 { position: absolute; left: 400px; top: 620px; }
#case16 table { border-spacing: 0; }
#case16 td { padding: 0; height: 20px; }
#case16 .d { background-color: #ff0000; }
#case16 .e { background-color: #008000; }
/* A child's percentage height resolves against nothing while the cell's content is measured, as
   Chrome's intrinsic pass does, so it can't stretch the row it is a percentage of. */
#case17 { position: absolute; left: 0; top: 720px; }
#case17 table { border-spacing: 0; width: 100px; }
#case17 td { padding: 0; height: 40px; font: 10px/1 monospace; background-color: #ff0000; }
#case17 td div { display: inline-block; height: 100%; width: 20px; background-color: #0000ff; }
</style></head><body>
<div id="case1"><table><tr><td></td></tr></table></div>
<div id="case2"><table><tr><td></td></tr></table></div>
<div id="case3"><table><div class="rowgroup"></div></table></div>
<div id="case4"><table><tr><td></td><td></td><td></td></tr></table></div>
<div id="case5"><div class="line"><span>X</span><span style="display: inline-table"><span
  style="display: table-row">X</span><span style="display: table-row">X</span></span></div></div>
<div id="case6"><table><div class="half">A</div> <div class="half">B</div></table></div>
<div id="case7"><table><div class="r"><div class="w m"><div class="m"></div></div>
  <div class="m"></div></div><div class="r"><div class="m"></div></div><div class="r"></div></table></div>
<div id="case8"><table><tr><td><div></div></td></tr></table></div>
<div id="case9"><table><tbody class="a"><tr><td></td></tr></tbody>
  <thead class="b"><tr><td></td></tr></thead><thead class="c"><tr><td></td></tr></thead></table></div>
<div id="case10"><table><tr><td colspan="2" style="width: 100px"></td><td colspan="2"></td></tr>
  <tr><td style="width: 5px"></td><td colspan="2" class="g"><div class="h"></div></td>
  <td style="width: 5px"></td></tr></table></div>
<div id="case11"><table><tr><td class="a"></td><td class="b"></td></tr></table></div>
<div id="case12"><div class="cb"><table><tr><td>X X X X X X X X X</td></tr></table></div></div>
<div id="case13"><table><caption></caption><tr><td></td></tr></table></div>
<div id="case14"><table><div class="g"><div></div></div></table></div>
<div id="case15"><table><col width="27"><col width="100"><col width="27">
  <tr><td class="a"></td><td class="b"></td><td class="c"></td></tr></table></div>
<div id="case16"><table><tr><td class="d"><div style="width: 20px; height: 60px"></div></td></tr>
  <tr><td class="e"></td></tr></table></div>
<div id="case17"><table><tr><td><div></div>x</td></tr></table></div>
</body></html>`;

const dir = mkdtempSync(join(tmpdir(), "native-table-layout-"));
writeFileSync(join(dir, "index.html"), PAGE);
const exe = join(dir, "app");
const build = spawnSync("node", ["compiler/cli.ts", "build", dir, "-o", exe], { encoding: "utf8" });
if (build.status !== 0) throw new Error(`build failed\n${build.stderr}`);
const png = join(dir, "out.png");
const run = spawnSync(exe, [], { encoding: "utf8", env: { ...process.env, NATIVE_SNAPSHOT: png } });
if (run.status !== 0) throw new Error(`render failed\n${run.stderr}`);

let failed = 0;
function check(name: string, ok: boolean, detail = ""): void {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || detail === "" ? "" : ` — ${detail}`}`);
}

const img = decodePng(png);
// The snapshot is two device pixels per CSS pixel.
const px = (x: number, y: number): number[] => {
  const o = (y * img.w + x) * 4;
  return [img.rgba[o], img.rgba[o + 1], img.rgba[o + 2]];
};
const near = (p: number[], c: number[]): boolean =>
  Math.abs(p[0] - c[0]) < 8 && Math.abs(p[1] - c[1]) < 8 && Math.abs(p[2] - c[2]) < 8;
const ORANGE = [0xff, 0xa5, 0x00];
const GRAY = [0xee, 0xee, 0xee];
const GREEN = [0x00, 0x80, 0x00];
const BLUE = [0x00, 0x00, 0xff];
const RED = [0xff, 0x00, 0x00];
const YELLOW = [0xff, 0xff, 0x00];
const PURPLE = [0x80, 0x00, 0x80];

/** The contiguous runs of `c` in device row `y`, as [start, end] pairs. */
function rowRuns(y: number, c: number[]): number[][] {
  const runs: number[][] = [];
  let start = -1;
  for (let x = 0; x <= img.w; x++) {
    const hit = x < img.w && near(px(x, y), c);
    if (hit && start < 0) start = x;
    if (!hit && start >= 0) {
      runs.push([start, x - 1]);
      start = -1;
    }
  }
  return runs;
}

/** The contiguous runs of `c` in device column `x`, as [start, end] pairs. */
function colRuns(x: number, c: number[]): number[][] {
  const runs: number[][] = [];
  let start = -1;
  for (let y = 0; y <= img.h; y++) {
    const hit = y < img.h && near(px(x, y), c);
    if (hit && start < 0) start = y;
    if (!hit && start >= 0) {
      runs.push([start, y - 1]);
      start = -1;
    }
  }
  return runs;
}

/** The one run of `c` in `runs`, as [start, end], or null when there isn't exactly one. */
function only(runs: number[][]): number[] | null {
  return runs.length === 1 ? runs[0] : null;
}
/** From the first run's start to the last run's end. */
function span(runs: number[][]): number[] | null {
  return runs.length === 0 ? null : [runs[0][0], runs[runs.length - 1][1]];
}
const height = (r: number[] | null): number => (r === null ? -1 : r[1] - r[0] + 1);

{
  // 144 CSS px, from the top of the 96px line to the bottom of the 48px half below the row.
  const r = only(colRuns(20, ORANGE));
  check("a specified row height is its border box under collapsed borders", height(r) === 288, `height ${height(r)}`);
}

{
  // 9px set, but 16 + 42 + 42 of column and spacing make it 100. The cell covers the middle of
  // the table, so the background shows on either side of it.
  const r = span(rowRuns(10, GRAY));
  const ok = r !== null && r[0] === 400 && r[1] === 599;
  check("declared columns widen a fixed-layout table", ok, r === null ? "no run" : `x ${r[0]}..${r[1]}`);
}

{
  // 96x96 at the right edge of the anonymous cell the fixup wraps it in. The cell is inset by
  // the table's 2px border-spacing, so the float covers x 302..398 and y 2..98 CSS.
  const r = only(rowRuns(500, BLUE));
  const ok = r !== null && r[0] === 604 && r[1] === 795;
  check("a floated table-row-group is a block at the right edge", ok,
    r === null ? `runs ${JSON.stringify(rowRuns(500, BLUE))}` : `x ${r[0]}..${r[1]}`);
  const v = only(colRuns(700, BLUE));
  check("it is 96px tall", height(v) === 192, `height ${height(v)}`);
}

{
  // The 240px of extra width goes 160/80 to the 20px and 10px columns: 180, 90, 30.
  const g = only(rowRuns(820, GREEN));
  const b = only(rowRuns(820, BLUE));
  const r = only(rowRuns(820, RED));
  const ok = g !== null && g[0] === 0 && g[1] === 359 && b !== null && b[0] === 360 && b[1] === 539 &&
    r !== null && r[0] === 540 && r[1] === 599;
  check("fixed layout shares its excess by the columns' widths", ok,
    `green ${JSON.stringify(g)} blue ${JSON.stringify(b)} red ${JSON.stringify(r)}`);
}

{
  // The span and the inline-table share one baseline, the table's first row's, so the table
  // runs from the float's top down its whole 100px. (The span's own background is its font box,
  // which reaches above the line and stops at the baseline, leaving the float's red below it.)
  const t = only(colRuns(1100, GREEN));
  const ok = t !== null && t[0] === 960 && height(t) === 200;
  check("an inline-table takes the line's baseline from its first row", ok,
    t === null ? `runs ${JSON.stringify(colRuns(1100, GREEN))}` : `y ${t[0]}..${t[1]}`);
  const red = only(colRuns(1010, RED));
  check("the line is as tall as the table, so the float is 100px", red !== null && red[0] === 1068 && red[1] === 1159,
    `red ${JSON.stringify(colRuns(1010, RED))}`);
}

{
  // The whitespace between the two 50% inline-blocks makes them wrap, so the anonymous cell the
  // table wraps them in is two 16px lines: the table's background runs down both, and its bottom
  // border sits below the second line rather than across it.
  const b = span(rowRuns(610, BLUE));
  const y = span(rowRuns(650, YELLOW));
  const ok = b !== null && b[0] === 1122 && b[1] === 1319 && y !== null && y[0] === 1122 && y[1] === 1319;
  check("wrapping inline-blocks in an anonymous cell take two lines", ok,
    `blue ${JSON.stringify(b)} yellow ${JSON.stringify(y)}`);
  const p = only(colRuns(1450, PURPLE));
  check("the table is as tall as both lines", p !== null && p[0] === 602 && p[1] === 665,
    `purple ${JSON.stringify(colRuns(1450, PURPLE))}`);
  const g = rowRuns(666, GREEN);
  check("its bottom border is below the second line", g.length === 1 && g[0][0] === 1120 && g[0][1] === 1519,
    `green ${JSON.stringify(g)}`);
}

{
  // The margins in the anonymous cells collapse through the empty blocks, so the first two rows
  // are 50px each, the table fills its 100px height with green, and its red background shows
  // nowhere.
  // Case 5's green span is in the same row, so look for this table's run rather than the only one.
  const g = rowRuns(960, GREEN).find((r) => r[0] === 600 && r[1] === 799) ?? null;
  const ok = g !== null;
  check("margins collapse through an anonymous cell's empty blocks", ok,
    `green ${JSON.stringify(rowRuns(960, GREEN))}`);
  const v = only(colRuns(700, GREEN));
  check("the two rows fill the table's 100px height", v !== null && v[0] === 920 && height(v) === 200,
    `green ${JSON.stringify(colRuns(700, GREEN))}`);
  const red = rowRuns(960, RED);
  check("the table's background shows nowhere in it", red.length === 0, `red ${JSON.stringify(red)}`);
}

{
  // The 60x60 padding box inside the cell's half of each 20px grid line, with the shadow's frame
  // on it: blue grid lines 200..239 and 360..399, green 240..259 and 340..359, red between.
  const g = rowRuns(220, GREEN);
  const ok = g.length === 2 && g[0][0] === 240 && g[0][1] === 259 && g[1][0] === 340 && g[1][1] === 359;
  check("an inset shadow starts at a collapsing cell's padding box", ok, `green ${JSON.stringify(g)}`);
  const b = rowRuns(220, BLUE);
  const bok = b.length === 2 && b[0][0] === 200 && b[0][1] === 239 && b[1][0] === 360 && b[1][1] === 399;
  check("the grid lines cover the cell's outer halves", bok, `blue ${JSON.stringify(b)}`);
  // Case 4's green is further down the same column.
  const v = colRuns(300, GREEN).filter((r) => r[0] < 600);
  const vok = v.length === 2 && v[0][0] === 160 && v[0][1] === 179 && v[1][0] === 260 && v[1][1] === 279;
  check("the shadow's frame runs down both sides of the padding box", vok, `green ${JSON.stringify(v)}`);
}

{
  // The header group's row goes first (blue), the body's row next (red), and the second header
  // group keeps its place after it (yellow).
  // Case 13's blue grid lines are in this column too, further down.
  const b = only(colRuns(820, BLUE).filter((run) => run[0] < 600));
  const r = only(colRuns(820, RED).filter((run) => run[0] < 600));
  const y = only(colRuns(820, YELLOW));
  const ok = b !== null && b[0] === 40 && b[1] === 83 && r !== null && r[0] === 84 && r[1] === 127 &&
    y !== null && y[0] === 128 && y[1] === 171;
  check("only the first header group moves to the top", ok,
    `blue ${JSON.stringify(b)} red ${JSON.stringify(r)} yellow ${JSON.stringify(y)}`);
}

{
  // The table is 5/95/5/5 wide: the spanning cell's 100px widens the auto column, not the 5px
  // one, so green starts at the red box's left edge and covers all 100px of it.
  const g = only(rowRuns(100, GREEN));
  const ok = g !== null && g[0] === 1400 && g[1] === 1599;
  check("a spanning cell's deficit goes to the auto columns", ok, `green ${JSON.stringify(g)}`);
  // Case 9's red row is on the same row, so look only at this table's stretch of it.
  const red = rowRuns(100, RED).filter((r) => r[0] >= 1400 && r[1] <= 1599);
  check("the box it covers shows no red", red.length === 0, `red ${JSON.stringify(red)}`);
}

{
  // With 150px to fill and 20px of preferred width, the 130px of spare room goes to the auto
  // column: green stays 20px and blue takes 130.
  const g = rowRuns(300, GREEN).find((r) => r[0] >= 1200 && r[1] <= 1499) ?? null;
  const b = rowRuns(300, BLUE).find((r) => r[0] >= 1200 && r[1] <= 1499) ?? null;
  const ok = g !== null && g[0] === 1200 && g[1] === 1239 && b !== null && b[0] === 1240 && b[1] === 1499;
  check("a table's spare width goes to its auto columns", ok,
    `green ${JSON.stringify(g)} blue ${JSON.stringify(b)}`);
}

{
  // The table sits at the containing block's left edge (left: -100 of a block at 100), and its
  // available width is the block's 100px, not the 200 the offset would allow: it covers the
  // block exactly and doesn't reach past it.
  const g = rowRuns(1060, GREEN).find((r) => r[1] < 400) ?? null;
  const ok = g !== null && g[0] === 0 && g[1] === 199;
  check("an abspos table is no wider than its containing block", ok,
    `green ${JSON.stringify(rowRuns(1060, GREEN))}`);
  const v = colRuns(50, GREEN).filter((r) => r[0] >= 960);
  check("it is as tall as its height", v.length === 1 && v[0][0] === 960 && v[0][1] === 1159,
    `green ${JSON.stringify(colRuns(50, GREEN))}`);
}

{
  // The caption's 4px border spans the table's box, from the outer edge of the cell's left grid
  // line to the outer edge of its right one (x 800..915 device): the table's content box is
  // narrower than that by half of each line.
  const c = only(rowRuns(966, ORANGE));
  const ok = c !== null && c[0] === 800 && c[1] === 915;
  check("a caption spans the table's collapsed border box", ok, `orange ${JSON.stringify(c)}`);
  const b = rowRuns(990, BLUE);
  const bok = b.length === 2 && b[0][0] === 800 && b[0][1] === 807 && b[1][0] === 908 && b[1][1] === 915;
  check("the cell's grid lines end where the caption does", bok, `blue ${JSON.stringify(b)}`);
}

{
  // The group's 100x60 box at 400,530: green across the table's whole width, and the table's
  // 60px height rather than the 20px the group asks for.
  const g = rowRuns(1120, GREEN).find((r) => r[0] >= 800 && r[1] <= 999) ?? null;
  const ok = g !== null && g[0] === 800 && g[1] === 999;
  check("a row group with anonymous rows paints its background", ok,
    `green ${JSON.stringify(rowRuns(1120, GREEN))}`);
  const v = only(colRuns(900, GREEN));
  check("it is as tall as the rows the table generated", v !== null && v[0] === 1060 && v[1] === 1179,
    `green ${JSON.stringify(colRuns(900, GREEN))}`);
}

{
  // The width attributes give the columns 27, 100 and 27 of the table's 154px.
  const r = rowRuns(1260, RED).filter((x) => x[0] < 400);
  const g = rowRuns(1260, GREEN).filter((x) => x[0] < 400);
  const b = rowRuns(1260, BLUE).filter((x) => x[0] < 400);
  const ok = r.length === 1 && r[0][0] === 0 && r[0][1] === 53 &&
    g.length === 1 && g[0][0] === 54 && g[0][1] === 253 &&
    b.length === 1 && b[0][0] === 254 && b[0][1] === 307;
  check("a <col> width attribute sizes its column", ok,
    `red ${JSON.stringify(r)} green ${JSON.stringify(g)} blue ${JSON.stringify(b)}`);
}

{
  // The first row's 60px content makes it 60px tall, so the second row's 20px starts below it.
  const d = colRuns(820, RED).filter((x) => x[0] >= 1200);
  const e = colRuns(820, GREEN).filter((x) => x[0] >= 1200);
  const ok = d.length === 1 && d[0][0] === 1240 && d[0][1] === 1359 &&
    e.length === 1 && e[0][0] === 1360 && e[0][1] === 1399;
  check("a cell's height is a minimum, not a fixed size", ok,
    `red ${JSON.stringify(d)} green ${JSON.stringify(e)}`);
}

{
  // The percentage-height child fills the cell's own 40px rather than stretching the row to a
  // height the child measured itself against: the cell stays 1440..1519 and so does the child.
  const r = only(colRuns(120, RED).filter((x) => x[0] >= 1400));
  const b = only(colRuns(20, BLUE).filter((x) => x[0] >= 1400));
  const ok = r !== null && r[0] === 1440 && r[1] === 1519 &&
    b !== null && b[0] === 1440 && b[1] === 1519;
  check("a percentage-height child doesn't stretch the cell", ok,
    `red ${JSON.stringify(colRuns(120, RED))} blue ${JSON.stringify(colRuns(20, BLUE))}`);
}

if (failed > 0) {
  console.log(`\n${failed} failed`);
  process.exit(1);
}
console.log("\nall passed");
