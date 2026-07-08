import { allDocsPages } from "./docs-navigation";
import { readFile } from "node:fs/promises";
import path from "node:path";

export type IndexEntry = {
  title: string;
  href: string;
  content: string;
};

let cached: IndexEntry[] | null = null;

export async function getSearchIndex(): Promise<IndexEntry[]> {
  if (cached) return cached;

  // The homepage lives in the site header, not the docs nav, so index it explicitly.
  const pages = [{ name: "Home", href: "/" }, ...allDocsPages];
  const entries: IndexEntry[] = await Promise.all(
    pages.map(async (item) => ({
      title: item.name,
      href: item.href,
      content: await pageContent(item.href, item.name),
    })),
  );

  cached = entries;
  return entries;
}

async function pageContent(href: string, fallback: string): Promise<string> {
  // The homepage is a TSX landing page, not MDX; index a hand-written summary.
  if (href === "/") {
    return "Toolkit for building native desktop apps. Cross-platform native UI: declarative Native markup views (.native), design tokens, Zig logic, a predictable message-based state loop, hot reload, typed effects, AI agent skills and evals, automation, WebView coexistence on macOS, Linux, Windows, iOS, and Android.";
  }
  const relative = path.join(href.slice(1), "page.mdx");
  const filePath = path.join(process.cwd(), "src", "app", relative);
  try {
    const source = await readFile(filePath, "utf8");
    return stripMdx(source);
  } catch {
    return fallback;
  }
}

function stripMdx(source: string): string {
  return source
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/[#*_`[\](){}>-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
