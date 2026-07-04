import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/alert");

export default function AlertLayout({ children }: { children: React.ReactNode }) {
  return children;
}
