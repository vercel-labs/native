import Image from "next/image";
import vocab from "@/lib/component-vocab.json";

const previews = vocab.previews as Record<string, { width: number; height: number }>;

/**
 * A theme-aware, engine-rendered component preview: the light and dark
 * webp pair from /public/components (drawn by the deterministic
 * reference renderer; regenerate with `zig build docs-component-previews`),
 * framed like a shadcn preview tile. Dimensions come from the generated
 * vocab JSON, so a renamed or resized scene fails the build here instead
 * of shipping a broken image.
 */
export function ComponentPreview({ name, alt, caption }: { name: string; alt: string; caption?: string }) {
  const dims = previews[name];
  if (!dims) {
    throw new Error(
      `Unknown component preview "${name}" — not in component-vocab.json. Regenerate with: zig build docs-component-previews`,
    );
  }
  return (
    <figure className="my-6">
      <div className="overflow-hidden rounded-md border border-gray-alpha-400 bg-background-100">
        {(["light", "dark"] as const).map((scheme) => (
          <Image
            key={`${name}-${scheme}`}
            src={`/components/${name}-${scheme}.webp`}
            alt={`${alt} (${scheme} theme)`}
            width={dims.width}
            height={dims.height}
            unoptimized
            className={`block h-auto w-full ${scheme === "light" ? "dark:hidden" : "hidden dark:block"}`}
          />
        ))}
      </div>
      {caption ? (
        <figcaption className="mt-2 text-center copy-13 text-gray-900">{caption}</figcaption>
      ) : null}
    </figure>
  );
}
