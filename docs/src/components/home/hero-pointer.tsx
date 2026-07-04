"use client";

import { useEffect, useRef } from "react";

/**
 * A barely-there neutral radial highlight that follows the cursor across the
 * hero. One pointermove listener updating two CSS custom properties — no
 * motion library. The overlay only exists for hover-capable pointers and is
 * disabled entirely when the visitor prefers reduced motion (both here and
 * in the .hero-pointer CSS gate).
 */
export function HeroPointer() {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    const section = el?.parentElement;
    if (!el || !section) return;
    if (!window.matchMedia("(hover: hover) and (prefers-reduced-motion: no-preference)").matches) {
      return;
    }

    let raf = 0;
    const move = (event: PointerEvent) => {
      const rect = section.getBoundingClientRect();
      const x = event.clientX - rect.left;
      const y = event.clientY - rect.top;
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        el.style.setProperty("--pointer-x", `${x}px`);
        el.style.setProperty("--pointer-y", `${y}px`);
        el.style.opacity = "1";
      });
    };
    const leave = () => {
      cancelAnimationFrame(raf);
      el.style.opacity = "0";
    };

    section.addEventListener("pointermove", move);
    section.addEventListener("pointerleave", leave);
    return () => {
      cancelAnimationFrame(raf);
      section.removeEventListener("pointermove", move);
      section.removeEventListener("pointerleave", leave);
    };
  }, []);

  return (
    <div
      ref={ref}
      aria-hidden
      className="hero-pointer pointer-events-none absolute inset-0 opacity-0 transition-opacity duration-500"
    />
  );
}
