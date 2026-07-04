import Image from "next/image";
import vocab from "@/lib/component-vocab.json";

/**
 * The built-in vector icon registry, one engine-rendered tile per icon
 * (light/dark pairs from /public/components/icons). Names and tiles both
 * come from `zig build docs-component-previews`, so the gallery always
 * matches `canvas.icons.known_icon_names`.
 */
export function IconGallery() {
  const icons = vocab.icons as string[];
  const size = vocab.iconTileSize as number;
  return (
    <div className="my-6 grid grid-cols-3 gap-3 sm:grid-cols-4 md:grid-cols-5">
      {icons.map((name) => (
        <figure
          key={name}
          className="flex flex-col items-center rounded-md border border-gray-alpha-400 bg-background-100 p-2"
        >
          {(["light", "dark"] as const).map((scheme) => (
            <Image
              key={`${name}-${scheme}`}
              src={`/components/icons/${name}-${scheme}.webp`}
              alt={`The ${name} icon (${scheme} theme)`}
              width={size}
              height={size}
              unoptimized
              className={`h-14 w-14 ${scheme === "light" ? "dark:hidden" : "hidden dark:block"}`}
            />
          ))}
          <figcaption className="mt-1 w-full truncate text-center font-mono text-[11px] leading-4 text-gray-900">
            {name}
          </figcaption>
        </figure>
      ))}
    </div>
  );
}
