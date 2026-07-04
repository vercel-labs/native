"use client";

import { useState } from "react";

/** The hero install block: prompt-styled lines with a copy button. */
export function CopyCommand({ lines }: { lines: string[] }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(lines.join("\n"));
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard unavailable (permissions, insecure context): do nothing.
    }
  }

  return (
    <div className="group relative rounded-xl border border-neutral-200 bg-white/70 text-left backdrop-blur-sm dark:border-neutral-800 dark:bg-neutral-950/70">
      <pre className="overflow-x-auto px-4 py-3.5 font-mono text-[13px] leading-relaxed text-neutral-800 dark:text-neutral-200">
        {lines.map((line) => (
          <span key={line} className="block">
            <span className="select-none text-neutral-400 dark:text-neutral-600">$ </span>
            {line}
          </span>
        ))}
      </pre>
      <button
        onClick={copy}
        aria-label={copied ? "Copied" : "Copy commands"}
        className="absolute right-2.5 top-2.5 rounded-md border border-neutral-200 bg-white p-1.5 text-neutral-500 opacity-0 transition-opacity hover:text-neutral-900 focus-visible:opacity-100 group-hover:opacity-100 dark:border-neutral-800 dark:bg-neutral-900 dark:text-neutral-400 dark:hover:text-neutral-100"
      >
        {copied ? (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
            <path d="M2.5 8.5l3.5 3.5 7.5-8" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        ) : (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.5" aria-hidden="true">
            <rect x="5.5" y="5.5" width="8" height="8" rx="1.5" />
            <path d="M10.5 5.5v-2a1.5 1.5 0 00-1.5-1.5H4a1.5 1.5 0 00-1.5 1.5V9A1.5 1.5 0 004 10.5h2" />
          </svg>
        )}
      </button>
    </div>
  );
}
