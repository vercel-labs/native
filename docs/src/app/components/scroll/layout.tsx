import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/scroll");

export default function ScrollLayout({ children }: { children: React.ReactNode }) {
  return children;
}
