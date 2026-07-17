import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("dynamic-images");

export default function DynamicImagesLayout({ children }: { children: React.ReactNode }) {
  return children;
}
