export type Severity = "error" | "warning" | "note";

export interface Diagnostic {
  severity: Severity;
  file: string;
  line: number;
  col: number;
  message: string;
  hint?: string;
}

export class Diagnostics {
  list: Diagnostic[] = [];

  add(severity: Severity, file: string, line: number, col: number, message: string, hint?: string): void {
    this.list.push({ severity, file, line, col, message, hint });
  }
  error(file: string, line: number, col: number, message: string, hint?: string): void {
    this.add("error", file, line, col, message, hint);
  }
  warn(file: string, line: number, col: number, message: string, hint?: string): void {
    this.add("warning", file, line, col, message, hint);
  }
  note(file: string, line: number, col: number, message: string, hint?: string): void {
    this.add("note", file, line, col, message, hint);
  }

  get errorCount(): number {
    return this.list.filter((d) => d.severity === "error").length;
  }

  /**
   * What a person should read. A problem found twice is shown once; a hint that would repeat on
   * every warning it applies to is printed with the first of them; and the vendor-prefixed
   * selectors, properties and `@supports` conditions a framework's stylesheet ships — which no
   * app author can act on — are one line per file, naming what they were.
   */
  collapsed(): Diagnostic[] {
    const out: Diagnostic[] = [];
    const seen = new Set<string>();
    const hints = new Set<string>();
    const groups = new Map<string, { diagnostic: Diagnostic; kind: "selector" | "property" | "supports"; names: string[] }>();
    for (const d of this.list) {
      const key = `${d.severity}\u0000${d.file}\u0000${d.line}\u0000${d.col}\u0000${d.message}\u0000${d.hint ?? ""}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const selector = /^selector '(.+)' is not supported yet; skipped$/.exec(d.message);
      const property = /^'(.+)' is not supported yet; ignored$/.exec(d.message);
      const supports = /^@supports '(.+)' doesn't hold here; its declarations are ignored$/.exec(d.message);
      const vendor = selector !== null ? /::?-[a-z]+-/.test(selector[1])
        : property !== null ? /^-[a-z]+-/.test(property[1])
        : supports !== null ? /-[a-z]+-/.test(supports[1])
        : false;
      if (vendor) {
        const kind = selector !== null ? "selector" : property !== null ? "property" : "supports";
        const groupKey = `${d.file}\u0000${d.severity}\u0000${kind}`;
        let group = groups.get(groupKey);
        if (group === undefined) {
          const diagnostic: Diagnostic = { ...d, hint: undefined };
          group = { diagnostic, kind, names: [] };
          groups.set(groupKey, group);
          out.push(diagnostic);
        }
        const name = (selector ?? property ?? supports)![1];
        if (group.names.indexOf(name) < 0) group.names.push(name);
        continue;
      }
      if (d.hint !== undefined && hints.has(d.hint)) out.push({ ...d, hint: undefined });
      else {
        if (d.hint !== undefined) hints.add(d.hint);
        out.push(d);
      }
    }
    for (const { diagnostic, kind, names } of groups.values()) {
      const one = names.length === 1;
      const listed = names.slice(0, 6).join(", ") + (names.length > 6 ? ` and ${names.length - 6} more` : "");
      diagnostic.message = kind === "selector"
        ? `${names.length} vendor-prefixed selector${one ? "" : "s"} ${one ? "is" : "are"} not supported yet; skipped: ${listed}`
        : kind === "property"
          ? `${names.length} vendor-prefixed propert${one ? "y is" : "ies are"} not supported yet; ignored: ${listed}`
          : `${names.length} vendor-prefixed @supports condition${one ? "" : "s"} ${one ? "doesn't" : "don't"} hold here; ${one ? "its declarations are" : "their declarations are"} ignored: ${listed}`;
    }
    return out;
  }

  format(color: boolean): string {
    const c = (code: string, s: string) => (color ? `\x1b[${code}m${s}\x1b[0m` : s);
    const tone: Record<Severity, string> = { error: "31", warning: "33", note: "36" };
    return this.collapsed()
      .map((d) => {
        let s = `${c("1", `${d.file}:${d.line}:${d.col}`)}: ${c(tone[d.severity], d.severity)}: ${d.message}`;
        if (d.hint) s += `\n  ${c("2", "hint:")} ${d.hint}`;
        return s;
      })
      .join("\n");
  }
}

/** Returns a function mapping a string offset to a 1-based [line, column]. */
export function locator(src: string): (offset: number) => [number, number] {
  const starts = [0];
  for (let i = 0; i < src.length; i++) if (src[i] === "\n") starts.push(i + 1);
  return (offset: number) => {
    let lo = 0;
    let hi = starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) lo = mid;
      else hi = mid - 1;
    }
    return [lo + 1, offset - starts[lo] + 1];
  };
}
