import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("files");

export default function FilesLayout({ children }: { children: React.ReactNode }) {
  return children;
}
