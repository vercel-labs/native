import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("native-controls");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
