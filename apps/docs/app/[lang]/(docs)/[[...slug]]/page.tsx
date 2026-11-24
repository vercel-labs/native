import { MobileDocsBar } from "@vercel/geistdocs/mobile-docs-bar";
import { createDocsPage } from "@vercel/geistdocs/pages/docs";
import { getMDXComponents } from "@/components/geistdocs/mdx-components";
import { config } from "@/lib/geistdocs/config";
import { geistdocsSource, getPageImage } from "@/lib/geistdocs/source";
import { versionedOgImage } from "@/lib/og-version";
import { HOME_OG_TITLE } from "@/lib/page-titles";

const docsPage = createDocsPage({
  config,
  mdx: ({ link }) => getMDXComponents({ a: link }),
  metadata: ({ metadata, page }) => {
    const isHome = page.url === "/";
    // Match the title the OG route draws so the version tracks card content.
    const imageTitle = isHome
      ? HOME_OG_TITLE
      : (page.data.title ?? config.title);
    const image = versionedOgImage(getPageImage(page).url, imageTitle);

    return {
      ...metadata,
      ...(isHome ? { title: { absolute: "Native SDK" } } : {}),
      openGraph: {
        ...metadata.openGraph,
        images: [image],
      },
    };
  },
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
