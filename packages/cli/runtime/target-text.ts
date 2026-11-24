// ::target-text: the stretch of text a URL's text fragment names. An app opened with the
// fragment (NATIVE_TARGET_TEXT, as a #:~:text= directive gives it) paints that stretch the way
// ::target-text's rule says, and with the browser's pale yellow when the page gives no rule.

import { documentTextStream, invalidatePaint } from "./dom.ts";
import { hostTargetText } from "./host.ts";
import { textVersion } from "./invalidation.ts";

/** The stretch the fragment names, as [start, end) offsets in the document's text stream. */
let span: [number, number] | null = null;
/** The directive the span came from, and the text version it was found in: the stretch is found
 *  again whenever the document's text moves, since its offsets are stream positions. */
let directive: string | null = null;
let resolvedVersion = -1;

/** The stretch a text fragment names this page, or null when it names nothing. */
export function targetTextSpan(): [number, number] | null {
  if (directive !== null && resolvedVersion !== textVersion.n) resolveTargetText();
  return span;
}

/** Forgets the page's target text, which the next page starts without. */
export function resetTargetText(): void {
  span = null;
  directive = null;
  resolvedVersion = -1;
}

/** Decodes a directive's percent escapes, leaving anything malformed as written. */
function decodePercent(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "%" && i + 2 < s.length) {
      const code = parseInt(s.slice(i + 1, i + 3), 16);
      if (!isNaN(code)) {
        out += String.fromCharCode(code);
        i += 2;
        continue;
      }
    }
    out += s[i];
  }
  return out;
}

/**
 * Parses a fragment directive's value — `[prefix-,]textStart[,textEnd][,-suffix]`, the part of
 * `#:~:text=` after `text=` — into [prefix, start, end, suffix], with "" for what it leaves out.
 * It names no text when it gives no start, or when a part is the wrong shape.
 */
export function parseTextDirective(value: string): [string, string, string, string] | null {
  const text = decodePercent(value.trim());
  if (text === "") return null;
  const parts = text.split(",");
  if (parts.length > 4) return null;
  let prefix = "";
  let suffix = "";
  let rest = parts;
  if (parts.length > 1 && parts[0].length > 1 && parts[0][parts[0].length - 1] === "-") {
    prefix = parts[0].slice(0, -1);
    rest = parts.slice(1);
  }
  if (rest.length > 1 && rest[rest.length - 1].length > 1 && rest[rest.length - 1][0] === "-") {
    suffix = rest[rest.length - 1].slice(1);
    rest = rest.slice(0, -1);
  }
  if (rest.length === 0 || rest.length > 2) return null;
  const start = rest[0];
  if (start === "") return null;
  const end = rest.length === 2 ? rest[1] : "";
  return [prefix, start, end, suffix];
}

/**
 * Reads the fragment the app was opened with and marks the stretch it names: the first place the
 * text appears, ASCII case-insensitively, with the prefix just before it and the suffix just
 * after when the directive gives them.
 */
export function setTargetText(value: string): boolean {
  directive = value;
  return resolveTargetText();
}

/** Finds the directive's stretch in the document's text as it stands now. */
function resolveTargetText(): boolean {
  span = null;
  resolvedVersion = textVersion.n;
  if (directive === null) return false;
  const parts = parseTextDirective(directive);
  if (parts === null) return false;
  const text = documentTextStream();
  const lower = text.toLowerCase();
  const prefix = parts[0].toLowerCase();
  const start = parts[1].toLowerCase();
  const end = parts[2].toLowerCase();
  const suffix = parts[3].toLowerCase();
  let from = 0;
  while (from + start.length <= lower.length) {
    const at = lower.indexOf(start, from);
    if (at < 0) break;
    const tail = at + start.length;
    const endAt = tail + end.length;
    if (lower.slice(tail, endAt) === end) {
      const before = lower.slice(Math.max(0, at - prefix.length), at);
      const after = lower.slice(endAt, endAt + suffix.length);
      if (before === prefix && after === suffix) {
        span = [at, endAt];
        invalidatePaint();
        return true;
      }
    }
    from = at + 1;
  }
  return false;
}

/** Asks the host for the text fragment the app was opened with, if any. */
export function readTargetText(): void {
  hostTargetText((text) => {
    setTargetText(text);
  });
}
