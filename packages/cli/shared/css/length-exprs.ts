// calc(), max(), min() and clamp() lengths. Each expression is a row of numbers, so a value can
// carry the expression's id instead of a plain length and the runtime can evaluate it against
// the percentage base the property uses, the way CSS resolves a calculation at used-value time.

import * as P from "../props.ts";
import { RowTable } from "./rows.ts";

/** A leaf row is [0, value, unit]; the operators hold the ids of their argument rows. */
export const EXPR_LEAF = 0;
export const EXPR_MIN = 1;
export const EXPR_MAX = 2;
export const EXPR_CLAMP = 3;
/** [4, n, id…]: the arguments, added together (calc()'s plus and minus). */
export const EXPR_SUM = 4;
/** [5, id, factor]: one expression times a number (calc()'s multiplication and division). */
export const EXPR_SCALE = 5;
/** [6, strategy, a, b]: round(a, b) with strategy 0 nearest, 1 up, 2 down, 3 to-zero. */
export const EXPR_ROUND = 6;
/** [7, a, b]: calc()'s mod(), whose sign follows b. */
export const EXPR_MOD = 7;
/** [8, a, b]: calc()'s rem(), whose sign follows a. */
export const EXPR_REM = 8;
export const EXPR_SIN = 9;
export const EXPR_COS = 10;
export const EXPR_TAN = 11;
export const EXPR_ASIN = 12;
export const EXPR_ACOS = 13;
export const EXPR_ATAN = 14;
/** [15, y, x]: atan2(), an angle in degrees. */
export const EXPR_ATAN2 = 15;
export const EXPR_POW = 16;
export const EXPR_SQRT = 17;
export const EXPR_HYPOT = 18;
/** [19, a, base]: log(a, base), with base -1 for the natural log. */
export const EXPR_LOG = 19;
export const EXPR_EXP = 20;
export const EXPR_ABS = 21;
export const EXPR_SIGN = 22;

// The unit each leaf's id stands for, as CSS writes it; the cq units sit at their ids.
const UNIT_TEXT: string[] = ["", "px", "%", "vw", "vh", "em", "", "normal"];
UNIT_TEXT[P.U_CQW] = "cqw";
UNIT_TEXT[P.U_CQH] = "cqh";
UNIT_TEXT[P.U_CQI] = "cqi";
UNIT_TEXT[P.U_CQB] = "cqb";
UNIT_TEXT[P.U_CQMIN] = "cqmin";
UNIT_TEXT[P.U_CQMAX] = "cqmax";
UNIT_TEXT[P.U_REM] = "rem";
UNIT_TEXT[P.U_LH] = "lh";

function numberText(n: number): string {
  if (n === Infinity) return "infinity";
  if (n === -Infinity) return "-infinity";
  const r = Math.round(n * 1000) / 1000;
  return r === 0 ? "0" : String(r);
}

function leafText(v: number, u: number): string {
  if (u === P.U_AUTO) return "auto";
  if (u === P.U_NONE) return numberText(v);
  return numberText(v) + (u < UNIT_TEXT.length ? UNIT_TEXT[u] : "px");
}

/** The expression's CSS text, for serializing a value that carries it. */
export function exprText(id: number): string {
  const row = exprRows.row(id);
  return row === null ? "" : rowText(row);
}

/** The argument rows of an expression row, leaving out the operator's own constants. */
function argIds(row: readonly number[]): number[] {
  const op = row[0];
  if (op === EXPR_LEAF) return [];
  if (op === EXPR_SCALE) return [row[1]];
  if (op === EXPR_ROUND) return [row[2], row[3]];
  if (op === EXPR_MOD || op === EXPR_REM || op === EXPR_ATAN2 || op === EXPR_POW) return [row[1], row[2]];
  if (op === EXPR_LOG) return row[2] < 0 ? [row[1]] : [row[1], row[2]];
  if (op === EXPR_CLAMP) return [row[2], row[3], row[4]];
  if (op === EXPR_MIN || op === EXPR_MAX || op === EXPR_SUM || op === EXPR_HYPOT) {
    const out: number[] = [];
    for (let k = 0; k < row[1]; k++) out.push(row[2 + k]);
    return out;
  }
  return [row[1]];
}

function callText(name: string, ids: number[]): string {
  return name + "(" + ids.map((id) => exprText(id)).join(", ") + ")";
}

function rowText(row: readonly number[]): string {
  const op = row[0];
  if (op === EXPR_LEAF) return leafText(row[1], row[2]);
  if (op === EXPR_ROUND) {
    const strategy = ["nearest", "up", "down", "to-zero"][row[1]];
    return `round(${strategy}, ${exprText(row[2])}, ${exprText(row[3])})`;
  }
  if (op === EXPR_MOD) return callText("mod", [row[1], row[2]]);
  if (op === EXPR_REM) return callText("rem", [row[1], row[2]]);
  if (op === EXPR_ATAN2) return callText("atan2", [row[1], row[2]]);
  if (op === EXPR_LOG) return callText("log", row[2] < 0 ? [row[1]] : [row[1], row[2]]);
  if (op >= EXPR_SIN && op <= EXPR_SIGN && op !== EXPR_MOD && op !== EXPR_REM && op !== EXPR_ATAN2) {
    const names = ["", "", "", "", "", "", "", "", "", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "pow", "sqrt", "hypot", "log", "exp", "abs", "sign"];
    return callText(names[op], argIds(row));
  }
  if (op === EXPR_CLAMP) return `clamp(${exprText(row[2])}, ${exprText(row[3])}, ${exprText(row[4])})`;
  if (op === EXPR_SCALE) return `calc(${exprText(row[1])} * ${numberText(row[2])})`;
  const parts: string[] = [];
  for (let k = 0; k < row[1]; k++) parts.push(exprText(row[2 + k]));
  if (op === EXPR_SUM) {
    // A negative term is written with a minus, as calc() serializes it.
    let s = "";
    for (let k = 0; k < row[1]; k++) {
      const id = row[2 + k];
      const leaf = exprRows.row(id);
      const negative = leaf !== null && leaf[0] === EXPR_LEAF && leaf[1] < 0;
      const text = negative ? exprText(id).slice(1) : exprText(id);
      if (k === 0) s = negative ? "-" + text : text;
      else s += negative ? " - " + text : " + " + text;
    }
    return `calc(${s})`;
  }
  return (op === EXPR_MIN ? "min(" : "max(") + parts.join(", ") + ")";
}

export const exprRows: RowTable = new RowTable();

/** Does the expression use a percentage anywhere in it? A property that takes lengths but no
 *  percentages (a shadow offset) has to refuse an expression that does. */
export function exprHasPercent(id: number): boolean {
  const row = exprRows.row(id);
  if (row === null) return false;
  if (row[0] === EXPR_LEAF) return row[2] === P.U_PCT;
  for (const id of argIds(row)) if (exprHasPercent(id)) return true;
  return false;
}

/** Does the expression use a container query unit anywhere in it? */
export function exprHasCq(id: number): boolean {
  const row = exprRows.row(id);
  if (row === null) return false;
  if (row[0] === EXPR_LEAF) return row[2] >= P.U_CQW && row[2] <= P.U_CQMAX;
  for (const id of argIds(row)) if (exprHasCq(id)) return true;
  return false;
}

/** Evaluates the expression with that id: px, or NaN when its base is indefinite. An em leaf
 *  resolves against `fontSize`, the element's computed font size in px; a cq leaf against `cqw`
 *  and `cqh`, the query container's content box, which default to the viewport (as CSS does
 *  when the element has no container). */
export function evalExpr(id: number, base: number, vw: number, vh: number, fontSize: number,
  cqw: number = vw, cqh: number = vh, rem: number = 16, lh: number = 0): number {
  const row = exprRows.row(id);
  return row === null ? NaN : evalRow(row, base, vw, vh, fontSize, cqw, cqh, rem, lh);
}

function evalRow(row: readonly number[], base: number, vw: number, vh: number, fontSize: number,
  cqw: number, cqh: number, rem: number, lh: number): number {
  const op = row[0];
  if (op === EXPR_LEAF) {
    const v = row[1];
    const u = row[2];
    if (u === P.U_PCT) return (v / 100) * base;
    if (u === P.U_VW) return (v / 100) * vw;
    if (u === P.U_VH) return (v / 100) * vh;
    if (u === P.U_EM) return v * fontSize;
    if (u === P.U_REM) return v * rem;
    if (u === P.U_LH) return v * lh;
    if (u === P.U_CQW || u === P.U_CQI) return (v / 100) * cqw;
    if (u === P.U_CQH || u === P.U_CQB) return (v / 100) * cqh;
    if (u === P.U_CQMIN) return (v / 100) * Math.min(cqw, cqh);
    if (u === P.U_CQMAX) return (v / 100) * Math.max(cqw, cqh);
    if (u === P.U_AUTO) return NaN;
    if (u === P.U_DEG) return (v * Math.PI) / 180; // a trig argument wants radians
    return v;
  }
  if (op === EXPR_CLAMP) {
    const lo = evalExpr(row[2], base, vw, vh, fontSize, cqw, cqh, rem, lh);
    const val = evalExpr(row[3], base, vw, vh, fontSize, cqw, cqh, rem, lh);
    const hi = evalExpr(row[4], base, vw, vh, fontSize, cqw, cqh, rem, lh);
    return Math.max(lo, Math.min(val, hi));
  }
  if (op === EXPR_SCALE) return evalExpr(row[1], base, vw, vh, fontSize, cqw, cqh, rem, lh) * row[2];
  if (op >= EXPR_ROUND) {
    const a = (i: number): number => evalExpr(i, base, vw, vh, fontSize, cqw, cqh, rem, lh);
    if (op === EXPR_ROUND) {
      const step = a(row[3]);
      if (!(step > 0)) return NaN;
      const q = a(row[2]) / step;
      const k = row[1];
      const r = k === 1 ? Math.ceil(q) : k === 2 ? Math.floor(q) : k === 3 ? Math.trunc(q) : Math.round(q);
      return r * step;
    }
    if (op === EXPR_MOD) {
      const x = a(row[1]), y = a(row[2]);
      return y === 0 ? NaN : x - y * Math.floor(x / y);
    }
    if (op === EXPR_REM) {
      const x = a(row[1]), y = a(row[2]);
      return y === 0 ? NaN : x - y * Math.trunc(x / y);
    }
    if (op === EXPR_SIN) return Math.sin(a(row[1]));
    if (op === EXPR_COS) return Math.cos(a(row[1]));
    if (op === EXPR_TAN) return Math.tan(a(row[1]));
    if (op === EXPR_ASIN) { const x = a(row[1]); return Math.abs(x) > 1 ? NaN : Math.asin(x) * 180 / Math.PI; }
    if (op === EXPR_ACOS) { const x = a(row[1]); return Math.abs(x) > 1 ? NaN : Math.acos(x) * 180 / Math.PI; }
    if (op === EXPR_ATAN) return Math.atan(a(row[1])) * 180 / Math.PI;
    if (op === EXPR_ATAN2) return Math.atan2(a(row[1]), a(row[2])) * 180 / Math.PI;
    if (op === EXPR_POW) return Math.pow(a(row[1]), a(row[2]));
    if (op === EXPR_SQRT) { const x = a(row[1]); return x < 0 ? NaN : Math.sqrt(x); }
    if (op === EXPR_HYPOT) {
      let sum = 0;
      for (let k = 0; k < row[1]; k++) { const v = a(row[2 + k]); sum += v * v; }
      return Math.sqrt(sum);
    }
    if (op === EXPR_LOG) {
      const x = a(row[1]);
      if (row[2] < 0) return x > 0 ? Math.log(x) : NaN;
      const b = a(row[2]);
      return x > 0 && b > 0 && b !== 1 ? Math.log(x) / Math.log(b) : NaN;
    }
    if (op === EXPR_EXP) return Math.exp(a(row[1]));
    if (op === EXPR_ABS) return Math.abs(a(row[1]));
    if (op === EXPR_SIGN) return Math.sign(a(row[1]));
  }
  if (op === EXPR_SUM) {
    let sum = 0;
    for (let k = 0; k < row[1]; k++) sum += evalExpr(row[2 + k], base, vw, vh, fontSize, cqw, cqh, rem, lh);
    return sum;
  }
  const n = row[1];
  let best = evalExpr(row[2], base, vw, vh, fontSize, cqw, cqh, rem, lh);
  for (let k = 1; k < n; k++) {
    const v = evalExpr(row[2 + k], base, vw, vh, fontSize, cqw, cqh, rem, lh);
    best = op === EXPR_MIN ? Math.min(best, v) : Math.max(best, v);
  }
  return best;
}
