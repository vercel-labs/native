import { createAgentsRoute } from "@vercel/geistdocs/routes/agents";
import { config } from "@/lib/geistdocs/config";

export const { GET, generateStaticParams } = createAgentsRoute({
  config,
});
