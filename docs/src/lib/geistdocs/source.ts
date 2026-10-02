import { createSource } from "@vercel/geistdocs/source";
import { docs } from "@/.source/server";
import { remarkNativeMarkdown } from "@/lib/remark-native";
import { config } from "./config";

export const geistdocsSource = createSource({ docs, config, baseUrl: "/docs", markdown: { remarkPlugins: [remarkNativeMarkdown] } });
export const source = geistdocsSource.source;
