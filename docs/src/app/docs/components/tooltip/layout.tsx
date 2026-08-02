import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/tooltip");

export default function TooltipLayout({ children }: { children: React.ReactNode }) {
  return children;
}
