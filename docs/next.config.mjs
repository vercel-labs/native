import { createGeistdocs } from "@vercel/geistdocs/next";
import { readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const withGeistdocs = createGeistdocs();
const contentDir = fileURLToPath(new URL("./content/docs", import.meta.url));

function docsSlugs(dir = contentDir, segments = []) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory()) return docsSlugs(path.join(dir, entry.name), [...segments, entry.name]);
    if (!entry.name.endsWith(".mdx")) return [];
    const name = entry.name.slice(0, -4);
    return [[...segments, ...(name === "index" ? [] : [name])].join("/")];
  });
}

/** @type {import('next').NextConfig} */
const nextConfig = {
  agentRules: false,
  allowedDevOrigins: ["127.0.0.1"],
  images: { qualities: [75, 90] },
  distDir: process.env.NEXT_DIST_DIR || ".next",
  skipProxyUrlNormalize: true,
  async redirects() {
    return [
      { source: "/philosophy", destination: "/docs/introduction", permanent: true },
      { source: "/docs", destination: "/docs/introduction", permanent: true },
      { source: "/docs.md", destination: "/docs/introduction.md", permanent: true },
      ...docsSlugs().flatMap((slug) => [
        { source: `/${slug}`, destination: `/docs/${slug}`, permanent: true },
        { source: `/${slug}.md`, destination: `/docs/${slug}.md`, permanent: true },
        { source: `/md/${slug}`, destination: `/docs/${slug}.md`, permanent: true },
      ]),
    ];
  },
  outputFileTracingIncludes: { "/og/[...slug]": ["./public/*.ttf"], "/og": ["./public/*.ttf"] },
};

export default withGeistdocs(nextConfig);
