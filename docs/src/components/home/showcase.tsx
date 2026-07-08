"use client";

import Image from "next/image";
import { useState } from "react";
import { githubUrl } from "@/lib/site";
import { WindowDots, type WindowDotsVariant } from "./window-dots";

interface ShowcaseApp {
  id: string;
  name: string;
  tagline: string;
  detail: string;
  facts: { label: string; value: string }[];
  width: number;
  height: number;
  portrait?: boolean;
  /**
   * The app's titlebar register: captures reserve the macOS chrome gap
   * in their own header and the site overlays the stoplights there
   * (see WindowDots for the shared geometry). Absent for chromeless
   * apps (deck), whose skins draw their own window controls.
   */
  chrome?: WindowDotsVariant;
  /** Dark-only apps ship one capture that shows in both site themes. */
  darkOnly?: boolean;
  /**
   * Multi-window apps (deck) present their fixed-size windows stacked at
   * natural scale instead of one edge-to-edge capture.
   */
  stack?: { src: string; alt: string; width: number; height: number }[];
}

// Every number below is measured from the repository on macOS arm64.
// Binary sizes are stripped release binaries, one method for all seven:
//   cd examples/<app> && native build && strip -x zig-out/bin/<app> && ls -lh zig-out/bin/<app>
// (`native build` compiles ReleaseFast; `strip -x` drops local symbols the
// way a shipped binary would. Unstripped adds ~0.3-0.5 MB per app and every
// app still lands well under 6 MB either way.)
const apps: ShowcaseApp[] = [
  {
    id: "markdown-viewer",
    chrome: "tall",
    name: "Markdown Viewer",
    tagline: "A split-pane editor whose preview is native widgets.",
    detail:
      "Headings, tables, task lists, links, and blockquotes on the right are ordinary widgets rendered live from the editor on the left — keystroke for keystroke, with no WebView and no HTML.",
    facts: [{ label: "Binary", value: "3.4 MB" }],
    width: 2400,
    height: 1520,
  },
  {
    id: "soundboard",
    chrome: "tall",
    name: "Soundboard",
    tagline: "A music library with album art, search, and a live transport.",
    detail:
      "Album covers are PNGs decoded and registered by the engine itself. Playback runs on effect timers, the seek bar mirrors runtime state, and queueing a track is a native context menu.",
    facts: [{ label: "Binary", value: "4.3 MB" }],
    width: 2160,
    height: 1440,
  },
  {
    id: "deck",
    name: "Deck",
    tagline: "Soundboard’s twin, rebuilt as vintage hi-fi rack hardware.",
    detail:
      "The same library, transport, and search in two fixed chromeless windows: a 512×264 enamel player chassis and a playlist rack the PL key docks beneath it. The fascia — cream enamel, recessed screws, smoked-glass bays, seven-segment timecode, a rotary volume knob — is a custom chrome pass over the same widgets, one finish by design.",
    facts: [{ label: "Binary", value: "4.3 MB" }],
    width: 1024,
    height: 528,
    darkOnly: true,
    stack: [
      {
        src: "/home/deck-dark.webp",
        alt: "The Deck example app rendered by the Native SDK engine: a fixed 512 by 264 chromeless hardware player in cream enamel with smoked-glass display bays, a phosphor seven-segment timecode, a spectrum analyzer, and a rotary volume knob",
        width: 1024,
        height: 528,
      },
      {
        src: "/home/deck-playlist-dark.webp",
        alt: "Deck's playlist window: a matching enamel rack unit around one smoked-glass playlist bay — numbered phosphor rows with the playing row highlighted, right-aligned durations, and a glass search inset",
        width: 1024,
        height: 880,
      },
    ],
  },
  {
    id: "feed",
    chrome: "tall",
    name: "Feed",
    tagline: "A 100,000-post timeline in one virtual list.",
    detail:
      "Every post derives deterministically from its index, and rows are as tall as their wrapped bodies — the view only ever builds the handful of rows on screen, the engine corrects its extent estimates as you scroll, and nearing the end appends the next 500 posts through one reach-end message.",
    facts: [
      { label: "Corpus", value: "100,000 posts" },
      { label: "Binary", value: "3.6 MB" },
    ],
    width: 1040,
    height: 1520,
    portrait: true,
  },
  {
    id: "notes",
    chrome: "tall",
    name: "Notes",
    tagline: "Three-pane notes: folders, full-text search, autosave.",
    detail:
      "The list re-sorts by edit time, the first line of a note becomes its title, and everything persists across launches through the same typed file effects the app uses for export.",
    facts: [{ label: "Binary", value: "3.4 MB" }],
    width: 2360,
    height: 1520,
  },
  {
    id: "system-monitor",
    chrome: "tall",
    name: "System Monitor",
    tagline: "Real ps and vm_stat samples drawn as live sparklines.",
    detail:
      "Process spawns run off the loop on a 2-second cadence and land back in update as plain messages. Sort, filter, pause, and send SIGTERM from a native confirmation dialog.",
    facts: [{ label: "Binary", value: "3.7 MB" }],
    width: 2288,
    height: 1440,
  },
  {
    id: "calculator",
    chrome: "compact",
    name: "Calculator",
    tagline: "Classic immediate-execution arithmetic in a small window.",
    detail:
      "Every keypad face dispatches a typed message, the keyboard routes through real focus and text-input events, and the whole app — engine, widgets, renderer — is one small static binary.",
    facts: [{ label: "Binary", value: "3.5 MB" }],
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

      {/* Screenshot: the light and dark captures are the same app state
          rendered per scheme; the site theme picks which one shows.
          Single-finish apps (deck) ship one capture for both themes.
          Every showcase window owns its own chrome (hidden-inset header
          bands or fixed chromeless chassis), so no capture gets an
          invented window frame — each sits on the page background as its
          own silhouette, and the site draws only the stoplights into the
          chrome gap the capture's header reserved (WindowDots). */}
      {active.stack ? (
        // Chromeless fixed-size windows at natural scale on the page
        // background — never framed, never stretched to fill a tile.
        <div className="mt-6 flex flex-col items-center gap-2 py-4">
          {active.stack.map((window) => (
            <Image
              key={window.src}
              src={window.src}
              alt={window.alt}
              width={window.width}
              height={window.height}
              quality={90}
              loading="eager"
              className="block h-auto w-full"
              // Captures are 2x; each fixed window shows at its own
              // natural 1x size (deck's two windows differ in width).
              style={{ maxWidth: window.width / 2 }}
            />
          ))}
        </div>
      ) : (
        // Single window: the app's own silhouette — rounded corners and
        // a shadow, like the real window on a desktop, no invented
        // titlebar. The relative wrapper hosts the stoplight overlay in
        // the header gap the capture reserved.
        <div className="mt-6 flex justify-center py-4">
          <div
            className={`relative overflow-hidden rounded-md border border-gray-alpha-400 shadow-modal dark:border-gray-alpha-200 ${
              active.portrait ? "w-64 sm:w-72" : "w-full"
            }`}
          >
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
                className={`block h-auto w-full ${
                  active.darkOnly ? "" : scheme === "light" ? "dark:hidden" : "hidden dark:block"
                }`}
              />
            ))}
            {active.chrome && (
              <WindowDots width={active.width / 2} height={active.height / 2} variant={active.chrome} />
            )}
          </div>
        </div>
      )}

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
