import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("theming");

export default function ThemingLayout({ children }: { children: React.ReactNode }) {
  return children;
}
