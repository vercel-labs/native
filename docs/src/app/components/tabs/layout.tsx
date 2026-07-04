import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/tabs");

export default function TabsLayout({ children }: { children: React.ReactNode }) {
  return children;
}
