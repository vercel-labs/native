// Tidies what scriptc prints for an app build.

import { join, resolve, sep } from "node:path";

/** scriptc's warnings about the SDK's own runtime, shared and host code are ours to fix, not
 *  the app author's, so a build leaves them out (NATIVE_SDK_WARNINGS=1 shows them). A warning
 *  block runs from its `file:line:col - warning SC…` header to the next header or summary line;
 *  the SC6101 list drops its SDK entries, and the summary lines go when nothing is left. */
export function withoutSdkWarnings(text: string, sdkRoot: string, bases: string[], mapPath?: (abs: string) => string): string {
  if (process.env.NATIVE_SDK_WARNINGS === "1") return text;
  const dirs = [join(sdkRoot, "runtime"), join(sdkRoot, "shared"), join(sdkRoot, "host")];
  // Headers carry absolute paths; the SC6101 list is relative to the entry's directory.
  // resolve() answers with the platform's separator, so a Windows path is matched on its own.
  const inSdk = (file: string): boolean =>
    bases.some((base) => { const abs = resolve(base, file); return dirs.some((d) => abs.startsWith(d + sep)); });
  const out: string[] = [];
  let dropping = false;
  let kept = 0;
  let dropped = 0;
  let slowKept = 0;
  let slowDropped = 0;
  let inSlowList = false;
  for (const line of text.split("\n")) {
    const head = /^(\S+?):\d+:\d+ - warning SC\d+/.exec(line);
    if (head) {
      inSlowList = false;
      dropping = inSdk(head[1]);
      if (dropping) dropped++; else kept++;
      if (!dropping) out.push(line);
      continue;
    }
    if (/^warning SC6101:/.test(line)) { dropping = false; inSlowList = true; out.push(line); continue; }
    if (inSlowList) {
      const entry = /^ {2}\S.*\((\S+?):\d+\)/.exec(line);
      if (entry && !line.startsWith("  hint:")) {
        if (inSdk(entry[1])) { slowDropped++; continue; }
        slowKept++;
        if (mapPath !== undefined) {
          out.push(line.replace(`(${entry[1]}:`, `(${mapPath(resolve(bases[bases.length - 1], entry[1]))}:`));
          continue;
        }
      }
      out.push(line);
      if (line.trim() === "") inSlowList = false;
      continue;
    }
    if (/^\S/.test(line)) dropping = false;
    if (!dropping) out.push(line);
  }
  let result = out.join("\n");
  if (dropped > 0) {
    result = kept === 0
      ? result.replace(/^\d+ warnings?: the program compiled, but these sites can behave differently from Node\.\n\n?/m, "")
      : result.replace(/^\d+ (warnings?): the program compiled/m, `${kept} ${kept === 1 ? "warning" : "warnings"}: the program compiled`);
    // When every warning was the SDK's, the count of warnings the compiler chose not to print is
    // all that is left; it names the ones just dropped, so it goes too.
    if (kept === 0) result = result.replace(/^\d+ more warnings? not shown \([^)]*\);[^\n]*\n?/m, "");
  }
  if (slowDropped > 0 && slowKept > 0) {
    result = result.replace(/^warning SC6101: \d+ functions? that likely runs? often uses? /m,
      slowKept === 1 ? "warning SC6101: 1 function that likely runs often uses " : `warning SC6101: ${slowKept} functions that likely run often use `);
  }
  if (slowDropped > 0 && slowKept === 0) {
    result = result.replace(/^warning SC6101:[^\n]*\n(?: {2}[^\n]*\n)*\n?/m, "")
      .replace(/^The program compiled\. Adding types to these functions[^\n]*\n?/m, "");
  }
  return result.replace(/^\n+/, "");
}
