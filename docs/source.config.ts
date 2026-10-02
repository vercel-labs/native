import {
  defineGeistdocsSourceConfig,
  geistdocsFrontmatterSchema,
  geistdocsMetaSchema,
} from "@vercel/geistdocs/source-config";
import { defineDocs, type DefaultMDXOptions } from "fumadocs-mdx/config";
import { headingId, remarkDocsConventions } from "./src/lib/remark-docs";
import { remarkNativeContent } from "./src/lib/remark-native";
import { docsShikiTheme } from "./src/lib/shiki-theme";

export const docs = defineDocs({
  dir: "content/docs",
  docs: {
    schema: geistdocsFrontmatterSchema,
    postprocess: { includeProcessedMarkdown: true },
  },
  meta: { schema: geistdocsMetaSchema },
});

const config = defineGeistdocsSourceConfig({
  mdxOptions: {
    remarkHeadingOptions: { slug: (_root, _heading, text) => headingId(text) },
    remarkPlugins: [remarkDocsConventions],
    remarkStructureOptions: {
      types: ["heading", "paragraph", "blockquote", "tableCell", "mdxJsxFlowElement", "mdxJsxTextElement", "text", "inlineCode", "code"],
    },
  },
});
const mdxOptions = config.mdxOptions as DefaultMDXOptions;

const codeOptions: Exclude<DefaultMDXOptions["rehypeCodeOptions"], false | undefined> = mdxOptions.rehypeCodeOptions || { themes: { light: docsShikiTheme, dark: docsShikiTheme } };

const nativeMdxOptions: DefaultMDXOptions = {
    ...mdxOptions,
    // Generated eject sections must enter the heading/search pipeline as real content.
    remarkPlugins: (defaults) => [remarkNativeContent, ...(typeof mdxOptions.remarkPlugins === "function" ? mdxOptions.remarkPlugins(defaults) : defaults)],
    rehypeCodeOptions: {
      ...codeOptions,
      themes: { light: docsShikiTheme, dark: docsShikiTheme },
      transformers: [...(codeOptions.transformers ?? []), {
        name: "native-code-language",
        pre(node) { node.properties["data-language"] = this.options.lang; },
      }],
    },
};

export default { ...config, mdxOptions: nativeMdxOptions };
