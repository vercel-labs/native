import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/badge");

export default function BadgeLayout({ children }: { children: React.ReactNode }) {
  return children;
}
