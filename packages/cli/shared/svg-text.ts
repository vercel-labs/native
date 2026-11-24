// SVG text: the pen running along a baseline, the runs a <text> draws, and `text-anchor`. Both
// painters lay text out here — the inline one, whose pieces come from the element's own subtree,
// and the SVG-image runtime, whose pieces come from the compiled program — so a text is drawn
// the same whether its <svg> is in the page or a file. Glyph widths come from the host, which the
// caller passes in as `measure`, since only the native side knows the font's metrics.

/** A stretch of text in a <text>: what it says, and the position and paint its element gives. */
export interface TextPiece {
  text: string;
  /** An absolute position for the piece — a <tspan>'s own x or y — or null to continue the pen. */
  x: number | null;
  y: number | null;
  /** A shift from that position, from dx and dy. */
  dx: number;
  dy: number;
  size: number;
  /** The packed font: family × 10000 + italic × 1000 + weight, as the host takes it. */
  font: number;
  fill: number;
  stroke: number;
  width: number;
  fillAlpha: number;
  strokeAlpha: number;
}

/** A piece laid out: where its baseline starts, and what to draw it with. */
export interface TextRun {
  text: string;
  x: number;
  y: number;
  size: number;
  font: number;
  fill: number;
  stroke: number;
  width: number;
  fillAlpha: number;
  strokeAlpha: number;
}

export const ANCHOR_START = 0;
export const ANCHOR_MIDDLE = 1;
export const ANCHOR_END = 2;

/** The anchor a `text-anchor` value names; an unknown value is "start". */
export function anchorOf(value: string): number {
  const v = value.trim().toLowerCase();
  return v === "middle" ? ANCHOR_MIDDLE : v === "end" ? ANCHOR_END : ANCHOR_START;
}

/**
 * Lays pieces out into runs. Whitespace collapses to one space and the spaces at the text's own
 * ends are dropped, as a browser lays it out. A piece with an x or y starts a run of text of its
 * own there, and `anchor` moves each such run: "middle" centres it on that point, "end" ends it
 * there.
 */
export function layoutText(pieces: readonly TextPiece[], anchor: number,
  measure: (text: string, size: number, font: number) => number): TextRun[] {
  const runs: TextRun[] = [];
  // The x each position of its own starts at, in the order the text reaches them.
  const chunks: number[] = [];
  let penX = 0;
  let penY = 0;
  // Whether text has been placed yet, and whether a space is waiting for text to follow it.
  let started = false;
  let pendingSpace = false;
  for (const p of pieces) {
    if (p.x !== null) penX = p.x;
    if (p.y !== null) penY = p.y;
    penX += p.dx;
    penY += p.dy;
    if (p.x !== null || p.y !== null) chunks.push(penX);
    const raw = p.text;
    let text = raw.replace(/\s+/g, " ");
    if (!started) text = text.replace(/^ /, "");
    if (text === "") {
      // Whitespace between elements shows only when text follows it.
      if (raw !== "" && started) pendingSpace = true;
      continue;
    }
    if (pendingSpace) {
      text = " " + text;
      pendingSpace = false;
    }
    const trail = text.endsWith(" ");
    if (trail) text = text.slice(0, -1);
    runs.push({
      text, x: penX, y: penY, size: p.size, font: p.font, fill: p.fill, stroke: p.stroke,
      width: p.width, fillAlpha: p.fillAlpha, strokeAlpha: p.strokeAlpha,
    });
    penX += measure(text, p.size, p.font);
    started = true;
    pendingSpace = trail;
  }
  if (anchor === ANCHOR_START || runs.length === 0) return runs;
  const factor = anchor === ANCHOR_MIDDLE ? 0.5 : 1;
  if (chunks.length === 0) chunks.push(runs[0].x);
  const xs = runs.map((r) => r.x);
  for (let k = 0; k < chunks.length; k++) {
    const start = chunks[k];
    const end = k + 1 < chunks.length ? chunks[k + 1] : penX;
    const shift = -factor * (end - start);
    if (shift === 0) continue;
    const last = k + 1 === chunks.length;
    for (let i = 0; i < runs.length; i++) {
      if (xs[i] >= start && (xs[i] < end || last)) runs[i].x = xs[i] + shift;
    }
  }
  return runs;
}
