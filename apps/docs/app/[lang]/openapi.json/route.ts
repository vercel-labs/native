import { createOpenApiRoute } from "@vercel/geistdocs/routes/openapi";
import { config } from "@/lib/geistdocs/config";

export const { GET, generateStaticParams } = createOpenApiRoute({
  config,
});
