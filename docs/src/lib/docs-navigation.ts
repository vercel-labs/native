export type NavItem = {
  name: string;
  href: string;
};

export type NavSection = {
  title: string;
  items: NavItem[];
};

export const navSections: NavSection[] = [
  {
    title: "Getting Started",
    items: [
      { name: "Introduction", href: "/" },
      { name: "Quick Start", href: "/quick-start" },
      { name: "App Model", href: "/app-model" },
      { name: "Frontend Projects", href: "/frontend" },
    ],
  },
  {
    title: "Core Concepts",
    items: [
      { name: "Web Engines", href: "/web-engines" },
      { name: "Windows Build", href: "/windows-build" },
      { name: "Windows", href: "/windows" },
      { name: "Bridge", href: "/bridge" },
      { name: "Builtin Commands", href: "/bridge/builtin-commands" },
      { name: "Dialogs", href: "/dialogs" },
      { name: "System Tray", href: "/tray" },
      { name: "Security", href: "/security" },
    ],
  },
  {
    title: "Tooling",
    items: [
      { name: "CLI Reference", href: "/cli" },
      { name: "Dev Server", href: "/cli/dev" },
      { name: "Packaging", href: "/packaging" },
      { name: "Code Signing", href: "/packaging/signing" },
      { name: "Updates", href: "/updates" },
      { name: "app.zon Reference", href: "/app-zon" },
    ],
  },
  {
    title: "Operations",
    items: [
      { name: "Debugging", href: "/debugging" },
      { name: "zero-native doctor", href: "/debugging/doctor" },
      { name: "Automation", href: "/automation" },
      { name: "Testing", href: "/testing" },
    ],
  },
  {
    title: "Advanced",
    items: [
      { name: "Extensions", href: "/extensions" },
      { name: "Embedded App", href: "/embed" },
      { name: "Package Distribution", href: "/packages" },
    ],
  },
];

export const allDocsPages: NavItem[] = navSections.flatMap((s) => s.items);
