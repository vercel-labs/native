import { createSearchExportRoute } from "@vercel/geistdocs/routes/search-export";
import { config } from "@/lib/geistdocs/config";
import { geistdocsSource } from "@/lib/geistdocs/source";

export const { GET } = createSearchExportRoute({
  config,
  sources: [geistdocsSource],
});
