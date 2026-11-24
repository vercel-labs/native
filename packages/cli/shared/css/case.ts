// `text-transform: capitalize`, shared by the layout and by innerText.

/**
 * Whether a character continues a word, so that a letter after it is not capitalized: a letter,
 * a digit, an underscore or an apostrophe. Everything else starts a new word.
 */
export function isWordChar(ch: string): boolean {
  const c = ch.codePointAt(0) ?? 0;
  if (c === 0) return false;
  if (c === 0x27 || c === 0x2019) return true;
  if (c === 0x5f) return true;
  if (c >= 0x30 && c <= 0x39) return true;
  if (c < 0x80) return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a);
  // Non-ASCII: punctuation starts a new word, a letter or ideograph continues one.
  if (c >= 0x2000 && c <= 0x206f) return false;
  if (c >= 0x3000 && c <= 0x303f) return false;
  if (c >= 0xff01 && c <= 0xff0f) return false;
  return true;
}

/**
 * `text` capitalized: the first cased letter of each word upper-cased, the rest untouched.
 * `before` is the character the text follows in the same line, so a run that starts in the
 * middle of a word (a span inside a word, say) does not capitalize its first letter.
 */
export function capitalizeText(text: string, before: string): string {
  let out = "";
  let prev = before;
  for (const ch of text) {
    const upper = ch.toUpperCase();
    if (upper !== ch && !isWordChar(prev)) out += upper;
    else out += ch;
    prev = ch;
  }
  return out;
}
