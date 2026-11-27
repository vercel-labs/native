// A small HTML parser: elements, attributes, text, comments, raw-text <script>/<style>.
// Good enough for hand-written app markup; not a spec-compliant tokenizer.

/**
 * The document mode the doctype selects (HTML's quirks-mode algorithm, in its common cases):
 * 0 for no-quirks, 1 for quirks (no doctype, an old one, or a transitional one without a system
 * identifier) and 2 for limited-quirks (XHTML 1.0 and HTML 4.01 transitional/frameset).
 */
/** The page's doctype: its name and the public and system identifiers it carries, if any. */
export function doctypeOf(src: string): { name: string; publicId: string; systemId: string } | null {
  const m = /^\s*<!doctype\s+([^>]*)>/i.exec(src);
  if (m === null) return null;
  const body = m[1].trim();
  const nameMatch = /^([^\s\[]+)/.exec(body);
  if (nameMatch === null) return null;
  const rest = body.slice(nameMatch[1].length);
  const ids = [...rest.matchAll(/"([^"]*)"/g)].map((q) => q[1]);
  const isPublic = /^\s*public/i.test(rest);
  return {
    name: nameMatch[1],
    publicId: isPublic && ids.length > 0 ? ids[0] : "",
    systemId: isPublic ? (ids.length > 1 ? ids[1] : "") : ids.length > 0 ? ids[0] : "",
  };
}

/**
 * The encoding a page's own markup declares: a `<meta charset>` or an http-equiv content-type,
 * lowercased, as document.characterSet reports it. No declaration is UTF-8, which is how this
 * build reads its files.
 */
export function pageCharset(src: string): string {
  const direct = /<meta\s[^>]*charset\s*=\s*["']?([^"'\s/>]+)/i.exec(src);
  if (direct !== null) return direct[1].toLowerCase();
  const equiv = /<meta\s[^>]*http-equiv\s*=\s*["']?content-type["']?[^>]*content\s*=\s*["'][^"']*charset\s*=\s*([^"'\s;]+)/i.exec(src);
  return equiv === null ? "UTF-8" : equiv[1].toLowerCase();
}

export function documentMode(src: string): number {
  const head = src.slice(0, 1024);
  const m = /^\s*<!doctype\s+([^>]*)>/i.exec(head);
  if (m === null) return 1;
  const body = m[1].trim();
  const pn = /^([^\s]+)/.exec(body);
  const name = pn === null ? "" : pn[1].toLowerCase();
  const pub = /public\s+(["'])([^"']*)\1/i.exec(body);
  const sys = /(?:public\s+(["'])[^"']*\1\s+|system\s+)(["'])([^"']*)\2/i.exec(body);
  const pubId = pub === null ? "" : pub[2];
  const sysId = sys === null ? "" : sys[3];
  if (name !== "html") return 1;
  // Old identifiers that force quirks, transitional or not.
  const quirky = [
    "-//w3o//dtd w3 html strict 3.0//en//", "-/w3c/dtd html 4.0 transitional/en", "html",
  ];
  const quirkyPrefix = [
    "+//silmaril//dtd html pro v0r11 19970101//", "-//as//dtd html 3.0 aswedit + extensions//",
    "-//advasoft ltd//dtd html 3.0 aswedit + extensions//", "-//ietf//dtd html 2.0 level 1//",
    "-//ietf//dtd html 2.0 level 2//", "-//ietf//dtd html 2.0 strict level 1//",
    "-//ietf//dtd html 2.0 strict level 2//", "-//ietf//dtd html 2.0 strict//",
    "-//ietf//dtd html 2.0//", "-//ietf//dtd html 2.1e//", "-//ietf//dtd html 3.0//",
    "-//ietf//dtd html 3.2 final//", "-//ietf//dtd html 3.2//", "-//ietf//dtd html 3//",
    "-//ietf//dtd html level 0//", "-//ietf//dtd html level 1//", "-//ietf//dtd html level 2//",
    "-//ietf//dtd html level 3//", "-//ietf//dtd html strict level 0//",
    "-//ietf//dtd html strict level 1//", "-//ietf//dtd html strict level 2//",
    "-//ietf//dtd html strict level 3//", "-//ietf//dtd html strict//",
    "-//ietf//dtd html//", "-//metrius//dtd metrius presentational//",
    "-//microsoft//dtd internet explorer 2.0 html strict//", "-//microsoft//dtd internet explorer 2.0 html//",
    "-//microsoft//dtd internet explorer 2.0 tables//", "-//microsoft//dtd internet explorer 3.0 html strict//",
    "-//microsoft//dtd internet explorer 3.0 html//", "-//microsoft//dtd internet explorer 3.0 tables//",
    "-//netscape comm. corp.//dtd html//", "-//netscape comm. corp.//dtd strict html//",
    "-//o'reilly and associates//dtd html 2.0//", "-//o'reilly and associates//dtd html extended 1.0//",
    "-//o'reilly and associates//dtd html extended relaxed 1.0//",
    "-//sq//dtd html 2.0 hotmetal + extensions//",
    "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
    "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//",
    "-//spyglass//dtd html 2.0 extended//", "-//sun microsystems corp.//dtd hotjava html//",
    "-//sun microsystems corp.//dtd hotjava strict html//", "-//w3c//dtd html 3 1995-03-24//",
    "-//w3c//dtd html 3.2 draft//", "-//w3c//dtd html 3.2 final//", "-//w3c//dtd html 3.2//",
    "-//w3c//dtd html 3.2s draft//", "-//w3c//dtd html 4.0 frameset//",
    "-//w3c//dtd html 4.0 transitional//", "-//w3c//dtd html experimental 19960712//",
    "-//w3c//dtd html experimental 970421//", "-//w3c//dtd w3 html//", "-//w3o//dtd w3 html 3.0//",
    "-//webtechs//dtd mozilla html 2.0//", "-//webtechs//dtd mozilla html//",
  ];
  if (quirky.includes(pubId.toLowerCase())) return 1;
  if (sysId.toLowerCase() === "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd") return 1;
  const lp = pubId.toLowerCase();
  if (quirkyPrefix.some((p) => lp.startsWith(p))) return 1;
  if (sysId === "") {
    if (lp.startsWith("-//w3c//dtd html 4.01 frameset//") || lp.startsWith("-//w3c//dtd html 4.01 transitional//")) return 1;
  }
  const limited = ["-//w3c//dtd xhtml 1.0 frameset//", "-//w3c//dtd xhtml 1.0 transitional//"];
  if (limited.some((p) => lp.startsWith(p))) return 2;
  if (sysId !== "") {
    if (lp.startsWith("-//w3c//dtd html 4.01 frameset//") || lp.startsWith("-//w3c//dtd html 4.01 transitional//")) return 2;
  }
  return 0;
}

import { type Diagnostics, locator } from "./diagnostics.ts";
import { NAMED_ENTITIES } from "../shared/entities.ts";

export interface HElement {
  kind: "element";
  tag: string;
  attrs: Map<string, string>;
  children: HNode[];
  line: number;
  col: number;
  /** A newline right after this start tag is not content: HTML drops one for pre, textarea and
   *  listing, so a page may write them on lines of their own. */
  dropNewline?: boolean;
}

export interface HText {
  kind: "text";
  text: string;
  line: number;
  col: number;
}

/** A processing instruction: its target and the data after it, which stays in the DOM. */
export interface HProcessingInstruction {
  kind: "pi";
  target: string;
  data: string;
  line: number;
  col: number;
}

export type HNode = HElement | HText | HProcessingInstruction;

const VOID = new Set([
  "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
]);
const RAW_TEXT = new Set(["script", "style"]);

// HTML's implied end tags: these start tags close an open <p>, as do the list-item ones.
const CLOSES_P = new Set([
  "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
  "dd", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
  "h6", "header", "hgroup", "hr", "li", "main", "menu", "nav", "ol", "p", "pre", "section",
  "summary", "table", "ul",
]);
// Elements that bound the scope in which an implied end tag is looked for.
const SCOPE_STOP = new Set(["html", "table", "td", "th", "caption", "button", "marquee", "object", "applet", "template", "svg", "math"]);
const LIST_STOP = new Set(["ul", "ol", "menu"]);

// The elements <head> holds. Any other start tag closes an open head, as in HTML: a document
// that writes <body> without </head> would otherwise put the whole page inside the head, where
// the compiler drops it.
const HEAD_CONTENT = new Set([
  "base", "basefont", "bgsound", "link", "meta", "title", "style", "script", "noscript", "template",
]);
// Elements the parser closes on its own, whose stray close tags are therefore not mistakes.
const IMPLIED_CLOSE = new Set(["head", "body", "html"]);

// Table content has implied end tags: a new <td> ends the open cell, a new <tr> ends the open
// cell and row, and a new row group ends the row. Without them, omitted </td> and </tr> (very
// common in tests and hand-written tables) nest each row inside the previous row's cell.
const CELLS = ["td", "th"];
const SECTIONS = new Set(["tbody", "thead", "tfoot"]);
const CELL_STOP = new Set(["table", "tbody", "thead", "tfoot", "tr"]);
const SECTION_STOP = new Set(["table", "tbody", "thead", "tfoot"]);

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]+);/gi, (m, name: string) => {
    if (name[0] === "#") {
      const code = name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    // The names are case-sensitive: `&amp;` and `&AMP;` are both references, `&Amp;` is not.
    const chars = NAMED_ENTITIES[name];
    return chars === undefined ? m : chars;
  });
}

/**
 * The text of an XHTML <style> or <script>: a character reference is decoded, except inside a
 * CDATA section, which XML treats as literal text. The section's markers themselves are markup,
 * and an XML parser hands on only what they enclose.
 */
function xmlText(text: string): string {
  let out = "";
  let i = 0;
  for (;;) {
    const start = text.indexOf("<![CDATA[", i);
    if (start < 0) return out + decodeEntities(text.slice(i));
    out += decodeEntities(text.slice(i, start));
    const end = text.indexOf("]]>", start + 9);
    // An unterminated section isn't markup a browser accepts; leave it as written.
    if (end < 0) return out + text.slice(start);
    out += text.slice(start + 9, end);
    i = end + 3;
  }
}

export function parseHtml(src: string, file: string, diags: Diagnostics, kind: "html" | "svg" = "html"): HElement {
  // A byte-order mark is not content: a file that starts with one would otherwise begin with a
  // stray text node, which renders as an empty line above everything.
  if (src.charCodeAt(0) === 0xfeff) src = src.slice(1);
  // An XHTML page is XML to a browser, where <style> and <script> content is PCDATA and its
  // character references are decoded. In HTML those are raw text and are left as written.
  const xml = /\.xht(ml)?$/i.test(file);
  const loc = locator(src);
  const root: HElement = { kind: "element", tag: "#document", attrs: new Map(), children: [], line: 1, col: 1 };
  const stack: HElement[] = [root];
  let i = 0;
  // A tag <head> can't hold closes the head, and the content goes into an implicit <body>, as a
  // browser builds one: it belongs to the body, not to <html> above it.
  let implicitBody: HElement | null = null;
  // The head a browser makes when the markup starts with head content and no <head> tag.
  let implicitHead: HElement | null = null;
  // The <html> element a browser makes when the page has no <html> tag at all. A page written
  // with bare <title>, <link> and content still gets the document skeleton the parser builds:
  // html, with the head and body inside it.
  let implicitHtml: HElement | null = null;
  // The document's body, whether the page wrote it or the parser made it. Content after </body>
  // goes back inside it, as a browser's parser leaves "after body" for "in body": a script the
  // page writes after its body is still the body's, and a page whose markup is a bare <body> has
  // one body, not a second one the parser made for the content that followed.
  let bodyEl: HElement | null = null;

  const top = () => stack[stack.length - 1];

  /** The document element, made (and re-entered) as a browser builds it. */
  const enterHtml = (line: number, col: number): HElement => {
    if (implicitHtml !== null) {
      if (!stack.includes(implicitHtml)) stack.push(implicitHtml);
      return implicitHtml;
    }
    for (let s = stack.length - 1; s > 0; s--) if (stack[s].tag === "html") return stack[s];
    implicitHtml = { kind: "element", tag: "html", attrs: new Map(), children: [], line, col };
    root.children.push(implicitHtml);
    stack.push(implicitHtml);
    return implicitHtml;
  };

  /** The implicit body, opened inside the html element when body content arrives. */
  const enterImplicitBody = (line: number, col: number): HElement => {
    const html = enterHtml(line, col);
    // A body the page wrote itself is the one its later content belongs to.
    if (implicitBody === null) {
      for (const c of html.children) {
        if (c.kind === "element" && c.tag === "body") { implicitBody = c; break; }
      }
    }
    if (implicitBody === null) {
      implicitBody = { kind: "element", tag: "body", attrs: new Map(), children: [], line, col };
      html.children.push(implicitBody);
    }
    if (!stack.includes(implicitBody)) stack.push(implicitBody);
    bodyEl = implicitBody;
    return implicitBody;
  };

  /** Enters the document's body for content that follows it: the body the page wrote itself is
   *  re-entered, and a page that has none gets the implicit one a browser builds. */
  const enterBody = (line: number, col: number): HElement => {
    if (bodyEl !== null) {
      if (!stack.includes(bodyEl)) stack.push(bodyEl);
      return bodyEl;
    }
    return enterImplicitBody(line, col);
  };

  /** Closes the nearest open element in `tags`, unless a scope boundary comes first. */
  const closeInScope = (tags: string[], extra: Set<string> | null): void => {
    for (let s = stack.length - 1; s > 0; s--) {
      const t = stack[s].tag;
      if (tags.includes(t)) { stack.length = s; return; }
      if (SCOPE_STOP.has(t) || (extra !== null && extra.has(t))) return;
    }
  };

  /** Closes the outermost open element in `tags` above the nearest `stop` boundary. */
  const closeTags = (tags: string[], stop: Set<string>): void => {
    let cut = -1;
    for (let s = stack.length - 1; s > 0; s--) {
      const t = stack[s].tag;
      if (tags.includes(t)) cut = s;
      else if (stop.has(t)) break;
    }
    if (cut >= 0) stack.length = cut;
  };

  while (i < src.length) {
    if (src.startsWith("<!--", i)) {
      const end = src.indexOf("-->", i + 4);
      i = end < 0 ? src.length : end + 3;
      top().dropNewline = false;
      continue;
    }
    if (src.startsWith("<?", i)) {
      // A processing instruction is a node of the document, as in XML and as the HTML parser
      // makes one for `<?target data?>`; the `<?xml …?>` prolog is a declaration, not a node.
      const end = src.indexOf("?>", i);
      const body = src.slice(i + 2, end < 0 ? src.length : end);
      const [line, col] = loc(i);
      i = end < 0 ? src.length : end + 2;
      const sp = body.search(/\s/);
      const target = (sp < 0 ? body : body.slice(0, sp)).trim();
      const data = sp < 0 ? "" : body.slice(sp + 1).replace(/^\s+/, "");
      if (target !== "" && target.toLowerCase() !== "xml") {
        top().children.push({ kind: "pi", target, data, line, col });
      }
      continue;
    }
    if (src.startsWith("<!", i)) {
      const end = src.indexOf(">", i);
      i = end < 0 ? src.length : end + 1;
      continue;
    }
    if (src.startsWith("</", i)) {
      top().dropNewline = false;
      const end = src.indexOf(">", i);
      const tag = src.slice(i + 2, end < 0 ? src.length : end).trim().toLowerCase();
      const [line, col] = loc(i);
      let found = -1;
      for (let s = stack.length - 1; s > 0; s--) {
        if (stack[s].tag === tag) { found = s; break; }
      }
      // A close tag for a void element (</col>, </br>) is ignored, as in HTML, and so is one for
      // an element the parser closed for the author — </head> after a tag the head can't hold,
      // say, or </body> and </html>, whose closing tags browsers take in their stride. </html>
      // leaves the document element open, as a browser's parser does: it only changes where the
      // content that follows goes, and that is still inside html.
      // Any other end tag — a stray </style>, say, or one for a void element — is ignored, as a
      // browser's parser ignores it: the document goes on as if it weren't there.
      if (found >= 0 && tag !== "html") stack.length = found;
      i = end < 0 ? src.length : end + 1;
      continue;
    }
    if (src[i] === "<" && /[a-zA-Z]/.test(src[i + 1] ?? "")) {
      const [line, col] = loc(i);
      let j = i + 1;
      while (j < src.length && /[^\s/>]/.test(src[j])) j++;
      const tag = src.slice(i + 1, j).toLowerCase();
      const attrs = new Map<string, string>();
      let selfClosing = false;
      while (j < src.length) {
        while (/\s/.test(src[j])) j++;
        if (src[j] === ">") { j++; break; }
        if (src.startsWith("/>", j)) { selfClosing = true; j += 2; break; }
        let k = j;
        while (k < src.length && /[^\s=/>]/.test(src[k])) k++;
        const name = src.slice(j, k).toLowerCase();
        j = k;
        while (/\s/.test(src[j])) j++;
        let value = "";
        if (src[j] === "=") {
          j++;
          while (/\s/.test(src[j])) j++;
          const q = src[j];
          if (q === '"' || q === "'") {
            const end = src.indexOf(q, j + 1);
            value = src.slice(j + 1, end < 0 ? src.length : end);
            j = end < 0 ? src.length : end + 1;
          } else {
            k = j;
            while (k < src.length && /[^\s>]/.test(src[k])) k++;
            value = src.slice(j, k);
            j = k;
          }
        }
        if (name) attrs.set(name, decodeEntities(value));
        else j++;
      }
      const el: HElement = { kind: "element", tag, attrs, children: [], line, col };
      // A tag <head> can't hold ends it: the browser closes the head there.
      if (!HEAD_CONTENT.has(tag)) {
        for (let s = stack.length - 1; s > 0; s--) {
          if (stack[s].tag !== "head") continue;
          stack.length = s;
          break;
        }
      }
      // An explicit <html> after an implicit one merges into it, as <body> below does.
      if (tag === "html" && implicitHtml !== null) {
        const html = enterHtml(line, col);
        for (const [k, v] of el.attrs) html.attrs.set(k, v);
        i = j;
        continue;
      }
      // Content that follows the page's body goes back inside it, as a browser's parser does
      // when it leaves "after body" mode: a script written after </body> is the body's, and a
      // page whose markup is a bare <body> keeps that one body for the content that follows.
      if (kind === "html" && bodyEl !== null && (top().tag === "#document" || top().tag === "html") &&
        tag !== "html" && tag !== "head" && tag !== "body" && !stack.includes(bodyEl)) {
        stack.push(bodyEl);
      }
      // Head content under <html> with no head yet builds the implicit head a browser makes, so
      // the title, links and scripts a page writes before its body live where a browser puts them.
      if (kind === "html" && tag !== "html" && tag !== "head" && tag !== "body" && HEAD_CONTENT.has(tag) &&
        (top().tag === "html" || top().tag === "#document") &&
        implicitHead === null && !stack.some((e) => e.tag === "head")) {
        const html = enterHtml(line, col);
        implicitHead = { kind: "element", tag: "head", attrs: new Map(), children: [], line, col };
        html.children.push(implicitHead);
        stack.push(implicitHead);
      }
      // Body content under <html> with no body yet builds the implicit body a browser makes, so
      // its margins and the UA sheet's body rules apply.
      if (kind === "html" && tag !== "html" && tag !== "head" && tag !== "body" && !HEAD_CONTENT.has(tag) &&
        (top().tag === "html" || top().tag === "#document") &&
        implicitBody === null && !stack.some((e) => e.tag === "body")) {
        enterImplicitBody(line, col);
      }
      // An explicit <body> after the body the document already has merges into it rather than
      // nesting a second body.
      if (tag === "body" && (implicitBody !== null || bodyEl !== null)) {
        for (let s = stack.length - 1; s > 0; s--) if (stack[s].tag === "head") { stack.length = s; break; }
        const body = enterBody(line, col);
        for (const [k, v] of el.attrs) body.attrs.set(k, v);
        i = j;
        continue;
      }
      // A heading start tag closes a heading the parser left as the current node, as HTML does,
      // so invalidly nested headings become siblings rather than nesting.
      if (/^h[1-6]$/.test(tag) && /^h[1-6]$/.test(top().tag)) stack.pop();
      if (CLOSES_P.has(tag)) closeInScope(["p"], null);
      if (tag === "li") closeInScope(["li"], LIST_STOP);
      else if (tag === "dt" || tag === "dd") closeInScope(["dt", "dd"], LIST_STOP);
      else if (tag === "option") closeInScope(["option"], null);
      else if (tag === "optgroup") closeInScope(["option", "optgroup"], null);
      // A cell or a row ends an open <colgroup>: HTML closes the column group as soon as anything
      // but a <col> follows it, and its end tag is usually left out.
      else if (CELLS.includes(tag)) closeTags([...CELLS, "colgroup"], CELL_STOP);
      else if (tag === "tr") closeTags([...CELLS, "tr", "colgroup"], SECTION_STOP);
      else if (tag === "tbody" || tag === "thead" || tag === "tfoot" || tag === "caption" || tag === "colgroup")
        closeTags([...CELLS, "tr", "tbody", "thead", "tfoot", "caption", "colgroup"], new Set(["table"]));
      // HTML's table insertion modes imply the rows and sections markup leaves out: a row in a
      // table goes in an implied tbody, and a cell in a table or section goes in an implied tr.
      // XML has no such implication, so an XHTML page keeps exactly the tree it writes.
      if (!xml) {
        const implied = (name: string): void => {
          const node: HElement = { kind: "element", tag: name, attrs: new Map(), children: [], line, col };
          top().children.push(node);
          stack.push(node);
        };
        if (tag === "tr" && top().tag === "table") implied("tbody");
        else if (CELLS.includes(tag)) {
          if (top().tag === "table") implied("tbody");
          if (SECTIONS.has(top().tag)) implied("tr");
        }
      }
      const parent = top();
      parent.children.push(el);
      // The document's body: a <body> the page wrote under <html> (or at the top of a page with
      // no <html> tag) is the one later content belongs to. One nested in a box is just a box.
      if (tag === "body" && (parent.tag === "html" || parent.tag === "#document")) bodyEl = el;
      i = j;
      if (tag === "pre" || tag === "listing" || tag === "textarea") el.dropNewline = true;
      if (RAW_TEXT.has(tag)) {
        const close = src.toLowerCase().indexOf(`</${tag}`, i);
        const end = close < 0 ? src.length : close;
        const [tl, tc] = loc(i);
        const raw = src.slice(i, end);
        el.children.push({ kind: "text", text: xml ? xmlText(raw) : raw, line: tl, col: tc });
        const gt = close < 0 ? -1 : src.indexOf(">", close);
        i = gt < 0 ? src.length : gt + 1;
      } else if (!selfClosing && !VOID.has(tag)) {
        stack.push(el);
      }
      continue;
    }
    // Text
    let end = src.indexOf("<", i + 1);
    if (end < 0) end = src.length;
    const [line, col] = loc(i);
    let text = decodeEntities(src.slice(i, end));
    const holder = top();
    if (holder.dropNewline) {
      holder.dropNewline = false;
      if (text.startsWith("\r\n")) text = text.slice(2);
      else if (text.startsWith("\n")) text = text.slice(1);
    }
    // Text under <html> with no body yet builds the implicit body too: a browser puts the page's
    // text in the body, and the box it makes (a flex or grid item, say) has to exist for layout.
    // Text after </body> belongs to the body all the same.
    if (kind === "html" && (top().tag === "html" || top().tag === "#document")) {
      const bodyOpen = bodyEl !== null ? stack.includes(bodyEl) : stack.some((e) => e.tag === "body");
      if (!bodyOpen && (implicitBody !== null || /\S/.test(text))) enterBody(line, col);
      else if (top().tag === "#document" && !/\S/.test(text)) {
        // White space before the document element is ignored, as a browser ignores it before <html>.
        i = end;
        continue;
      }
    }
    top().children.push({ kind: "text", text, line, col });
    i = end;
  }
  return root;
}

export function findAll(el: HElement, pred: (e: HElement) => boolean, out: HElement[] = []): HElement[] {
  for (const c of el.children) {
    if (c.kind !== "element") continue;
    if (pred(c)) out.push(c);
    findAll(c, pred, out);
  }
  return out;
}

export function textOf(el: HElement): string {
  let s = "";
  for (const c of el.children) s += c.kind === "text" ? c.text : c.kind === "pi" ? "" : textOf(c);
  return s;
}
