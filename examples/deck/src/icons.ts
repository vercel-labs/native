import { asciiBytes } from "@native-sdk/core";
import type { CanvasIconDefinition, CanvasIconShape, CanvasPathElement, CanvasPathVerb, CanvasPoint } from "@native-sdk/core/events";

function point(x: number, y: number): CanvasPoint { return { x: Math.fround(x), y: Math.fround(y) }; }
function path(verb: CanvasPathVerb, first: CanvasPoint, second: CanvasPoint, third: CanvasPoint): CanvasPathElement {
  return { verb, first, second, third };
}
const zero: CanvasPoint = { x: 0, y: 0 };
const kappa = Math.fround(0.5522847498307936);
const stop: readonly CanvasPathElement[] = [
  path("move_to", point(7, 6), zero, zero),
  path("line_to", point(17, 6), zero, zero),
  path("cubic_to", point(17 + kappa, 6), point(18, 7 - kappa), point(18, 7)),
  path("line_to", point(18, 17), zero, zero),
  path("cubic_to", point(18, 17 + kappa), point(17 + kappa, 18), point(17, 18)),
  path("line_to", point(7, 18), zero, zero),
  path("cubic_to", point(7 - kappa, 18), point(6, 17 + kappa), point(6, 17)),
  path("line_to", point(6, 7), zero, zero),
  path("cubic_to", point(6, 7 - kappa), point(7 - kappa, 6), point(7, 6)),
  path("close", zero, zero, zero),
];
const minimize: readonly CanvasPathElement[] = [
  path("move_to", point(5, 12), zero, zero),
  path("line_to", point(19, 12), zero, zero),
];
function stroke(count: number): CanvasIconShape {
  const elementCount = count >= 0 && count <= 512 ? Math.trunc(count) : 0;
  return { start: 0, count: elementCount, fill: { kind: "none" }, stroke: { kind: "current_color" }, strokeWidth: 2, linecap: "round", linejoin: "round" };
}
const definitions: readonly CanvasIconDefinition[] = [
  { name: asciiBytes("stop"), viewBox: { x: 0, y: 0, width: 24, height: 24 }, elements: stop, shapes: [stroke(10)] },
  { name: asciiBytes("minimize"), viewBox: { x: 0, y: 0, width: 24, height: 24 }, elements: minimize, shapes: [stroke(2)] },
];
export function deckIcons(): readonly CanvasIconDefinition[] { return definitions; }
