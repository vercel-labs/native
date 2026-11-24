// CSS color, font and text properties. Returns undefined for a property this module doesn't handle.

import * as P from "../../props.ts";
import { BORDER_COLORS, BORDER_SIDES, BORDER_WIDTHS, borderColor, borderColors, borderShorthand, borderStyles, borderWidth, borderWidths } from "../borders.ts";
import { parseColor } from "../colors.ts";
import { calcNumber, colorDecl, kw, lengths, parseLength, single } from "../declarations.ts";
import { exprHasPercent } from "../length-exprs.ts";
import type { Len } from "../declarations.ts";
import { sizeLen, splitValue } from "../fonts.ts";
import { textShadow } from "../shadows.ts";
import type { Decl, FontContext } from "../types.ts";

export function textProperty(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null | undefined {
  switch (prop) {
    case "color":
      return colorDecl(prop, value, P.P_COLOR, out);
    case "font-size":
      {
      // The shared parse keeps `medium` a unit of its own, and smaller and larger relative: only
      // the runtime knows the family's medium size or the parent's.
      const l = sizeLen(value);
      if (!l) return `unsupported font-size '${value}'`;
      out.push({ p: P.P_FONT_SIZE, v: l.v, u: l.u });
      return null;
    }
    case "font-weight":
      {
      // bolder and lighter are relative to the parent's weight, which only the runtime knows.
      if (value === "bolder") { out.push({ p: P.P_FONT_WEIGHT, v: 0, u: P.U_BOLDER }); return null; }
      if (value === "lighter") { out.push({ p: P.P_FONT_WEIGHT, v: 0, u: P.U_LIGHTER }); return null; }
      const named: Record<string, number> = { normal: 400, bold: 700 };
      const n = named[value] ?? Number(value);
      if (!Number.isFinite(n) || n < 100 || n > 900) return `unsupported font-weight '${value}'`;
      out.push({ p: P.P_FONT_WEIGHT, v: n, u: 0 });
      return null;
    }
    case "line-height":
      {
      // `normal` is the font's own line height, which only the runtime can measure, so it stays
      // a keyword rather than becoming a multiplier here.
      if (value === "normal") { out.push({ p: P.P_LINE_HEIGHT, v: 0, u: P.U_NORMAL }); return null; }
      const n = Number(value);
      if (Number.isFinite(n)) { out.push({ p: P.P_LINE_HEIGHT, v: n, u: P.U_NONE }); return null; }
      // A calc() of numbers is still a multiplier: Tailwind writes calc(1.75 / 1.25).
      const c = calcNumber(value);
      if (c !== null) { out.push({ p: P.P_LINE_HEIGHT, v: c, u: P.U_NONE }); return null; }
      {
        const l = parseLength(value, false);
        if (l === null) return `unsupported line-height '${value}'`;
        out.push({ p: P.P_LINE_HEIGHT, v: l.v, u: l.u });
        return null;
      }
    }
    case "vertical-align":
      {
      const named: Record<string, number> = {
        baseline: P.VA_BASELINE, sub: P.VA_SUB, super: P.VA_SUPER, "text-top": P.VA_TEXT_TOP,
        "text-bottom": P.VA_TEXT_BOTTOM, middle: P.VA_MIDDLE, top: P.VA_TOP, bottom: P.VA_BOTTOM,
      };
      const k = named[value.toLowerCase()];
      if (k !== undefined) { out.push({ p: P.P_VERTICAL_ALIGN, v: k, u: P.U_NONE }); return null; }
      const l = parseLength(value, false);
      if (!l || l.u === P.U_AUTO || l.u === P.U_VW || l.u === P.U_VH ||
        (l.u === P.U_EXPR && exprHasPercent(l.v))) return `unsupported vertical-align '${value}'`;
      out.push({ p: P.P_VERTICAL_ALIGN, v: l.v, u: l.u });
      return null;
    }
    case "text-align":
      return kw(prop, value, {
        left: P.T_LEFT, start: P.T_START, center: P.T_CENTER, right: P.T_RIGHT, end: P.T_END,
        justify: P.T_JUSTIFY,
      }, P.P_TEXT_ALIGN, out);
    case "text-justify":
      return kw(prop, value, {
        auto: P.TJUST_AUTO, "inter-word": P.TJUST_INTER_WORD,
        "inter-character": P.TJUST_INTER_CHARACTER, none: P.TJUST_NONE,
        // The old name of inter-character, which computed values report by its new name.
        distribute: P.TJUST_INTER_CHARACTER,
      }, P.P_TEXT_JUSTIFY, out);
    case "direction":
      return kw(prop, value, { ltr: P.DIR_LTR, rtl: P.DIR_RTL }, P.P_DIRECTION, out);
    case "writing-mode":
      return kw(prop, value, {
        "horizontal-tb": P.WM_HORIZONTAL_TB, "vertical-rl": P.WM_VERTICAL_RL,
        "vertical-lr": P.WM_VERTICAL_LR, "sideways-rl": P.WM_SIDEWAYS_RL,
        "sideways-lr": P.WM_SIDEWAYS_LR,
      }, P.P_WRITING_MODE, out);
    case "text-decoration-inset": {
      // `auto`, or one or two lengths or percentages: the start and end inset, the same on both
      // sides when one is written. `auto` is a length the line's own metrics choose, which is
      // resolved when the value is used.
      const parts = splitValue(value.trim());
      if (parts.length < 1 || parts.length > 2) return `unsupported text-decoration-inset '${value}'`;
      const vals: Len[] = [];
      for (const part of parts) {
        const l = parseLength(part, true);
        if (l === null) return `unsupported text-decoration-inset '${value}'`;
        vals.push(l);
      }
      const end = vals.length > 1 ? vals[1] : vals[0];
      out.push({ p: P.P_TEXT_DECORATION_INSET, v: vals[0].v, u: vals[0].u });
      out.push({ p: P.P_TEXT_DECORATION_INSET_END, v: end.v, u: end.u });
      return null;
    }
    case "text-align-last": {
      const named: Record<string, number> = {
        auto: 0, left: P.T_LEFT + 1, start: P.T_START + 1, center: P.T_CENTER + 1,
        right: P.T_RIGHT + 1, end: P.T_END + 1, justify: P.T_JUSTIFY + 1,
      };
      const v = named[value.toLowerCase()];
      if (v === undefined) {
        return `unsupported value '${value}' for 'text-align-last' (supported: ${Object.keys(named).join(", ")})`;
      }
      out.push({ p: P.P_TEXT_ALIGN_LAST, v, u: P.U_NONE });
      return null;
    }
    case "text-orientation":
      return kw(prop, value, { mixed: P.TO_MIXED, upright: P.TO_UPRIGHT, sideways: P.TO_SIDEWAYS },
        P.P_TEXT_ORIENTATION, out);
    case "line-break":
      return kw(prop, value, {
        auto: P.LB_AUTO, loose: P.LB_LOOSE, normal: P.LB_NORMAL, strict: P.LB_STRICT,
        anywhere: P.LB_ANYWHERE,
      }, P.P_LINE_BREAK, out);
    case "text-transform":
      return kw(prop, value, {
        none: P.TT_NONE, uppercase: P.TT_UPPERCASE, lowercase: P.TT_LOWERCASE, capitalize: P.TT_CAPITALIZE,
      }, P.P_TEXT_TRANSFORM, out);
    case "tab-size":
      {
      // A tab stop counts spaces, so only a number is taken; a length isn't measured here.
      const n = Number(value);
      if (!Number.isFinite(n) || n < 0 || Math.floor(n) !== n) return `unsupported tab-size '${value}'`;
      out.push({ p: P.P_TAB_SIZE, v: n, u: P.U_NONE });
      return null;
    }
    case "text-shadow":
      return textShadow(prop, value, out, fonts);
    case "overflow-wrap":
    case "word-wrap":
      // word-wrap is the old name for overflow-wrap.
      return kw(prop, value, { normal: P.OW_NORMAL, "break-word": P.OW_BREAK_WORD, anywhere: P.OW_ANYWHERE }, P.P_OVERFLOW_WRAP, out);
    case "word-break":
      return kw(prop, value, {
        normal: P.WB_NORMAL, "break-all": P.WB_BREAK_ALL, "keep-all": P.WB_KEEP_ALL, "break-word": P.WB_BREAK_WORD,
      }, P.P_WORD_BREAK, out);
    case "text-overflow":
      return kw(prop, value, { clip: P.TO_CLIP, ellipsis: P.TO_ELLIPSIS }, P.P_TEXT_OVERFLOW, out);
    case "line-clamp":
    case "-webkit-line-clamp":
      {
      // The clamped box is always a vertical one here: content flows down the block. The
      // standard shorthand also takes what ends the last line, which the old webkit property
      // always makes an ellipsis.
      const toks = value.trim().toLowerCase().split(/\s+/).filter((t) => t !== "");
      if (toks.length === 1 && toks[0] === "none") {
        out.push({ p: P.P_LINE_CLAMP, v: 0, u: P.U_NONE });
        out.push({ p: P.P_BLOCK_ELLIPSIS, v: P.BE_AUTO, u: P.U_NONE });
        return null;
      }
      if (toks.length === 1 && toks[0] === "auto") {
        // `auto` clamps to the box's max-height rather than a line count.
        if (prop === "-webkit-line-clamp") return `unsupported ${prop} '${value}' (the webkit property takes a line count)`;
        out.push({ p: P.P_LINE_CLAMP, v: -1, u: P.U_NONE });
        out.push({ p: P.P_BLOCK_ELLIPSIS, v: P.BE_AUTO, u: P.U_NONE });
        return null;
      }
      const n = Number(toks[0]);
      if (!Number.isFinite(n) || n < 1 || Math.floor(n) !== n || toks.length > 2) {
        return `unsupported ${prop} '${value}' (a positive whole number of lines, or none)`;
      }
      let ellipsis = P.BE_AUTO;
      if (toks.length === 2) {
        const w = toks[1];
        if (w !== "auto" && w !== "ellipsis" && w !== "no-ellipsis") {
          return `unsupported ${prop} '${value}' (block-ellipsis auto, ellipsis or no-ellipsis)`;
        }
        if (prop === "-webkit-line-clamp" && w === "no-ellipsis") {
          return `unsupported ${prop} '${value}' (the webkit property always ellipsizes)`;
        }
        ellipsis = w === "no-ellipsis" ? P.BE_NO_ELLIPSIS : P.BE_AUTO;
      }
      out.push({ p: P.P_LINE_CLAMP, v: n, u: P.U_NONE });
      out.push({ p: P.P_BLOCK_ELLIPSIS, v: ellipsis, u: P.U_NONE });
      return null;
    }
    case "block-ellipsis": {
      const w = value.trim().toLowerCase();
      if (w === "auto" || w === "ellipsis") { out.push({ p: P.P_BLOCK_ELLIPSIS, v: P.BE_AUTO, u: P.U_NONE }); return null; }
      if (w === "no-ellipsis") { out.push({ p: P.P_BLOCK_ELLIPSIS, v: P.BE_NO_ELLIPSIS, u: P.U_NONE }); return null; }
      return `unsupported ${prop} '${value}' (auto, ellipsis or no-ellipsis; a string isn't supported yet)`;
    }
    case "text-indent":
      {
      const l = parseLength(value, false);
      if (l === null || l.u === P.U_AUTO) return `unsupported text-indent '${value}'`;
      out.push({ p: P.P_TEXT_INDENT, v: l.v, u: l.u });
      return null;
    }
    case "letter-spacing":
    case "word-spacing":
      {
      // `normal` is zero here: unlike a font-relative keyword, the spacing it stands for is
      // simply none.
      if (value === "normal") {
        out.push({ p: prop === "letter-spacing" ? P.P_LETTER_SPACING : P.P_WORD_SPACING, v: 0, u: P.U_NORMAL });
        return null;
      }
      const l = parseLength(value, false);
      if (l === null || l.u === P.U_AUTO || l.u === P.U_PCT ||
        (l.u === P.U_EXPR && exprHasPercent(l.v))) return `unsupported ${prop} '${value}'`;
      out.push({ p: prop === "letter-spacing" ? P.P_LETTER_SPACING : P.P_WORD_SPACING, v: l.v, u: l.u });
      return null;
    }
    case "white-space":
      {
        const r = kw(prop, value, {
          normal: P.W_NORMAL, nowrap: P.W_NOWRAP, pre: P.W_PRE,
          "pre-wrap": P.W_PRE_WRAP, "pre-line": P.W_PRE_LINE, "break-spaces": P.W_BREAK_SPACES,
        }, P.P_WHITE_SPACE, out);
        // white-space is a shorthand for white-space-collapse and text-wrap-mode, so it sets the
        // mode too: `pre` and `nowrap` are the values that don't wrap.
        if (r === null) {
          const v = value.trim().toLowerCase();
          const mode = v === "nowrap" || v === "pre" ? P.TWM_NOWRAP : P.TWM_WRAP;
          out.push({ p: P.P_TEXT_WRAP_MODE, v: mode, u: P.U_NONE });
        }
        return r;
      }
    case "font-style":
      return kw(prop, value === "oblique" ? "italic" : value, { normal: P.FS_NORMAL, italic: P.FS_ITALIC }, P.P_FONT_STYLE, out);
    case "text-decoration-line":
      return decorationLine(prop, value, out);
    case "text-decoration-style":
      return kw(prop, value, DECORATION_STYLES, P.P_TEXT_DECORATION_STYLE, out);
    case "text-decoration-color":
      return decorationColor(prop, value, out);
    case "text-decoration-thickness":
      return decorationThickness(prop, value, out);
    case "text-underline-offset":
      return underlineOffset(prop, value, out);
    case "text-decoration":
      return decorationShorthand(value, out);
    case "text-underline-position":
      return kw(prop, value, {
        auto: P.TUP_AUTO, under: P.TUP_UNDER, left: P.TUP_LEFT, right: P.TUP_RIGHT,
        "from-font": P.TUP_FROM_FONT,
      }, P.P_TEXT_UNDERLINE_POSITION, out);
    case "text-decoration-skip-ink":
      return kw(prop, value, { auto: P.TDSI_AUTO, none: P.TDSI_NONE, all: P.TDSI_ALL },
        P.P_TEXT_DECORATION_SKIP_INK, out);
    case "text-box-trim":
      return kw(prop, value, {
        none: P.TBT_NONE, "trim-start": P.TBT_START, "trim-end": P.TBT_END, "trim-both": P.TBT_BOTH,
      }, P.P_TEXT_BOX_TRIM, out);
    case "text-box-edge":
      {
      const edges: Record<string, number> = {
        auto: P.TBE_AUTO, text: P.TBE_TEXT, cap: P.TBE_CAP, ex: P.TBE_EX, alphabetic: P.TBE_ALPHABETIC,
        ideographic: P.TBE_IDEOGRAPHIC, leading: P.TBE_LEADING,
      };
      const parts = value.trim().toLowerCase().split(/\s+/).filter((t) => t !== "");
      if (parts.length < 1 || parts.length > 2) return `unsupported text-box-edge '${value}' (one or two edges)`;
      const over = edges[parts[0]];
      const under = parts.length > 1 ? edges[parts[1]] : over;
      if (over === undefined || under === undefined) return `unsupported text-box-edge '${value}'`;
      out.push({ p: P.P_TEXT_BOX_EDGE, v: over * 16 + under, u: P.U_NONE });
      return null;
    }
    case "initial-letter":
      {
      const t = value.trim().toLowerCase();
      if (t === "normal") { out.push({ p: P.P_INITIAL_LETTER, v: 0, u: P.U_NONE }); return null; }
      const m = /^(\d+(?:\.\d+)?)(?:\s+(\d+))?$/.exec(t);
      if (m === null) return `unsupported initial-letter '${value}' (normal, or a size with an optional sink)`;
      const size = Number(m[1]);
      const sink = m[2] !== undefined ? Number(m[2]) : 1;
      if (!(size >= 1) || !(sink >= 1)) return `unsupported initial-letter '${value}' (a size and sink of at least 1)`;
      out.push({ p: P.P_INITIAL_LETTER, v: Math.round(size * 10000) + sink, u: P.U_NONE });
      return null;
    }
    case "alignment-baseline":
    case "dominant-baseline":
      return kw(prop, value, {
        auto: P.AB_AUTO, baseline: P.AB_BASELINE, "text-bottom": P.AB_TEXT_BOTTOM,
        alphabetic: P.AB_ALPHABETIC, ideographic: P.AB_IDEOGRAPHIC, middle: P.AB_MIDDLE,
        central: P.AB_CENTRAL, mathematical: P.AB_MATHEMATICAL, hanging: P.AB_HANGING,
      }, prop === "alignment-baseline" ? P.P_ALIGNMENT_BASELINE : P.P_DOMINANT_BASELINE, out);
    case "baseline-shift":
      {
      const t = value.trim().toLowerCase();
      if (t === "baseline") { out.push({ p: P.P_BASELINE_SHIFT, v: P.BS_BASELINE, u: P.U_NONE }); return null; }
      if (t === "sub") { out.push({ p: P.P_BASELINE_SHIFT, v: P.BS_SUB, u: P.U_NONE }); return null; }
      if (t === "super") { out.push({ p: P.P_BASELINE_SHIFT, v: P.BS_SUPER, u: P.U_NONE }); return null; }
      const l = parseLength(t, false);
      if (l === null) return `unsupported baseline-shift '${value}' (baseline, sub, super or a length)`;
      out.push({ p: P.P_BASELINE_SHIFT, v: l.v, u: l.u });
      return null;
    }
    case "white-space-collapse":
      return kw(prop, value, {
        collapse: P.WSC_COLLAPSE, preserve: P.WSC_PRESERVE, "preserve-breaks": P.WSC_PRESERVE_BREAKS,
        "preserve-spaces": P.WSC_PRESERVE_SPACES, "break-spaces": P.WSC_BREAK_SPACES,
      }, P.P_WHITE_SPACE_COLLAPSE, out);
    case "font-feature-settings":
      return featureSettings(prop, value, out, fonts);
    case "font-variant-caps":
    case "font-variant-ligatures":
    case "font-variant-numeric":
    case "font-variant-east-asian":
    case "font-variant-position":
    case "font-variant-alternates":
      return variantLonghand(prop, value, out, fonts);
    case "font-variant":
      return variantShorthand(value, out);
    case "font-variation-settings":
      return variationSettings(prop, value, out, fonts);
    case "font-synthesis":
      return fontSynthesis(prop, value, out);
    case "font-palette":
      return paletteProperty(prop, value, out, fonts);
    case "font-kerning":
      return kw(prop, value, { auto: P.FKERN_AUTO, normal: P.FKERN_NORMAL, none: P.FKERN_NONE },
        P.P_FONT_KERNING, out);
    case "font-optical-sizing":
      return kw(prop, value, { auto: P.FOPSZ_AUTO, none: P.FOPSZ_NONE }, P.P_FONT_OPTICAL_SIZING, out);
    case "font-language-override":
      {
      // `normal`, or a string of exactly four letters: the OpenType language system to use.
      const t = value.trim();
      if (t.toLowerCase() === "normal") {
        out.push({ p: P.P_FONT_LANGUAGE_OVERRIDE, v: 0, u: P.U_NONE });
        return null;
      }
      const m = /^"([ -~]{4})"$/.exec(t);
      if (m === null) return `unsupported font-language-override '${value}' (a quoted four-character language tag)`;
      let packed = 0;
      for (let i = 0; i < 4; i++) packed = packed * 256 + m[1].charCodeAt(i);
      out.push({ p: P.P_FONT_LANGUAGE_OVERRIDE, v: packed, u: P.U_NONE });
      return null;
    }
    case "font-stretch":
      {
      const t = value.trim().toLowerCase();
      const named = STRETCH_PERCENT[t];
      if (named !== undefined) { out.push({ p: P.P_FONT_STRETCH, v: named, u: P.U_NONE }); return null; }
      const m = /^(\d+(?:\.\d+)?)%$/.exec(t);
      if (m === null) return `unsupported font-stretch '${value}' (a keyword or a percentage)`;
      // A percentage keeps its unit, so the longhand reads back as written; both forms carry the
      // percentage the face matching uses.
      out.push({ p: P.P_FONT_STRETCH, v: Number(m[1]), u: P.U_PCT });
      return null;
    }
    case "font-synthesis-weight":
    case "font-synthesis-style":
    case "font-synthesis-small-caps": {
      const t = value.trim().toLowerCase();
      const p = prop === "font-synthesis-weight" ? P.P_FONT_SYNTHESIS_WEIGHT
        : prop === "font-synthesis-style" ? P.P_FONT_SYNTHESIS_STYLE : P.P_FONT_SYNTHESIS_SMALL_CAPS;
      if (t === "auto") { out.push({ p, v: P.FSYNTH_AUTO, u: P.U_NONE }); return null; }
      if (t === "none") { out.push({ p, v: P.FSYNTH_NONE, u: P.U_NONE }); return null; }
      return `unsupported ${prop} '${value}' (auto or none)`;
    }
    case "font-variant-emoji":
      return kw(prop, value, {
        normal: P.FVE_NORMAL, text: P.FVE_TEXT, emoji: P.FVE_EMOJI, unicode: P.FVE_UNICODE,
      }, P.P_FONT_VARIANT_EMOJI, out);
    case "font-size-adjust":
      {
      const t = value.trim().toLowerCase();
      if (t === "none") { out.push({ p: P.P_FONT_SIZE_ADJUST, v: -1, u: P.U_NONE }); return null; }
      const n = Number(t);
      if (!Number.isFinite(n) || n < 0) {
        return `unsupported font-size-adjust '${value}' (none, or a ratio of the x-height to the font size)`;
      }
      out.push({ p: P.P_FONT_SIZE_ADJUST, v: n, u: P.U_NONE });
      return null;
    }
    case "text-emphasis-style":
      return emphasisStyle(prop, value, out);
    case "text-emphasis-color":
      return emphasisColor(prop, value, out);
    case "text-emphasis-position":
      return emphasisPosition(prop, value, out);
    case "text-emphasis":
      return emphasisShorthand(value, out);
    case "hyphens":
      return kw(prop, value, { none: P.HY_NONE, manual: P.HY_MANUAL, auto: P.HY_AUTO }, P.P_HYPHENS, out);
    case "text-wrap-mode":
      // `wrap` and `nowrap` are the only modes; the style longhand carries `balance` and the rest.
      return kw(prop, value, { wrap: P.TWM_WRAP, nowrap: P.TWM_NOWRAP }, P.P_TEXT_WRAP_MODE, out);
    case "text-wrap-style":
      return kw(prop, value, {
        auto: P.TWS_AUTO, balance: P.TWS_BALANCE, pretty: P.TWS_PRETTY, stable: P.TWS_STABLE,
      }, P.P_TEXT_WRAP_STYLE, out);
    case "text-wrap":
      return textWrapShorthand(value, out);
    default:
      return undefined;
  }
}

/**
 * text-wrap: `wrap` or `nowrap` says whether lines wrap, and `auto`, `balance`, `pretty` or
 * `stable` says how they are broken; one of each, in either order. The shorthand resets the
 * part it leaves out, as a shorthand does.
 */
function textWrapShorthand(value: string, out: Decl[]): string | null {
  const mods = splitValue(value);
  let mode = -1;
  let style = -1;
  for (const w of mods) {
    if (w === "wrap") mode = P.TWM_WRAP;
    else if (w === "nowrap") mode = P.TWM_NOWRAP;
    else if (w === "auto") style = P.TWS_AUTO;
    else if (w === "balance") style = P.TWS_BALANCE;
    else if (w === "pretty") style = P.TWS_PRETTY;
    else if (w === "stable") style = P.TWS_STABLE;
    else return `unsupported text-wrap '${value}'`;
  }
  if (mods.length === 0 || mods.length > 2 || (mods.length === 2 && (mode === -1 || style === -1))) {
    return `unsupported text-wrap '${value}'`;
  }
  out.push({ p: P.P_TEXT_WRAP_MODE, v: mode < 0 ? P.TWM_WRAP : mode, u: P.U_NONE });
  out.push({ p: P.P_TEXT_WRAP_STYLE, v: style < 0 ? P.TWS_AUTO : style, u: P.U_NONE });
  return null;
}

/**
 * font-feature-settings: `normal` turns every feature back to the font's default, and anything
 * else is a list of quoted four-character OpenType tags, each with `on`, `off` or a whole
 * number, the last value a tag gets winning.
 */
function featureSettings(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  if (value.trim().toLowerCase() === "normal") {
    out.push({ p: P.P_FONT_FEATURE_SETTINGS, v: 0, u: P.U_NONE });
    return null;
  }
  const tags: string[] = [];
  const values: number[] = [];
  for (const part of value.split(",")) {
    const m = /^"([^"]*)"(?:\s+(\S+))?$/.exec(part.trim());
    if (m === null) return `unsupported ${prop} '${value}' (a quoted four-character OpenType tag, with on, off or a number)`;
    const tag = m[1];
    if (!/^[^=;"]{4}$/.test(tag)) return `unsupported ${prop} '${value}' ('${tag}' is not a four-character OpenType tag)`;
    let n = 1;
    const v = m[2];
    if (v !== undefined) {
      if (v === "on") n = 1;
      else if (v === "off") n = 0;
      else if (/^\d+$/.test(v)) n = Number(v);
      else return `unsupported ${prop} '${value}' (the value of '${tag}' is on, off or a whole number)`;
    }
    const at = tags.indexOf(tag);
    if (at >= 0) values[at] = n;
    else { tags.push(tag); values.push(n); }
  }
  if (tags.length === 0) return `unsupported ${prop} '${value}' (it names no feature)`;
  const spec: string[] = [];
  for (let i = 0; i < tags.length; i++) spec.push(tags[i] + "=" + values[i]);
  // A list the compile context doesn't keep (an SVG presentation attribute, say) has no id to
  // store, and there is nothing drawing with it either.
  const id = fonts === undefined || fonts.features === undefined ? -1 : fonts.features(spec.join(";"));
  out.push({ p: P.P_FONT_FEATURE_SETTINGS, v: id < 0 ? 0 : id + 1, u: P.U_NONE });
  return null;
}

/**
 * font-variation-settings: `normal` leaves every axis at the font's default, and anything else is
 * a list of quoted four-character axis tags, each with a number, the last value a tag gets
 * winning. The axes ride to the font with the feature settings, as a run of `tag=value` pairs.
 */
function variationSettings(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  if (value.trim().toLowerCase() === "normal") {
    out.push({ p: P.P_FONT_VARIATION_SETTINGS, v: 0, u: P.U_NONE });
    return null;
  }
  const tags: string[] = [];
  const values: string[] = [];
  for (const part of value.split(",")) {
    const m = /^"([^"]*)"\s+([+-]?(?:\d+(?:\.\d+)?|\.\d+))$/.exec(part.trim());
    if (m === null) return `unsupported ${prop} '${value}' (a quoted four-character axis tag, with a number)`;
    const tag = m[1];
    if (!/^[^=;"]{4}$/.test(tag)) return `unsupported ${prop} '${value}' ('${tag}' is not a four-character axis tag)`;
    // The number is kept as CSS writes numbers: `+700` and `700.50` are `700` and `700.5`.
    const n = String(Number(m[2]));
    const at = tags.indexOf(tag);
    if (at >= 0) values[at] = n;
    else { tags.push(tag); values.push(n); }
  }
  if (tags.length === 0) return `unsupported ${prop} '${value}' (it names no axis)`;
  const spec: string[] = [];
  for (let i = 0; i < tags.length; i++) spec.push(tags[i] + "=" + values[i]);
  const id = fonts === undefined || fonts.variations === undefined ? -1 : fonts.variations(spec.join(";"));
  out.push({ p: P.P_FONT_VARIATION_SETTINGS, v: id < 0 ? 0 : id + 1, u: P.U_NONE });
  return null;
}

/**
 * font-palette: `normal` (the font's palette 0), `light` or `dark` (the first palette the font
 * marks for that background, or palette 0 when it marks none), or a dashed-ident naming a
 * palette an @font-palette-values rule defines. The ident is case-sensitive, and only applies to
 * a font whose family the rule names; the runtime checks that per element.
 */
function paletteProperty(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  const t = value.trim();
  const k = t.toLowerCase();
  if (k === "normal") { out.push({ p: P.P_FONT_PALETTE, v: P.PALETTE_NORMAL, u: P.U_NONE }); return null; }
  if (k === "light") { out.push({ p: P.P_FONT_PALETTE, v: P.PALETTE_LIGHT, u: P.U_NONE }); return null; }
  if (k === "dark") { out.push({ p: P.P_FONT_PALETTE, v: P.PALETTE_DARK, u: P.U_NONE }); return null; }
  if (/^--[-_a-zA-Z0-9]+$/.test(t)) {
    // A name the page defines no rule for behaves as normal, as the spec says.
    const id = fonts === undefined || fonts.palette === undefined ? -1 : fonts.palette(t);
    out.push({ p: P.P_FONT_PALETTE, v: id < 0 ? P.PALETTE_NORMAL : P.PALETTE_NAME + id, u: P.U_NONE });
    return null;
  }
  if (t.toLowerCase().startsWith("palette-mix(")) {
    return `unsupported font-palette '${value}' (palette-mix() isn't supported yet)`;
  }
  return `unsupported ${prop} '${value}' (normal, light, dark or a --name an @font-palette-values rule defines)`;
}

/** The font-stretch keywords, as the percentages CSS Fonts 4 gives them. */
const STRETCH_PERCENT: Record<string, number> = {
  "ultra-condensed": 50, "extra-condensed": 62.5, condensed: 75, "semi-condensed": 87.5,
  normal: 100, "semi-expanded": 112.5, expanded: 125, "extra-expanded": 150, "ultra-expanded": 200,
};

/** font-synthesis: the kinds of face the family may synthesize, as a bitmask; `none` turns all off. */
function fontSynthesis(prop: string, value: string, out: Decl[]): string | null {
  const parts = value.trim().toLowerCase().split(/\s+/);
  // `none` names no kind at all, so every kind is off; it falls through with an empty mask so the
  // longhands say so too, which is where the kinds are read from.
  let mask = 0;
  if (!(parts.length === 1 && parts[0] === "none")) {
    for (const part of parts) {
      const bit = part === "weight" ? P.FSYNTH_WEIGHT : part === "style" ? P.FSYNTH_STYLE
        : part === "small-caps" ? P.FSYNTH_SMALL_CAPS : 0;
      if (bit === 0) return `unsupported ${prop} '${value}' (weight, style, small-caps or none)`;
      if ((mask & bit) !== 0) return `invalid value '${value}' for '${prop}': it names ${part} twice`;
      mask |= bit;
    }
  }
  out.push({ p: P.P_FONT_SYNTHESIS, v: mask, u: P.U_NONE });
  out.push({ p: P.P_FONT_SYNTHESIS_WEIGHT, v: (mask & P.FSYNTH_WEIGHT) !== 0 ? P.FSYNTH_AUTO : P.FSYNTH_NONE, u: P.U_NONE });
  out.push({ p: P.P_FONT_SYNTHESIS_STYLE, v: (mask & P.FSYNTH_STYLE) !== 0 ? P.FSYNTH_AUTO : P.FSYNTH_NONE, u: P.U_NONE });
  out.push({ p: P.P_FONT_SYNTHESIS_SMALL_CAPS, v: (mask & P.FSYNTH_SMALL_CAPS) !== 0 ? P.FSYNTH_AUTO : P.FSYNTH_NONE, u: P.U_NONE });
  return null;
}

// The mark shapes text-emphasis-style names, each with the filled id its open kind follows.
const EMPHASIS_SHAPES: Record<string, number> = {
  dot: P.TEXTE_DOT, circle: P.TEXTE_CIRCLE, "double-circle": P.TEXTE_DOUBLE_CIRCLE,
  triangle: P.TEXTE_TRIANGLE, sesame: P.TEXTE_SESAME,
};

/**
 * text-emphasis-style: `none`, or a mark that is filled (the default) or open, of a shape that is
 * a dot (the default), circle, double-circle, triangle or sesame. A string mark draws the string's
 * own glyphs, which the host doesn't do yet.
 */
function emphasisStyle(prop: string, value: string, out: Decl[]): string | null {
  const parts = splitValue(value);
  let filled = -1; // 1 filled, 0 open
  let shape = 0;
  for (const part of parts) {
    const t = part.toLowerCase();
    if (t === "none") {
      if (parts.length > 1) return `invalid value '${value}' for '${prop}': none can't be combined with a mark`;
      out.push({ p: P.P_TEXT_EMPHASIS_STYLE, v: P.TEXTE_NONE, u: P.U_NONE });
      return null;
    }
    if (t === "filled" || t === "open") {
      if (filled !== -1) return `invalid ${prop} '${value}': it names two fills`;
      filled = t === "filled" ? 1 : 0;
      continue;
    }
    const s = EMPHASIS_SHAPES[t];
    if (s === undefined) {
      const quoted = part.length > 1 && (part[0] === '"' || part[0] === "'");
      return quoted
        ? `unsupported ${prop} '${value}' (a string mark isn't drawn yet)`
        : `unsupported ${prop} '${value}' (filled or open, and dot, circle, double-circle, triangle or sesame)`;
    }
    if (shape !== 0) return `invalid ${prop} '${value}': it names two shapes`;
    shape = s;
  }
  const base = shape === 0 ? P.TEXTE_DOT : shape;
  // The open kind of a shape is the id after it, so an unspecified fill is the filled one.
  out.push({ p: P.P_TEXT_EMPHASIS_STYLE, v: filled === 0 ? base + 1 : base, u: P.U_NONE });
  return null;
}

/** text-emphasis-color: a colour, or currentColor, which the text's own colour resolves. */
function emphasisColor(prop: string, value: string, out: Decl[]): string | null {
  if (value.trim().toLowerCase() === "currentcolor") {
    out.push({ p: P.P_TEXT_EMPHASIS_COLOR, v: -1, u: P.U_NONE });
    return null;
  }
  return colorDecl(prop, value, P.P_TEXT_EMPHASIS_COLOR, out);
}

/**
 * text-emphasis-position: `over` or `under`, which is `over` at first, and `right` or `left`,
 * which is `right` and matters only for vertical text. Either may come first, and the computed
 * value writes the side only when it is `left`, as a browser does.
 */
function emphasisPosition(prop: string, value: string, out: Decl[]): string | null {
  let over: number | null = null; // 1 over, 0 under
  let left: number | null = null; // 1 left, 0 right
  for (const part of splitValue(value)) {
    const t = part.toLowerCase();
    if (t === "over" || t === "under") {
      if (over !== null) return `invalid ${prop} '${value}': it names over and under`;
      over = t === "over" ? 1 : 0;
    } else if (t === "left" || t === "right") {
      if (left !== null) return `invalid ${prop} '${value}': it names two sides`;
      left = t === "left" ? 1 : 0;
    } else {
      return `unsupported ${prop} '${value}' (over or under, and right or left)`;
    }
  }
  out.push({ p: P.P_TEXT_EMPHASIS_POSITION, v: (over === 0 ? 2 : 0) + (left === 1 ? 1 : 0), u: P.U_NONE });
  return null;
}

/**
 * The text-emphasis shorthand: a style, a colour, or both in either order. It sets those two
 * longhands, so a shorthand without a style turns the mark off and one without a colour draws it
 * in the text's colour, as a browser does.
 */
function emphasisShorthand(value: string, out: Decl[]): string | null {
  let color: number | null = null;
  const style: string[] = [];
  for (const part of splitValue(value)) {
    const t = part.toLowerCase();
    if (t === "filled" || t === "open" || t === "none" || EMPHASIS_SHAPES[t] !== undefined ||
      (part.length > 1 && (part[0] === '"' || part[0] === "'"))) {
      style.push(part);
      continue;
    }
    if (t === "currentcolor") {
      if (color !== null) return `invalid value '${value}' for 'text-emphasis': it has two colours`;
      color = -1;
      continue;
    }
    const c = parseColor(t);
    if (c === null) return `unsupported text-emphasis '${value}' (a mark and a colour)`;
    if (color !== null) return `invalid value '${value}' for 'text-emphasis': it has two colours`;
    color = c;
  }
  const err = emphasisStyle("text-emphasis-style", style.length === 0 ? "none" : style.join(" "), out);
  if (err !== null) return err;
  out.push({ p: P.P_TEXT_EMPHASIS_COLOR, v: color ?? -1, u: P.U_NONE });
  return null;
}


const VARIANT_KEYWORDS: Record<string, Record<string, number>> = {
  "font-variant-caps": {
    normal: P.FVC_NORMAL, "small-caps": P.FVC_SMALL_CAPS, "all-small-caps": P.FVC_ALL_SMALL_CAPS,
    "petite-caps": P.FVC_PETITE_CAPS, "all-petite-caps": P.FVC_ALL_PETITE_CAPS,
    unicase: P.FVC_UNICASE, "titling-caps": P.FVC_TITLING_CAPS,
  },
  "font-variant-ligatures": {
    normal: 0, none: P.FVL_NONE,
    "common-ligatures": P.FVL_COMMON_ON, "no-common-ligatures": P.FVL_COMMON_OFF,
    "discretionary-ligatures": P.FVL_DISCRETIONARY_ON, "no-discretionary-ligatures": P.FVL_DISCRETIONARY_OFF,
    "historical-ligatures": P.FVL_HISTORICAL_ON, "no-historical-ligatures": P.FVL_HISTORICAL_OFF,
    contextual: P.FVL_CONTEXTUAL_ON, "no-contextual": P.FVL_CONTEXTUAL_OFF,
  },
  "font-variant-numeric": {
    normal: 0, "lining-nums": P.FVN_LINING, "oldstyle-nums": P.FVN_OLDSTYLE,
    "proportional-nums": P.FVN_PROPORTIONAL, "tabular-nums": P.FVN_TABULAR,
    "diagonal-fractions": P.FVN_DIAGONAL_FRACTIONS, "stacked-fractions": P.FVN_STACKED_FRACTIONS,
    ordinal: P.FVN_ORDINAL, "slashed-zero": P.FVN_SLASHED_ZERO,
  },
  "font-variant-east-asian": {
    normal: 0, jis78: P.FVE_JIS78, jis83: P.FVE_JIS83, jis90: P.FVE_JIS90, jis04: P.FVE_JIS04,
    simplified: P.FVE_SIMPLIFIED, traditional: P.FVE_TRADITIONAL,
    "full-width": P.FVE_FULL_WIDTH, "proportional-width": P.FVE_PROPORTIONAL_WIDTH, ruby: P.FVE_RUBY,
  },
  "font-variant-position": { normal: P.FVP_NORMAL, sub: P.FVP_SUB, super: P.FVP_SUPER },
  "font-variant-alternates": { normal: P.FVA_NORMAL, "historical-forms": P.FVA_HISTORICAL_FORMS },
};

// The keywords that rule each other out, as bit groups: at most one value of a group may be
// named, and two values the same group doesn't rule out add up (as `ordinal slashed-zero` does).
const VARIANT_GROUPS: Record<string, number[]> = {
  "font-variant-caps": [0b1111111],
  "font-variant-ligatures": [0b11, 0b1100, 0b110000, 0b11000000],
  "font-variant-numeric": [0b11, 0b1100, 0b110000, 0b1000000, 0b10000000],
  "font-variant-east-asian": [0b111111, 0b11000000],
  "font-variant-position": [0b11],
  "font-variant-alternates": [0b1],
};

/** One font-variant longhand: the keywords its value names, as a bitmask. */
function variantLonghand(prop: string, value: string, out: Decl[], fonts?: FontContext): string | null {
  const names = VARIANT_KEYWORDS[prop];
  const groups = VARIANT_GROUPS[prop];
  const parts = value.trim().toLowerCase().split(/\s+/);
  let mask = 0;
  // font-variant-alternates may also name an @font-feature-values alias: the alias resolves to
  // the OpenType feature it stands for, which is added as a font-feature-settings entry.
  let aliases: string[] = [];
  if (prop === "font-variant-alternates" && fonts !== undefined && fonts.featureValue !== undefined) {
    const kept: string[] = [];
    for (const part of parts) {
      const m = /^(styleset|stylistic|character-variant|swash|ornaments|annotation)\(([^)]*)\)$/.exec(part);
      if (m === null) {
        kept.push(part);
        continue;
      }
      const spec = fonts.featureValue(m[1], m[2].trim().split(/\s+/)[0]);
      if (spec === null) return `unsupported ${prop} '${value}' (no @font-feature-values alias '${m[2].trim()}' for ${m[1]})`;
      aliases.push(spec);
    }
    value = kept.join(" ");
    if (value === "") value = "normal";
  }
  const parts2 = value.trim() === "" ? [] : value.trim().split(/\s+/);
  for (const part of parts2) {
    const bit = names[part];
    if (bit === undefined) return `unsupported ${prop} '${value}'`;
    // `normal` and, for the ligatures, `none` only stand alone.
    if (parts2.length > 1 && (part === "normal" || part === "none")) {
      return `invalid value '${value}' for '${prop}': ${part} can't be combined with another value`;
    }
    for (const g of groups) {
      if ((bit & g) !== 0 && (mask & g) !== 0) return `invalid value '${value}' for '${prop}': it names two of one value`;
    }
    mask |= bit;
  }
  const id = prop === "font-variant-caps" ? P.P_FONT_VARIANT_CAPS
    : prop === "font-variant-ligatures" ? P.P_FONT_VARIANT_LIGATURES
      : prop === "font-variant-numeric" ? P.P_FONT_VARIANT_NUMERIC
        : prop === "font-variant-east-asian" ? P.P_FONT_VARIANT_EAST_ASIAN
          : prop === "font-variant-position" ? P.P_FONT_VARIANT_POSITION : P.P_FONT_VARIANT_ALTERNATES;
  out.push({ p: id, v: mask, u: P.U_NONE });
  if (aliases.length > 0 && fonts !== undefined && fonts.features !== undefined) {
    const row = fonts.features(aliases.join(";"));
    out.push({ p: P.P_FONT_FEATURE_SETTINGS, v: row + 1, u: P.U_NONE });
  }
  return null;
}

/**
 * The font-variant shorthand: `normal`, `none`, or one value from each longhand's list in any
 * order. It sets all six longhands, so a value it doesn't name goes back to its initial one.
 */
function variantShorthand(value: string, out: Decl[]): string | null {
  const parts = value.trim().toLowerCase().split(/\s+/);
  if (parts.length === 1 && (parts[0] === "normal" || parts[0] === "none")) {
    const none = parts[0] === "none";
    out.push({ p: P.P_FONT_VARIANT_CAPS, v: P.FVC_NORMAL, u: P.U_NONE });
    out.push({ p: P.P_FONT_VARIANT_LIGATURES, v: none ? P.FVL_NONE : 0, u: P.U_NONE });
    out.push({ p: P.P_FONT_VARIANT_NUMERIC, v: 0, u: P.U_NONE });
    out.push({ p: P.P_FONT_VARIANT_EAST_ASIAN, v: 0, u: P.U_NONE });
    out.push({ p: P.P_FONT_VARIANT_POSITION, v: P.FVP_NORMAL, u: P.U_NONE });
    out.push({ p: P.P_FONT_VARIANT_ALTERNATES, v: P.FVA_NORMAL, u: P.U_NONE });
    return null;
  }
  const props = ["font-variant-caps", "font-variant-ligatures", "font-variant-numeric",
    "font-variant-east-asian", "font-variant-position", "font-variant-alternates"];
  const mask: number[] = [0, 0, 0, 0, 0, 0];
  const used: boolean[] = [false, false, false, false, false, false];
  for (const part of parts) {
    // `normal` and `none` only stand alone in the shorthand.
    if (part === "normal" || part === "none") {
      return `invalid value '${value}' for 'font-variant': ${part} can't be combined with another value`;
    }
    let found = -1;
    for (let i = 0; i < props.length && found < 0; i++) {
      const bit = VARIANT_KEYWORDS[props[i]][part];
      if (bit === undefined) continue;
      found = i;
      const groups = VARIANT_GROUPS[props[i]];
      for (const g of groups) {
        if ((bit & g) !== 0 && (mask[i] & g) !== 0) return `invalid value '${value}' for 'font-variant': it names two of one value`;
      }
      mask[i] = used[i] ? mask[i] | bit : bit;
      used[i] = true;
    }
    if (found < 0) return `unsupported font-variant '${value}'`;
  }
  for (let i = 0; i < props.length; i++) {
    const id = i === 0 ? P.P_FONT_VARIANT_CAPS : i === 1 ? P.P_FONT_VARIANT_LIGATURES
      : i === 2 ? P.P_FONT_VARIANT_NUMERIC : i === 3 ? P.P_FONT_VARIANT_EAST_ASIAN
        : i === 4 ? P.P_FONT_VARIANT_POSITION : P.P_FONT_VARIANT_ALTERNATES;
    out.push({ p: id, v: mask[i], u: P.U_NONE });
  }
  return null;
}

const DECORATION_LINES: Record<string, number> = {
  underline: P.TD_UNDERLINE, overline: P.TD_OVERLINE, "line-through": P.TD_LINE_THROUGH,
};

const DECORATION_STYLES: Record<string, number> = {
  solid: P.TDS_SOLID, double: P.TDS_DOUBLE, dotted: P.TDS_DOTTED, dashed: P.TDS_DASHED, wavy: P.TDS_WAVY,
};

/** text-decoration-line: `none` or any of the three lines, in any order. */
function decorationLine(prop: string, value: string, out: Decl[]): string | null {
  const parts = value.trim().toLowerCase().split(/\s+/);
  let mask = P.TD_NONE;
  for (const p of parts) {
    if (p === "none") {
      if (parts.length > 1) return `invalid ${prop} '${value}': none can't be combined with a line`;
      continue;
    }
    const bit = DECORATION_LINES[p];
    if (bit === undefined) return `unsupported ${prop} '${value}' (supported: none, underline, overline, line-through)`;
    mask |= bit;
  }
  out.push({ p: P.P_TEXT_DECORATION, v: mask, u: P.U_NONE });
  return null;
}

/** text-decoration-color: a colour, or currentColor, which the text's own colour resolves. */
function decorationColor(prop: string, value: string, out: Decl[]): string | null {
  if (value.trim().toLowerCase() === "currentcolor") {
    out.push({ p: P.P_TEXT_DECORATION_COLOR, v: -1, u: P.U_NONE });
    return null;
  }
  return colorDecl(prop, value, P.P_TEXT_DECORATION_COLOR, out);
}

/** A length-percentage decoration value, rejecting the units its position can't use. */
function decorationLen(value: string): Len | null {
  const l = parseLength(value, false);
  if (!l || l.u === P.U_AUTO || l.u === P.U_VW || l.u === P.U_VH ||
    (l.u === P.U_EXPR && exprHasPercent(l.v))) return null;
  return l;
}

/** Is this length negative? An expression's row id says nothing about its sign. */
function negative(l: Len): boolean {
  return l.u !== P.U_EXPR && l.v < 0;
}

/** text-decoration-thickness: `auto`, `from-font`, or a non-negative length or percentage. */
function decorationThickness(prop: string, value: string, out: Decl[]): string | null {
  const t = value.trim().toLowerCase();
  if (t === "auto" || t === "from-font") {
    out.push({ p: P.P_TEXT_DECORATION_THICKNESS, v: 0, u: t === "auto" ? P.U_AUTO : P.U_FROM_FONT });
    return null;
  }
  const l = decorationLen(t);
  if (l === null) return `unsupported ${prop} '${value}'`;
  if (negative(l)) return `invalid value '${value}' for '${prop}': it can't be negative, so the declaration is ignored`;
  out.push({ p: P.P_TEXT_DECORATION_THICKNESS, v: l.v, u: l.u });
  return null;
}

/** text-underline-offset: `auto`, or a length or percentage of the font size, which may be negative. */
function underlineOffset(prop: string, value: string, out: Decl[]): string | null {
  const t = value.trim().toLowerCase();
  if (t === "auto") {
    out.push({ p: P.P_UNDERLINE_OFFSET, v: 0, u: P.U_AUTO });
    return null;
  }
  const l = decorationLen(t);
  if (l === null) return `unsupported ${prop} '${value}'`;
  out.push({ p: P.P_UNDERLINE_OFFSET, v: l.v, u: l.u });
  return null;
}

/**
 * The text-decoration shorthand: any of the three lines, a style, a colour and a thickness, in
 * any order. It sets all four longhands, so a shorthand without a style resets it to solid.
 */
function decorationShorthand(value: string, out: Decl[]): string | null {
  let mask = P.TD_NONE;
  let sawNone = false;
  let sawLine = false;
  let style: number | null = null;
  let color: number | null = null;
  let thickness: Len | null = null;
  for (const part of splitValue(value)) {
    const t = part.toLowerCase();
    if (t === "none") {
      if (sawNone || sawLine) return `invalid value '${value}' for 'text-decoration': none can't be combined with a line`;
      sawNone = true;
      continue;
    }
    const bit = DECORATION_LINES[t];
    if (bit !== undefined) {
      if (sawNone) return `invalid value '${value}' for 'text-decoration': none can't be combined with a line`;
      mask |= bit;
      sawLine = true;
      continue;
    }
    const s = DECORATION_STYLES[t];
    if (s !== undefined) {
      if (style !== null) return `invalid value '${value}' for 'text-decoration': it has two line styles`;
      style = s;
      continue;
    }
    if (t === "auto" || t === "from-font") {
      thickness = { v: 0, u: t === "auto" ? P.U_AUTO : P.U_FROM_FONT };
      continue;
    }
    if (t === "currentcolor") {
      if (color !== null) return `invalid value '${value}' for 'text-decoration': it has two colours`;
      color = -1;
      continue;
    }
    const c = parseColor(t);
    if (c !== null) {
      if (color !== null) return `invalid value '${value}' for 'text-decoration': it has two colours`;
      color = c;
      continue;
    }
    const l = decorationLen(t);
    if (l !== null) {
      if (thickness !== null) return `invalid value '${value}' for 'text-decoration': it has two thicknesses`;
      if (negative(l)) return `invalid value '${value}' for 'text-decoration': the thickness can't be negative`;
      thickness = l;
      continue;
    }
    return `unsupported text-decoration '${value}'`;
  }
  if (!sawLine) mask = P.TD_NONE;
  out.push({ p: P.P_TEXT_DECORATION, v: mask, u: P.U_NONE });
  out.push({ p: P.P_TEXT_DECORATION_STYLE, v: style ?? P.TDS_SOLID, u: P.U_NONE });
  out.push({ p: P.P_TEXT_DECORATION_COLOR, v: color ?? -1, u: P.U_NONE });
  const th = thickness;
  out.push({
    p: P.P_TEXT_DECORATION_THICKNESS, v: th === null ? 0 : th.v,
    u: th === null ? P.U_AUTO : th.u,
  });
  return null;
}
