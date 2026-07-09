import type { Metadata } from "next";
import Link from "next/link";
import { GeistSans } from "geist/font/sans";
import { GeistMono } from "geist/font/mono";
import { GeistPixelSquare } from "geist/font/pixel";
import { ThemeProvider } from "@/components/theme-provider";
import { ThemeToggle } from "@/components/theme-toggle";
import { Search } from "@/components/search";
import { HeaderNav, HeaderMobileMenu } from "@/components/header-nav";
import { DocsMobileNav } from "@/components/docs-mobile-nav";
import { DocsNav } from "@/components/docs-nav";
import { getStarCount } from "@/lib/github";
import { siteName, siteUrl, tagline, description, githubUrl } from "@/lib/site";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: {
    default: `${siteName} | ${tagline}`,
    template: `%s | ${siteName}`,
  },
  description,
  openGraph: {
    type: "website",
    locale: "en_US",
    url: siteUrl,
    siteName,
    title: `${siteName} | ${tagline}`,
    description,
    images: [{ url: "/og", width: 1200, height: 630, alt: siteName }],
  },
  twitter: {
    card: "summary_large_image",
    title: `${siteName} | ${tagline}`,
    description,
    images: ["/og"],
  },
};

function Header({ stars }: { stars?: string }) {
  return (
    <header className="sticky top-0 z-50 border-b border-gray-alpha-400 bg-background-100/80 backdrop-blur-sm">
      <div className="flex h-16 items-center justify-between px-4 gap-6">
        <div className="flex items-center gap-2">
          <Link href="https://vercel.com" title="Made with love by Vercel">
            <svg
              data-testid="geist-icon"
              height="18"
              strokeLinejoin="round"
              viewBox="0 0 16 16"
              width="18"
              style={{ color: "currentcolor" }}
            >
              <path
                fillRule="evenodd"
                clipRule="evenodd"
                d="M8 1L16 15H0L8 1Z"
                fill="currentColor"
              />
            </svg>
          </Link>
          <span className="text-gray-500">
            <svg
              data-testid="geist-icon"
              height="16"
              strokeLinejoin="round"
              viewBox="0 0 16 16"
              width="16"
              style={{ color: "currentcolor" }}
            >
              <path
                fillRule="evenodd"
                clipRule="evenodd"
                d="M4.01526 15.3939L4.3107 14.7046L10.3107 0.704556L10.6061 0.0151978L11.9849 0.606077L11.6894 1.29544L5.68942 15.2954L5.39398 15.9848L4.01526 15.3939Z"
                fill="currentColor"
              />
            </svg>
          </span>
          <Link href="/">
            <span className={`${GeistPixelSquare.className} text-lg`}>{siteName}</span>
          </Link>
        </div>
        <div className="flex items-center gap-4">
          <HeaderNav />
          <Search />
          <a
            href={githubUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-1.5 label-14 text-gray-900 hover:text-gray-1000 transition-colors"
          >
            <svg viewBox="0 0 16 16" className="h-4 w-4" fill="currentColor" aria-hidden="true">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
            </svg>
            {stars && <span>{stars}</span>}
          </a>
          <div className="hidden md:block">
            <ThemeToggle />
          </div>
          <HeaderMobileMenu />
        </div>
      </div>
    </header>
  );
}

export default async function RootLayout({ children }: { children: React.ReactNode }) {
  const stars = await getStarCount();

  return (
    <html
      lang="en"
      suppressHydrationWarning
      // overscroll-none on the root scroller: the document never
      // rubber-bands past its edges.
      className={`${GeistSans.variable} ${GeistMono.variable} overscroll-none`}
    >
      <body className="overscroll-none bg-background-100 text-gray-1000 antialiased">
        <ThemeProvider>
          <Header stars={stars} />
          <DocsMobileNav />
          <DocsNav>{children}</DocsNav>
        </ThemeProvider>
      </body>
    </html>
  );
}
