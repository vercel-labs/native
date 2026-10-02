import { geistShikiTheme } from "@vercel/geistdocs/shiki-theme";

/** Shell sessions should not inherit the generic text scope's parameter color. */
export const docsShikiTheme = {
  ...geistShikiTheme,
  name: "geist-shell",
  tokenColors: [
    ...geistShikiTheme.tokenColors,
    { scope: "text.shell-session", settings: { foreground: "var(--shiki-color-text, inherit)" } },
    {
      scope: ["punctuation.separator.prompt.shell-session", "meta.output.shell-session"],
      settings: { foreground: "var(--shiki-token-comment)" },
    },
  ],
};
