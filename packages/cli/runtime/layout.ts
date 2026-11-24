// Layout: block flow, inline formatting, flexbox and out-of-flow positioning. Sizes are border-box; positions are relative to the parent's border box. Implementation lives in ./layout/.

export { viewport, measure, isOutOfFlow } from "./layout/box-model.ts";
export { fontMetrics, baselineOffset, maxContentWidth, textWidth, spacingPx, letterSpacingPx, wordSpacingPx } from "./layout/text.ts";
export { layoutBox, layoutRoot } from "./layout/box.ts";
export { setIncrementalLayout, layoutCounts } from "./layout/incremental.ts";
export { FRAG_TEXT, FRAG_EDGE, isInlineLevel } from "./layout/inline.ts";
export { offsetParent, offsetLeft, offsetTop, absolutePosition, scrollIntoView, inputIndexAt } from "./layout/geometry.ts";
export { containingBlock } from "./layout/positioned.ts";
export { snapAfterLayout } from "./layout/snap.ts";
