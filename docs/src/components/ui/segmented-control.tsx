"use client";

import { Fragment, useRef } from "react";

// The site's segmented control: the quiet text-tab register (active
// foreground, inactive muted, thin dividers) inside the pill chrome the
// component previews' Default | Geist theme-pack toggle established.
// Extracted so every switcher — the preview titlebar's pack toggle, the
// TS | Zig code toggle — is the exact same control: same shape, same
// paddings, same radii, same active-segment treatment, and the same
// dark-mode behavior (the gray/alpha tokens flip with the site theme).
//
// Accessibility contract: role="tablist" with roving tabindex — the
// whole control is one tab stop, arrows move within it, and selecting
// with the arrows also moves focus. `tabId`/`panelId` are optional so a
// caller with a real tabpanel (the code toggle) can wire aria-controls
// and aria-labelledby, while a caller whose "panel" is a canvas (the
// preview titlebar) can skip them.

export interface SegmentedControlTab {
  key: string;
  label: string;
}

export function SegmentedControl({
  label,
  tabs,
  activeIndex,
  onSelect,
  tabId,
  panelId,
}: {
  label: string;
  tabs: readonly SegmentedControlTab[];
  activeIndex: number;
  onSelect: (index: number) => void;
  tabId?: (index: number) => string;
  panelId?: string;
}) {
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  return (
    <div
      role="tablist"
      aria-label={label}
      className="inline-flex items-center gap-1.5 rounded-full border border-gray-alpha-400 bg-background-100/90 px-2 py-0.5 text-[11px] leading-4"
    >
      {tabs.map((tab, index) => (
        <Fragment key={tab.key}>
          {index > 0 && <span aria-hidden className="h-3 w-px bg-gray-alpha-400" />}
          <button
            ref={(el) => {
              tabRefs.current[index] = el;
            }}
            role="tab"
            id={tabId?.(index)}
            aria-selected={activeIndex === index}
            aria-controls={panelId}
            tabIndex={activeIndex === index ? 0 : -1}
            onClick={() => onSelect(index)}
            onKeyDown={(event) => {
              if (event.key !== "ArrowRight" && event.key !== "ArrowLeft") return;
              event.preventDefault();
              const step = event.key === "ArrowRight" ? 1 : -1;
              const next = (index + step + tabs.length) % tabs.length;
              onSelect(next);
              tabRefs.current[next]?.focus();
            }}
            className={`transition-colors ${
              activeIndex === index ? "text-gray-1000" : "text-gray-700 hover:text-gray-1000"
            }`}
          >
            {tab.label}
          </button>
        </Fragment>
      ))}
    </div>
  );
}
