import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/tree");

export default function TreeLayout({ children }: { children: React.ReactNode }) {
  return children;
}
