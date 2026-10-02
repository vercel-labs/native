import type { Metadata } from "next";
import { PAGE_TITLES } from "./page-titles";
import { description, docsPath } from "./site";

export function pageMetadata(slug: string): Metadata {
  const title = PAGE_TITLES[slug];
  if (!title) return {};

  const displayTitle = title.replace(/\n/g, " ");
  const fullTitle = `${displayTitle} | Native SDK`;
  const ogImageUrl = slug ? `/og/${slug}` : "/og";
  const canonicalUrl = `${docsPath}/${slug}`;

  return {
    title: displayTitle,
    alternates: { canonical: canonicalUrl },
    openGraph: {
      type: "website",
      locale: "en_US",
      siteName: "Native SDK",
      title: fullTitle,
      url: canonicalUrl,
      description,
      images: [
        {
          url: ogImageUrl,
          width: 1200,
          height: 630,
          alt: `${displayTitle} - Native SDK`,
        },
      ],
    },
    twitter: {
      card: "summary_large_image",
      title: fullTitle,
      description,
      images: [ogImageUrl],
    },
  };
}
