import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/toggle");

export default function ToggleLayout({ children }: { children: React.ReactNode }) {
  return children;
}
