import Image from "next/image";
import { siteName } from "@/lib/site";
import { WindowDots } from "./window-dots";

// One capture per color scheme, rendered by the engine from examples/ —
// the site theme picks which one shows.
const shot = { id: "soundboard", name: "Soundboard", width: 2160, height: 1440 };

/**
 * The above-the-fold product shot: one real example app in one flat window,
 * straight-on and centered beneath the hero copy. No rotation, no stacking —
 * and no invented titlebar: the app's own header is its titlebar (captured
 * with the chrome gap reserved), so the site draws only the stoplights
 * into that gap.
 */
export function HeroWindow() {
  return (
    <div className="mx-auto max-w-5xl px-6">
      <div className="relative overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100 shadow-[0_16px_40px_-24px_rgba(0,0,0,0.25)] dark:border-gray-alpha-200 dark:shadow-none">
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
        <WindowDots width={shot.width / 2} height={shot.height / 2} />
      </div>
    </div>
  );
}
