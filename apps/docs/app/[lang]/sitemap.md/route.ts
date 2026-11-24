import { createSitemapMarkdownRoute } from "@vercel/geistdocs/routes/sitemap";
import { config } from "@/lib/geistdocs/config";
import { geistdocsSource } from "@/lib/geistdocs/source";

export const { GET, generateStaticParams } = createSitemapMarkdownRoute({
  config,
  sources: [{ source: geistdocsSource }],
});
