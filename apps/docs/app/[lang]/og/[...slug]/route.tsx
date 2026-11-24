import type { NextRequest } from "next/server";
import { config } from "@/lib/geistdocs/config";
import { createOpenGraphImage } from "@/lib/geistdocs/og";
import { getPageImage, source } from "@/lib/geistdocs/source";

export const GET = async (
  _request: NextRequest,
  { params }: RouteContext<"/[lang]/og/[...slug]">
) => {
  const { slug, lang } = await params;
  const page = source.getPage(slug.slice(0, -1), lang);

  if (!page) {
    return new Response("Not found", { status: 404 });
  }

  return createOpenGraphImage(
    page.data.title ?? config.title,
    page.data.description
  );
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
