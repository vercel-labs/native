import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("sqlite");

export default function SqliteLayout({ children }: { children: React.ReactNode }) {
  return children;
}
