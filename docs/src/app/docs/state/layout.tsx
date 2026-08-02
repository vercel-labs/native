import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("state");

export default function StateLayout({ children }: { children: React.ReactNode }) {
  return children;
}
