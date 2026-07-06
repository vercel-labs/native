import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/resizable");

export default function ResizableLayout({ children }: { children: React.ReactNode }) {
  return children;
}
