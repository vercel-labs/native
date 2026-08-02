import vocab from "./component-vocab.json";
import { componentPages } from "./components-pages";
import { docsPath } from "./site";

/**
 * Turn a docs page.mdx source into clean plain markdown for "Copy Page"
 * and the /<slug>.md route. The .mdx source is the truth; this strips the
 * MDX-only parts (imports, JSX components) and replaces the data-driven
 * components with the same content they render:
 *
 * - `<AttrTable attrs={[...]} element="x" />` becomes a markdown table
 *   using the same component-vocab.json lookup the component uses.
 * - `<ComponentIndexGrid />` becomes the component index as a list.
 * - `<IconGallery />` becomes the icon-name list from the vocabulary.
 * - Support tiers become their visible labels, notes, and footnote references.
 * - `<EjectSection ... />` becomes the same instructions and commands as HTML.
 * - `<ComponentPreview ... />` (an engine-rendered image) is dropped.
 * - `<CodeToggle>` wrappers are unwrapped: the fenced samples inside are
 *   plain markdown already, so only the tags drop.
 * - MDX string expressions used to print literal braces become their visible
 *   text (for example, `{'{id}'}` becomes `{id}`).
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
    let renderedLine = line;
    let trimmed = renderedLine.trim();

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

    // These components occur inline with prose and inside HTML tables. Resolve
    // them before the standalone-component state machine so a line such as
    // `<Experimental /> Mobile ...` cannot be mistaken for an unterminated JSX
    // block and swallow the rest of the document.
    renderedLine = renderMdxStringExpressions(renderInlineComponents(renderedLine));
    trimmed = renderedLine.trim();

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
      jsxBlock = [renderedLine];
    } else if (jsxBlock !== null) {
      jsxBlock.push(renderedLine);
    } else {
      out.push(renderedLine);
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
type Ejectable = { name: string; form: string; path: string };
type SupportTier = "full" | "caveats" | "embed" | "none";

const ejectable = vocab.ejectable as Ejectable[];
const supportTierLabels: Record<SupportTier, string> = {
  full: "First-class",
  caveats: "Works with caveats",
  embed: "Embed-level",
  none: "Not available",
};

function renderInlineComponents(line: string): string {
  // At the start of prose the badge reads naturally as a Markdown label. In
  // an HTML table header it must remain plain text because Markdown emphasis
  // is not parsed inside an HTML block.
  let rendered = line.replace(
    /^(\s*)<Experimental\s*\/>\s*/,
    "$1**Experimental.** ",
  );
  rendered = rendered.replace(/<Experimental\s*\/>/g, "Experimental");
  return rendered.replace(/<Tier\s+([^>]*?)\s*\/>/g, (_match, attrs: string) =>
    renderSupportTier(attrs),
  );
}

/** Resolve text-only MDX expressions while fenced code remains byte-for-byte. */
function renderMdxStringExpressions(line: string): string {
  return line.replace(
    /\{"([^"\\\r\n]*)"\}|\{'([^'\\\r\n]*)'\}/g,
    (_match, doubleQuoted: string | undefined, singleQuoted: string | undefined) =>
      doubleQuoted ?? singleQuoted ?? "",
  );
}

function renderSupportTier(attrs: string): string {
  const tier = attrs.match(/\btier="([^"]+)"/)?.[1] as SupportTier | undefined;
  if (!tier || !(tier in supportTierLabels)) {
    throw new Error(`Tier has an unknown or missing tier attribute: ${attrs}`);
  }
  const note = attrs.match(/\bnote="([^"]*)"/)?.[1];
  const footnote = attrs.match(/\bfn=\{(\d+)\}/)?.[1];
  return [
    supportTierLabels[tier],
    note ? ` — ${escapeHtmlText(note)}` : "",
    footnote ? ` (footnote ${footnote})` : "",
  ].join("");
}

function renderJsxComponent(block: string): string | null {
  const component = block.trimStart();
  if (component.startsWith("<AttrTable")) return renderAttrTable(component);
  if (component.startsWith("<ComponentIndexGrid")) return renderComponentIndex();
  if (component.startsWith("<IconGallery")) return renderIconList();
  if (component.startsWith("<EjectSection")) return renderEjectSection(component);
  if (component.startsWith("<TierLegend")) return renderTierLegend();
  if (component.startsWith("<ComponentPreview")) return null;

  const name = component.match(/^<([A-Z][A-Za-z0-9]*)/)?.[1] ?? "unknown";
  throw new Error(`mdx-to-markdown: unsupported JSX component <${name}>`);
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
    .map((page) => `- [${page.name}](${docsPath}/components/${page.slug}) — ${page.blurb}`)
    .join("\n");
}

function renderIconList(): string {
  const icons = vocab.icons as string[];
  return `Built-in icon names: ${icons.map((name) => `\`${name}\``).join(", ")}.`;
}

function renderEjectSection(block: string): string {
  const componentsSource = block.match(/components=\{\[([\s\S]*?)\]\}/)?.[1] ?? "";
  const names = [...componentsSource.matchAll(/"([^"]+)"/g)].map((match) => match[1]!);
  if (names.length === 0) {
    throw new Error("EjectSection has no component names");
  }
  const entries = names.map((name) => {
    const entry = ejectable.find((candidate) => candidate.name === name);
    if (!entry) {
      throw new Error(`EjectSection names unknown component "${name}"`);
    }
    return entry;
  });
  const descriptions = entries
    .map((entry) => `\`${entry.name}\` ejects as a ${entry.form} (\`${entry.path}\`)`)
    .join("; ");
  const commands = entries.map((entry) => `native eject component ${entry.name}`).join("\n");

  return [
    "## Eject",
    "",
    `When theming is not enough and you need to own the ${entries[0]!.name}'s *shape*, eject it: the canonical source lands in your project as your code — SDK updates never touch it, and ejecting twice errors instead of overwriting your edits. ${descriptions}.`,
    "",
    "```sh",
    commands,
    "```",
    "",
    `The ownership model and what to do after ejecting are in [Use, eject, or build](${docsPath}/building-components#use-eject-or-build).`,
  ].join("\n");
}

function renderTierLegend(): string {
  return [
    "- First-class — implemented and exercised",
    "- Works with caveats — real support, footnote applies",
    "- Embed-level — runs inside a host app you own",
    "- Not available today",
    "- Experimental — verified on the simulator/emulator; APIs and tooling may still change",
  ].join("\n");
}

function escapeCell(text: string): string {
  return text.replace(/\|/g, "\\|").replace(/\n/g, " ");
}

function escapeHtmlText(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
