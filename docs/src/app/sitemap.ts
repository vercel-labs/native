import type { MetadataRoute } from "next";
import { allDocsPages } from "@/lib/docs-navigation";
import { statSync } from "node:fs";
import path from "node:path";

const baseUrl = "https://zero-native.dev";

export default function sitemap(): MetadataRoute.Sitemap {
  return allDocsPages.map((page) => ({
    url: `${baseUrl}${page.href}`,
    lastModified: lastModifiedFor(page.href),
  }));
}

function lastModifiedFor(href: string): Date {
  const relative = href === "/" ? "page.tsx" : path.join(href.slice(1), "page.mdx");
  try {
    return statSync(path.join(process.cwd(), "src", "app", relative)).mtime;
  } catch {
    return new Date("2026-05-08T00:00:00.000Z");
  }
}
