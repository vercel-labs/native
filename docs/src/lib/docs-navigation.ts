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
      { name: "Home", href: "/" },
      { name: "Quick Start", href: "/quick-start" },
      { name: "App Model", href: "/app-model" },
      { name: "Native UI", href: "/native-ui" },
      { name: "Frontend Projects", href: "/frontend" },
      { name: "Native Surfaces", href: "/native-surfaces" },
    ],
  },
  {
    title: "Core Concepts",
    items: [
      { name: "Web Engines", href: "/web-engines" },
      { name: "Windows", href: "/windows" },
      { name: "Multiple WebViews", href: "/webviews" },
      { name: "Keyboard Shortcuts", href: "/keyboard-shortcuts" },
      { name: "Commands", href: "/commands" },
      { name: "Bridge", href: "/bridge" },
      { name: "Builtin Commands", href: "/bridge/builtin-commands" },
      { name: "Dialogs", href: "/dialogs" },
      { name: "Menus", href: "/menus" },
      { name: "Native Controls", href: "/native-controls" },
      { name: "Built-in Components", href: "/built-in-components" },
      { name: "Capabilities", href: "/capabilities" },
      { name: "Platform Support", href: "/platform-support" },
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
      { name: "Testing in CI", href: "/testing/ci" },
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
