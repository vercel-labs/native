import createMDX from "@next/mdx";
import { createRequire } from "node:module";
import { readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Resolve the plugin to an absolute path (still a string, so the config
// stays serializable for Turbopack). A bare "remark-gfm" is require()d
// from the MDX loader's own package context, which under pnpm's strict
// module isolation cannot see this app's dependencies — production
// builds resolved it, the Turbopack dev server did not.
const require = createRequire(import.meta.url);
const docsContentDir = fileURLToPath(new URL("./src/app/docs", import.meta.url));

function docsSlugs(dir = docsContentDir, segments = []) {
  const slugs = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      slugs.push(...docsSlugs(path.join(dir, entry.name), [...segments, entry.name]));
    } else if (entry.name === "page.mdx" && segments.length > 0) {
      slugs.push(segments.join("/"));
    }
  }
  return slugs;
}

const withMDX = createMDX({
  options: {
    // GFM is what gives .mdx pages pipe tables (plus autolinks and
    // strikethrough) — without it, table markdown renders as a plain
    // paragraph of pipes.
    remarkPlugins: [[require.resolve("remark-gfm")]],
  },
});

/** @type {import('next').NextConfig} */
const nextConfig = {
  pageExtensions: ["ts", "tsx", "md", "mdx"],
  // CI-style builds set NEXT_DIST_DIR so `pnpm check` never shares .next
  // with a running dev server (a shared dist dir corrupts the dev cache).
  distDir: process.env.NEXT_DIST_DIR || ".next",
  // The gate builds into .next-gate INSIDE this dir; without an ignore,
  // the dev watcher sees every one of those build files land and
  // recompiles continuously whenever a gate runs.
  watchOptions: {
    ignored: ["**/.next-gate/**", "**/.next-check/**"],
  },
  async redirects() {
    // Config redirects preserve the request query string. Keeping these out
    // of the prerendered catch-all route avoids baking a query-less Location
    // header into every legacy URL's static response.
    const legacyDocsRedirects = docsSlugs().flatMap((slug) => [
      { source: `/${slug}`, destination: `/docs/${slug}`, permanent: true },
      { source: `/${slug}.md`, destination: `/docs/${slug}.md`, permanent: true },
      { source: `/md/${slug}`, destination: `/docs/${slug}.md`, permanent: true },
    ]);

    return [
      // The Philosophy page became the Introduction, the opening page of the docs.
      { source: "/philosophy", destination: "/docs/introduction", permanent: true },
      // docsSlugs() only yields nested slugs, so the /docs segment itself has
      // neither a route nor a generated redirect and 404s. It is the parent of
      // every documentation link on the site and the likeliest hand-typed entry
      // point, so open it on the Introduction instead. The .md sibling keeps the
      // Markdown surface whole for agents that reach for it.
      { source: "/docs", destination: "/docs/introduction", permanent: true },
      { source: "/docs.md", destination: "/docs/introduction.md", permanent: true },
      ...legacyDocsRedirects,
    ];
  },
};

export default withMDX(nextConfig);
