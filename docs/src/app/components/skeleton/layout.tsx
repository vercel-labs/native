import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/skeleton");

export default function SkeletonLayout({ children }: { children: React.ReactNode }) {
  return children;
}
