import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("windows");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
