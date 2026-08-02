import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/card");

export default function CardLayout({ children }: { children: React.ReactNode }) {
  return children;
}
