import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/video");

export default function VideoLayout({ children }: { children: React.ReactNode }) {
  return children;
}
