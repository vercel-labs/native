import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/sheet");

export default function SheetLayout({ children }: { children: React.ReactNode }) {
  return children;
}
