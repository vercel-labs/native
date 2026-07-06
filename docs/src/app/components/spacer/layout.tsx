import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/spacer");

export default function SpacerLayout({ children }: { children: React.ReactNode }) {
  return children;
}
