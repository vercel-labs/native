import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/split");

export default function SplitLayout({ children }: { children: React.ReactNode }) {
  return children;
}
