import type {
  GeistdocsAgentReadinessConfig,
  GeistdocsNavbarBrand,
} from "@vercel/geistdocs/config";

export const navbarBrand: GeistdocsNavbarBrand = "labs";

export const Logo = () => (
  <span
    className="font-sans text-[24.4px] font-semibold leading-none tracking-[-0.05em] text-black dark:text-white"
    style={{ transform: "translateY(-0.5px)" }}
  >
    Native SDK
  </span>
);

export const github = {
  branch: "next",
  editPath: "apps/docs/content/docs/{path}",
  owner: "vercel-labs",
  repo: "native",
};

const repositoryUrl = `https://github.com/${github.owner}/${github.repo}`;

export const nav = [
  {
    label: "Docs",
    href: "/",
  },
  {
    label: "GitHub",
    href: repositoryUrl,
  },
];

export const title = "Native SDK";

export const agent = {
  product: {
    name: "Native SDK",
    description:
      "Native SDK builds native apps from HTML, CSS and TypeScript. native compiles the HTML and CSS ahead of time, and scriptc compiles the TypeScript to machine code.",
    category: "Developer tools",
    audience: ["Web developers", "App developers"],
    useCases: [
      "Build a native app from HTML, CSS and TypeScript",
      "Run a web interface without a browser, webview or JavaScript engine",
      "Test an app headlessly with scripted input and screenshots",
    ],
  },
  api: {
    siteOpenApiUrl: "/openapi.json",
  },
  links: [
    {
      label: "Native SDK on GitHub",
      href: repositoryUrl,
      description: "Source code and examples",
    },
  ],
} satisfies GeistdocsAgentReadinessConfig;

export const translations = {
  en: {
    displayName: "English",
  },
};

export const basePath: string | undefined = undefined;

