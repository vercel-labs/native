import type { MetadataRoute } from "next";
import { source } from "@/lib/geistdocs/source";
import { siteUrl } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  return [{ url: siteUrl }, ...source.getPages("en").map((page) => ({ url: `${siteUrl}${page.url}` }))];
}
