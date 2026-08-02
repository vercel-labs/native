import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("components/stepper");

export default function StepperLayout({ children }: { children: React.ReactNode }) {
  return children;
}
