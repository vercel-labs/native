import Image from "next/image";
import { siteName } from "@/lib/site";

// One capture per color scheme, rendered by the engine from examples/ —
// the site theme picks which one shows.
const shot = { id: "soundboard", name: "Soundboard", width: 2160, height: 1440 };

/**
 * The above-the-fold product shot: one real example app in one flat window,
 * straight-on and centered beneath the hero copy. No rotation, no stacking.
 */
export function HeroWindow() {
  return (
    <div className="mx-auto max-w-5xl px-6">
      <div className="overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 shadow-[0_16px_40px_-24px_rgba(0,0,0,0.25)] dark:border-gray-alpha-500 dark:shadow-none">
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
            priority
            loading="eager"
            className={`block h-auto w-full ${scheme === "light" ? "dark:hidden" : "hidden dark:block"}`}
          />
        ))}
      </div>
    </div>
  );
}
