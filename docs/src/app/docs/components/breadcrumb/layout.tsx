import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/breadcrumb");

export default function BreadcrumbLayout({ children }: { children: React.ReactNode }) {
  return children;
}
