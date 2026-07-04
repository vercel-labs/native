import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/dialog");

export default function DialogLayout({ children }: { children: React.ReactNode }) {
  return children;
}
