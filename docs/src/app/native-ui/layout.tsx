import { pageMetadata } from "@/lib/page-metadata";

export const metadata = pageMetadata("native-ui");

export default function NativeUiLayout({ children }: { children: React.ReactNode }) {
  return children;
}
