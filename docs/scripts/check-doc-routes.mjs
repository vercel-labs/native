// SEO regression gate for the /docs migration. Every page.mdx must build at
// one canonical HTML URL and one canonical Markdown sibling; the former route
// must redirect permanently rather than render duplicate content. Canonical
// metadata, sitemap entries, llms.txt, and rendered internal links must all
// point directly into /docs so crawlers never have to choose between copies.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const docsDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const sourceDir = join(docsDir, "src", "app", "docs");
const distDir = join(docsDir, process.env.NEXT_DIST_DIR || ".next");
const appOutputDir = join(distDir, "server", "app");
const siteUrl = "https://native-sdk.dev";

function* mdxPages(dir) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) yield* mdxPages(full);
    else if (entry === "page.mdx") yield full;
  }
}

function readRequired(file, route) {
  if (!existsSync(file)) {
    throw new Error(`${route}: missing build output ${file}`);
  }
  return readFileSync(file, "utf8");
}

const routesManifest = JSON.parse(
  readRequired(join(distDir, "routes-manifest.json"), "redirect manifest"),
);

function assertConfiguredRedirect(source, destination) {
  const redirect = routesManifest.redirects.find((candidate) => candidate.source === source);
  if (!redirect || redirect.statusCode !== 308 || redirect.destination !== destination) {
    throw new Error(
      `${source}: expected a query-preserving 308 config redirect to ${destination}, got ${JSON.stringify(redirect)}`,
    );
  }
}

function proseLines(markdown) {
  const lines = [];
  let fence = null;
  for (const line of markdown.split("\n")) {
    const marker = line.trimStart().match(/^(```|~~~)/)?.[1];
    if (marker) {
      if (fence === marker) fence = null;
      else if (fence === null) fence = marker;
      continue;
    }
    if (fence === null) lines.push(line);
  }
  return lines;
}

function headings(markdown) {
  return proseLines(markdown)
    .map((line) => line.match(/^(#{1,6})\s+(.+?)\s*#*\s*$/))
    .filter(Boolean)
    .map((match) => `${match[1]} ${match[2]}`);
}

function assertCleanMarkdown(source, markdown, route) {
  // Generic type spellings such as `Sub<Msg>` are legitimate inside inline
  // code and must not be mistaken for unresolved MDX components.
  const prose = proseLines(markdown).join("\n").replace(/`[^`\n]*`/g, "");
  const unresolved = prose.match(/<[A-Z][A-Za-z0-9]*(?:\s|\/?>)/)?.[0];
  if (unresolved) {
    throw new Error(`${route}: unresolved MDX component in Markdown output: ${unresolved}`);
  }
  const unresolvedExpression = prose.match(/\{"[^"\\\r\n]*"\}|\{'[^'\\\r\n]*'\}/)?.[0];
  if (unresolvedExpression) {
    throw new Error(
      `${route}: unresolved MDX string expression in Markdown output: ${unresolvedExpression}`,
    );
  }

  const renderedHeadings = new Set(headings(markdown));
  for (const heading of headings(source)) {
    if (!renderedHeadings.has(heading)) {
      throw new Error(`${route}: Markdown output dropped source heading ${heading}`);
    }
  }

  for (const component of source.matchAll(/<EjectSection\s+components=\{\[([\s\S]*?)\]\}\s*\/>/g)) {
    if (!renderedHeadings.has("## Eject")) {
      throw new Error(`${route}: EjectSection did not render its heading`);
    }
    for (const name of component[1].matchAll(/"([^"]+)"/g)) {
      const command = `native eject component ${name[1]}`;
      if (!markdown.includes(command)) {
        throw new Error(`${route}: EjectSection did not render command ${command}`);
      }
    }
  }
}

const pageFiles = [...mdxPages(sourceDir)];
const canonicalPaths = new Set(
  pageFiles.map((page) => {
    const slug = relative(sourceDir, dirname(page)).split(sep).join("/");
    return `/docs/${slug}`;
  }),
);
const canonicalUrls = new Set([...canonicalPaths].map((route) => `${siteUrl}${route}`));
const canonicalMarkdownUrls = new Set(
  [...canonicalPaths].map((route) => `${siteUrl}${route}.md`),
);
let pages = 0;

for (const page of pageFiles) {
  pages += 1;
  const slug = relative(sourceDir, dirname(page)).split(sep).join("/");
  const canonicalPath = `/docs/${slug}`;
  const canonicalUrl = `${siteUrl}${canonicalPath}`;
  const output = join(appOutputDir, "docs", slug);
  const html = readRequired(`${output}.html`, canonicalPath);
  const source = readFileSync(page, "utf8");

  if (!html.includes(`<link rel="canonical" href="${canonicalUrl}"/>`)) {
    throw new Error(`${canonicalPath}: missing its exact canonical link tag`);
  }
  if (!html.includes(`<meta property="og:url" content="${canonicalUrl}"/>`)) {
    throw new Error(`${canonicalPath}: Open Graph URL is not canonical`);
  }

  for (const match of html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)) {
    const href = match[1];
    if (href?.startsWith("/") && href !== "/" && !href.startsWith("/docs/")) {
      throw new Error(`${canonicalPath}: rendered internal link bypasses /docs: ${href}`);
    }
    if (href?.startsWith("/docs/")) {
      const target = href.split(/[?#]/, 1)[0];
      if (target && !canonicalPaths.has(target)) {
        throw new Error(`${canonicalPath}: rendered internal link targets no docs page: ${href}`);
      }
    }
  }

  const markdownMeta = JSON.parse(readRequired(`${output}.md.meta`, `${canonicalPath}.md`));
  if (
    markdownMeta.status !== 200 ||
    markdownMeta.headers?.["content-type"] !== "text/markdown; charset=utf-8"
  ) {
    throw new Error(`${canonicalPath}.md: expected a static text/markdown response`);
  }
  if (markdownMeta.headers?.link !== `<${canonicalUrl}>; rel="canonical"`) {
    throw new Error(`${canonicalPath}.md: missing its exact canonical HTTP Link header`);
  }
  const markdown = readRequired(`${output}.md.body`, `${canonicalPath}.md`);
  assertCleanMarkdown(source, markdown, `${canonicalPath}.md`);

  assertConfiguredRedirect(`/${slug}`, canonicalPath);
  assertConfiguredRedirect(`/${slug}.md`, `${canonicalPath}.md`);
  assertConfiguredRedirect(`/md/${slug}`, `${canonicalPath}.md`);

  for (const legacyOutput of [
    join(appOutputDir, `${slug}.html`),
    join(appOutputDir, `${slug}.meta`),
    join(appOutputDir, `${slug}.md.meta`),
    join(appOutputDir, "md", `${slug}.meta`),
  ]) {
    if (existsSync(legacyOutput)) {
      throw new Error(`/${slug}: legacy URL was prerendered instead of using its config redirect`);
    }
  }
}

if (pages === 0) throw new Error("no docs page.mdx files found");

const sitemap = readRequired(join(appOutputDir, "sitemap.xml.body"), "/sitemap.xml");
const sitemapUrls = new Set([...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((match) => match[1]));
for (const match of sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)) {
  const url = match[1];
  if (url !== `${siteUrl}/` && !canonicalUrls.has(url)) {
    throw new Error(`/sitemap.xml: non-canonical documentation URL ${url}`);
  }
}
for (const url of canonicalUrls) {
  if (!sitemapUrls.has(url)) throw new Error(`/sitemap.xml: missing canonical page ${url}`);
}

const llms = readRequired(join(appOutputDir, "llms.txt.body"), "/llms.txt");
const llmsUrls = new Set();
for (const line of llms.split("\n")) {
  if (!line.startsWith("- [")) continue;
  const url = line.match(/^- \[[^\]]+\]\(([^)]+)\)$/)?.[1];
  if (!url || !canonicalMarkdownUrls.has(url)) {
    throw new Error(`/llms.txt: non-canonical documentation link: ${line}`);
  }
  llmsUrls.add(url);
}
for (const url of canonicalMarkdownUrls) {
  if (!llmsUrls.has(url)) throw new Error(`/llms.txt: missing canonical page ${url}`);
}

console.log(
  `docs route check passed: ${pages} canonical pages, Markdown siblings, and query-preserving legacy redirects verified`,
);
