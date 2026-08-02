import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/timeline");

export default function TimelineLayout({ children }: { children: React.ReactNode }) {
  return children;
}
