import { existsSync } from "node:fs";
import { join } from "node:path";
import { createGeistdocs } from "@vercel/geistdocs/next";
import type { NextConfig } from "next";

const withGeistdocs = createGeistdocs();

// In this monorepo, compile @vercel/geistdocs from its workspace source so edits
// to the package hot-reload in the running dev server (no rebuild/restart).
// Turbopack only watches packages listed here; without it, changes to the
// prebuilt dist in node_modules are ignored. Published/scaffolded installs have
// no workspace source, so this is skipped and the prebuilt dist is used as-is.
const inMonorepo = existsSync(
  join(process.cwd(), "../../packages/geistdocs/src")
);
// Distinct favicon per environment; production keeps the default (no-op).
const ENV_FAVICONS = {
  development: "/favicon.development.ico",
  preview: "/favicon.preview.ico",
} as const;

const environment = process.env.VERCEL_ENV ?? process.env.NODE_ENV;
const envFavicon = ENV_FAVICONS[environment as keyof typeof ENV_FAVICONS];

const config: NextConfig = {
  agentRules: false,
  ...(inMonorepo ? { transpilePackages: ["@vercel/geistdocs"] } : {}),
  cacheComponents: true,
  partialPrefetching: true,
  outputFileTracingIncludes: {
    "/[lang]/og/[...slug]": ["./app/og/*.ttf", "./app/og/labs-logo.svg"],
  },

  rewrites() {
    if (!envFavicon) {
      return Promise.resolve([]);
    }

    return Promise.resolve({
      beforeFiles: [{ source: "/favicon.ico", destination: envFavicon }],
      afterFiles: [],
      fallback: [],
    });
  },
};

export default withGeistdocs(config);
