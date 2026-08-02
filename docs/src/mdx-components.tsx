import type { MDXComponents } from "mdx/types";
import { Code } from "@/components/code";
import { CopyPage } from "@/components/copy-page";
import { HeadingLink } from "@/components/heading-link";

export function useMDXComponents(components: MDXComponents): MDXComponents {
  return {
    // The page h1 is the heading row: title on the left, the layout-level
    // "Copy Page" button (copies the page as markdown) on the right.
    h1: (props) => (
      <div className="mb-6 flex items-start justify-between gap-4">
        <HeadingLink
          as="h1"
          className="text-2xl font-semibold tracking-tight text-neutral-900 dark:text-neutral-100"
          {...props}
        />
        <CopyPage />
      </div>
    ),
    h2: (props) => (
      <HeadingLink
        as="h2"
        className="mb-4 mt-12 text-lg font-semibold text-neutral-900 first:mt-0 dark:text-neutral-100"
        {...props}
      />
    ),
    h3: (props) => (
      <HeadingLink
        as="h3"
        className="mb-3 mt-8 text-base font-semibold text-neutral-900 dark:text-neutral-100"
        {...props}
      />
    ),
    p: (props) => (
      <p
        className="mb-4 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400"
        {...props}
      />
    ),
    ul: (props) => <ul className="mb-4 list-disc space-y-1 pl-5 text-sm" {...props} />,
    ol: (props) => <ol className="mb-4 list-decimal space-y-1 pl-5 text-sm" {...props} />,
    li: (props) => <li className="text-neutral-600 dark:text-neutral-400" {...props} />,
    a: (props) => (
      <a
        className="text-neutral-900 underline decoration-neutral-300 underline-offset-2 hover:decoration-neutral-900 dark:text-neutral-100 dark:decoration-neutral-700 dark:hover:decoration-neutral-100"
        {...props}
      />
    ),
    code: ({ children, className }: { children?: React.ReactNode; className?: string }) => {
      if (className) {
        return <code className={className}>{children}</code>;
      }
      return (
        <code className="rounded bg-neutral-100 px-1.5 py-0.5 text-[13px] dark:bg-neutral-800">
          {children}
        </code>
      );
    },
    pre: async ({ children }: { children?: React.ReactNode }) => {
      const codeElement = children as React.ReactElement<{
        className?: string;
        children?: string;
      }>;
      const className = codeElement?.props?.className || "";
      // The fence info string, e.g. ```ts:src/core.ts — MDX drops fence
      // meta (```ts title="…" never reaches this component), so the
      // colon-in-info-string convention is the one filename channel that
      // survives the pipeline: micromark treats the whole word as the
      // language, MDX forwards it as language-ts:src/core.ts, and this
      // split hands shiki the real language and Code the filename.
      const info = className.replace("language-", "") || "typescript";
      const colon = info.indexOf(":");
      const lang = (colon === -1 ? info : info.slice(0, colon)) || "typescript";
      const filename = colon === -1 ? undefined : info.slice(colon + 1) || undefined;
      const code = codeElement?.props?.children || "";

      return (
        <Code lang={lang} filename={filename}>
          {typeof code === "string" ? code : String(code)}
        </Code>
      );
    },
    blockquote: (props) => (
      <blockquote
        className="mb-4 border-l-2 border-neutral-200 pl-4 text-sm text-neutral-500 dark:border-neutral-800 dark:text-neutral-500"
        {...props}
      />
    ),
    // Markdown pipe tables render as bare table elements inside a scroll
    // wrapper: the `article table` rules in globals.css style them, the
    // same register the literal HTML tables on the component pages use.
    table: (props) => (
      <div className="overflow-x-auto">
        <table {...props} />
      </div>
    ),
    hr: () => <hr className="my-8 border-neutral-200 dark:border-neutral-800" />,
    strong: (props) => (
      <strong className="font-medium text-neutral-900 dark:text-neutral-100" {...props} />
    ),
    ...components,
  };
}
