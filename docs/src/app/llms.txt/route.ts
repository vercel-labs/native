import { createLlmsRoute } from "@vercel/geistdocs/routes/llms";
import type { NextRequest } from "next/server";
import { geistdocsSource } from "@/lib/geistdocs/source";

const route = createLlmsRoute({ source: geistdocsSource });
export const dynamic = "force-static";

export function GET(request: NextRequest) {
  return route.GET(request, { params: Promise.resolve({ lang: "en" }) });
}
