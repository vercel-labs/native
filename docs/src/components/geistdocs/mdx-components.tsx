import { createMdxComponents } from "@vercel/geistdocs/mdx";
import type { ComponentProps, ComponentType } from "react";
import type { MDXComponents } from "mdx/types";

const defaults = createMdxComponents();
const Pre = defaults.pre as ComponentType<ComponentProps<"pre">>;

export const getMDXComponents = (components?: MDXComponents) => createMdxComponents({
  // Native's persisted TypeScript/Zig tabs use this wrapper; Geistdocs owns the code block.
  pre: (props) => <div data-language={(props as { "data-language"?: string })["data-language"]}><Pre {...props} /></div>,
  ...components,
});
