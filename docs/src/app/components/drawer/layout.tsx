import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/drawer");

export default function DrawerLayout({ children }: { children: React.ReactNode }) {
  return children;
}
