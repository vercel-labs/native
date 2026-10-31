"use client";

import { useId, useSyncExternalStore } from "react";
import { SegmentedControl } from "@/components/ui/segmented-control";

// The TS | Zig code toggle for docs pages that show the same sample in both
// authoring languages. Usage in MDX: two fenced code blocks as children, the
// TypeScript one (```ts) first, the Zig one (```zig) second — the fences
// render through the site's shiki pipeline as usual and this component only
// frames and switches them. TypeScript is the default; the reader's pick is
// one site-wide choice (localStorage), so every toggle on every page follows
// it. With a single sample there is nothing to switch: the tab header hides
// and the block renders plain.
//
// The header bar is the component previews' titlebar register: the shared
// SegmentedControl pill sits on the right, and a fence's filename row (see
// code.tsx) overlays the left of the same bar — one bar, filename opposite
// the segments, exactly like a preview's name opposite its Default | Geist
// toggle.
//
// The children are server-rendered and cross the RSC boundary as one opaque
// node, so this client component never counts, wraps, or introspects them —
// doing so is unsound (they are not an inspectable element array here, which
// is exactly the bug that used to make every toggle fall back to stacked
// fences). Instead the fences carry data-language (stamped by the Code
// component), the container carries data-active, and the CSS below does the
// switching. The server snapshot is always TypeScript, so the SSR HTML
// already hides the Zig fence: no-JS readers and the first paint agree.

const STORAGE_KEY = "native-docs-code-lang";
const LANGS = [
  { key: "ts", label: "TypeScript" },
  { key: "zig", label: "Zig" },
] as const;

type Lang = 0 | 1;

// All switching is attribute + CSS. Every rule is gated with :has() so a
// toggle holding a single sample degrades gracefully: the lone fence is
// never hidden, the tab header disappears, and the container stops framing
// (the fence's own chrome shows instead). Fences outside a toggle are
// untouched — every selector is scoped under [data-code-toggle].
//
// The last rule folds the active fence's filename row into the header bar:
// inside a two-language toggle the row leaves the flow and overlays the
// bar's left side (the right inset clears the segmented control), losing
// its own border and background. It is display-only there — pointer-events
// pass through to the bar. Each language's fence keeps its own filename
// (core.ts vs main.zig), and because the row lives inside the fence it
// switches with it for free.
const css = `
[data-code-toggle][data-active="ts"]:has([data-language="ts"]) [data-language="zig"],
[data-code-toggle][data-active="zig"]:has([data-language="zig"]) [data-language="ts"] {
  display: none;
}
[data-code-toggle]:not(:has([data-language="ts"])) [data-code-toggle-tabs],
[data-code-toggle]:not(:has([data-language="zig"])) [data-code-toggle-tabs] {
  display: none;
}
[data-code-toggle]:has([data-language="ts"]):has([data-language="zig"]) [data-language] {
  margin-block: 0;
  border: 0;
  border-radius: 0;
}
[data-code-toggle]:not(:has([data-language="ts"]):has([data-language="zig"])) {
  margin-block: 0;
  border: 0;
  border-radius: 0;
  overflow: visible;
}
[data-code-toggle]:has([data-language="ts"]):has([data-language="zig"]) [data-code-filename] {
  position: absolute;
  top: 0;
  left: 0;
  right: 9.5rem;
  border: 0;
  background: transparent;
  pointer-events: none;
}
`;

// One module-level store keeps every toggle on the page in sync: picking a
// language in one instance re-renders them all, and the server snapshot is
// always TypeScript so no-JS readers and the first paint agree.
let current: Lang = 0;
let loaded = false;
const listeners = new Set<() => void>();

function load(): void {
  if (loaded) return;
  loaded = true;
  try {
    if (window.localStorage.getItem(STORAGE_KEY) === "zig") current = 1;
  } catch {
    // Storage unavailable (privacy mode): stay on the default.
  }
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function snapshot(): Lang {
  load();
  return current;
}

function serverSnapshot(): Lang {
  return 0;
}

function select(next: Lang): void {
  current = next;
  try {
    window.localStorage.setItem(STORAGE_KEY, next === 1 ? "zig" : "ts");
  } catch {
    // Storage unavailable: the choice still applies for this page.
  }
  listeners.forEach((listener) => listener());
}

export function CodeToggle({ children }: { children: React.ReactNode }) {
  const active = useSyncExternalStore(subscribe, snapshot, serverSnapshot);
  const id = useId();

  return (
    <div
      data-code-toggle=""
      data-active={LANGS[active].key}
      className="relative my-4 rounded-lg border border-neutral-200 overflow-hidden dark:border-neutral-800"
    >
      {/* React hoists this into <head> and dedupes it across instances. */}
      <style href="native-docs-code-toggle" precedence="default">
        {css}
      </style>
      <div
        data-code-toggle-tabs=""
        className="flex h-9 items-center justify-end border-b border-neutral-200 bg-neutral-100 px-4 dark:border-neutral-800 dark:bg-neutral-900"
      >
        <SegmentedControl
          label="Sample language"
          tabs={LANGS}
          activeIndex={active}
          onSelect={(index) => select(index as Lang)}
          tabId={(index) => `${id}-tab-${index}`}
          panelId={`${id}-panel`}
        />
      </div>
      {/* One tabpanel reused for both languages: the children stay opaque,
          so the panel cannot be split per fence — the CSS above shows only
          the active language's fence inside it. */}
      <div
        role="tabpanel"
        id={`${id}-panel`}
        aria-labelledby={`${id}-tab-${active}`}
      >
        {children}
      </div>
    </div>
  );
}
