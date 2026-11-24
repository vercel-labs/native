import { createLlmsRoute } from "@vercel/geistdocs/routes/llms";
import { geistdocsSource } from "@/lib/geistdocs/source";

export const { GET } = createLlmsRoute({
  sources: [geistdocsSource],
});
