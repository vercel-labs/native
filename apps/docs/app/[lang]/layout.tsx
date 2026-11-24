import "../global.css";
import { geistFontClasses } from "@vercel/geistdocs/core";
import { cn } from "@vercel/geistdocs/utils";
import "@/lib/geistdocs/site-url-warning";
import { Footer } from "@vercel/geistdocs/footer";
import { GeistdocsThemeScript } from "@vercel/geistdocs/layout";
import { Navbar } from "@vercel/geistdocs/navbar";
import type { Metadata } from "next";
import { GeistdocsProvider } from "@/components/geistdocs/provider";
import { config } from "@/lib/geistdocs/config";
import { i18n } from "@/lib/geistdocs/i18n";
import { getRootLang } from "@/lib/geistdocs/root-params";
import { isSiteUrlConfigured, siteUrl } from "@/lib/geistdocs/site-url";

export const generateStaticParams = () =>
  i18n.languages.map((lang) => ({ lang }));

export const metadata: Metadata = {
  metadataBase: isSiteUrlConfigured ? siteUrl : undefined,
  title: {
    default: "Native SDK",
    template: "%s | Native SDK",
  },
  description: "HTML, CSS and TypeScript compiled into native apps, without Node.js.",
};

const Layout = async ({ children }: LayoutProps<"/[lang]">) => {
  const lang = await getRootLang();

  return (
    <html
      className={cn(
        geistFontClasses,
        "tailwind tailwind-preflight antialiased"
      )}
      lang={lang}
      suppressHydrationWarning
    >
      <head>
        <GeistdocsThemeScript />
      </head>
      <body style={{ backgroundColor: "var(--ds-background-200)" }}>
        <GeistdocsProvider basePath={config.basePath} lang={lang}>
          <Navbar config={config} />
          {children}
          <Footer />
        </GeistdocsProvider>
      </body>
    </html>
  );
};

export default Layout;
