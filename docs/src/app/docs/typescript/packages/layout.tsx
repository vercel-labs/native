import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("typescript/packages");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
