import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/list");

export default function ListLayout({ children }: { children: React.ReactNode }) {
  return children;
}
