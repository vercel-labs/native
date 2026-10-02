import type { Root } from "mdast";
import vocab from "./component-vocab.json";
import { componentPages } from "./components-pages";

// Read only literal props from documentation. Never evaluate MDX JavaScript.
type Expression = { type: string; value?: unknown; elements?: (Expression | null)[]; body?: { type: string; expression?: Expression }[] };
type Node = { type: string; name?: string | null; value?: string; children?: Node[]; attributes?: { type: string; name?: string; value?: string | { value: string; data?: { estree?: Expression } } | null }[]; [key: string]: unknown };
const text = (value: string): Node => ({ type: "text", value });
const paragraph = (value: string): Node => ({ type: "paragraph", children: [text(value)] });
const inlineCode = (value: string): Node => ({ type: "inlineCode", value });
const link = (label: string, url: string): Node => ({ type: "link", url, children: [text(label)] });

function prop(node: Node, name: string): unknown {
  const attributes = node.attributes ?? [];
  if (attributes.some((a) => a.type === "mdxJsxExpressionAttribute")) return undefined;
  const attribute = attributes.filter((a) => a.name === name).at(-1);
  const value = attribute?.value;
  if (typeof value === "string") return value;
  if (!value) return undefined;
  const expression = value.data?.estree?.body?.[0]?.expression;
  const literal = (entry?: Expression | null): unknown => {
    if (entry?.type === "Literal") return entry.value;
    if (entry?.type === "ArrayExpression") {
      const items = entry.elements?.map(literal);
      return items?.every((item) => item !== undefined) ? items : undefined;
    }
    return undefined;
  };
  if (expression) return literal(expression);
  try { return JSON.parse(value.value); } catch { return undefined; }
}

function strings(node: Node, name: string): string[] {
  const value = prop(node, name);
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new Error(`${node.name}.${name} must be a literal string array`);
  }
  return value;
}

function eject(node: Node): Node[] {
  const entries = strings(node, "components").map((name) => {
    const entry = vocab.ejectable.find((candidate) => candidate.name === name);
    if (!entry) throw new Error(`Unknown ejectable component: ${name}`);
    return entry;
  });
  if (!entries.length) throw new Error("EjectSection requires component names");
  return [
    { type: "heading", depth: 2, children: [text("Eject")] },
    paragraph(`Use the eject command to copy ${entries[0].name} into your project when you need to change its structure. SDK updates preserve your copy. The command refuses to overwrite an existing file.`),
    ...entries.map((entry): Node => ({ type: "paragraph", children: [inlineCode(entry.name), text(` ejects as a ${entry.form} (`), inlineCode(entry.path), text(").")] })),
    { type: "code", lang: "sh", value: entries.map((entry) => `native eject component ${entry.name}`).join("\n") },
    { type: "paragraph", children: [text("The ownership model and what to do after ejecting are in "), link("Use, eject, or build", "/docs/building-components#use-eject-or-build"), text(".")] },
  ];
}

function transform(node: Node, replace: (child: Node) => Node[] | undefined): void {
  if (!node.children) return;
  node.children = node.children.flatMap((child) => {
    const replacement = replace(child);
    if (replacement) { replacement.forEach((entry) => transform(entry, replace)); return replacement; }
    transform(child, replace);
    return [child];
  });
}

/** Expand generated eject instructions before headings, search, and code highlighting. */
export function remarkNativeContent() {
  return (tree: Root) => transform(tree as unknown as Node, (node) => {
    if (node.name === "EjectSection") return eject(node);
    // Processed MDX decodes HTML entities. Inline-code nodes keep literal braces
    // in table examples from becoming JavaScript on the Markdown parse pass.
    if (node.name === "code" && !node.attributes?.length && node.children?.every((child) => child.type === "text")) {
      return [inlineCode(node.children.map((child) => child.value ?? "").join(""))];
    }
    return undefined;
  });
}

/** Preserve app-owned component data in the package's Markdown exporter. */
export function remarkNativeMarkdown() {
  return (tree: Root) => transform(tree as unknown as Node, (node) => {
    if (node.type === "mdxTextExpression" || node.type === "mdxFlowExpression") {
      try { const value: unknown = JSON.parse(node.value ?? ""); if (typeof value === "string") return [text(value)]; } catch { /* Dynamic expressions stay with the package's exporter. */ }
      // Existing pages also use single-quoted literals to print binding braces.
      const single = node.value?.match(/^'([^'\\]*)'$/);
      if (single) return [text(single[1])];
    }
    if (node.name === "div" && typeof prop(node, "data-language") === "string") return node.children ?? [];
    switch (node.name) {
      case "EjectSection": return eject(node);
      case "CodeToggle": return (node.children ?? []).flatMap((child) => child.name === "div" && typeof prop(child, "data-language") === "string" ? child.children ?? [] : [child]);
      case "ComponentPreview": return [];
      case "Experimental": return [text("Experimental")];
      case "Tier": {
        const labels: Record<string, string> = { full: "First-class", caveats: "Works with caveats", embed: "Embed-level", none: "Not available" };
        const tier = prop(node, "tier");
        if (typeof tier !== "string" || !labels[tier]) throw new Error("Unknown support tier");
        const note = prop(node, "note");
        const footnote = prop(node, "fn");
        return [text(`${labels[tier]}${typeof note === "string" ? ` — ${note}` : ""}${typeof footnote === "number" ? ` (footnote ${footnote})` : ""}`)];
      }
      case "TierLegend": return [
        { type: "list", ordered: false, spread: false, children: ["First-class — implemented and exercised", "Works with caveats — real support, footnote applies", "Embed-level — runs inside a host app you own", "Not available today", "Experimental — verified on the simulator/emulator; APIs and tooling may still change"].map((label) => ({ type: "listItem", spread: false, children: [paragraph(label)] })) },
      ];
      case "IconGallery": return [{ type: "paragraph", children: [text("Built-in icon names: "), ...vocab.icons.flatMap((name, index) => [inlineCode(name), text(index + 1 < vocab.icons.length ? ", " : ".")])] }];
      case "ComponentIndexGrid": return [{ type: "list", ordered: false, spread: false, children: componentPages.map((page) => ({ type: "listItem", spread: false, children: [{ type: "paragraph", children: [link(page.name, `/docs/components/${page.slug}`), text(` — ${page.blurb}`)] }] })) }];
      case "AttrTable": {
        const element = prop(node, "element");
        const scoped = vocab.scoped as Record<string, { name: string; doc: string }[]>;
        const rows = strings(node, "attrs").map((name) => {
          const doc = (typeof element === "string" ? scoped[element]?.find((item) => item.name === name) : undefined) ?? vocab.attributes.find((item) => item.name === name) ?? vocab.events.find((item) => item.name === name);
          if (!doc) throw new Error(`Unknown markup attribute: ${name}`);
          return { type: "tableRow", children: [{ type: "tableCell", children: [inlineCode(name)] }, { type: "tableCell", children: [text(doc.doc)] }] };
        });
        return [{ type: "table", align: [null, null], children: [{ type: "tableRow", children: [{ type: "tableCell", children: [text("Attribute")] }, { type: "tableCell", children: [text("Description")] }] }, ...rows] }];
      }
      default: return undefined;
    }
  });
}
