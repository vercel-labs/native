import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/slider");

export default function SliderLayout({ children }: { children: React.ReactNode }) {
  return children;
}
