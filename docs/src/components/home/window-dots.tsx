/**
 * The site-drawn macOS stoplights for showcase captures.
 *
 * Showcase apps own their chrome: each header IS its titlebar, laid out
 * around the traffic lights through the engine's window-chrome channel.
 * The captures are rendered offscreen by the deterministic engine
 * renderer — no OS chrome by construction — with the screenshot harness
 * dispatching the standard macOS inset geometry first, so every header
 * reserves the exact gap real lights would occupy. This overlay draws
 * dots-only into that reserved gap; the full CSS titlebar band stays
 * with the component-preview tiles, whose scenes have no chrome of
 * their own.
 *
 * Coordinate derivation — the same numbers the harnesses dispatch
 * (`.insets = .{ .top = 52, .left = 78 }, .buttons = RectF(20, 19, 52, 14)`
 * in each example's homepage-shots test), so the two cannot drift:
 *
 * - tall (`hidden_inset_tall`, the ~52pt unified-toolbar band): button
 *   cluster at (20, 19), 52x14 — three 14pt dots with 5pt gaps
 *   (3x14 + 2x5 = 52), vertically centered in the band ((52-14)/2 = 19).
 * - compact (`hidden_inset`, the ~28pt band — calculator, whose fixed
 *   16pt window padding + 24pt drag band clears it by construction):
 *   the same 52x14 cluster at the compact leading margin and centerline,
 *   (7, (28-14)/2 = 7).
 *
 * All geometry is emitted as percentages of the capture's logical size,
 * so the dots scale with the displayed image at any width. The parent
 * must be `position: relative` around the capture's <Image>.
 */

const clusters = {
  tall: { x: 20, y: 19, w: 52, h: 14 },
  compact: { x: 7, y: 7, w: 52, h: 14 },
} as const;

export type WindowDotsVariant = keyof typeof clusters;

interface WindowDotsProps {
  /** The capture's logical (1x) size in engine points — file pixels / 2. */
  width: number;
  height: number;
  variant?: WindowDotsVariant;
}

export function WindowDots({ width, height, variant = "tall" }: WindowDotsProps) {
  const cluster = clusters[variant];
  return (
    <span
      aria-hidden
      className="pointer-events-none absolute flex items-center justify-between"
      style={{
        left: `${(cluster.x / width) * 100}%`,
        top: `${(cluster.y / height) * 100}%`,
        width: `${(cluster.w / width) * 100}%`,
        aspectRatio: `${cluster.w} / ${cluster.h}`,
      }}
    >
      {/* justify-between over three h-full circles reproduces the 5pt
          gaps exactly: (52 - 3x14) / 2 = 5. Same neutral dot register
          as the component-preview titlebar band. */}
      <span className="aspect-square h-full rounded-full bg-gray-500" />
      <span className="aspect-square h-full rounded-full bg-gray-500" />
      <span className="aspect-square h-full rounded-full bg-gray-500" />
    </span>
  );
}
