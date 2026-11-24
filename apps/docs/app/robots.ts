import { getPublicPath } from "@vercel/geistdocs/config";
import type { MetadataRoute } from "next";
import { config } from "@/lib/geistdocs/config";
import { absoluteUrl } from "@/lib/geistdocs/site-url";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: "*",
      allow: "/",
    },
    sitemap: absoluteUrl(getPublicPath("/sitemap.xml", config.basePath)),
  };
}
