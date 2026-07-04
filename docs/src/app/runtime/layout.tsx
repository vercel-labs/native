import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("runtime");

export default function RuntimeLayout({ children }: { children: React.ReactNode }) {
  return children;
}
