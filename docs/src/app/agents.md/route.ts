import { createAgentsRoute } from "@vercel/geistdocs/routes/agents";
import type { NextRequest } from "next/server";
import { config } from "@/lib/geistdocs/config";

const route = createAgentsRoute({ config });
export const dynamic = "force-static";

export function GET(request: NextRequest) {
  return route.GET(request, { params: Promise.resolve({ lang: "en" }) });
}
