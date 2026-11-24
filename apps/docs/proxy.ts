import { createProxy } from "@vercel/geistdocs/proxy";
import { config as geistdocsConfig } from "@/lib/geistdocs/config";
import { source } from "@/lib/geistdocs/source";

const pagePaths = new Set(source.getPages().map((page) => page.url));

const notFoundHtml = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex">
    <title>Page not found | Native SDK</title>
  </head>
  <body>
    <main>
      <p>404</p>
      <h1>Page not found</h1>
      <p>The requested documentation page does not exist.</p>
      <p><a href="/">Browse the documentation</a></p>
    </main>
  </body>
</html>
`;

const proxy = createProxy({
  config: geistdocsConfig,
  markdownRoutes: [{ from: "/*path", to: "/[lang]/llms.mdx/*path" }],
  before: () => null,
  after: ({ request }) => {
    const pathname =
      decodeURIComponent(request.nextUrl.pathname).replace(/\/$/, "") || "/";

    if (pathname === "/en" || pathname.startsWith("/en/")) {
      return null;
    }

    if (pathname.includes(".") || pagePaths.has(pathname)) {
      return null;
    }

    return new Response(notFoundHtml, {
      status: 404,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "X-Robots-Tag": "noindex",
      },
    });
  },
});

export const config = {
  matcher: [
    "/",
    "/((?!api(?:/|$)|_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt).*)",
  ],
};

export default proxy;
