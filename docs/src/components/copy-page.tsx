"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname } from "next/navigation";

/**
 * The "Copy Page" button in every docs page's heading row: fetches the
 * page's clean markdown from /<path>.md and puts it on the clipboard.
 * Rendered by the MDX h1 (see mdx-components.tsx), so every content
 * page gets it without opting in.
 *
 * Feedback is icon-only — the label never changes, the copy glyph swaps
 * to a check (or a cross on failure) for two seconds, same mechanism as
 * the hero install command's copy button. A visually hidden status
 * region announces the outcome for screen readers.
 */
export function CopyPage() {
  const pathname = usePathname();
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (timer.current) clearTimeout(timer.current);
    };
  }, []);

  const settle = (next: "copied" | "failed") => {
    setState(next);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setState("idle"), 2000);
  };

  const handleClick = async () => {
    const markdown = fetch(`${pathname}.md`).then((response) => {
      if (!response.ok) throw new Error(`copy-page: ${response.status}`);
      return response.text();
    });
    try {
      // ClipboardItem with a promise keeps the user-gesture window open
      // across the fetch (Safari revokes it after an await).
      if (typeof ClipboardItem !== "undefined" && navigator.clipboard?.write) {
        await navigator.clipboard.write([
          new ClipboardItem({
            "text/plain": markdown.then((text) => new Blob([text], { type: "text/plain" })),
          }),
        ]);
      } else {
        await navigator.clipboard.writeText(await markdown);
      }
      settle("copied");
    } catch {
      settle("failed");
    }
  };

  return (
    <>
      <button
        type="button"
        onClick={handleClick}
        className="flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-gray-alpha-400 px-3 label-14 text-gray-900 transition-colors hover:border-gray-alpha-500 hover:text-gray-1000"
      >
        {state === "copied" ? (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" aria-hidden="true">
            <path
              d="M13.5 4.5 6 12 2.5 8.5"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        ) : state === "failed" ? (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" aria-hidden="true">
            <path
              d="M4 4l8 8M12 4l-8 8"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
            />
          </svg>
        ) : (
          <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" fill="none" aria-hidden="true">
            <rect
              x="5.5"
              y="5.5"
              width="8"
              height="8"
              rx="1.5"
              stroke="currentColor"
              strokeWidth="1.5"
            />
            <path
              d="M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h1"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
            />
          </svg>
        )}
        Copy Page
      </button>
      <span role="status" className="sr-only">
        {state === "copied" ? "Page copied as markdown" : state === "failed" ? "Copy failed" : ""}
      </span>
    </>
  );
}
