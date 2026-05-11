export const PAGE_TITLES: Record<string, string> = {
  "": "Build Desktop Apps\nwith Zig + WebView",
  "quick-start": "Quick Start",
  "app-model": "App Model",
  frontend: "Frontend Projects",
  windows: "Windows",
  bridge: "Bridge",
  "bridge/builtin-commands": "Builtin Commands",
  dialogs: "Dialogs",
  tray: "System Tray",
  security: "Security",
  cli: "CLI Reference",
  "cli/dev": "Dev Server",
  packaging: "Packaging",
  "packaging/signing": "Code Signing",
  updates: "Updates",
  "app-zon": "app.zon Reference",
  debugging: "Debugging",
  "debugging/doctor": "zero-native doctor",
  automation: "Automation",
  testing: "Testing",
  extensions: "Extensions",
  embed: "Embedded App",
  "web-engines": "Web Engines",
  "windows-build": "Windows Build",
  packages: "Package Distribution",
};

export function getPageTitle(slug: string): string | null {
  return slug in PAGE_TITLES ? PAGE_TITLES[slug]! : null;
}
