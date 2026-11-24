// A release build's page tables are data the app carries, not code compiled into the executable:
// the build writes them into the bundle's resources, and this reads that file at startup and
// mounts the page. A markup or style edit rewrites the file, so nothing has to be compiled again.

import { readFileSync } from "node:fs";
import { hostBundleDir } from "../host.ts";
import { PAGE_TABLES_DIR, PAGE_TABLES_FILE } from "../../shared/page-tables.ts";
import { mount, type AppTables } from "./mount.ts";

/** Mounts the page whose tables the bundle carries, from the file the build wrote. */
export function mountPage(): void {
  // The host is the one that knows where the bundle is, however the app was started or moved.
  let dir = "";
  hostBundleDir((d) => { dir = d; });
  const file = dir + "/" + PAGE_TABLES_DIR + "/" + PAGE_TABLES_FILE;
  let text = "";
  try {
    text = readFileSync(file, "utf8");
  } catch {
    console.error(`native: can't read ${file}, which holds the page's compiled tables`);
    process.exit(1);
  }
  mount(JSON.parse(text) as AppTables);
}
