import vocab from "./component-vocab.json";
import { componentPages } from "./components-pages";

/**
 * Turn a docs page.mdx source into clean plain markdown for "Copy Page"
 * and the /md/<slug> route. The .mdx source is the truth; this strips the
 * MDX-only parts (imports, JSX components) and replaces the data-driven
 * components with the same content they render:
 *
 * - `<AttrTable attrs={[...]} element="x" />` becomes a markdown table
 *   using the same component-vocab.json lookup the component uses.
 * - `<ComponentIndexGrid />` becomes the component index as a list.
 * - `<IconGallery />` becomes the icon-name list from the vocabulary.
 * - `<ComponentPreview ... />` (an engine-rendered image) is dropped.
 * - `<CodeToggle>` wrappers are unwrapped: the fenced samples inside are
 *   plain markdown already, so only the tags drop.
 * - Filenamed fences (```ts:src/core.ts) become a labeled `path`: line
 *   above a plain ```ts fence.
 *
 * Inline HTML (tables, definition lists) passes through untouched —
 * it is valid markdown as written.
 */
export function mdxToCleanMarkdown(raw: string): string {
  const lines = raw.split("\n");
  const out: string[] = [];
  let jsxBlock: string[] | null = null;
  let inFence = false;

  for (const line of lines) {
    const trimmed = line.trim();

    // Fenced code passes through verbatim: TypeScript samples start lines
    // with `import`/`export`, which only MDX-level lines may strip. The one
    // rewrite is a filenamed opener (```ts:src/core.ts — the site renders
    // the path as a header row): copied markdown gets the path as a labeled
    // line above a plain fence, so any renderer highlights the real
    // language instead of choking on the colon.
    if (jsxBlock === null && trimmed.startsWith("```")) {
      if (!inFence) {
        const meta = trimmed.match(/^```([^\s:`]+):(\S+)$/);
        if (meta) {
          out.push(`\`${meta[2]}\`:`);
          out.push("");
          out.push("```" + meta[1]);
          inFence = true;
          continue;
        }
      }
      inFence = !inFence;
      out.push(line);
      continue;
    }
    if (inFence) {
      out.push(line);
      continue;
    }

    if (jsxBlock === null && (trimmed.startsWith("export ") || trimmed.startsWith("import "))) {
      continue;
    }

    // CodeToggle is the one paired-tag component: its children are ordinary
    // fenced code blocks, valid markdown as written, so drop only the tags.
    if (jsxBlock === null && (trimmed === "<CodeToggle>" || trimmed === "</CodeToggle>")) {
      continue;
    }

    // A capitalized JSX component; every other docs component is self-closing.
    if (jsxBlock === null && /^<[A-Z]/.test(trimmed)) {
      jsxBlock = [line];
    } else if (jsxBlock !== null) {
      jsxBlock.push(line);
    } else {
      out.push(line);
      continue;
    }

    if (trimmed.endsWith("/>")) {
      const replacement = renderJsxComponent(jsxBlock.join("\n"));
      if (replacement) out.push(replacement);
      jsxBlock = null;
    }
  }

  return out
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

type Doc = { name: string; doc: string };

function renderJsxComponent(block: string): string | null {
  if (block.startsWith("<AttrTable")) return renderAttrTable(block);
  if (block.startsWith("<ComponentIndexGrid")) return renderComponentIndex();
  if (block.startsWith("<IconGallery")) return renderIconList();
  // ComponentPreview and anything unknown: an image or purely visual
  // element with no markdown equivalent.
  return null;
}

/** The same lookup AttrTable does: scoped table first, then shared tables. */
function lookupAttr(name: string, element?: string): Doc | undefined {
  if (element) {
    const table = (vocab.scoped as Record<string, Doc[]>)[element];
    const hit = table?.find((doc) => doc.name === name);
    if (hit) return hit;
  }
  return (
    (vocab.attributes as Doc[]).find((doc) => doc.name === name) ??
    (vocab.events as Doc[]).find((doc) => doc.name === name)
  );
}

function renderAttrTable(block: string): string {
  const element = block.match(/element="([^"]+)"/)?.[1];
  const attrsSource = block.match(/attrs=\{\[([\s\S]*?)\]\}/)?.[1] ?? "";
  const attrs = [...attrsSource.matchAll(/"([^"]+)"/g)].map((m) => m[1]!);

  const rows = attrs.map((name) => {
    const doc = lookupAttr(name, element);
    return `| \`${name}\` | ${doc ? escapeCell(doc.doc) : ""} |`;
  });
  return ["| Attribute | Description |", "| --- | --- |", ...rows].join("\n");
}

function renderComponentIndex(): string {
  return componentPages
    .map((page) => `- [${page.name}](/components/${page.slug}) — ${page.blurb}`)
    .join("\n");
}

function renderIconList(): string {
  const icons = vocab.icons as string[];
  return `Built-in icon names: ${icons.map((name) => `\`${name}\``).join(", ")}.`;
}

function escapeCell(text: string): string {
  return text.replace(/\|/g, "\\|").replace(/\n/g, " ");
}
