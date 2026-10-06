import { utf8Bytes } from "@native-sdk/core/bytes";

const author_names: readonly Uint8Array[] = [
    utf8Bytes("Ada Byron"),     utf8Bytes("Alan Kay"),       utf8Bytes("Annie Easley"),   utf8Bytes("Barbara Liskov"),
    utf8Bytes("Dennis Wilson"), utf8Bytes("Edith Clarke"),   utf8Bytes("Grace Murray"),   utf8Bytes("Hedy Keller"),
    utf8Bytes("Ivan Marsh"),    utf8Bytes("Katherine Ross"), utf8Bytes("Lin Chen"),       utf8Bytes("Mary Allen"),
    utf8Bytes("Niklaus Wirth"), utf8Bytes("Radia Perl"),     utf8Bytes("Sofia Kovaleva"), utf8Bytes("Vera Cortez"),];
const author_handles: readonly Uint8Array[] = [
    utf8Bytes("@ada"),    utf8Bytes("@kay"),    utf8Bytes("@easley"), utf8Bytes("@liskov"),
    utf8Bytes("@dwilson"), utf8Bytes("@edith"),  utf8Bytes("@gmurray"), utf8Bytes("@hedy"),
    utf8Bytes("@ivanm"),  utf8Bytes("@kross"),  utf8Bytes("@linchen"), utf8Bytes("@mallen"),
    utf8Bytes("@wirth"),  utf8Bytes("@radia"),  utf8Bytes("@sofia"),   utf8Bytes("@vera"),];
const author_initials: readonly Uint8Array[] = [
    utf8Bytes("AB"), utf8Bytes("AK"), utf8Bytes("AE"), utf8Bytes("BL"),
    utf8Bytes("DW"), utf8Bytes("EC"), utf8Bytes("GM"), utf8Bytes("HK"),
    utf8Bytes("IM"), utf8Bytes("KR"), utf8Bytes("LC"), utf8Bytes("MA"),
    utf8Bytes("NW"), utf8Bytes("RP"), utf8Bytes("SK"), utf8Bytes("VC"),];
const openers: readonly Uint8Array[] = [
    utf8Bytes("Shipping it:"),
    utf8Bytes("Today I learned that"),
    utf8Bytes("Hot take:"),
    utf8Bytes("Field note —"),
    utf8Bytes("Small win:"),
    utf8Bytes("Debugging diary:"),
    utf8Bytes("Reading group takeaway:"),
    utf8Bytes("Draft thought:"),];
const subjects: readonly Uint8Array[] = [
    utf8Bytes("the retained tree keeps row state by identity"),
    utf8Bytes("fixed budgets make failure modes honest"),
    utf8Bytes("a flat list reads faster than a wall of cards"),
    utf8Bytes("the scrollbar should always tell the truth"),
    utf8Bytes("uniform row heights turn layout into arithmetic"),
    utf8Bytes("the model owns the data, the runtime owns the viewport"),
    utf8Bytes("overscan is the difference between smooth and shimmer"),
    utf8Bytes("one keyed node per visible row is all a feed needs"),
    utf8Bytes("deterministic fixtures beat recorded network traffic"),
    utf8Bytes("an approach-end signal wants hysteresis, not a timer"),
    utf8Bytes("typed messages make dispatch a compiler problem"),
    utf8Bytes("windowed builds keep the arena small and warm"),];
const closers: readonly Uint8Array[] = [
    utf8Bytes("More tomorrow."),
    utf8Bytes("Notes in the repo."),
    utf8Bytes("Convince me otherwise."),
    utf8Bytes("It held up under 100k rows."),
    utf8Bytes("The gate agrees."),
    utf8Bytes("Still chewing on it."),
    utf8Bytes("Benchmarks pending."),
    utf8Bytes("Filed under obvious-in-hindsight."),];

function multiply(a: Uint8Array, b: Uint8Array): Uint8Array {
  const product = new Uint8Array(16);
  for (let i = 0; i < 8; i++) {
    let carry = 0;
    for (let j = 0; j < 8; j++) {
      const at = i + j, total = (product[at] ?? 0) + (a[i] ?? 0) * (b[j] ?? 0) + carry;
      product[at] = total & 255;
      carry = total >>> 8;
    }
    product[i + 8] = carry;
  }
  return product;
}
function xor(a: Uint8Array, b: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(8);
  for (let i = 0; i < 8; i++) bytes[i] = (a[i] ?? 0) ^ (b[i] ?? 0);
  return bytes;
}
function mix(a: Uint8Array, b: Uint8Array): Uint8Array {
  const product = multiply(a, b);
  return xor(product.subarray(0, 8), product.subarray(8));
}
function secret0(): Uint8Array { const bytes = new Uint8Array(8); bytes.set([47, 100, 189, 120, 100, 29, 118, 160]); return bytes; }
function secret1(): Uint8Array { const bytes = new Uint8Array(8); bytes.set([219, 40, 180, 160, 209, 126, 3, 231]); return bytes; }
/** Exact Wyhash over the eight-byte index, for exact TypeScript integers. */
export function corpusHash(seed: number, index: number): Uint8Array {
  const seedBytes = new Uint8Array(8), a = new Uint8Array(8), b = new Uint8Array(8);
  let upper = 0, remaining = index;
  if (index >= 4294967296) {
    for (let step = 1048576; step > 0; step >>>= 1) {
      const weight = step * 4294967296;
      if (remaining >= weight) { remaining -= weight; upper += step; }
    }
  }
  for (let i = 0; i < 4; i++) {
    seedBytes[i] = (seed >>> (i * 8)) & 255;
    a[i] = (upper >>> (i * 8)) & 255;
    a[i + 4] = (index >>> (i * 8)) & 255;
    b[i] = (index >>> (i * 8)) & 255;
    b[i + 4] = (upper >>> (i * 8)) & 255;
  }
  const state = xor(seedBytes, mix(xor(seedBytes, secret0()), secret1()));
  const product = multiply(xor(a, secret1()), xor(b, state));
  const length = new Uint8Array(8); length[0] = 8;
  return mix(xor(xor(product.subarray(0, 8), secret0()), length), xor(product.subarray(8), secret1()));
}
function remainder(hash: Uint8Array, start: number, modulus: number): number {
  let result = 0;
  for (let i = 7; i >= start; i--) result = (result * 256 + (hash[i] ?? 0)) % modulus;
  return result;
}
export interface Post {
  readonly author: Uint8Array; readonly handle: Uint8Array; readonly initials: Uint8Array;
  readonly opener: Uint8Array; readonly subject: Uint8Array; readonly closer: Uint8Array;
  readonly minutes_ago: number; readonly likes: number; readonly boosts: number; readonly replies: number;
}
export function postAt(index: number): Post {
  const hash = corpusHash(0xfeed0001, index), author = remainder(hash, 0, 16);
  return { author: author_names[author] ?? utf8Bytes(""), handle: author_handles[author] ?? utf8Bytes(""), initials: author_initials[author] ?? utf8Bytes(""), opener: openers[remainder(hash, 1, 8)] ?? utf8Bytes(""), subject: subjects[remainder(hash, 2, 12)] ?? utf8Bytes(""), closer: closers[remainder(hash, 3, 8)] ?? utf8Bytes(""), minutes_ago: index % 1440, likes: remainder(hash, 4, 900), boosts: remainder(hash, 5, 120), replies: remainder(hash, 6, 40) };
}
export function postBodySentences(index: number): number {
  const hash = corpusHash(0xfeed0002, index);
  if (index % 47 === 0) return 14 + remainder(hash, 0, 6);
  if (index % 13 === 0) return 6 + remainder(hash, 0, 4);
  return 1 + remainder(hash, 0, 3);
}
function sentence(index: number, extra: number): Uint8Array { return subjects[remainder(corpusHash(0xfeed0003 + extra, index), 0, 12)] ?? utf8Bytes(""); }
export function postBody(index: number): Uint8Array {
  const post = postAt(index), extras = postBodySentences(index) - 1;
  const parts: Uint8Array[] = [post.opener, utf8Bytes(" "), post.subject, utf8Bytes(".")];
  for (let k = 0; k < extras; k++) { parts.push(utf8Bytes(" ")); parts.push(sentence(index, k)); parts.push(utf8Bytes(".")); }
  parts.push(utf8Bytes(" ")); parts.push(post.closer);
  let size = 0;
  for (const part of parts) size += part.length;
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const part of parts) { bytes.set(part, at); at += part.length; }
  return bytes;
}
export function postBodyLength(index: number): number {
  const post = postAt(index);
  let length = post.opener.length + 1 + post.subject.length + 1;
  for (let k = 0; k < postBodySentences(index) - 1; k++) length += 1 + sentence(index, k).length + 1;
  return length + 1 + post.closer.length;
}
