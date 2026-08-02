import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/panel");

export default function PanelLayout({ children }: { children: React.ReactNode }) {
  return children;
}
