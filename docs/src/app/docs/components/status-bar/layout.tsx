import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/status-bar");

export default function StatusBarLayout({ children }: { children: React.ReactNode }) {
  return children;
}
