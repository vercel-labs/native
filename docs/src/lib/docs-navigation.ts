import { componentPages } from "./components-pages";
import { docsPath } from "./site";

export type NavItem = {
  name: string;
  href: string;
};

export type NavSection = {
  title: string;
  items: NavItem[];
};

const unprefixedNavSections: NavSection[] = [
  {
    title: "Get Started",
    items: [
      { name: "Introduction", href: "/introduction" },
      { name: "Quick Start", href: "/quick-start" },
      { name: "CLI", href: "/cli" },
      { name: "Config", href: "/app-zon" },
      { name: "Agent Skills", href: "/skills" },
    ],
  },
  {
    title: "Core Concepts",
    items: [
      { name: "App Model", href: "/app-model" },
      { name: "TypeScript Cores", href: "/typescript" },
      { name: "Where Packages Go", href: "/typescript/packages" },
      { name: "Native UI", href: "/native-ui" },
      { name: "Dynamic Images", href: "/dynamic-images" },
      { name: "Model Persistence", href: "/persistence" },
      { name: "Terminal", href: "/terminal" },
      { name: "State & Data Flow", href: "/state" },
      { name: "Theming", href: "/theming" },
      { name: "Fonts", href: "/fonts" },
      { name: "Building Components", href: "/building-components" },
    ],
  },
  {
    // One entry per built-in component page, generated from the shared
    // components-pages inventory (previews regenerate via
    // `zig build docs-component-previews`).
    title: "Components",
    items: [
      { name: "Overview", href: "/components" },
      ...componentPages.map((page) => ({ name: page.name, href: `/components/${page.slug}` })),
    ],
  },
  {
    title: "Native Platform",
    items: [
      { name: "Windows", href: "/windows" },
      { name: "Native Surfaces", href: "/native-surfaces" },
      { name: "Menus", href: "/menus" },
      { name: "Dialogs", href: "/dialogs" },
      { name: "System Tray", href: "/tray" },
      { name: "Keyboard Shortcuts", href: "/keyboard-shortcuts" },
      { name: "Commands", href: "/commands" },
      { name: "Native Controls", href: "/native-controls" },
    ],
  },
  {
    title: "Automation & Testing",
    items: [
      { name: "Automation", href: "/automation" },
      { name: "Testing", href: "/testing" },
      { name: "Testing in CI", href: "/testing/ci" },
    ],
  },
  {
    title: "Packaging & Distribution",
    items: [
      { name: "Packaging", href: "/packaging" },
      { name: "Code Signing", href: "/packaging/signing" },
      { name: "Updates", href: "/updates" },
      { name: "Package Distribution", href: "/packages" },
    ],
  },
  {
    title: "Mobile & Embedding",
    items: [
      { name: "Embedded App", href: "/embed" },
      { name: "Media Producers", href: "/media-producers" },
    ],
  },
  {
    title: "Web Content",
    items: [
      { name: "Web Engines", href: "/web-engines" },
      { name: "Web Content", href: "/frontend" },
      { name: "Dev Server", href: "/cli/dev" },
      { name: "Multiple WebViews", href: "/webviews" },
      { name: "Bridge", href: "/bridge" },
      { name: "Builtin Commands", href: "/bridge/builtin-commands" },
    ],
  },
  {
    title: "Reference",
    items: [
      { name: "App & Runtime", href: "/runtime" },
      { name: "Capabilities", href: "/capabilities" },
      { name: "Security", href: "/security" },
      { name: "Platform Support", href: "/platform-support" },
      { name: "Debugging", href: "/debugging" },
      { name: "native doctor", href: "/debugging/doctor" },
      { name: "Zig 0.16 Notes", href: "/zig" },
      { name: "Extensions", href: "/extensions" },
    ],
  },
];

// Canonical pages that remain searchable and model-discoverable without
// taking a permanent slot in the human navigation. The built-in overview is
// a compatibility page that points readers into the component catalog.
const unprefixedAdditionalDocsSections: NavSection[] = [
  {
    title: "Additional Guides",
    items: [{ name: "Built-in Components", href: "/built-in-components" }],
  },
];

function withDocsPrefix(sections: NavSection[]): NavSection[] {
  return sections.map((section) => ({
    ...section,
    items: section.items.map((item) => ({ ...item, href: `${docsPath}${item.href}` })),
  }));
}

/** All public docs links use the canonical /docs route space. */
export const navSections: NavSection[] = withDocsPrefix(unprefixedNavSections);

/** Complete canonical inventory for search, sitemap, and model discovery. */
export const docsIndexSections: NavSection[] = [
  ...navSections,
  ...withDocsPrefix(unprefixedAdditionalDocsSections),
];

export const allDocsPages: NavItem[] = docsIndexSections.flatMap((s) => s.items);
