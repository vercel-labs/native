import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("cli");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
