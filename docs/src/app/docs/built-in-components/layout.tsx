import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("built-in-components");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
