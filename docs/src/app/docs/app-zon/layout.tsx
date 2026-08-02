import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("app-zon");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
