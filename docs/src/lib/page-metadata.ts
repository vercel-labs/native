import type { Metadata } from "next";
import { PAGE_TITLES } from "./page-titles";

const DESCRIPTION =
  "Toolkit for building native desktop apps: declarative markup views, a predictable message-based state model, and its own engine rendering into real OS windows — no browser or WebView in the binary.";

export function pageMetadata(slug: string): Metadata {
  const title = PAGE_TITLES[slug];
  if (!title) return {};

  const displayTitle = title.replace(/\n/g, " ");
  const fullTitle = `${displayTitle} | Native SDK`;
  const ogImageUrl = slug ? `/og/${slug}` : "/og";

  return {
    title: displayTitle,
    openGraph: {
      type: "website",
      locale: "en_US",
      siteName: "Native SDK",
      title: fullTitle,
      description: DESCRIPTION,
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
      description: DESCRIPTION,
      images: [ogImageUrl],
    },
  };
}
