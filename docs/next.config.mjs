import createMDX from "@next/mdx";

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const nextConfig = {
  pageExtensions: ["ts", "tsx", "md", "mdx"],
  // CI-style builds set NEXT_DIST_DIR so `pnpm check` never shares .next
  // with a running dev server (a shared dist dir corrupts the dev cache).
  distDir: process.env.NEXT_DIST_DIR || ".next",
};

export default withMDX(nextConfig);
