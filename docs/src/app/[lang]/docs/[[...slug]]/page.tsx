import { MobileDocsBar } from "@vercel/geistdocs/mobile-docs-bar";
import { createDocsPage } from "@vercel/geistdocs/pages/docs";
import { getMDXComponents } from "@/components/geistdocs/mdx-components";
import { config } from "@/lib/geistdocs/config";
import { geistdocsSource } from "@/lib/geistdocs/source";
import { pageMetadata } from "@/lib/page-metadata";
import { headingId } from "@/lib/remark-docs";

const page = createDocsPage({
  config,
  source: geistdocsSource,
  canViewPage: (_page, { params }) => params.lang === "en",
  mdx: ({ link }) => getMDXComponents({ a: link }),
  getMarkdownUrl: ({ page }) => `${page.url}.md`,
  metadata: ({ metadata, page }) => {
    const legacy = pageMetadata(page.slugs.join("/"));
    return {
      ...metadata,
      ...legacy,
      alternates: { ...metadata.alternates, ...legacy.alternates },
      openGraph: { ...metadata.openGraph, ...legacy.openGraph },
      twitter: { ...metadata.twitter, ...legacy.twitter },
    };
  },
  renderTop: ({ data }) => (
    <>
      <span id="main-content" tabIndex={-1} className="sr-only">Documentation content</span>
      <span id={headingId(data.title)} className="sr-only" />
      <MobileDocsBar toc={data.toc} />
    </>
  ),
});

export default page.Page;
export const generateStaticParams = page.generateStaticParams;
export const generateMetadata = page.generateMetadata;
