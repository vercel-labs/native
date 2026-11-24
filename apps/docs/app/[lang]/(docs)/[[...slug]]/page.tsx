import { MobileDocsBar } from "@vercel/geistdocs/mobile-docs-bar";
import { createDocsPage } from "@vercel/geistdocs/pages/docs";
import { getMDXComponents } from "@/components/geistdocs/mdx-components";
import { config } from "@/lib/geistdocs/config";
import { geistdocsSource } from "@/lib/geistdocs/source";

const docsPage = createDocsPage({
  config,
  mdx: ({ link }) => getMDXComponents({ a: link }),
  metadata: ({ metadata, page }) =>
    page.url === "/"
      ? { ...metadata, title: { absolute: "Native SDK" } }
      : metadata,
  openGraph: {
    images: true,
  },
  source: geistdocsSource,
  tableOfContentPopover: {
    enabled: false,
  },
  renderTop: ({ data }) => <MobileDocsBar toc={data.toc} />,
});

export default docsPage.Page;
export const generateStaticParams = docsPage.generateStaticParams;
export const generateMetadata = docsPage.generateMetadata;
