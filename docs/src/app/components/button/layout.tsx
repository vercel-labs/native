import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/button");

export default function ButtonLayout({ children }: { children: React.ReactNode }) {
  return children;
}
