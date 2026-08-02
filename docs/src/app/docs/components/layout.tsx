import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components");

export default function ComponentsLayout({ children }: { children: React.ReactNode }) {
  return children;
}
