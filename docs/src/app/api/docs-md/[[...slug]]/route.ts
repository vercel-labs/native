import { createDocsMarkdownRoute } from "@vercel/geistdocs/routes/llms";
import { geistdocsSource } from "@/lib/geistdocs/source";

const route = createDocsMarkdownRoute({ source: geistdocsSource });

export async function GET(request: Request, { params }: { params: Promise<{ slug?: string[] }> }) {
  return route.GET(request, { params: Promise.resolve({ ...(await params), lang: "en" }) });
}
