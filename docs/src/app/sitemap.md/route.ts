import { createSitemapMarkdownRoute } from "@vercel/geistdocs/routes/sitemap";
import type { NextRequest } from "next/server";
import { config } from "@/lib/geistdocs/config";
import { geistdocsSource } from "@/lib/geistdocs/source";

const route = createSitemapMarkdownRoute({ config, source: geistdocsSource });
export const dynamic = "force-static";

export function GET(request: NextRequest) {
  return route.GET(request, { params: Promise.resolve({ lang: "en" }) });
}
