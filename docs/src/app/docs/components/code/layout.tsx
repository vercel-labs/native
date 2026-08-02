import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/code");

export default function CodeLayout({ children }: { children: React.ReactNode }) {
  return children;
}
