import { codeToHtml } from "shiki";

const vercelDarkTheme = {
  name: "vercel-dark",
  type: "dark" as const,
  colors: {
    "editor.background": "transparent",
    "editor.foreground": "#EDEDED",
  },
  settings: [
    {
      scope: ["comment", "punctuation.definition.comment"],
      settings: { foreground: "#A1A1A1" },
    },
    {
      scope: ["string", "string.quoted", "string.template", "punctuation.definition.string"],
      settings: { foreground: "#00CA50" },
    },
    {
      scope: ["constant.numeric", "constant.language.boolean", "constant.language.null"],
      settings: { foreground: "#47A8FF" },
    },
    {
      scope: ["keyword", "storage.type", "storage.modifier"],
      settings: { foreground: "#FF4D8D" },
    },
    {
      scope: ["keyword.operator", "keyword.control"],
      settings: { foreground: "#FF4D8D" },
    },
    {
      scope: ["entity.name.function", "support.function", "meta.function-call"],
      settings: { foreground: "#C472FB" },
    },
    {
      scope: ["variable", "variable.other"],
      settings: { foreground: "#EDEDED" },
    },
    {
      scope: ["variable.parameter"],
      settings: { foreground: "#FF9300" },
    },
    {
      scope: ["entity.name.tag", "support.class.component", "entity.name.type"],
      settings: { foreground: "#FF4D8D" },
    },
    {
      scope: ["punctuation", "meta.brace", "meta.bracket"],
      settings: { foreground: "#EDEDED" },
    },
    {
      scope: [
        "support.type.property-name",
        "entity.name.tag.json",
        "meta.object-literal.key",
        "punctuation.support.type.property-name",
      ],
      settings: { foreground: "#FF4D8D" },
    },
    {
      scope: ["entity.other.attribute-name"],
      settings: { foreground: "#00CA50" },
    },
    {
      scope: ["support.type.primitive", "entity.name.type.primitive"],
      settings: { foreground: "#00CA50" },
    },
  ],
};

const vercelLightTheme = {
  name: "vercel-light",
  type: "light" as const,
  colors: {
    "editor.background": "transparent",
    "editor.foreground": "#171717",
  },
  settings: [
    {
      scope: ["comment", "punctuation.definition.comment"],
      settings: { foreground: "#6B7280" },
    },
    {
      scope: ["string", "string.quoted", "string.template", "punctuation.definition.string"],
      settings: { foreground: "#067A6E" },
    },
    {
      scope: ["constant.numeric", "constant.language.boolean", "constant.language.null"],
      settings: { foreground: "#0070C0" },
    },
    {
      scope: ["keyword", "storage.type", "storage.modifier"],
      settings: { foreground: "#D6409F" },
    },
    {
      scope: ["keyword.operator", "keyword.control"],
      settings: { foreground: "#D6409F" },
    },
    {
      scope: ["entity.name.function", "support.function", "meta.function-call"],
      settings: { foreground: "#6E56CF" },
    },
    {
      scope: ["variable", "variable.other"],
      settings: { foreground: "#171717" },
    },
    {
      scope: ["variable.parameter"],
      settings: { foreground: "#B45309" },
    },
    {
      scope: ["entity.name.tag", "support.class.component", "entity.name.type"],
      settings: { foreground: "#D6409F" },
    },
    {
      scope: ["punctuation", "meta.brace", "meta.bracket"],
      settings: { foreground: "#6B7280" },
    },
    {
      scope: [
        "support.type.property-name",
        "entity.name.tag.json",
        "meta.object-literal.key",
        "punctuation.support.type.property-name",
      ],
      settings: { foreground: "#D6409F" },
    },
    {
      scope: ["entity.other.attribute-name"],
      settings: { foreground: "#067A6E" },
    },
    {
      scope: ["support.type.primitive", "entity.name.type.primitive"],
      settings: { foreground: "#067A6E" },
    },
  ],
};

/**
 * The optional filename row atop a fence: a small file glyph (the site's
 * inline-SVG icon register — 16 viewBox, 1.5 stroke, h-3.5) and the path in
 * the mono register, quiet against the header band. Standalone fences render
 * it as their own top bar; inside a two-language CodeToggle the toggle's CSS
 * lifts the row into the shared header bar, opposite the segmented control
 * (see code-toggle.tsx). The h-9 height is the contract that makes that
 * overlay line up with the toggle bar — change one, change both.
 */
function FilenameRow({ filename }: { filename: string }) {
  return (
    <div
      data-code-filename=""
      className="flex h-9 items-center gap-2 border-b border-neutral-200 bg-neutral-100 px-4 text-xs text-neutral-500 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-400"
    >
      <svg viewBox="0 0 16 16" className="h-3.5 w-3.5 shrink-0" fill="none" aria-hidden="true">
        <path
          d="M9.5 1.5h-5a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V4.5l-3-3Z"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinejoin="round"
        />
        <path d="M9.5 1.5v3h3" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
      </svg>
      <span className="truncate">{filename}</span>
    </div>
  );
}

function DiffBlock({ children, filename }: { children: string; filename?: string }) {
  const lines = children.trim().split("\n");
  return (
    <div
      data-language="diff"
      className="my-4 rounded-lg border border-neutral-200 bg-neutral-50 text-[13px] font-mono overflow-hidden dark:border-neutral-800 dark:bg-neutral-900"
    >
      {filename ? <FilenameRow filename={filename} /> : null}
      <pre className="m-0 overflow-x-auto">
        <code>
          {lines.map((line, i) => {
            let cls = "block px-4";
            if (i === 0) cls += " pt-4";
            if (i === lines.length - 1) cls += " pb-4";
            if (line.startsWith("+")) cls += " diff-add";
            else if (line.startsWith("-")) cls += " diff-remove";
            return (
              <span key={i} className={cls}>
                {line}
                {"\n"}
              </span>
            );
          })}
        </code>
      </pre>
    </div>
  );
}

interface CodeProps {
  children: string;
  lang?: string;
  /**
   * Optional filename shown in a header row above the code. Authored in the
   * fence info string as `lang:path` (e.g. ```ts:src/core.ts) — the one
   * fence-meta channel that survives the MDX pipeline as a className (see
   * mdx-components.tsx). No filename, no header row.
   */
  filename?: string;
}

export async function Code({ children, lang = "typescript", filename }: CodeProps) {
  if (lang === "diff") {
    return <DiffBlock filename={filename}>{children}</DiffBlock>;
  }

  const html = await codeToHtml(children.trim(), {
    lang,
    themes: {
      light: vercelLightTheme,
      dark: vercelDarkTheme,
    },
    defaultColor: false,
  });

  return (
    // data-language stamps the fence's language on the rendered wrapper.
    // CodeToggle's CSS keys on it to switch samples: its children cross the
    // RSC boundary as one opaque node, so the DOM attribute is the only
    // channel that survives to tell the TypeScript fence from the Zig one.
    <div
      data-language={lang}
      className="my-4 rounded-lg border border-neutral-200 bg-neutral-50 text-[13px] font-mono overflow-hidden dark:border-neutral-800 dark:bg-neutral-900"
    >
      {filename ? <FilenameRow filename={filename} /> : null}
      <div
        className="overflow-x-auto [&_pre]:bg-transparent! [&_pre]:m-0! [&_pre]:p-4! [&_code]:bg-transparent! [&_.shiki]:bg-transparent!"
        dangerouslySetInnerHTML={{ __html: html }}
      />
    </div>
  );
}
