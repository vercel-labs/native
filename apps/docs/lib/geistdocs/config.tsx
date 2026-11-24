import { defineConfig } from "@vercel/geistdocs/config";
import {
  agent,
  basePath,
  github,
  Logo,
  nav,
  navbarBrand,
  title,
  translations,
} from "@/geistdocs";
import { isSiteUrlConfigured, siteUrl } from "./site-url";

export const config = defineConfig({
  title,
  agent,
  defaultLanguage: "en",
  logo: <Logo />,
  github,
  nav,
  navbarBrand,
  basePath,
  siteUrl: isSiteUrlConfigured ? siteUrl.toString() : undefined,
  translations,
  content: [{ id: "docs", label: "Docs", dir: "content/docs", route: "/" }],
  ai: { enabled: false },
  feedback: { enabled: false },
  language: { enabled: false },
  pageActions: {
    askAI: false,
    copyPage: true,
    openInChat: false,
  },
  webmcp: { enabled: true },
});
