import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/calendar");

export default function CalendarLayout({ children }: { children: React.ReactNode }) {
  return children;
}
