// Which characters a ::first-letter takes, as CSS Pseudo-Elements 4 has it: the first letter with
// the punctuation around it — everything before it, and the punctuation after it except an
// opening one or a dash, with a typographic space bridging to what follows while a word
// separator does not.

const OPEN = new Set([
  "(", "[", "{", "‘", "‚", "‛", "“", "„", "‟", "«", "‹",
  "⁅", "⁽", "₍", "〈", "❨", "❪", "❬", "❮", "❰", "❲",
  "❴", "⟅", "⟦", "⟨", "⟪", "⟬", "⟮", "⦃", "⦅", "⦇",
  "⦉", "⦋", "⦍", "⦏", "⦑", "⦓", "⦕", "⦗", "⧘", "⧚",
  "⧼", "⸢", "⸤", "⸦", "⸨", "〈", "《", "「", "『", "【",
  "〔", "〖", "〘", "〚", "〝", "︗", "︵", "︷", "︹", "︻",
  "︽", "︿", "﹁", "﹃", "﹇", "﹙", "﹛", "﹝", "（", "［",
  "｛", "｟", "｢",
]);

const DASH = new Set([
  "-", "֊", "־", "᐀", "᠆", "‐", "‑", "‒", "–", "—",
  "―", "⸗", "⸚", "⸺", "⸻", "⹀", "〜", "〰", "゠", "︱",
  "︲", "﹘", "﹣", "－",
]);

/** The spaces that separate words: punctuation does not reach across them. */
function isWordSeparator(ch: string): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f" || ch === " ";
}

/** A space that isn't a word separator (an em space, a thin space): punctuation reaches across. */
function isTypographicSpace(ch: string): boolean {
  if (isWordSeparator(ch)) return false;
  const c = ch.codePointAt(0) ?? 0;
  return (c >= 0x2000 && c <= 0x200a) || c === 0x202f || c === 0x205f || c === 0x3000;
}

/** Whether a character is punctuation (one of the Unicode P* categories). */
export function isPunctuation(ch: string): boolean {
  const c = ch.codePointAt(0) ?? 0;
  if (c < 128) return "!\"#%&'()*,-./:;?@[\\]_{}".indexOf(ch) >= 0;
  if (c >= 0xa1 && c <= 0xbf) return "\u00a1\u00a7\u00b6\u00b7\u00ab\u00bb\u00bf".indexOf(ch) >= 0;
  if (c >= 0x2000 && c <= 0x206f) return !isTypographicSpace(ch); // General Punctuation
  if (c >= 0x2e00 && c <= 0x2e7f) return true; // Supplemental Punctuation
  if (c >= 0x3001 && c <= 0x303f) return c !== 0x3000; // CJK Symbols and Punctuation
  if (c >= 0xfe10 && c <= 0xfe19) return true;
  if (c >= 0xfe30 && c <= 0xfe4f) return true;
  if (c >= 0xff01 && c <= 0xff0f) return true;
  if (c >= 0xff1a && c <= 0xff20) return true;
  if (c >= 0xff3b && c <= 0xff40) return true;
  if (c >= 0xff5b && c <= 0xff65) return true;
  if (c >= 0x10100 && c <= 0x10102) return true; // Aegean word separators
  return false;
}

/**
 * How many characters at the start of `text` make up its ::first-letter. 0 when the text has no
 * letter at all (only spaces, say).
 */
/**
 * A combining mark that belongs to the character before it: the diacritic and vowel-sign blocks,
 * and a variation selector. The first-letter takes the letter's marks with it (T + U+0300 is one
 * letter), which is also what keeps a surrogate pair from being split.
 */
function isCombiningMark(ch: string): boolean {
  const c = ch.codePointAt(0) ?? 0;
  return (c >= 0x0300 && c <= 0x036f) || (c >= 0x0483 && c <= 0x0489) ||
    (c >= 0x0591 && c <= 0x05c7) || (c >= 0x0610 && c <= 0x061a) || (c >= 0x064b && c <= 0x065f) ||
    (c >= 0x0670 && c <= 0x0670) || (c >= 0x06d6 && c <= 0x06ed) ||
    (c >= 0x0900 && c <= 0x0903) || (c >= 0x093a && c <= 0x094f) || (c >= 0x0951 && c <= 0x0957) ||
    (c >= 0x0962 && c <= 0x0963) || (c >= 0x0e31 && c <= 0x0e3a) || (c >= 0x0e47 && c <= 0x0e4e) ||
    (c >= 0x1ab0 && c <= 0x1aff) || (c >= 0x1dc0 && c <= 0x1dff) ||
    (c >= 0x20d0 && c <= 0x20ff) || (c >= 0xfe00 && c <= 0xfe0f) || (c >= 0xfe20 && c <= 0xfe2f) ||
    (c >= 0xe0100 && c <= 0xe01ef);
}

/**
 * How many characters of the word at `t` the first letter takes: one, or two for a language whose
 * orthography writes one letter with two characters — Dutch "ij" counts as a single letter when
 * both halves are the same case.
 */
function letterLength(chars: string[], t: number, lang: string): number {
  if (lang.toLowerCase().split("-")[0] !== "nl" || t + 1 >= chars.length) return 1;
  const a = chars[t], b = chars[t + 1];
  return (a === "I" && b === "J") || (a === "i" && b === "j") ? 2 : 1;
}

/**
 * How many characters at the start of `text` make up its ::first-letter. 0 when the text has no
 * letter at all (only spaces, say). The letter is one code point plus any combining marks that
 * follow it, so a supplementary letter is never cut in half; `lang` lets a digraph count as the
 * letter for the languages that have one.
 */
export function firstLetterLength(text: string, lang: string = ""): number {
  // Characters by code point: the letter itself, then the marks that belong to it, then the
  // punctuation after it.
  const chars = Array.from(text);
  let t = 0;
  while (t < chars.length && (isWordSeparator(chars[t]) || isPunctuation(chars[t]))) t++;
  if (t >= chars.length) return 0;
  let end = t + letterLength(chars, t, lang);
  while (end < chars.length && isCombiningMark(chars[end])) end++;
  while (end < chars.length) {
    const ch = chars[end];
    if (isPunctuation(ch) && !OPEN.has(ch) && !DASH.has(ch)) {
      end++;
      continue;
    }
    // A typographic space bridges to the punctuation after it; a word separator stops the letter.
    let k = end;
    while (k < chars.length && isTypographicSpace(chars[k])) k++;
    if (k > end && k < chars.length && isPunctuation(chars[k]) && !OPEN.has(chars[k]) && !DASH.has(chars[k])) {
      end = k + 1;
      continue;
    }
    break;
  }
  let length = 0;
  for (let i = 0; i < end; i++) length += chars[i].length;
  return length;
}
