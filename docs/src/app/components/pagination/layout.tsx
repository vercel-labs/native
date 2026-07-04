import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/pagination");

export default function PaginationLayout({ children }: { children: React.ReactNode }) {
  return children;
}
