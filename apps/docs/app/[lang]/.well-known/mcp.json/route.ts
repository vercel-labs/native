import { createMcpManifestRoute } from "@vercel/geistdocs/routes/mcp";
import { config } from "@/lib/geistdocs/config";

export const { GET, generateStaticParams } = createMcpManifestRoute({
  config,
});
