"use client";

import Image from "next/image";
import { useTheme } from "next-themes";
import { useCallback, useEffect, useRef, useState } from "react";
import { SegmentedControl } from "@/components/ui/segmented-control";
import { LivePreview, PointerKind, type ThemePack, loadPreviewEngine } from "@/lib/live-preview";

/**
 * A component-preview tile that upgrades from the static engine-rendered
 * webp pair to a LIVE engine instance running in-page via wasm.
 *
 * Layers, honestly ordered:
 * - The theme-aware webp pair is the SSR / no-JS / instant layer (same
 *   markup as before the wasm existed).
 * - Approaching the viewport warms the shared wasm module; ENTERING the
 *   viewport activates the tile (creates the scene instance and swaps
 *   in a canvas that follows the site theme), so time-driven previews
 *   (spinner, skeleton) animate without waiting for a pointer. Leaving
 *   the viewport releases the instance again — live cost tracks what
 *   the reader can actually see.
 * - The rAF loop runs only while the tile is visible AND something
 *   recently changed; `render` returns whether the engine's retained
 *   display list repainted, so an idle preview costs nothing. Looping
 *   animations keep repainting, so their tiles simply never idle-park
 *   while on screen — parking happens when they scroll away.
 *
 * Keyboard: the canvas is focusable (click or Tab); keys route into the
 * engine's roving widget focus. Escape returns focus to the page.
 */

/**
 * Backstop cap on simultaneous live instances (LRU). Activation is
 * viewport-driven, so the working set is normally "tiles on screen";
 * the cap only guards pathological layouts (a huge grid of tiny tiles)
 * from unbounded wasm memory. Each instance is a fixed-capacity engine
 * runtime, single-digit megabytes.
 */
const max_live_instances = 12;
/** Park the rAF loop after this much time without a repaint or input. */
const idle_park_ms = 600;

const liveRegistry: { id: number; visible: () => boolean; release: () => void }[] = [];
let nextLiveId = 1;

function registerLive(visible: () => boolean, release: () => void): number {
  const id = nextLiveId++;
  liveRegistry.push({ id, visible, release });
  while (liveRegistry.length > max_live_instances) {
    // Evict the oldest OFF-SCREEN instance first — visibility drives
    // activation, so releasing a visible tile would freeze something
    // the reader is looking at. Only when every live tile is on screen
    // does plain LRU apply.
    const index = liveRegistry.findIndex((entry) => !entry.visible());
    const evicted = liveRegistry.splice(index >= 0 ? index : 0, 1)[0];
    evicted?.release();
  }
  return id;
}

function unregisterLive(id: number): void {
  const index = liveRegistry.findIndex((entry) => entry.id === id);
  if (index >= 0) liveRegistry.splice(index, 1);
}

/** Keys the engine consumes while the canvas owns keyboard focus. */
const handled_keys = new Set([
  "tab",
  "enter",
  "space",
  "backspace",
  "delete",
  "arrowleft",
  "arrowright",
  "arrowup",
  "arrowdown",
  "home",
  "end",
]);

/**
 * Cmd/Ctrl chords the engine consumes: select-all routes INTO the
 * focused engine text field (the same synthetic key_down the desktop
 * edit menu emits) and cut/copy/paste hit the engine's clipboard, so
 * none of them may fall through to the page (Cmd+A selecting the whole
 * docs page under a focused preview field).
 */
const handled_shortcut_keys = new Set(["a", "c", "x", "v"]);

/**
 * The theme packs a live tile can present, in toggle order. The static
 * webp underlay is only ever rendered in the default pack, so the
 * toggle appears strictly on the live canvas layer, where the engine
 * re-themes the retained scene in place.
 */
const pack_tabs = [
  { pack: "house", label: "Default" },
  { pack: "geist", label: "Geist" },
] as const satisfies readonly { pack: ThemePack; label: string }[];

function engineKeyName(key: string): string {
  return key === " " ? "space" : key.toLowerCase();
}

function engineModifiers(event: { metaKey: boolean; ctrlKey: boolean; altKey: boolean; shiftKey: boolean }): number {
  let mask = 0;
  if (event.metaKey) mask |= 1 | 2;
  if (event.ctrlKey) mask |= 4;
  if (event.altKey) mask |= 8;
  if (event.shiftKey) mask |= 16;
  return mask;
}

/** Whether the engine consumes this key event while the canvas is focused. */
function engineConsumesKey(event: { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean }): boolean {
  const key = engineKeyName(event.key);
  if ((event.metaKey || event.ctrlKey) && !event.altKey) {
    return handled_shortcut_keys.has(key);
  }
  const printable = event.key.length === 1;
  return handled_keys.has(key) || printable;
}

export function ComponentPreviewLive({
  name,
  alt,
  width,
  height,
}: {
  name: string;
  alt: string;
  width: number;
  height: number;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const previewRef = useRef<LivePreview | null>(null);
  const liveIdRef = useRef(0);
  const rafRef = useRef(0);
  const lastActivityRef = useRef(0);
  const visibleRef = useRef(false);
  const pointerDownRef = useRef(false);
  const [live, setLive] = useState(false);
  const [painted, setPainted] = useState(false);
  // Only advertise interactivity once the client is actually capable of
  // it (SSR + no-JS readers keep the plain static tile, no false hint).
  const [interactive, setInteractive] = useState(false);
  useEffect(() => setInteractive(true), []);
  const { resolvedTheme } = useTheme();
  const isDark = resolvedTheme !== "light";
  const isDarkRef = useRef(isDark);
  isDarkRef.current = isDark;
  // Per-tile theme pack, local state only: the choice composes with the
  // site-wide light/dark axis but is deliberately NOT persisted or
  // shared across tiles — it is a "what does this component look like
  // in the other register" glance, not a site preference. The ref lets
  // the stable `activate` callback re-apply the choice when a tile
  // scrolls back into view and its engine instance is recreated.
  const [pack, setPack] = useState<ThemePack>("house");
  const packRef = useRef(pack);
  packRef.current = pack;

  /** Mirror the engine's cursor channel onto the canvas's CSS cursor. */
  const syncCursor = useCallback(() => {
    const preview = previewRef.current;
    const canvas = canvasRef.current;
    if (!preview || !canvas) return;
    const cursor = preview.cursor();
    if (canvas.style.cursor !== cursor) canvas.style.cursor = cursor;
  }, []);

  const blit = useCallback(() => {
    const preview = previewRef.current;
    const canvas = canvasRef.current;
    if (!preview || !canvas) return false;
    const cssWidth = canvas.clientWidth || canvas.getBoundingClientRect().width;
    if (cssWidth <= 0) return false;
    const scale = (cssWidth * (window.devicePixelRatio || 1)) / preview.logicalWidth;
    const imageData = preview.render(scale);
    if (!imageData) return false;
    if (canvas.width !== imageData.width || canvas.height !== imageData.height) {
      canvas.width = imageData.width;
      canvas.height = imageData.height;
    }
    canvas.getContext("2d")?.putImageData(imageData, 0, 0);
    setPainted(true);
    return true;
  }, []);

  const stopLoop = useCallback(() => {
    if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = 0;
    }
  }, []);

  const wake = useCallback(() => {
    lastActivityRef.current = performance.now();
    if (rafRef.current || !previewRef.current) return;
    const tick = (time: number) => {
      rafRef.current = 0;
      const preview = previewRef.current;
      if (!preview || !visibleRef.current || document.hidden) return;
      preview.setNow(time);
      preview.frame();
      syncCursor();
      if (blit()) lastActivityRef.current = time;
      if (time - lastActivityRef.current < idle_park_ms) {
        rafRef.current = requestAnimationFrame(tick);
      }
    };
    rafRef.current = requestAnimationFrame(tick);
  }, [blit, syncCursor]);

  const deactivate = useCallback(() => {
    stopLoop();
    if (liveIdRef.current) {
      unregisterLive(liveIdRef.current);
      liveIdRef.current = 0;
    }
    previewRef.current?.destroy();
    previewRef.current = null;
    pointerDownRef.current = false;
    setLive(false);
    setPainted(false);
  }, [stopLoop]);

  const activate = useCallback(() => {
    if (previewRef.current) return;
    void loadPreviewEngine().then((engine) => {
      if (!engine || previewRef.current || !containerRef.current) return;
      // The tile may have scrolled away while the module downloaded;
      // only keyboard engagement (the container holds focus) still
      // justifies going live off-screen.
      if (!visibleRef.current && document.activeElement !== containerRef.current) return;
      const preview = engine.create(name, isDarkRef.current);
      if (!preview) return;
      // Re-apply the tile's pack choice before the first paint: a tile
      // that was toggled to another pack, scrolled away (releasing its
      // instance), and scrolled back must come back in the chosen pack
      // with no default-themed first frame.
      if (packRef.current !== "house") preview.setThemePack(packRef.current);
      previewRef.current = preview;
      liveIdRef.current = registerLive(() => visibleRef.current, deactivate);
      setLive(true);
      wake();
    });
  }, [deactivate, name, wake]);

  // Two rings around the viewport drive the tile's lifecycle:
  // - The outer ring (generous margin) warms the shared wasm module so
  //   the download races the scroll.
  // - The inner ring activates the tile as it becomes visible — no
  //   pointer required, which is what lets always-animating previews
  //   (spinner, skeleton) run on sight — and releases the instance
  //   once it leaves, so a long components page never accumulates live
  //   engines it isn't showing.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const warm = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) void loadPreviewEngine();
        }
      },
      { rootMargin: "600px" },
    );
    const active = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          visibleRef.current = entry.isIntersecting;
          if (entry.isIntersecting) {
            if (previewRef.current) wake();
            else activate();
          } else {
            stopLoop();
            // Keep a keyboard-engaged tile alive even when scrolled
            // away: dropping it would yank focus back to the page.
            const focused = document.activeElement;
            if (focused !== container && (!canvasRef.current || focused !== canvasRef.current)) {
              deactivate();
            }
          }
        }
      },
      { rootMargin: "64px" },
    );
    warm.observe(container);
    active.observe(container);
    const onVisibility = () => {
      if (document.hidden) stopLoop();
      else if (previewRef.current && visibleRef.current) wake();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      warm.disconnect();
      active.disconnect();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [activate, deactivate, stopLoop, wake]);

  // Hand keyboard focus from the static tile to the live canvas so an
  // Enter/Tab activation flows straight into the engine's widget focus.
  useEffect(() => {
    if (live && document.activeElement === containerRef.current) {
      canvasRef.current?.focus();
    }
  }, [live]);

  // The single live canvas follows the site theme.
  useEffect(() => {
    const preview = previewRef.current;
    if (!preview || !live) return;
    preview.setTheme(isDark);
    wake();
  }, [isDark, live, wake]);

  // ... and the tile's pack choice rides on top of it: the engine
  // re-themes the retained scene in place (same rebuild path as the
  // scheme flip), so pack × scheme always composes — Geist under a dark
  // site is Geist dark.
  useEffect(() => {
    const preview = previewRef.current;
    if (!preview || !live) return;
    preview.setThemePack(pack);
    wake();
  }, [pack, live, wake]);

  // Re-render at the new scale when the tile resizes (or DPR changes).
  useEffect(() => {
    if (!live) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const observer = new ResizeObserver(() => wake());
    observer.observe(canvas);
    return () => observer.disconnect();
  }, [live, wake]);

  // Wheel needs a native non-passive listener (React's onWheel is
  // passive, so it can never stop the page from scrolling underneath).
  // The wheel only routes into the engine once the reader has engaged
  // the preview (focused it by clicking); until then the page scrolls
  // normally.
  useEffect(() => {
    if (!live) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const onWheel = (event: WheelEvent) => {
      const preview = previewRef.current;
      if (!preview || document.activeElement !== canvas) return;
      const rect = canvas.getBoundingClientRect();
      if (rect.width <= 0 || rect.height <= 0) return;
      event.preventDefault();
      preview.setNow(performance.now());
      preview.scroll(
        ((event.clientX - rect.left) * preview.logicalWidth) / rect.width,
        ((event.clientY - rect.top) * preview.logicalHeight) / rect.height,
        event.deltaX,
        event.deltaY,
      );
      wake();
    };
    canvas.addEventListener("wheel", onWheel, { passive: false });
    return () => canvas.removeEventListener("wheel", onWheel);
  }, [live, wake]);

  useEffect(() => deactivate, [deactivate]);

  const toLogical = useCallback((event: React.PointerEvent<HTMLCanvasElement> | React.WheelEvent<HTMLCanvasElement>) => {
    const preview = previewRef.current;
    const canvas = canvasRef.current;
    if (!preview || !canvas) return null;
    const rect = canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return null;
    return {
      x: ((event.clientX - rect.left) * preview.logicalWidth) / rect.width,
      y: ((event.clientY - rect.top) * preview.logicalHeight) / rect.height,
    };
  }, []);

  const sendPointer = useCallback(
    (kind: number, event: React.PointerEvent<HTMLCanvasElement>) => {
      const preview = previewRef.current;
      const point = toLogical(event);
      if (!preview || !point) return;
      preview.setNow(performance.now());
      preview.pointer(kind, point.x, point.y);
      syncCursor();
      wake();
    },
    [syncCursor, toLogical, wake],
  );

  // The generated vocab records the 2x FILE pixel dimensions; the tile
  // presents at the scene's logical size in CSS pixels (the size the
  // engine laid it out at), with the canvas backing store scaled by
  // devicePixelRatio in `blit`. Letting the raw pixel dimensions drive
  // the CSS size rendered every control at double its native size.
  const logicalWidth = width / 2;

  return (
    // The tile is a small app window in the homepage hero's register:
    // same corner radius, border, titlebar band, traffic-light dots,
    // and resting shadow as HeroWindow, so every preview on the site
    // reads as the same artifact — an app in a window. The chrome is
    // presentation-only DOM around the engine output; the static webp
    // underlay and the live canvas sit inside it identically, so going
    // live never shifts a pixel.
    <div
      className="mx-auto overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 shadow-[0_16px_40px_-24px_rgba(0,0,0,0.25)] dark:border-gray-alpha-500 dark:shadow-none"
      style={{ maxWidth: `${logicalWidth}px` }}
      onPointerEnter={activate}
    >
      <div className="flex items-center border-b border-gray-alpha-400 bg-background-200 px-3.5 py-2 dark:bg-gray-alpha-100">
        <span aria-hidden className="flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
          <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
          <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        </span>
        <span className="ml-2.5 min-w-0 truncate font-mono text-[11px] leading-4 text-gray-900">
          {name}
        </span>
        {interactive ? (
          <div className="ml-auto flex items-center gap-1.5 pl-3">
            {/* Theme-pack toggle, a titlebar control: the shared
                SegmentedControl (this titlebar is where its register
                was established). Always visible once hydrated —
                activation is visibility-driven, and a choice made
                before the engine instance exists is carried by packRef
                and applied before the first paint, so the affordance
                is honest even on the brief static frame. Hidden only
                pre-hydration (no-JS readers never meet a dead
                control). Roving tabindex means tabbing past the
                titlebar still reaches the canvas in one step. */}
            <SegmentedControl
              label="Preview theme pack"
              tabs={pack_tabs.map((tab) => ({ key: tab.pack, label: tab.label }))}
              activeIndex={pack_tabs.findIndex((tab) => tab.pack === pack)}
              onSelect={(index) => setPack(pack_tabs[index].pack)}
            />
            <span
              aria-hidden
              className="pointer-events-none hidden items-center gap-1.5 rounded-full border border-gray-alpha-400 bg-background-100/90 px-2 py-0.5 text-[11px] leading-4 text-gray-900 sm:inline-flex"
            >
              WASM Preview
            </span>
          </div>
        ) : null}
      </div>
      <div
        ref={containerRef}
        // Visibility normally activates the tile, but the content area
        // stays focusable while static so keyboard-only readers (and
        // any tile the observer hasn't reached yet) can upgrade it
        // directly; once live the canvas itself is the tab stop. Inert
        // until hydration so no-JS readers never meet a dead button.
        // Pointer-enter on the window shell stays as a
        // belt-and-suspenders activation path.
        tabIndex={interactive && !live ? 0 : -1}
        role={interactive ? "button" : undefined}
        aria-label={interactive && !live ? `Load interactive preview: ${alt}` : undefined}
        className="group/live relative outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-700"
        onFocus={activate}
      >
        {(["light", "dark"] as const).map((scheme) => (
          <Image
            key={`${name}-${scheme}`}
            src={`/components/${name}-${scheme}.webp`}
            alt={`${alt} (${scheme} theme)`}
            width={width}
            height={height}
            unoptimized
            className={`h-auto w-full ${scheme === "light" ? "block dark:hidden" : "hidden dark:block"} ${
              painted ? "invisible" : ""
            }`}
          />
        ))}
        {live ? (
          <canvas
            ref={canvasRef}
            role="application"
            aria-label={`${alt} — interactive WASM preview`}
            aria-roledescription="Interactive component preview rendered by the Native SDK engine. Press Escape to leave."
            tabIndex={0}
            className={`absolute inset-0 h-full w-full touch-none outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-700 ${
              painted ? "opacity-100" : "opacity-0"
            }`}
            onPointerDown={(event) => {
              pointerDownRef.current = true;
              event.currentTarget.setPointerCapture(event.pointerId);
              // preventScroll: a partially-visible tile must not scroll
              // itself into view MID-CLICK — the page would shift between
              // pointer-down and pointer-up and the press would land on
              // the wrong widget (or a drag would jump).
              event.currentTarget.focus({ preventScroll: true });
              sendPointer(PointerKind.down, event);
              event.preventDefault();
            }}
            onPointerMove={(event) => {
              sendPointer(pointerDownRef.current ? PointerKind.drag : PointerKind.move, event);
            }}
            onPointerUp={(event) => {
              pointerDownRef.current = false;
              sendPointer(PointerKind.up, event);
            }}
            onPointerCancel={(event) => {
              pointerDownRef.current = false;
              sendPointer(PointerKind.cancel, event);
            }}
            onPointerLeave={(event) => {
              if (!pointerDownRef.current) sendPointer(PointerKind.move, event);
            }}
            onFocus={() => {
              const preview = previewRef.current;
              if (!preview) return;
              preview.setFocused(true);
              wake();
            }}
            onBlur={() => {
              const preview = previewRef.current;
              if (!preview) return;
              preview.setFocused(false);
              wake();
            }}
            onKeyDown={(event) => {
              const preview = previewRef.current;
              if (!preview) return;
              if (event.key === "Escape") {
                event.currentTarget.blur();
                return;
              }
              if (!engineConsumesKey(event)) return;
              const printable = event.key.length === 1 && !event.metaKey && !event.ctrlKey;
              preview.setNow(performance.now());
              preview.key(0, engineKeyName(event.key), printable ? event.key : "", engineModifiers(event));
              wake();
              event.preventDefault();
            }}
            onKeyUp={(event) => {
              const preview = previewRef.current;
              if (!preview) return;
              if (!engineConsumesKey(event)) return;
              preview.setNow(performance.now());
              preview.key(1, engineKeyName(event.key), "", engineModifiers(event));
              wake();
              event.preventDefault();
            }}
          />
        ) : null}
      </div>
    </div>
  );
}
