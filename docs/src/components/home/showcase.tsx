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
}

// Every number below is measured from the repository: line counts are the
// app's src/ markup + Zig with tests excluded, binary sizes are
// `zig build -Doptimize=ReleaseFast` on macOS arm64.
const apps: ShowcaseApp[] = [
  {
    id: "soundboard",
    name: "Soundboard",
    tagline: "A music library with album art, search, and a live transport.",
    detail:
      "Album covers are PNGs decoded and registered by the engine itself. Playback runs on effect timers, the seek bar mirrors runtime state, and queueing a track is a native context menu.",
    facts: [
      { label: "App source", value: "1,155 lines" },
      { label: "Binary", value: "4.5 MB" },
    ],
    width: 2160,
    height: 1440,
  },
  {
    id: "notes",
    name: "Notes",
    tagline: "Three-pane notes: folders, full-text search, autosave.",
    detail:
      "The list re-sorts by edit time, the first line of a note becomes its title, and everything persists across launches through the same typed file effects the app uses for export.",
    facts: [
      { label: "App source", value: "1,426 lines" },
      { label: "Binary", value: "2.4 MB" },
    ],
    width: 2360,
    height: 1520,
  },
  {
    id: "markdown-viewer",
    name: "Markdown Viewer",
    tagline: "A split-pane editor whose preview is native widgets.",
    detail:
      "Headings, tables, task lists, links, and blockquotes on the right are ordinary widgets rendered live from the editor on the left — keystroke for keystroke, with no WebView and no HTML.",
    facts: [
      { label: "App source", value: "701 lines" },
      { label: "Binary", value: "2.4 MB" },
    ],
    width: 2400,
    height: 1520,
  },
  {
    id: "system-monitor",
    name: "System Monitor",
    tagline: "Real ps and vm_stat samples drawn as live sparklines.",
    detail:
      "Process spawns run off the loop on a 2-second cadence and land back in update as plain messages. Sort, filter, pause, and send SIGTERM from a native confirmation dialog.",
    facts: [
      { label: "App source", value: "1,575 lines" },
      { label: "Binary", value: "2.5 MB" },
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
      { label: "App source", value: "918 lines" },
      { label: "Binary", value: "2.4 MB" },
    ],
    width: 640,
    height: 992,
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
              className={`shrink-0 rounded-full px-4 py-1.5 text-sm font-medium transition-colors ${
                selected
                  ? "bg-neutral-900 text-white dark:bg-white dark:text-neutral-900"
                  : "text-neutral-600 hover:bg-neutral-100 hover:text-neutral-900 dark:text-neutral-400 dark:hover:bg-neutral-900 dark:hover:text-neutral-100"
              }`}
            >
              {app.name}
            </button>
          );
        })}
      </div>

      {/* Framed screenshot: the light and dark captures are the same app
          state rendered per scheme; the site theme picks which one shows. */}
      <div className="mt-6 overflow-hidden rounded-2xl border border-neutral-200 bg-neutral-50 shadow-[0_24px_48px_-24px_rgba(0,0,0,0.18)] dark:border-neutral-800 dark:bg-neutral-900/60 dark:shadow-[0_24px_48px_-24px_rgba(0,0,0,0.7)]">
        <div className="flex items-center gap-1.5 border-b border-neutral-200 px-4 py-2.5 dark:border-neutral-800">
          <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
          <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
          <span className="h-2.5 w-2.5 rounded-full bg-neutral-300 dark:bg-neutral-700" />
          <span className="ml-3 font-mono text-xs text-neutral-500 dark:text-neutral-400">
            examples/{active.id}
          </span>
        </div>
        <div className={`relative ${active.portrait ? "flex justify-center bg-neutral-100 py-8 dark:bg-neutral-900" : ""}`}>
          {(["light", "dark"] as const).map((scheme) => (
            <Image
              key={`${active.id}-${scheme}`}
              src={`/home/${active.id}-${scheme}.webp`}
              alt={`The ${active.name} example app rendered by the framework's engine (${scheme} theme)`}
              width={active.width}
              height={active.height}
              quality={90}
              loading="eager"
              className={`h-auto ${active.portrait ? "w-64 rounded-xl border border-neutral-200 shadow-lg sm:w-72 dark:border-neutral-800" : "w-full"} ${
                scheme === "light" ? "dark:hidden" : "hidden dark:block"
              }`}
            />
          ))}
        </div>
      </div>

      {/* Caption */}
      <div className="mx-auto mt-6 flex max-w-3xl flex-col items-start gap-4 sm:flex-row sm:items-baseline sm:justify-between">
        <div>
          <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">{active.tagline}</p>
          <p className="mt-2 text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">{active.detail}</p>
        </div>
        <div className="flex shrink-0 flex-col gap-1 sm:items-end">
          {active.facts.map((fact) => (
            <div key={fact.label} className="flex items-baseline gap-2 sm:flex-row-reverse">
              <span className="text-xs uppercase tracking-wider text-neutral-400 dark:text-neutral-500">{fact.label}</span>
              <span className="font-mono text-sm text-neutral-900 dark:text-neutral-100">{fact.value}</span>
            </div>
          ))}
          <a
            href={`${githubUrl}/tree/main/examples/${active.id}`}
            target="_blank"
            rel="noopener noreferrer"
            className="mt-1 text-sm font-medium text-neutral-900 hover:underline dark:text-neutral-100"
          >
            Browse the source →
          </a>
        </div>
      </div>
    </div>
  );
}
