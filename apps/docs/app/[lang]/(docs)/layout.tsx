import { DocsLayout } from "@/components/geistdocs/docs-layout";
import { getRootLang } from "@/lib/geistdocs/root-params";
import { source } from "@/lib/geistdocs/source";

const Layout = async ({ children }: LayoutProps<"/[lang]">) => {
  const lang = await getRootLang();
  const tree = source.pageTree[lang];

  return (
    <div className="bg-background-200">
      {tree ? <DocsLayout tree={tree}>{children}</DocsLayout> : children}
    </div>
  );
};

export default Layout;
