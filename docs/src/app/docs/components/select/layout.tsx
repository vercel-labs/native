import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/select");

export default function SelectLayout({ children }: { children: React.ReactNode }) {
  return children;
}
