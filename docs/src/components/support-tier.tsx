import type { ReactNode } from "react";

/**
 * Support-matrix tier marks for the Platform Support page. Each cell renders
 * an icon plus an aria-label carrying the tier name and the full caveat text,
 * so screen readers read exactly what sighted readers get from the legend,
 * the tooltip, and the footnotes.
 */
export type SupportTier = "full" | "caveats" | "embed" | "none";

const TIER_LABELS: Record<SupportTier, string> = {
  full: "First-class",
  caveats: "Works with caveats",
  embed: "Embed-level",
  none: "Not available",
};

function TierGlyph({ tier }: { tier: SupportTier }) {
  const common = {
    width: 16,
    height: 16,
    viewBox: "0 0 16 16",
    "aria-hidden": true as const,
    className: "inline-block align-[-2px]",
  };
  switch (tier) {
    case "full":
      // Filled circle with a check: the one accent color in the matrix.
      return (
        <svg {...common} className={`${common.className} text-blue-600 dark:text-blue-500`}>
          <circle cx="8" cy="8" r="7" fill="currentColor" />
          <path
            d="M4.8 8.2l2.2 2.2 4.2-4.6"
            fill="none"
            stroke="white"
            strokeWidth="1.6"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
      );
    case "caveats":
      // Half-filled circle: present, but read the footnote.
      return (
        <svg {...common} className={`${common.className} text-neutral-500 dark:text-neutral-400`}>
          <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path d="M8 2.5a5.5 5.5 0 0 0 0 11z" fill="currentColor" />
        </svg>
      );
    case "embed":
      // A box inside a box: runs embedded in a host app you own.
      return (
        <svg {...common} className={`${common.className} text-neutral-500 dark:text-neutral-400`}>
          <rect
            x="2.75"
            y="2.75"
            width="10.5"
            height="10.5"
            rx="2"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
          />
          <rect x="6" y="6" width="4" height="4" rx="1" fill="currentColor" />
        </svg>
      );
    case "none":
      // A quiet dash.
      return (
        <svg {...common} className={`${common.className} text-neutral-300 dark:text-neutral-700`}>
          <path d="M4.5 8h7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
      );
  }
}

/**
 * One matrix cell. `note` is the one-line caveat: it goes into the tooltip
 * and the aria-label, never into visible cell text. `fn` renders a footnote
 * marker pointing at the numbered list under the table.
 */
export function Tier({ tier, note, fn }: { tier: SupportTier; note?: string; fn?: number }) {
  const label = note ? `${TIER_LABELS[tier]}: ${note}` : TIER_LABELS[tier];
  return (
    <span role="img" aria-label={label} title={label} className="whitespace-nowrap">
      <TierGlyph tier={tier} />
      {fn !== undefined && (
        <sup className="ml-0.5 text-[10px] text-neutral-400 dark:text-neutral-500" aria-hidden>
          {fn}
        </sup>
      )}
    </span>
  );
}

/** The legend mapping each mark to its meaning, shown above the matrix. */
export function TierLegend() {
  const entries: { tier: SupportTier; text: ReactNode }[] = [
    { tier: "full", text: "First-class — implemented and exercised" },
    { tier: "caveats", text: "Works with caveats — real support, footnote applies" },
    { tier: "embed", text: "Embed-level — runs inside a host app you own" },
    { tier: "none", text: "Not available today" },
  ];
  return (
    <ul className="mb-4 flex list-none flex-col gap-1.5 pl-0 text-sm sm:flex-row sm:flex-wrap sm:gap-x-6">
      {entries.map(({ tier, text }) => (
        <li
          key={tier}
          className="flex items-center gap-2 pl-0 text-neutral-600 dark:text-neutral-400"
        >
          <TierGlyph tier={tier} />
          <span>{text}</span>
        </li>
      ))}
    </ul>
  );
}
