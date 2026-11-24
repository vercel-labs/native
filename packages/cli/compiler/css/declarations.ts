// Compiling a style attribute or a rule's declaration block, with diagnostics. The value
// parsing itself lives in shared/css/, so the runtime can reuse it for inline style changes.

import { type Diagnostics } from "../diagnostics.ts";
import { parseDeclarationBlock, skipString, type ParsedDeclaration } from "../../shared/css/declarations.ts";
import type { Loc } from "./selectors.ts";
import { supportsHolds } from "./supports.ts";
import type { ContentContext, Decl, FontContext } from "./types.ts";

const UNSUPPORTED_HINTS: Record<string, string> = {
  "float": "use display: flex",
};

/** Index just past the `}` matching the `{` at `open`, or the end of the text if unterminated. */
function blockEnd(body: string, open: number): number {
  let depth = 1;
  for (let i = open + 1; i < body.length; i++) {
    const ch = body[i];
    if (ch === '"' || ch === "'") { i = skipString(body, i) - 1; continue; }
    if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) return i + 1;
  }
  return body.length;
}

/**
 * Compiles a declaration block. A nested @supports group holds declarations for the same
 * element, as Tailwind writes to upgrade a colour when color-mix() is available; its condition
 * is decided here, and its declarations take their place in the cascade when it holds.
 */
export function compileDeclarations(body: string, loc: Loc, file: string, diags: Diagnostics, fonts?: FontContext, content?: ContentContext): Decl[] {
  const out: Decl[] = [];
  compileRange(body, 0, out, loc, file, diags, fonts, content);
  return out;
}

function compileRange(body: string, base: number, out: Decl[], loc: Loc, file: string, diags: Diagnostics,
  fonts: FontContext | undefined, content: ContentContext | undefined): void {
  const report = (d: ParsedDeclaration): void => {
    if (d.blank) return;
    for (const decl of d.decls) out.push(decl);
    if (d.error === null) return;
    const [line, col] = loc(base + d.offset + d.lead);
    // A value the build takes but renders differently from a browser is reported as a note, so
    // the page still counts as supported. Some values are invalid CSS: a browser drops the
    // declaration. Say so without skipping the page over it either.
    if (d.error.startsWith("note: ")) diags.note(file, line, col, d.error.slice("note: ".length));
    else if (d.error.startsWith("invalid ")) diags.note(file, line, col, d.error);
    else if (d.prop === "font") diags.warn(file, line, col, d.error, UNSUPPORTED_HINTS.font);
    else diags.warn(file, line, col, d.error, UNSUPPORTED_HINTS[d.prop]);
  };
  const chunk = (start: number, end: number): void => {
    if (end <= start) return;
    for (const d of parseDeclarationBlock(body.slice(start, end), fonts, (off) => loc(base + start + off), content)) report(d);
  };

  let chunkStart = 0;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === '"' || ch === "'") { i = skipString(body, i) - 1; continue; }
    if (ch !== "@") continue;
    const m = /^@([\w-]+)\s*/.exec(body.slice(i));
    if (m === null) continue;
    let open = i + m[0].length;
    while (open < body.length && body[open] !== "{" && body[open] !== ";") open++;
    if (open >= body.length || body[open] !== "{") continue; // a statement at-rule: report it as text
    const end = blockEnd(body, open);
    if (m[1].toLowerCase() === "supports") {
      chunk(chunkStart, i);
      const cond = body.slice(i + m[0].length, open).trim().replace(/\s+/g, " ");
      const holds = supportsHolds(cond);
      const [line, col] = loc(base + i);
      if (holds === null) diags.warn(file, line, col, `invalid @supports condition '${cond}'; its declarations are ignored`);
      else if (!holds) diags.note(file, line, col, `@supports '${cond}' doesn't hold here; its declarations are ignored`);
      else compileRange(body.slice(open + 1, end - 1), base + open + 1, out, loc, file, diags, fonts, content);
      i = end - 1;
      chunkStart = end;
    } else {
      // Not a conditional group: leave the text in place, so the declaration parser reports it.
      i = end - 1;
    }
  }
  chunk(chunkStart, body.length);
}
