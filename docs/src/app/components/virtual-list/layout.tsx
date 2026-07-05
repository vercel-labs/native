import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/virtual-list");

export default function VirtualListLayout({ children }: { children: React.ReactNode }) {
  return children;
}
