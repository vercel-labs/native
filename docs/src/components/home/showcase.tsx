"use client";

import Image from "next/image";
import { useState } from "react";
import { githubUrl } from "@/lib/site";

interface ShowcaseApp {
  id: string;
  name: string;
  tagline: string;
  detail: string;
  facts: { label: string; value: string }[];
  width: number;
  height: number;
  portrait?: boolean;
  /** Dark-only apps ship one capture that shows in both site themes. */
  darkOnly?: boolean;
  /**
   * Multi-window apps (deck) present their fixed-size windows stacked at
   * natural scale on a padded stage instead of one edge-to-edge capture.
   */
  stack?: { src: string; alt: string; width: number; height: number }[];
}

// Every number below is measured from the repository: line counts are the
// app's src/ markup + Zig with tests excluded, binary sizes are
// `zig build -Doptimize=ReleaseFast` on macOS arm64.
const apps: ShowcaseApp[] = [
  {
    id: "markdown-viewer",
    name: "Markdown Viewer",
    tagline: "A split-pane editor whose preview is native widgets.",
    detail:
      "Headings, tables, task lists, links, and blockquotes on the right are ordinary widgets rendered live from the editor on the left — keystroke for keystroke, with no WebView and no HTML.",
    facts: [
      { label: "App source", value: "765 lines" },
      { label: "Binary", value: "2.7 MB" },
    ],
    width: 2400,
    height: 1520,
  },
  {
    id: "soundboard",
    name: "Soundboard",
    tagline: "A music library with album art, search, and a live transport.",
    detail:
      "Album covers are PNGs decoded and registered by the engine itself. Playback runs on effect timers, the seek bar mirrors runtime state, and queueing a track is a native context menu.",
    facts: [
      { label: "App source", value: "1,170 lines" },
      { label: "Binary", value: "4.8 MB" },
    ],
    width: 2160,
    height: 1440,
  },
  {
    id: "deck",
    name: "Deck",
    tagline: "Soundboard’s twin, rebuilt as classic rack hardware.",
    detail:
      "The same library, transport, queue, and search in two fixed windows: a 460×180 player chassis and a playlist rack the PL key docks beneath it. The chassis — bevels, screws, seven-segment timecode — is a custom chrome pass over the same widgets, dark-only by design.",
    facts: [
      { label: "App source", value: "2,089 lines" },
      { label: "Binary", value: "3.3 MB" },
    ],
    width: 920,
    height: 360,
    darkOnly: true,
    stack: [
      {
        src: "/home/deck-dark.webp",
        alt: "The Deck example app rendered by the Native SDK engine: a fixed 460 by 180 hardware player chassis with a gold cap band, a seven-segment timecode, and a spectrum analyzer, dark by design",
        width: 920,
        height: 360,
      },
      {
        src: "/home/deck-playlist-dark.webp",
        alt: "Deck's playlist rack window: a matching 460 by 440 rack unit with a channel bank, the full track ledger with the playing row highlighted, and a search field",
        width: 920,
        height: 880,
      },
    ],
  },
  {
    id: "notes",
    name: "Notes",
    tagline: "Three-pane notes: folders, full-text search, autosave.",
    detail:
      "The list re-sorts by edit time, the first line of a note becomes its title, and everything persists across launches through the same typed file effects the app uses for export.",
    facts: [
      { label: "App source", value: "1,415 lines" },
      { label: "Binary", value: "2.7 MB" },
    ],
    width: 2360,
    height: 1520,
  },
  {
    id: "system-monitor",
    name: "System Monitor",
    tagline: "Real ps and vm_stat samples drawn as live sparklines.",
    detail:
      "Process spawns run off the loop on a 2-second cadence and land back in update as plain messages. Sort, filter, pause, and send SIGTERM from a native confirmation dialog.",
    facts: [
      { label: "App source", value: "1,630 lines" },
      { label: "Binary", value: "2.8 MB" },
    ],
    width: 2288,
    height: 1440,
  },
  {
    id: "calculator",
    name: "Calculator",
    tagline: "Classic immediate-execution arithmetic in a small window.",
    detail:
      "Every keypad face dispatches a typed message, the keyboard routes through real focus and text-input events, and the whole app — engine, widgets, renderer — is one small static binary.",
    facts: [
      { label: "App source", value: "959 lines" },
      { label: "Binary", value: "2.7 MB" },
    ],
    width: 640,
    height: 980,
    portrait: true,
  },
];

export function Showcase() {
  const [activeId, setActiveId] = useState(apps[0].id);
  const active = apps.find((app) => app.id === activeId) ?? apps[0];

  return (
    <div>
      {/* App switcher */}
      <div className="flex justify-start gap-1.5 overflow-x-auto pb-1 sm:justify-center" role="tablist" aria-label="Showcase apps">
        {apps.map((app) => {
          const selected = app.id === active.id;
          return (
            <button
              key={app.id}
              role="tab"
              aria-selected={selected}
              onClick={() => setActiveId(app.id)}
              className={`inline-flex h-8 shrink-0 items-center rounded-full px-4 button-14 transition-colors ${
                selected
                  ? "bg-gray-1000 text-background-100"
                  : "text-gray-900 hover:bg-gray-alpha-100 hover:text-gray-1000"
              }`}
            >
              {app.name}
            </button>
          );
        })}
      </div>

      {/* Framed screenshot: the light and dark captures are the same app
          state rendered per scheme; the site theme picks which one shows.
          Dark-only apps (deck) ship a single capture for both themes. */}
      <div className="mt-6 overflow-hidden rounded-md border border-gray-alpha-400 bg-background-200 shadow-[0_24px_48px_-24px_rgba(0,0,0,0.18)] dark:bg-gray-alpha-100 dark:shadow-[0_24px_48px_-24px_rgba(0,0,0,0.7)]">
        <div className="flex items-center gap-1.5 border-b border-gray-alpha-400 px-4 py-2.5">
          <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
          <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
          <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
          <span className="ml-3 font-mono label-12 text-gray-900">
            examples/{active.id}
          </span>
        </div>
        {active.stack ? (
          // Fixed-size windows at natural scale on a padded stage — never
          // stretched to fill the tile.
          <div className="flex flex-col items-center gap-2 bg-gray-100 px-6 py-10">
            {active.stack.map((window) => (
              <Image
                key={window.src}
                src={window.src}
                alt={window.alt}
                width={window.width}
                height={window.height}
                quality={90}
                loading="eager"
                className="block h-auto w-full max-w-[460px]"
              />
            ))}
          </div>
        ) : (
          <div className={`relative ${active.portrait ? "flex justify-center bg-gray-100 py-8" : ""}`}>
            {(active.darkOnly ? (["dark"] as const) : (["light", "dark"] as const)).map((scheme) => (
              <Image
                key={`${active.id}-${scheme}`}
                src={`/home/${active.id}-${scheme}.webp`}
                alt={`The ${active.name} example app rendered by the Native SDK engine ${
                  active.darkOnly ? "(dark by design)" : `(${scheme} theme)`
                }`}
                width={active.width}
                height={active.height}
                quality={90}
                loading="eager"
                className={`h-auto ${active.portrait ? "w-64 rounded-md border border-gray-alpha-400 shadow-modal sm:w-72" : "w-full"} ${
                  active.darkOnly ? "" : scheme === "light" ? "dark:hidden" : "hidden dark:block"
                }`}
              />
            ))}
          </div>
        )}
      </div>

      {/* Caption */}
      <div className="mx-auto mt-6 flex max-w-3xl flex-col items-start gap-4 sm:flex-row sm:items-baseline sm:justify-between">
        <div>
          <p className="label-14 font-medium text-gray-1000">{active.tagline}</p>
          <p className="mt-2 copy-14 text-gray-900">{active.detail}</p>
        </div>
        <div className="flex shrink-0 flex-col gap-1 sm:items-end">
          {active.facts.map((fact) => (
            <div key={fact.label} className="flex items-baseline gap-2 sm:flex-row-reverse">
              <span className="label-12 uppercase tracking-wider text-gray-900">{fact.label}</span>
              <span className="font-mono label-14 tabular-nums text-gray-1000">{fact.value}</span>
            </div>
          ))}
          <a
            href={`${githubUrl}/tree/main/examples/${active.id}`}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-1 button-14 text-gray-1000 hover:underline"
          >
            Browse the Source →
          </a>
        </div>
      </div>
    </div>
  );
}
