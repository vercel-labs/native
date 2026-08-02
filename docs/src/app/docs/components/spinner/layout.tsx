import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/spinner");

export default function SpinnerLayout({ children }: { children: React.ReactNode }) {
  return children;
}
