import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/table");

export default function TableLayout({ children }: { children: React.ReactNode }) {
  return children;
}
