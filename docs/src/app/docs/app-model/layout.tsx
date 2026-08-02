import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("app-model");

export default function Layout({ children }: { children: React.ReactNode }) {
  return children;
}
