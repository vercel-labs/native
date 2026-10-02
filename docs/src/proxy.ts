import { createProxy } from "@vercel/geistdocs/proxy";
import { createI18nMiddleware } from "fumadocs-core/i18n/middleware";
import { NextResponse } from "next/server";
import { config as geistdocsConfig } from "@/lib/geistdocs/config";

const localeProxy = createI18nMiddleware({ defaultLanguage: "en", languages: ["en"], hideLocale: "default-locale" });
const appRoutes = ["/og", "/llms.txt", "/sitemap.md", "/agents.md"];

export default createProxy({
  config: geistdocsConfig,
  markdownRoutes: [{ from: "/docs/*path", to: "/api/docs-md/*path" }],
  additionalMarkdownRoutes: [{ from: "/", to: "/agents.md" }],
  before: async ({ request, context }) => {
    // These app-owned routes do not use locale prefixes or Markdown negotiation.
    const path = request.nextUrl.pathname;
    if (path.startsWith("/schemas/") || /\.(?:wasm|webp|png|jpg|jpeg|gif|svg|ico|ttf|woff2?)$/i.test(path)) {
      return NextResponse.next();
    }
    if (appRoutes.some((route) => path === route || path.startsWith(`${route}/`))) {
      return NextResponse.next();
    }
    // Keep the default locale out of public URLs, including old bookmarks.
    if (path === "/en/docs" || path.startsWith("/en/docs/")) {
      const destination = request.nextUrl.clone();
      destination.pathname = path.slice(3);
      return NextResponse.redirect(destination, 308);
    }
    // Navigation and prefetch requests need the React payload, even for agent UAs.
    if (
      request.headers.get("rsc") === "1" ||
      request.headers.has("next-router-prefetch") ||
      request.headers.has("next-router-segment-prefetch") ||
      /\bprefetch\b/i.test(request.headers.get("purpose") ?? "") ||
      /\bprefetch\b/i.test(request.headers.get("sec-purpose") ?? "")
    ) {
      return path === "/" ? NextResponse.next() : (await localeProxy(request, context)) ?? NextResponse.next();
    }
  },
  after: ({ request }) => {
    if (request.nextUrl.pathname === "/") {
      return NextResponse.next({ headers: { Vary: "Accept" } });
    }
  },
});

export const config = {
  matcher: ["/((?!api(?:/|$)|_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt).*)"],
};
