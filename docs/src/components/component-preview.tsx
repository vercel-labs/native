import vocab from "@/lib/component-vocab.json";
import { ComponentPreviewLive } from "@/components/component-preview-live";

const previews = vocab.previews as Record<string, { width: number; height: number }>;

/**
 * A theme-aware, engine-rendered component preview. Server-side (and
 * with JS disabled) this is the light/dark webp pair from
 * /public/components, drawn by the deterministic reference renderer
 * (`zig build docs-component-previews`). In the browser the tile
 * upgrades on hover/click/focus to a LIVE engine instance — the same
 * scene compiled to wasm (`zig build docs-wasm-preview`) — with one
 * canvas that follows the site theme. Dimensions come from the
 * generated vocab JSON, so a renamed or resized scene fails the build
 * here instead of shipping a broken image.
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
      <ComponentPreviewLive name={name} alt={alt} width={dims.width} height={dims.height} />
      {caption ? (
        <figcaption className="mt-2 text-center copy-13 text-gray-900">{caption}</figcaption>
      ) : null}
    </figure>
  );
}
