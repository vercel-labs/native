"use client";

import Image from "next/image";
import { useTheme } from "next-themes";
import { useCallback, useEffect, useRef, useState } from "react";
import { LivePreview, PointerKind, loadPreviewEngine } from "@/lib/live-preview";

/**
 * A component-preview tile that upgrades from the static engine-rendered
 * webp pair to a LIVE engine instance running in-page via wasm.
 *
 * Layers, honestly ordered:
 * - The theme-aware webp pair is the SSR / no-JS / instant layer (same
 *   markup as before the wasm existed).
 * - Entering the viewport warms the shared wasm module; hovering,
 *   clicking, or focusing the tile creates the scene instance and swaps
 *   in a canvas that follows the site theme (one canvas replaces the
 *   light/dark image pair).
 * - The rAF loop runs only while the tile is visible AND something
 *   recently changed; `render` returns whether the engine's retained
 *   display list repainted, so an idle preview costs nothing.
 *
 * Keyboard: the canvas is focusable (click or Tab); keys route into the
 * engine's roving widget focus. Escape returns focus to the page.
 */

/** How many live engine instances to keep at once (LRU). */
const max_live_instances = 4;
/** Park the rAF loop after this much time without a repaint or input. */
const idle_park_ms = 600;

const liveRegistry: { id: number; release: () => void }[] = [];
let nextLiveId = 1;

function registerLive(release: () => void): number {
  const id = nextLiveId++;
  liveRegistry.push({ id, release });
  while (liveRegistry.length > max_live_instances) {
    const oldest = liveRegistry.shift();
    oldest?.release();
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
      const preview = engine.create(name, isDarkRef.current);
      if (!preview) return;
      previewRef.current = preview;
      liveIdRef.current = registerLive(deactivate);
      setLive(true);
      wake();
    });
  }, [deactivate, name, wake]);

  // Warm the shared wasm module when the tile approaches the viewport;
  // pause/resume the live loop as it leaves and re-enters.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          visibleRef.current = entry.isIntersecting;
          if (entry.isIntersecting) {
            void loadPreviewEngine();
            if (previewRef.current) wake();
          } else {
            stopLoop();
          }
        }
      },
      { rootMargin: "200px" },
    );
    observer.observe(container);
    const onVisibility = () => {
      if (document.hidden) stopLoop();
      else if (previewRef.current && visibleRef.current) wake();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      observer.disconnect();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [stopLoop, wake]);

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
    <div
      ref={containerRef}
      // Focusable while static so keyboard-only readers can upgrade the
      // tile too; once live the canvas itself is the tab stop. Inert
      // until hydration so no-JS readers never meet a dead button.
      tabIndex={interactive && !live ? 0 : -1}
      role={interactive ? "button" : undefined}
      aria-label={interactive && !live ? `Load interactive preview: ${alt}` : undefined}
      className="group/live relative mx-auto overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 outline-none focus-visible:ring-2 focus-visible:ring-blue-700"
      style={{ maxWidth: `${logicalWidth}px` }}
      onPointerEnter={activate}
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
          className={`absolute inset-0 h-full w-full touch-none outline-none focus-visible:ring-2 focus-visible:ring-blue-700 ${
            painted ? "opacity-100" : "opacity-0"
          }`}
          onPointerDown={(event) => {
            pointerDownRef.current = true;
            event.currentTarget.setPointerCapture(event.pointerId);
            event.currentTarget.focus();
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
      {interactive ? (
        <span
          aria-hidden
          className={`pointer-events-none absolute right-2 top-2 inline-flex items-center gap-1.5 rounded-full border border-gray-alpha-400 bg-background-100/90 px-2 py-0.5 text-[11px] leading-4 text-gray-900 transition-opacity ${
            live ? "opacity-100" : "opacity-0 group-hover/live:opacity-70"
          }`}
        >
          {live ? "WASM Preview" : "Hover to interact"}
        </span>
      ) : null}
    </div>
  );
}
