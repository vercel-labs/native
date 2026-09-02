// @native-sdk/core/text-doc — multi-block GFM document model.
// Zig counterpart: src/primitives/canvas/text_doc.zig.

export const MAX_DOCUMENT_BLOCKS = 256;

export type BlockKind =
  | "paragraph"
  | "heading1"
  | "heading2"
  | "heading3"
  | "bullet_item"
  | "numbered_item"
  | "code_fence";

export interface DocBlock {
  readonly kind: BlockKind;
  readonly text: Uint8Array;
  readonly language: Uint8Array;
}



function startsWithBytes(hay: Uint8Array, needle: Uint8Array): boolean {
  if (hay.length < needle.length) return false;
  for (let i = 0; i < needle.length; i++) {
    if (hay[i] !== needle[i]) return false;
  }
  return true;
}

const NL = new Uint8Array([10]);
const H1 = new Uint8Array([35, 32]);
const H2 = new Uint8Array([35, 35, 32]);
const H3 = new Uint8Array([35, 35, 35, 32]);
const BULLET = new Uint8Array([45, 32]);
const BULLET_STAR = new Uint8Array([42, 32]);
const FENCE = new Uint8Array([96, 96, 96]);
const NUM_PREFIX = new Uint8Array([49, 46, 32]);
const MERMAID_FENCE = new Uint8Array([96, 96, 96, 109, 101, 114, 109, 97, 105, 100]);
const MATH_DOLLAR = new Uint8Array([36, 36]);

function isBlankLine(line: Uint8Array): boolean {
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (c !== 32 && c !== 9 && c !== 13) return false;
  }
  return true;
}

function trimRightCr(line: Uint8Array): Uint8Array {
  if (line.length > 0 && line[line.length - 1] === 13) {
    return line.subarray(0, line.length - 1);
  }
  return line;
}

function numberedPrefixLen(line: Uint8Array): number {
  let i = 0;
  while (i < line.length) {
    const c = line[i]!;
    if (c < 48 || c > 57) break;
    i += 1;
  }
  if (i === 0) return 0;
  if (i + 2 > line.length) return 0;
  if (line[i] !== 46 || line[i + 1] !== 32) return 0;
  return i + 2;
}

function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

function emptyLang(): Uint8Array {
  return new Uint8Array(0);
}

function copyBytes(b: Uint8Array): Uint8Array {
  const out = new Uint8Array(b.length);
  out.set(b);
  return out;
}

function classifyLine(
  line: Uint8Array,
): { kind: BlockKind; body: Uint8Array } {
  const trimmed = trimRightCr(line);
  if (startsWithBytes(trimmed, H3)) {
    return { kind: "heading3", body: trimmed.subarray(4) };
  }
  if (startsWithBytes(trimmed, H2)) {
    return { kind: "heading2", body: trimmed.subarray(3) };
  }
  if (startsWithBytes(trimmed, H1)) {
    return { kind: "heading1", body: trimmed.subarray(2) };
  }
  if (startsWithBytes(trimmed, BULLET) || startsWithBytes(trimmed, BULLET_STAR)) {
    return { kind: "bullet_item", body: trimmed.subarray(2) };
  }
  const n = numberedPrefixLen(trimmed);
  if (n > 0) {
    return { kind: "numbered_item", body: trimmed.subarray(n) };
  }
  return { kind: "paragraph", body: trimmed };
}

/** Parse GFM subset → blocks. */
export function parseBlocks(source: Uint8Array): DocBlock[] {
  const out: DocBlock[] = [];
  let i = 0;
  let paraParts: Uint8Array[] = [];

  while (i < source.length) {
    const lineStart = i;
    while (i < source.length && source[i] !== 10) i += 1;
    const raw = source.subarray(lineStart, i);
    if (i < source.length) i += 1;
    const line = trimRightCr(raw);

    if (startsWithBytes(line, FENCE)) {
      if (paraParts.length > 0 && out.length < MAX_DOCUMENT_BLOCKS) {
        out.push({
          kind: "paragraph",
          text: concatBytes(paraParts),
          language: emptyLang(),
        });
        paraParts = [];
      }
      if (out.length >= MAX_DOCUMENT_BLOCKS) break;
      const language = copyBytes(line.subarray(3));
      const bodyParts: Uint8Array[] = [];
      while (i < source.length) {
        const fs = i;
        while (i < source.length && source[i] !== 10) i += 1;
        const fenceLine = trimRightCr(source.subarray(fs, i));
        if (i < source.length) i += 1;
        if (startsWithBytes(fenceLine, FENCE)) break;
        if (bodyParts.length > 0) bodyParts.push(NL);
        bodyParts.push(copyBytes(fenceLine));
      }
      out.push({
        kind: "code_fence",
        text: concatBytes(bodyParts),
        language,
      });
      continue;
    }

    if (isBlankLine(line)) {
      if (paraParts.length > 0 && out.length < MAX_DOCUMENT_BLOCKS) {
        out.push({
          kind: "paragraph",
          text: concatBytes(paraParts),
          language: emptyLang(),
        });
        paraParts = [];
      }
      continue;
    }

    const classified = classifyLine(line);
    if (classified.kind === "paragraph") {
      if (paraParts.length > 0) paraParts.push(NL);
      paraParts.push(copyBytes(classified.body));
      continue;
    }

    if (paraParts.length > 0 && out.length < MAX_DOCUMENT_BLOCKS) {
      out.push({
        kind: "paragraph",
        text: concatBytes(paraParts),
        language: emptyLang(),
      });
      paraParts = [];
    }
    if (out.length >= MAX_DOCUMENT_BLOCKS) break;
    out.push({
      kind: classified.kind,
      text: copyBytes(classified.body),
      language: emptyLang(),
    });
  }
  if (paraParts.length > 0 && out.length < MAX_DOCUMENT_BLOCKS) {
    out.push({
      kind: "paragraph",
      text: concatBytes(paraParts),
      language: emptyLang(),
    });
  }
  if (out.length === 0) {
    out.push({ kind: "paragraph", text: emptyLang(), language: emptyLang() });
  }
  return out;
}

function prefixFor(kind: BlockKind): Uint8Array {
  switch (kind) {
    case "heading1":
      return H1;
    case "heading2":
      return H2;
    case "heading3":
      return H3;
    case "bullet_item":
      return BULLET;
    case "numbered_item":
      return NUM_PREFIX;
    case "code_fence":
      return FENCE;
    case "paragraph":
      return emptyLang();
  }
}

/** Serialize blocks to GFM bytes. */
export function serializeBlocks(blocks: readonly DocBlock[]): Uint8Array {
  const parts: Uint8Array[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i]!;
    if (i > 0) {
      parts.push(NL);
      const prev = blocks[i - 1]!;
      if (
        block.kind === "paragraph" ||
        prev.kind === "paragraph" ||
        prev.kind === "heading1" ||
        prev.kind === "heading2" ||
        prev.kind === "heading3" ||
        prev.kind === "code_fence"
      ) {
        parts.push(NL);
      }
    }
    if (block.kind === "code_fence") {
      parts.push(FENCE);
      parts.push(block.language);
      parts.push(NL);
      parts.push(block.text);
      if (
        block.text.length === 0 ||
        block.text[block.text.length - 1] !== 10
      ) {
        parts.push(NL);
      }
      parts.push(FENCE);
      continue;
    }
    parts.push(prefixFor(block.kind));
    parts.push(block.text);
  }
  return concatBytes(parts);
}

export function splitBlock(
  blocks: readonly DocBlock[],
  index: number,
  byteOffset: number,
): DocBlock[] | null {
  if (index < 0 || index >= blocks.length) return null;
  if (blocks.length + 1 > MAX_DOCUMENT_BLOCKS) return null;
  const src = blocks[index]!;
  const off =
    byteOffset < 0 ? 0 : byteOffset > src.text.length ? src.text.length : byteOffset;
  const out: DocBlock[] = [];
  for (let i = 0; i < blocks.length; i++) {
    if (i === index) {
      const rightKind: BlockKind =
        src.kind === "code_fence" ? "code_fence" : "paragraph";
      out.push({
        kind: src.kind,
        text: copyBytes(src.text.subarray(0, off)),
        language:
          src.kind === "code_fence" ? copyBytes(src.language) : emptyLang(),
      });
      out.push({
        kind: rightKind,
        text: copyBytes(src.text.subarray(off)),
        language:
          rightKind === "code_fence" ? copyBytes(src.language) : emptyLang(),
      });
    } else {
      const b = blocks[i]!;
      out.push({
        kind: b.kind,
        text: copyBytes(b.text),
        language: copyBytes(b.language),
      });
    }
  }
  return out;
}

export function mergeWithPrevious(
  blocks: readonly DocBlock[],
  index: number,
): DocBlock[] | null {
  if (index <= 0 || index >= blocks.length) return null;
  const left = blocks[index - 1]!;
  const right = blocks[index]!;
  const out: DocBlock[] = [];
  for (let i = 0; i < blocks.length; i++) {
    if (i === index - 1) {
      out.push({
        kind: left.kind,
        text: concatBytes([left.text, right.text]),
        language: copyBytes(left.language),
      });
    } else if (i === index) {
      continue;
    } else {
      const b = blocks[i]!;
      out.push({
        kind: b.kind,
        text: copyBytes(b.text),
        language: copyBytes(b.language),
      });
    }
  }
  return out;
}

export function changeBlockKind(
  blocks: readonly DocBlock[],
  index: number,
  kind: BlockKind,
): DocBlock[] | null {
  if (index < 0 || index >= blocks.length) return null;
  const out: DocBlock[] = [];
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i]!;
    if (i === index) {
      out.push({
        kind,
        text: copyBytes(b.text),
        language: kind === "code_fence" ? copyBytes(b.language) : emptyLang(),
      });
    } else {
      out.push({
        kind: b.kind,
        text: copyBytes(b.text),
        language: copyBytes(b.language),
      });
    }
  }
  return out;
}

/** True when source needs Lexical (tables / mermaid / math). */
export function gfmNeedsLexicalFallback(source: Uint8Array): boolean {
  // pipe table row, mermaid fence, or $$ math
  let i = 0;
  let lineStart = 0;
  let sawPipeRow = false;
  while (i <= source.length) {
    if (i === source.length || source[i] === 10) {
      const line = trimRightCr(source.subarray(lineStart, i));
      if (startsWithBytes(line, MERMAID_FENCE)) return true;
      if (startsWithBytes(line, MATH_DOLLAR)) return true;
      let pipes = 0;
      for (let j = 0; j < line.length; j++) {
        if (line[j] === 124) pipes += 1;
      }
      if (pipes >= 2) {
        if (sawPipeRow) return true;
        sawPipeRow = true;
      } else {
        sawPipeRow = false;
      }
      lineStart = i + 1;
    }
    i += 1;
  }
  return false;
}

