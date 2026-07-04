import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/progress");

export default function ProgressLayout({ children }: { children: React.ReactNode }) {
  return children;
}
