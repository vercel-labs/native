import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/dropdown-menu");

export default function DropdownMenuLayout({ children }: { children: React.ReactNode }) {
  return children;
}
