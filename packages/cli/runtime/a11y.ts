// The accessibility tree a page presents to a screen reader, computed on demand: the role
// HTML-AAM gives an element, the name and description accname 1.2 computes, and the states the
// element reports. The host bridge reads accessibleNode() for VoiceOver; nothing here draws.

import * as P from "../shared/props.ts";
import { Document, Element, HTMLInputElement, HTMLSelectElement, HTMLSlotElement, HTMLTextAreaElement, Node, Text, document, elementNamespace } from "./dom.ts";
import { selectPopupSerial } from "./select-popup.ts";

/** The states an accessible node reports. A null means the state doesn't apply. */
export interface AccessibleStates {
  disabled: boolean;
  required: boolean;
  invalid: boolean;
  readonly: boolean;
  checked: boolean | string | null;
  pressed: boolean | string | null;
  expanded: boolean | null;
  selected: boolean | null;
  level: number;
  valueNow: number | null;
  valueMin: number | null;
  valueMax: number | null;
  live: string;
  atomic: boolean;
  relevant: string;
  hidden: boolean;
}

/** What a screen reader sees of one element. */
export interface AccessibleNode {
  role: string;
  name: string;
  description: string;
  states: AccessibleStates;
}

// The ARIA roles this build knows, as a page may name them.
const ROLES = new Set([
  "alert", "alertdialog", "application", "article", "banner", "blockquote", "button", "caption",
  "cell", "checkbox", "code", "columnheader", "combobox", "complementary", "contentinfo",
  "definition", "deletion", "dialog", "directory", "document", "emphasis", "feed", "figure",
  "form", "generic", "grid", "gridcell", "group", "heading", "img", "insertion", "link", "list",
  "listbox", "listitem", "log", "main", "marquee", "math", "menu", "menubar", "menuitem",
  "menuitemcheckbox", "menuitemradio", "meter", "navigation", "none", "note", "option",
  "paragraph", "presentation", "progressbar", "radio", "radiogroup", "region", "row", "rowgroup",
  "rowheader", "scrollbar", "search", "searchbox", "sectionfooter", "sectionheader", "separator", "slider", "spinbutton", "status",
  "strong", "subscript", "suggestion", "superscript", "switch", "tab", "table", "tablist",
  "tabpanel", "term", "textbox", "time", "timer", "toolbar", "tooltip", "tree", "treegrid",
  "treeitem",
]);

/** Whether an explicit role is presentational, and whether the element is allowed to keep it. */
function presentational(el: Element, role: string): boolean {
  if (role !== "presentation" && role !== "none") return false;
  // A focusable element, or one carrying a global ARIA state or property, keeps its own role:
  // the attribute the browser exposes is the implicit one.
  if (el.getAttribute("tabindex") !== null) return false;
  for (const name of el.attributeNames()) {
    if (name.indexOf("aria-") === 0 && name !== "aria-hidden") return false;
  }
  return true;
}

/** The explicit role when the page names one this build knows, else the implicit role. */
function explicitRole(el: Element): string {
  const raw = el.getAttribute("role");
  if (raw === null) return "";
  for (const part of raw.toLowerCase().split(/\s+/)) {
    if (part === "" || !ROLES.has(part)) continue;
    // presentation/none is honored unless the element is focusable or carries a global ARIA
    // state, in which case the implicit role shows instead.
    if (part === "presentation" || part === "none") return presentational(el, part) ? part : "";
    // generic is prohibited on an element that can take focus, so its implicit role shows.
    if (part === "generic" && (hasAttr(el, "tabindex") || hasAttr(el, "autofocus"))) return implicitRole(el);
    // A role that only exists when the element has a name (a form or region landmark) is
    // prohibited without one: the element keeps its implicit role, as a browser gives it.
    if ((part === "form" || part === "region") && !hasNameForRole(el)) return implicitRole(el);
    return part;
  }
  return "";
}

function hasAttr(el: Element, name: string): boolean {
  return el.getAttribute(name) !== null;
}

/** The role HTML-AAM gives an element by its tag and attributes. */
function implicitRole(el: Element): string {
  const tag = el.localName;
  if (tag === "a" || tag === "area") return hasAttr(el, "href") ? "link" : "";
  if (tag === "article") return "article";
  if (tag === "aside") return scopedInSectioning(el) ? "generic" : "complementary";
  if (tag === "body") return "generic";
  if (tag === "button") return "button";
  if (tag === "datalist") return "listbox";
  if (tag === "caption") return "caption";
  if (tag === "dd") return "definition";
  if (tag === "dir") return "list";
  if (tag === "details") return "group";
  if (tag === "dialog") return "dialog";
  if (tag === "div") return hasAttr(el, "autofocus") ? "group" : "generic";
  if (tag === "dl") return "list";
  if (tag === "dt") return "term";
  if (tag === "fieldset") return "group";
  if (tag === "figure") return "figure";
  if (tag === "form") return hasNameForRole(el) ? "form" : "generic";
  if (/^h[1-6]$/.test(tag)) return "heading";
  if (tag === "hr") return "separator";
  if (tag === "img") return el.getAttribute("alt") === "" ? "presentation" : "img";
  if (tag === "input") return inputRole(el);
  if (tag === "li") return "listitem";
  if (tag === "main") return "main";
  if (tag === "math") return "math";
  if (tag === "menu") return "list";
  if (tag === "nav") return "navigation";
  if (tag === "ol" || tag === "ul") return "list";
  if (tag === "optgroup") return "group";
  if (tag === "option") return "option";
  if (tag === "output") return "status";
  if (tag === "p") return "paragraph";
  if (tag === "progress") return "progressbar";
  // A section or form is a landmark only when it has a name; scoped headers and footers lose
  // their banner/contentinfo role inside sectioning content.
  if (tag === "section") return hasNameForRole(el) ? "region" : "generic";
  if (tag === "header") return scopedInSectioning(el) ? "sectionheader" : "banner";
  if (tag === "footer") return scopedInSectioning(el) ? "sectionfooter" : "contentinfo";
  if (tag === "select") {
    const size = el.getAttribute("size");
    return hasAttr(el, "multiple") || (size !== null && Number(size) > 1) ? "listbox" : "combobox";
  }
  if (tag === "table") return "table";
  if (tag === "tbody" || tag === "tfoot" || tag === "thead") return "rowgroup";
  if (tag === "td") return "cell";
  if (tag === "textarea") return "textbox";
  if (tag === "th") {
    const scope = el.getAttribute("scope");
    if (scope === "row") return "rowheader";
    if (scope === "col" || scope === "colgroup") return "columnheader";
    // HTML-AAM: a cell in the head heads its column; one in the body heads its row.
    for (let p = el.parentNode; p !== null; p = p.parentNode) {
      if (!p.isElementNode) continue;
      const parentTag = (p as Element).localName;
      if (parentTag === "thead") return "columnheader";
      if (parentTag === "tbody" || parentTag === "tfoot") return "rowheader";
      if (parentTag === "table") break;
    }
    return "columnheader";
  }
  if (tag === "tr") return "row";
  return "";
}

/** Whether an element has an accessible name (used by the roles that need one). */
let probingRoleName = false;
function hasNameForRole(el: Element): boolean {
  if (probingRoleName) return el.getAttribute("aria-label") !== null || el.getAttribute("aria-labelledby") !== null;
  probingRoleName = true;
  const name = computeName(el, false, [], false);
  probingRoleName = false;
  return name.trim() !== "";
}

/** Is the element inside sectioning content (article, aside, main, nav or section)? */
function scopedInSectioning(el: Element): boolean {
  for (let p = el.parentNode; p !== null; p = p.parentNode) {
    if (!p.isElementNode) continue;
    const tag = (p as Element).localName;
    if (tag === "article" || tag === "aside" || tag === "main" || tag === "nav" || tag === "section") return true;
  }
  return false;
}

function inputRole(el: Element): string {
  const raw = el.getAttribute("type");
  const type = raw === null ? "text" : raw.toLowerCase();
  if (type === "button" || type === "submit" || type === "reset" || type === "image") return "button";
  if (type === "checkbox") return hasAttr(el, "switch") ? "switch" : "checkbox";
  if (type === "radio") return "radio";
  if (type === "range") return "slider";
  if (type === "number") return "spinbutton";
  if (type === "search") return "searchbox";
  if (type === "hidden") return "";
  return "textbox";
}

/** The role a page's explicit attribute or the tag implies; "" when it maps to none. */
export function computedRole(el: Element): string {
  const explicit = explicitRole(el);
  if (explicit !== "") return explicit;
  return implicitRole(el);
}

/**
 * accname's whitespace flattening: runs of ASCII white space become one space, and the edges
 * lose theirs. A non-breaking space is content, not white space, and stays.
 */
function flatName(text: string): string {
  return text.replace(/[ \t\n\r\f]+/g, " ").replace(/^ | $/g, "");
}

/** Roles that take their name from their content. */
const NAME_FROM_CONTENT = new Set([
  "button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link", "listitem",
  "menuitem", "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader",
  "switch", "tab", "tooltip", "treeitem",
]);

/** Is the element or an ancestor hidden from the accessibility tree? */
function hiddenToAT(el: Element): boolean {
  let n: Node | null = el;
  while (n !== null) {
    if (n.isElementNode) {
      const e = n as Element;
      if (e.getAttribute("aria-hidden") === "true") return true;
      if (e.sv[P.P_DISPLAY] === P.D_NONE) return true;
      if (e.sv[P.P_VISIBILITY] !== P.VIS_VISIBLE) return true;
      if (e.getAttribute("hidden") !== null) return true;
    }
    n = n.parentNode;
  }
  return false;
}

/** The element an id names in `el`'s tree scope. */
function byId(el: Element, id: string): any {
  const root = el.getRootNode();
  if (root.nodeType === 9) return (root as Document).getElementById(id);
  return null;
}

/** The ids an IDREF list names, resolved to elements in `el`'s tree scope. */
function idRefs(el: Element, attr: string): Element[] {
  const raw = el.getAttribute(attr);
  if (raw === null || raw === "") return [];
  const out: Element[] = [];
  for (const id of raw.split(/\s+/)) {
    if (id === "") continue;
    const found = byId(el, id);
    if (found !== null && out.indexOf(found) < 0) out.push(found);
  }
  return out;
}

/** The accessible name of a node in the middle of a name computation. */
function computeName(node: Node, recursive: boolean, visited: Element[], fromContent: boolean): string {
  if (node.isTextNode) return node.ownText;
  if (!node.isElementNode) return "";
  const el = node as Element;
  if (visited.indexOf(el) >= 0) return "";
  if (visited.length > 12) return "";
  visited.push(el);

  // aria-labelledby first, unless the element is itself being named from its content.
  if (!fromContent) {
    const refs = idRefs(el, "aria-labelledby");
    if (refs.length > 0) {
      let text = "";
      for (const ref of refs) {
        // A reference to the element itself contributes its aria-label, not its content.
        const part = ref === el
          ? flatName(el.getAttribute("aria-label") ?? "")
          : flatName(computeName(ref, true, visited, false));
        if (part !== "") text += (text === "" ? "" : " ") + part;
      }
      if (flatName(text) !== "") return flatName(text);
    }
    const label = el.getAttribute("aria-label");
    // An aria-label folds only ASCII white space: a trailing no-break space is content.
    if (label !== null && flatName(label) !== "") return flatName(label);
  }

  const role = computedRole(el);
  const tag = el.localName;

  // Native label sources, before content.
  if (tag === "input" || tag === "select" || tag === "textarea" || tag === "output" || tag === "progress" ||
    tag === "meter" || tag === "button") {
    const native = nativeLabel(el);
    if (native !== "") return native;
  }
  if (tag === "input") {
    const kind = (el.getAttribute("type") ?? "text").toLowerCase();
    if (kind === "image") {
      const alt = el.getAttribute("alt");
      if (alt !== null) return alt;
    }
  }
  // An area takes its alt, as an image does; it has no content of its own to name it.
  if (tag === "area") {
    const alt = el.getAttribute("alt");
    if (alt !== null) return alt;
  }
  if (tag === "img") {
    const alt = el.getAttribute("alt");
    if (alt !== null) return alt;
    const title = el.getAttribute("title");
    if (title !== null && title.trim() !== "") return title.trim();
    // A figure's figcaption names the image only when the image is all the figure holds.
    const caption = soleFigureCaption(el);
    if (caption !== "") return caption;
  }
  if (tag === "fieldset") {
    const legend = visibleChild(el, "legend");
    if (legend !== null) return flatName(contentName(legend, visited));
  }
  if (tag === "table") {
    const caption = visibleChild(el, "caption");
    if (caption !== null) return flatName(contentName(caption, visited));
  }
  if (tag === "svg" || elementNamespace(el) === "http://www.w3.org/2000/svg") {
    const title = firstChildElement(el, "title");
    if (title !== null) {
      const text = flatName(contentName(title, visited));
      if (flatName(text) !== "") return text;
    }
  }

  if (!fromContent && (NAME_FROM_CONTENT.has(role) || tag === "summary")) {
    const content = flatName(contentName(el, visited));
    if (content !== "") return content;
  }

  // A referenced node with no name of its own names itself from its content. A hidden
  // reference's whole subtree counts; a visible one's hidden descendants don't.
  if (recursive) {
    const content = flatName(contentName(el, visited, hiddenToAT(el)));
    if (content !== "") return content;
  }

  // A title names an element nothing else named.
  if (!fromContent) {
    const title = el.getAttribute("title");
    if (title !== null && title.trim() !== "") return title.trim();
    // HTML-AAM: a text field nothing else named takes its placeholder, after its title.
    if (takesPlaceholderName(el)) {
      const placeholder = el.getAttribute("placeholder");
      if (placeholder !== null && flatName(placeholder) !== "") return flatName(placeholder);
    }
  }
  return "";
}

/** The fields HTML-AAM names from the placeholder attribute: textarea and the text-like inputs. */
function takesPlaceholderName(el: Element): boolean {
  if (el.localName === "textarea") return true;
  if (el.localName !== "input") return false;
  const type = (el.getAttribute("type") ?? "text").toLowerCase();
  return type === "text" || type === "search" || type === "url" || type === "tel" ||
    type === "email" || type === "password" || type === "number" || type === "";
}

/**
 * The text an embedded control contributes to another element's name: a field's value, a
 * combobox's text, a listbox's chosen option.
 */
function embeddedText(el: Element): string {
  const tag = el.localName;
  if (tag === "input") return el.getAttribute("value") ?? "";
  // A field's text may be its own or the #text child a DOM read of it gave it; both are its value.
  if (tag === "textarea") return (el as HTMLTextAreaElement).value;
  if (tag === "select") return selectText(el);
  const role = computedRole(el);
  if (role === "slider" || role === "spinbutton" || role === "progressbar") {
    const valuetext = el.getAttribute("aria-valuetext");
    if (valuetext !== null && valuetext !== "") return valuetext;
    const valuenow = el.getAttribute("aria-valuenow");
    if (valuenow !== null && valuenow !== "") return valuenow;
  }
  if (role === "listbox" || role === "combobox") {
    // A queue of the elements still to look at, so the chosen and first options are plain locals
    // (scriptc can't narrow a variable a closure assigns).
    let chosen: Element | null = null;
    let first: Element | null = null;
    const queue: Element[] = [el];
    while (queue.length > 0) {
      const node = queue[0];
      queue.shift();
      for (const k of node.kids) {
        if (!k.isElementNode) continue;
        const kid = k as Element;
        if (computedRole(kid) === "option") {
          if (first === null) first = kid;
          if (kid.getAttribute("aria-selected") === "true" && chosen === null) chosen = kid;
        }
        queue.push(kid);
      }
    }
    if (chosen !== null) return flatName(contentName(chosen, [el], true));
    if (first !== null) return flatName(contentName(first, [el], true));
  }
  return flatName(contentName(el, [el], true));
}

/** The figcaption of the figure whose only content is `el`, if there is one. */
function soleFigureCaption(el: Element): string {
  let fig: Element | null = null;
  for (let p: Node | null = el.parentNode; p !== null; p = p.parentNode) {
    if (p.isElementNode && (p as Element).localName === "figure") { fig = p as Element; break; }
  }
  if (fig === null) return "";
  for (const k of fig.kids) {
    if (k.pseudoKind !== P.PE_NONE || k === el) continue;
    if (k.isTextNode) {
      if (/\S/.test(k.ownText)) return "";
      continue;
    }
    if (k.isElementNode && (k as Element).localName === "figcaption") continue;
    return "";
  }
  const cap = firstChildElement(fig, "figcaption");
  return cap === null ? "" : flatName(contentName(cap, [el]));
}

/** The first child element with the given local name that isn't hidden. */
function visibleChild(el: Element, name: string): Element | null {
  for (const k of el.kids) {
    if (!k.isElementNode) continue;
    const kid = k as Element;
    if (kid.localName === name && !hiddenToAT(kid)) return kid;
  }
  return null;
}

/** The first direct child element with the given local name. */
function firstChildElement(el: Element, name: string): Element | null {
  for (const k of el.kids) {
    if (k.isElementNode && (k as Element).localName === name) return k as Element;
  }
  return null;
}

/** The name from content: text and the names of the children that add one. */
/**
 * The children a name computation walks: a shadow host's content is its shadow tree, and a slot
 * stands for the light children assigned to it (or its own fallback content).
 */
function flatChildren(el: Element): Node[] {
  const shadow = el.shadowTree();
  const source = shadow !== null ? shadow.kids : el.kids;
  const out: Node[] = [];
  for (const k of source) {
    if (k.pseudoKind !== P.PE_NONE) continue;
    if (k instanceof HTMLSlotElement) {
      const assigned = k.assignedNodes();
      if (assigned.length > 0) {
        // A slot's assigned content reads as a stretch of its own in the flat tree, so the text
        // either side of it keeps a space between them.
        out.push(new Text(" "));
        for (const a of assigned) out.push(a);
        out.push(new Text(" "));
        continue;
      }
      // An empty slot shows the host's light text it kept as one run, else its own fallback
      // content. A slot's aria-label is not part of the name around it.
      out.push(new Text(" "));
      if (el.ownText !== "") {
        out.push(new Text(el.ownText));
      } else {
        if (k.ownText !== "") out.push(new Text(k.ownText));
        for (const c of k.kids) if (c.pseudoKind === P.PE_NONE) out.push(c);
      }
      out.push(new Text(" "));
      continue;
    }
    out.push(k);
  }
  return out;
}

/** Roles of controls whose value, not whose name, counts inside another element's name. */
const EMBEDDED_ROLES = new Set(["combobox", "listbox", "searchbox", "slider", "spinbutton", "textbox"]);

function contentName(el: Element, visited: Element[], includeHidden: boolean = false): string {
  // An element that keeps its text as its own contributes it before its children's names. A
  // shadow host's content is its shadow tree: its light text is only what a slot shows.
  let out = el.shadowTree() !== null ? "" : el.ownText;
  // A heading's name leaves out the headings inside it.
  const headingHere = /^h[1-6]$/.test(el.localName) || computedRole(el) === "heading";
  for (const k of flatChildren(el)) {
    if (k.isTextNode) {
      out += k.ownText;
      continue;
    }
    if (!k.isElementNode) continue;
    const kid = k as Element;
    // An element the computation is already inside (the control a label names, say) contributes
    // nothing to the name around it.
    if (visited.indexOf(kid) >= 0) continue;
    // A hidden referenced node's whole subtree contributes, as accname has it; in ordinary
    // content a hidden descendant names nothing.
    if (!includeHidden && hiddenToAT(kid)) continue;
    const tag = kid.localName;
    if (tag === "br") {
      out += " ";
      continue;
    }
    // An element the host names in aria-actions is one of its actions, not part of its name.
    const actions = el.ariaActionsElements;
    if (actions !== null && actions.indexOf(kid) >= 0) {
      out += " ";
      continue;
    }
    if (headingHere && computedRole(kid) === "heading") continue;
    // An embedded control contributes its own value to the name (a text field inside a label).
    if (tag === "input" || tag === "textarea" || tag === "select" || EMBEDDED_ROLES.has(computedRole(kid))) {
      const value = embeddedText(kid);
      out += (out === "" ? "" : " ") + value;
      continue;
    }
    // Content another element owns through aria-owns isn't this element's content.
    const kidId = kid.getAttribute("id");
    if (kidId !== null && ownedElsewhere(el, kidId)) continue;
    // A child that names nothing itself still contributes its text, as accname has it; under a
    // reference, descendants hidden by an ancestor count too.
    let part = computeName(kid, includeHidden, visited, false);
    if (flatName(part) === "") part = contentName(kid, visited, includeHidden);
    out += part;
  }
  // aria-owns adds the owned elements' content at the place the attribute names.
  const owns = el.getAttribute("aria-owns");
  if (owns !== null) {
    for (const id of owns.split(/\s+/)) {
      if (id === "") continue;
      const owned = byId(el, id);
      // Ownership lifts an ancestor's aria-hidden, but not the target's own, nor a box that isn't
      // rendered at all.
      if (owned !== null && owned !== el && visited.indexOf(owned) < 0 && !hiddenByBox(owned) &&
        owned.getAttribute("aria-hidden") !== "true") {
        out += " " + contentName(owned, visited, includeHidden);
      }
    }
  }
  return out;
}

/** Hidden by the box itself or an ancestor (display:none, the hidden attribute), not aria-hidden:
 *  ownership lifts aria-hidden, but not a box that isn't rendered. */
function hiddenByBox(el: Element): boolean {
  for (let n: Node | null = el; n !== null; n = n.parentNode) {
    if (!n.isElementNode) continue;
    const e = n as Element;
    if (e.getAttribute("hidden") !== null) return true;
    if (e.sv[P.P_DISPLAY] === P.D_NONE) return true;
  }
  return false;
}

/** Does an element other than `owner` own the id through aria-owns? */
function ownedElsewhere(owner: Element, id: string): boolean {
  const root = owner.getRootNode();
  if (root.nodeType !== 9) return false;
  const all = (root as Document).getElementsByTagName("*");
  for (const node of all) {
    const el = node as Element;
    if (el === owner || hiddenToAT(el)) continue;
    const owns = el.getAttribute("aria-owns");
    if (owns === null) continue;
    for (const owned of owns.split(/\s+/)) if (owned === id) return true;
  }
  return false;
}

/** The text a select contributes: its selected option's, or the first option's. */
function selectText(select: Element): string {
  let first: Element | null = null;
  const walk = (node: Node): Element | null => {
    for (const c of node.kids) {
      if (!c.isElementNode) continue;
      const el = c as Element;
      if (el.localName === "option") {
        if (first === null) first = el;
        if (el.getAttribute("selected") !== null) return el;
      } else {
        const found = walk(el);
        if (found !== null) return found;
      }
    }
    return null;
  };
  const chosen = walk(select);
  const option = chosen !== null ? chosen : first;
  return option === null ? "" : flatName(contentName(option as Element, [], true));
}

/** A label element's control association: label[for] or a label wrapping the control. */
function nativeLabel(el: Element): string {
  const id = el.getAttribute("id");
  // Every label HTML associates: a <label for> naming the control, and an ancestor <label> that
  // wraps it, in tree order, their texts joined as accname joins a list of names.
  const labels: Element[] = [];
  for (const node of document.getElementsByTagName("label")) {
    const label = node as Element;
    let wraps = false;
    for (let p: Node | null = el.parentNode; p !== null; p = p.parentNode) {
      if (p === label) { wraps = true; break; }
    }
    const names = id !== null && id !== "" && label.getAttribute("for") === id;
    if ((names || wraps) && !hiddenToAT(label) && labels.indexOf(label) < 0) labels.push(label);
  }
  if (labels.length > 0) {
    let out = "";
    for (const label of labels) {
      const part = flatName(contentName(label, [el]));
      if (part !== "") out += (out === "" ? "" : " ") + part;
    }
    return out;
  }
  if (el.localName === "input") {
    const type = (el.getAttribute("type") ?? "text").toLowerCase();
    if (type === "button" || type === "submit" || type === "reset") return el.getAttribute("value") ?? "";
    if (type === "image") return el.getAttribute("alt") ?? el.getAttribute("value") ?? "";
  }
  return "";
}

/** The description: aria-describedby's text, else the title attribute. */
function computeDescription(el: Element, name: string): string {
  const refs = idRefs(el, "aria-describedby");
  if (refs.length > 0) {
    let text = "";
    for (const ref of refs) {
      const part = flatName(contentName(ref, []));
      if (part !== "") text += (text === "" ? "" : " ") + part;
    }
    if (text !== "") return text;
  }
  const title = el.getAttribute("title");
  if (title !== null && title.trim() !== "" && title.trim() !== name) return title.trim();
  return "";
}

function attrBool(el: Element, attr: string): boolean {
  const v = el.getAttribute(attr);
  return v !== null && v !== "false";
}

function numberAttr(el: Element, attr: string): number | null {
  const v = el.getAttribute(attr);
  if (v === null || v.trim() === "") return null;
  const n = Number(v);
  return Number.isNaN(n) ? null : n;
}

/** The states the element reports, from its ARIA attributes or its native control state. */
export function computedStates(el: Element): AccessibleStates {
  const tag = el.localName;
  const type = tag === "input" ? (el.getAttribute("type") ?? "text").toLowerCase() : "";
  const nativeDisabled = (tag === "button" || tag === "input" || tag === "select" || tag === "textarea" || tag === "option" || tag === "optgroup" || tag === "fieldset") && hasAttr(el, "disabled");
  const checkedAttr = el.getAttribute("aria-checked");
  const pressedAttr = el.getAttribute("aria-pressed");
  const selectedAttr = el.getAttribute("aria-selected");
  const expandedAttr = el.getAttribute("aria-expanded");
  let checked: boolean | string | null = null;
  if (checkedAttr === "true") checked = true;
  else if (checkedAttr === "false") checked = false;
  else if (checkedAttr === "mixed") checked = "mixed";
  else if ((type === "checkbox" || type === "radio") && el.localName === "input") {
    // The control's checkedness, which a click or a script moves, not the checked attribute,
    // which only sets its default; an indeterminate checkbox is mixed.
    const input = el as any;
    checked = type === "checkbox" && input.indeterminate === true ? "mixed" : input.checked === true;
  }
  // A checkable role that says nothing reports unchecked, not "no state".
  if (checked === null) {
    const checkable = computedRole(el);
    if (checkable === "checkbox" || checkable === "radio" || checkable === "switch" ||
      checkable === "menuitemcheckbox" || checkable === "menuitemradio") checked = false;
  }
  let pressed: boolean | string | null = null;
  if (pressedAttr === "true") pressed = true;
  else if (pressedAttr === "false") pressed = false;
  else if (pressedAttr === "mixed") pressed = "mixed";
  let selected: boolean | null = null;
  if (selectedAttr === "true") selected = true;
  else if (selectedAttr === "false") selected = false;
  else if (tag === "option") selected = hasAttr(el, "selected");
  let expanded: boolean | null = null;
  if (expandedAttr === "true") expanded = true;
  else if (expandedAttr === "false") expanded = false;
  // A closed field with a picker is collapsed, and one whose picker is open is expanded, as a
  // browser reports the field; a list box has no picker of its own.
  else if (tag === "select") {
    const picker = el as HTMLSelectElement;
    if (!picker.multiple && picker.size <= 1) expanded = selectPopupSerial() === picker.serial;
  }
  let rangeNow: number | null = null;
  if (tag === "input" && type === "range") {
    // A native range's position is its value property, which a drag or a step moves; the
    // attribute only sets the default it started at.
    const field = el as HTMLInputElement;
    rangeNow = Number(field.value);
  }
  let level = numberAttr(el, "aria-level") ?? 0;
  if (level === 0 && /^h[1-6]$/.test(tag)) level = Number(tag.slice(1));
  const invalidAttr = el.getAttribute("aria-invalid");
  return {
    disabled: nativeDisabled || attrBool(el, "aria-disabled"),
    required: hasAttr(el, "required") || attrBool(el, "aria-required"),
    invalid: invalidAttr !== null && invalidAttr !== "false",
    readonly: hasAttr(el, "readonly") || attrBool(el, "aria-readonly"),
    checked,
    pressed,
    expanded,
    selected,
    level,
    valueNow: numberAttr(el, "aria-valuenow") ?? rangeNow,
    valueMin: numberAttr(el, "aria-valuemin") ?? (tag === "input" && type === "range" ? Number(el.getAttribute("min") ?? "0") : null),
    valueMax: numberAttr(el, "aria-valuemax") ?? (tag === "input" && type === "range" ? Number(el.getAttribute("max") ?? "100") : null),
    live: el.getAttribute("aria-live") ?? "off",
    atomic: attrBool(el, "aria-atomic"),
    relevant: el.getAttribute("aria-relevant") ?? "additions text",
    hidden: hiddenToAT(el),
  };
}

/** Everything a screen reader sees of an element: role, name, description and states. */
export function accessibleNode(el: Element): AccessibleNode {
  const role = computedRole(el);
  const name = computeName(el, false, [], false);
  return { role, name, description: computeDescription(el, name), states: computedStates(el) };
}

// ---------------------------------------------------------------------------
// The WPT accessibility-properties driver

/** The elements and parent ids behind the node ids the driver hands out. */
let driverNodes: Element[] = [];
let driverParents: string[] = [];

/** Forgets the driver's node ids, which belong to the page that just ended. */
export function resetAccessibleProperties(): void {
  driverNodes = [];
  driverParents = [];
}

/** The accessible properties of an element, with its accessible children as node ids. */
export function accessibilityProperties(el: Element): any {
  resetAccessibleProperties();
  return axPropertyRecord(el, "0", "");
}

/** The properties of a child the driver named by id, or of an element passed directly. */
export function accessibilityPropertiesForNode(id: any): any {
  if (id instanceof Node) {
    resetAccessibleProperties();
    return axPropertyRecord(id as Element, "0", "");
  }
  const at = Number(id);
  if (!(at >= 0 && at < driverNodes.length)) return null;
  return axPropertyRecord(driverNodes[at], String(at), driverParents[at]);
}

/** The accessible children of an element, with generic wrappers flattened away. */
function axDriverChildren(el: Element): Element[] {
  const out: Element[] = [];
  for (const k of el.kids) {
    if (!k.isElementNode || k.pseudoKind !== P.PE_NONE) continue;
    const kid = k as Element;
    if (hiddenToAT(kid)) continue;
    const role = computedRole(kid);
    if ((role !== "" && role !== "generic" && role !== "none" && role !== "presentation") ||
      kid.getAttribute("role") !== null || computeName(kid, false, [], false) !== "") {
      out.push(kid);
    } else {
      for (const d of axDriverChildren(kid)) out.push(d);
    }
  }
  return out;
}

/** The properties the WPT accessibility driver reports for one node. */
export interface AccessibilityProperties {
  accessibilityId: string;
  parent: string;
  role: string;
  label: string;
  description: string;
  children: string[];
  checked?: string;
  pressed?: string;
  expanded?: string;
  selected?: string;
  disabled?: string;
  required?: string;
  readonly?: string;
  invalid?: string;
  level?: number;
  valuenow?: number;
  valuemin?: number;
  valuemax?: number;
}

/** The record itself: every field declared, so no expando writes are needed. */
class AxProperties {
  accessibilityId = "";
  parent = "";
  role = "";
  label = "";
  description = "";
  children: string[] = [];
  checked: string | undefined = undefined;
  pressed: string | undefined = undefined;
  expanded: string | undefined = undefined;
  selected: string | undefined = undefined;
  disabled: string | undefined = undefined;
  required: string | undefined = undefined;
  readonly: string | undefined = undefined;
  invalid: string | undefined = undefined;
  level: number | undefined = undefined;
  valuenow: number | undefined = undefined;
  valuemin: number | undefined = undefined;
  valuemax: number | undefined = undefined;
}

/** A state a browser reports as the string "mixed". */
function mixedState(value: boolean | string): boolean {
  return value === "mixed";
}

/** One element's properties in the shape Chrome's test driver reports them. */
function axPropertyRecord(el: Element, id: string, parent: string): AccessibilityProperties {
  const states = computedStates(el);
  const rec = new AxProperties();
  rec.accessibilityId = id;
  rec.parent = parent;
  rec.role = computedRole(el);
  rec.label = computeName(el, false, [], false);
  rec.description = computeDescription(el, "");
  if (states.checked !== null) rec.checked = mixedState(states.checked) ? "mixed" : String(states.checked);
  if (states.pressed !== null) rec.pressed = mixedState(states.pressed) ? "mixed" : String(states.pressed);
  if (states.expanded !== null) rec.expanded = String(states.expanded);
  if (states.selected !== null) rec.selected = String(states.selected);
  if (states.disabled) rec.disabled = "true";
  if (states.required) rec.required = "true";
  if (states.readonly) rec.readonly = "true";
  if (states.invalid) rec.invalid = "true";
  if (states.level !== 0) rec.level = states.level;
  if (states.valueNow !== null) rec.valuenow = states.valueNow;
  if (states.valueMin !== null) rec.valuemin = states.valueMin;
  if (states.valueMax !== null) rec.valuemax = states.valueMax;
  const ids: string[] = [];
  for (const child of axDriverChildren(el)) {
    const childId = String(driverNodes.length);
    driverNodes.push(child);
    driverParents.push(id);
    ids.push(childId);
  }
  rec.children = ids;
  return rec;
}
