import { getPublicPath } from "@vercel/geistdocs/config";
import { isPageVisibleForSurface } from "@vercel/geistdocs/page-visibility";
import type { MetadataRoute } from "next";
import { cacheLife } from "next/cache";
import { config } from "@/lib/geistdocs/config";
import { absoluteUrl } from "@/lib/geistdocs/site-url";
import { source } from "@/lib/geistdocs/source";

// biome-ignore lint/suspicious/useAwait: Next.js requires cached functions to be async.
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  "use cache";
  cacheLife("max");

  const url = (path: string) =>
    absoluteUrl(getPublicPath(path, config.basePath));

  const pages: MetadataRoute.Sitemap = [];

  for (const page of source.getPages()) {
    if (!isPageVisibleForSurface(page, "sitemap") || page.url === "/") {
      continue;
    }

    const data = page.data as { lastModified?: Date };

    pages.push({
      changeFrequency: "weekly" as const,
      lastModified: data.lastModified ? new Date(data.lastModified) : undefined,
      priority: 0.5,
      url: url(page.url),
    });
  }

  return [
    {
      changeFrequency: "monthly",
      priority: 1,
      url: url("/"),
    },
    ...pages,
  ];
}
