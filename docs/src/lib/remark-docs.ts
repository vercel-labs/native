import type { Root } from "mdast";
import { visit } from "unist-util-visit";

/** Preserve anchors published by the previous HeadingLink component. */
export function headingId(text: string): string {
  return text.toLowerCase().replace(/[^\w\s-]/g, "").replace(/\s+/g, "-").replace(/-+/g, "-").trim();
}

/** Keep Native's language:filename fence syntax in the shared MDX pipeline. */
export function remarkDocsConventions() {
  return (tree: Root) => visit(tree, "code", (node) => {
    const colon = node.lang?.indexOf(":") ?? -1;
    if (colon < 0 || !node.lang) return;
    const filename = node.lang.slice(colon + 1);
    node.lang = node.lang.slice(0, colon);
    if (filename) node.meta = `title=${JSON.stringify(filename)}`;
  });
}
