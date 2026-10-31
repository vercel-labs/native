import { defineConfig } from "@vercel/geistdocs/config";
import { description, githubUrl, siteName, siteUrl } from "@/lib/site";

const [owner, repo] = new URL(githubUrl).pathname.slice(1).split("/");

export const config = defineConfig({
  title: siteName,
  siteUrl,
  defaultLanguage: "en",
  translations: { en: { displayName: "English" } },
  logo: <span className="font-[family-name:var(--font-geist-pixel-square)] text-lg">{siteName}</span>,
  navbarBrand: "labs",
  navbarActiveProduct: siteName,
  github: { owner, repo, branch: "main", editPath: "docs/content/docs/{path}" },
  content: [{ id: "docs", label: "Documentation", dir: "content/docs", route: "/docs" }],
  nav: [{ label: "Docs", href: "/docs/introduction" }],
  search: { enabled: true },
  ai: { enabled: false },
  feedback: { enabled: false },
  language: { enabled: false },
  pageActions: { askAI: false, openInChat: false },
  agent: {
    product: {
      name: siteName,
      description,
      category: "Application framework",
      useCases: ["Build native desktop apps with TypeScript and Native markup", "Look up Native markup components and platform support", "Test and automate native apps"],
    },
  },
});
