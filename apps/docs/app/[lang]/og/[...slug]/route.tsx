import type { NextRequest } from "next/server";
import { renderLabsOg } from "@/app/og/labs-og";
import { config } from "@/lib/geistdocs/config";
import { getPageImage, source } from "@/lib/geistdocs/source";
import { HOME_OG_TITLE } from "@/lib/page-titles";

const product = "Native SDK";

export const GET = async (
  _request: NextRequest,
  { params }: RouteContext<"/[lang]/og/[...slug]">
) => {
  const { slug, lang } = await params;
  const page = source.getPage(slug.slice(0, -1), lang);

  if (!page) {
    return new Response("Not found", { status: 404 });
  }

  const title = page.slugs.length
    ? (page.data.title ?? config.title)
    : HOME_OG_TITLE;

  return renderLabsOg({ product, title });
};

export const generateStaticParams = async ({
  params,
}: RouteContext<"/[lang]/og/[...slug]">) => {
  const { lang } = await params;

  return source.getPages(lang).map((page) => ({
    lang: page.locale,
    slug: getPageImage(page).segments,
  }));
};
