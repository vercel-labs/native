import Image from "next/image";
import Link from "next/link";
import vocab from "@/lib/component-vocab.json";
import { componentPages } from "@/lib/components-pages";

const previews = vocab.previews as Record<string, { width: number; height: number }>;

/**
 * The Components index: a docs-catalog grid of engine-rendered
 * preview tiles, one per component page, driven by the shared
 * components-pages inventory.
 */
export function ComponentIndexGrid() {
  return (
    <div className="my-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      {componentPages.map((page) => {
        const dims = previews[page.preview];
        if (!dims) {
          throw new Error(
            `Unknown preview tile "${page.preview}" for /components/${page.slug} — regenerate with: zig build docs-component-previews`,
          );
        }
        return (
          <Link
            key={page.slug}
            href={`/components/${page.slug}`}
            className="group block rounded-md border border-gray-alpha-400 bg-background-100 transition-colors hover:border-gray-alpha-500"
          >
            {/* Letterbox bands match the engine's background tokens
                (#fff light, #0a0a0a dark) so contained tiles read as one
                seamless surface. */}
            <div className="flex aspect-[16/9] items-center justify-center overflow-hidden rounded-t-md border-b border-gray-alpha-400 bg-white dark:bg-[#0a0a0a]">
              {(["light", "dark"] as const).map((scheme) => (
                <Image
                  key={`${page.slug}-${scheme}`}
                  src={`/components/${page.preview}-${scheme}.webp`}
                  alt={`The ${page.name} component rendered by the engine (${scheme} theme)`}
                  width={dims.width}
                  height={dims.height}
                  unoptimized
                  className={`h-full w-full object-contain ${scheme === "light" ? "dark:hidden" : "hidden dark:block"}`}
                />
              ))}
            </div>
            <div className="px-4 py-3">
              <div className="copy-14 font-medium text-gray-1000">{page.name}</div>
              <div className="mt-0.5 copy-13 text-gray-900">{page.blurb}</div>
            </div>
          </Link>
        );
      })}
    </div>
  );
}
