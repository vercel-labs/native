import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/chart");

export default function ChartLayout({ children }: { children: React.ReactNode }) {
  return children;
}
