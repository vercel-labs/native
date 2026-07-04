import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/accordion");

export default function AccordionLayout({ children }: { children: React.ReactNode }) {
  return children;
}
