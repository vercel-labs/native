import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("zig");

export default function ZigLayout({ children }: { children: React.ReactNode }) {
  return children;
}
