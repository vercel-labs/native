import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/bubble");

export default function BubbleLayout({ children }: { children: React.ReactNode }) {
  return children;
}
