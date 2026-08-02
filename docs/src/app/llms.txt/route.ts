import { docsIndexSections } from "@/lib/docs-navigation";
import { description, siteName, siteUrl } from "@/lib/site";

/**
 * Keep the model-readable docs index on the complete canonical inventory: the
 * sidebar plus compatibility pages that remain public but need no navigation
 * slot. Each target is the clean Markdown representation generated from its
 * page.mdx source at /<page path>.md, so neither this index nor its linked
 * content needs a second hand-maintained copy.
 */
export const dynamic = "force-static";

export function GET() {
  const sections = docsIndexSections.map(({ title, items }) => {
    const links = items.map(({ name, href }) => `- [${name}](${siteUrl}${href}.md)`);
    return [`## ${title}`, "", ...links].join("\n");
  });

  const body = [
    `# ${siteName}`,
    "",
    `> ${description}`,
    "",
    `The documentation home is [${siteUrl}](${siteUrl}). The links below return clean Markdown generated from the canonical MDX documentation sources.`,
    "",
    sections.join("\n\n"),
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });
}
