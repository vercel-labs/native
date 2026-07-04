import Image from "next/image";
import { siteName } from "@/lib/site";

interface Shot {
  id: string;
  name: string;
  width: number;
  height: number;
}

// All captures are the example apps in examples/, rendered by the engine —
// one capture per color scheme, so the collage follows the site theme.
const center: Shot = { id: "soundboard", name: "Soundboard", width: 2160, height: 1440 };
const left: Shot = { id: "system-monitor", name: "System Monitor", width: 2288, height: 1440 };
const right: Shot = { id: "notes", name: "Notes", width: 2360, height: 1520 };

function AppWindow({ shot, priority = false }: { shot: Shot; priority?: boolean }) {
  return (
    <div className="overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 shadow-[0_32px_64px_-24px_rgba(0,0,0,0.35)] dark:border-gray-alpha-500 dark:shadow-[0_32px_80px_-16px_rgba(0,0,0,0.9)]">
      <div className="flex items-center gap-1.5 border-b border-gray-alpha-400 bg-background-200 px-3.5 py-2 dark:bg-gray-alpha-100">
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="h-2.5 w-2.5 rounded-full bg-gray-500" />
        <span className="ml-2.5 font-mono text-[11px] leading-4 text-gray-900">
          examples/{shot.id}
        </span>
      </div>
      {(["light", "dark"] as const).map((scheme) => (
        <Image
          key={scheme}
          src={`/home/${shot.id}-${scheme}.webp`}
          alt={`The ${shot.name} example app rendered by the ${siteName} engine (${scheme} theme)`}
          width={shot.width}
          height={shot.height}
          quality={90}
          priority={priority}
          loading="eager"
          className={`block h-auto w-full ${scheme === "light" ? "dark:hidden" : "hidden dark:block"}`}
        />
      ))}
    </div>
  );
}

/**
 * The above-the-fold window stack: three real example apps as layered OS
 * windows. The side windows tuck behind the center one on large screens and
 * disappear on small ones, where the center window stands alone.
 */
export function HeroCollage() {
  return (
    <div className="relative mx-auto max-w-6xl px-6">
      <div className="pointer-events-none absolute left-1/2 top-1/2 h-[120%] w-[130%] -translate-x-1/2 -translate-y-1/2 rounded-[100%] bg-gradient-to-b from-gray-200/50 via-transparent to-transparent blur-3xl dark:from-blue-700/[0.14] dark:via-transparent" />
      <div className="relative">
        <div className="absolute -left-4 top-14 hidden w-[38%] -rotate-[1.5deg] opacity-90 lg:block">
          <AppWindow shot={left} />
        </div>
        <div className="absolute -right-4 top-14 hidden w-[38%] rotate-[1.5deg] opacity-90 lg:block">
          <AppWindow shot={right} />
        </div>
        <div className="relative z-10 mx-auto w-full max-w-[44rem]">
          <AppWindow shot={center} priority />
        </div>
      </div>
    </div>
  );
}
