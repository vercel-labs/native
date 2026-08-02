import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/markdown");

export default function MarkdownLayout({ children }: { children: React.ReactNode }) {
  return children;
}
