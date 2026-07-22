import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("terminal");

export default function TerminalLayout({ children }: { children: React.ReactNode }) {
  return children;
}
