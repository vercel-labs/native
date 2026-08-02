import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/avatar");

export default function AvatarLayout({ children }: { children: React.ReactNode }) {
  return children;
}
