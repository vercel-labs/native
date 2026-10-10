import { asciiBytes } from "@native-sdk/core";
import type { CanvasChromeCommand, CanvasChromeContext, CanvasColor, CanvasFill, CanvasPathElement } from "@native-sdk/core/events";

export interface Model { readonly phase: number; readonly level: number; }
export type Msg = { readonly kind: "next" } | { readonly kind: "reset" } | { readonly kind: "level"; readonly fraction: number };
export function initialModel(): Model { return { phase: 0, level: 0.5 }; }
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "next": return { ...model, phase: model.phase >= 0 && model.phase < 3 ? Math.trunc(model.phase + 1) : 0 };
    case "reset": return initialModel();
    case "level": return { ...model, level: msg.fraction };
  }
}
export const viewUnbound = ["phase"] as const;

function color(r: number, g: number, b: number, a: number): CanvasColor { return { r, g, b, a }; }
function paint(context: CanvasChromeContext): CanvasFill {
  return { kind: "linear_gradient", start: { x: 0.25, y: 1.5 }, end: { x: 310.75, y: 280.5 }, stops: [
    { offset: 0, color: context.background }, { offset: 0.375, color: color(0.125, 0.5, 0.875, 0.75) }, { offset: 1, color: context.surface },
  ] };
}
function pathElements(level: number): readonly CanvasPathElement[] {
  return [
    { verb: "move_to", first: { x: 180.25, y: 180.5 }, second: { x: 7, y: 8 }, third: { x: 9, y: 10 } },
    { verb: "line_to", first: { x: 225.75, y: 182.25 }, second: { x: 0, y: 0 }, third: { x: 0, y: 0 } },
    { verb: "quad_to", first: { x: 265.5, y: 210.75 }, second: { x: 222.25, y: 246.5 }, third: { x: 11, y: 12 } },
    { verb: "cubic_to", first: { x: 205.25, y: 268.5 }, second: { x: 155.75, y: 246.25 }, third: { x: Math.fround(160.5 + Math.fround(level * 8)), y: 205.5 } },
    { verb: "close", first: { x: 13, y: 14 }, second: { x: 15, y: 16 }, third: { x: 17, y: 18 } },
  ];
}
export function canvasChrome(model: Model, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  if (model.phase === 3) return [];
  const commands: CanvasChromeCommand[] = [
    { kind: "rect", id: asciiBytes("18446744073709551615"), rect: { x: 0, y: 0, width: context.width, height: context.height }, fill: paint(context) },
    { kind: "rounded_rect", id: asciiBytes("9007199254740993"), rect: { x: 20.25, y: 95.5, width: 128.75, height: 120.25 }, radius: 13.5, fill: { kind: "color", color: color(0.875, 0.125, 0.375, 0.75) } },
  ];
  if (model.phase === 1) commands.push({ kind: "line", id: asciiBytes("3"), from: { x: 16.25, y: 232.5 }, to: { x: 300.75, y: 310.5 }, stroke: { width: 3.25, fill: paint(context) } });
  return commands;
}
export function canvasChromeSuffix(model: Model, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  if (model.phase === 2) return [];
  const commands: CanvasChromeCommand[] = [
    { kind: "stroke_rect", id: asciiBytes("4"), rect: { x: 12.5, y: 12.25, width: 380.75, height: 270.5 }, radius: { topLeft: 3.25, topRight: 6.5, bottomRight: 9.75, bottomLeft: 13 }, stroke: { width: 2.5, fill: { kind: "color", color: context.border } } },
    { kind: "fill_path", id: asciiBytes("5"), elements: pathElements(model.level), fill: { kind: "color", color: color(0.25, 0.75, 0.5, 0.5) } },
    { kind: "stroke_path", id: asciiBytes("6"), elements: pathElements(model.level), stroke: { width: 2.75, fill: paint(context) }, cap: "round" },
  ];
  if (model.phase === 1) commands.push({ kind: "stroke_path", id: asciiBytes("7"), elements: [{ verb: "move_to", first: { x: 24.5, y: 260.25 }, second: { x: 0, y: 0 }, third: { x: 0, y: 0 } }, { verb: "line_to", first: { x: 130.25, y: 278.5 }, second: { x: 0, y: 0 }, third: { x: 0, y: 0 } }], stroke: { width: 6.5, fill: { kind: "color", color: color(0.75, 0.5, 0.25, 1) } }, cap: "butt" });
  return commands;
}
