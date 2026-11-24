// Property compilation: each area of CSS has its own module in ./properties/. To add a property,
// add a case to the module for its area (or a new module, listed in HANDLERS below).

import type { ContentContext, Decl, FontContext, Loc } from "./types.ts";
import { TABLE_DISPLAY, tableProperty } from "./properties/table.ts";
import { boxProperty } from "./properties/box.ts";
import { flexProperty } from "./properties/flex.ts";
import { bordersProperty } from "./properties/borders.ts";
import { backgroundsProperty } from "./properties/backgrounds.ts";
import { textProperty } from "./properties/text.ts";
import { miscProperty } from "./properties/misc.ts";
import { transformProperty } from "./properties/transform.ts";
import { animationsProperty } from "./properties/animations.ts";
import { effectsProperty } from "./properties/effects.ts";
import { listStyleProperty } from "./lists.ts";
import { imagesProperty } from "./properties/images.ts";
import { gridProperty } from "./properties/grid.ts";
import { multicolProperty } from "./properties/multicol.ts";
import { containProperty } from "./properties/contain.ts";

type Handler = (prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc, content?: ContentContext) => string | null | undefined;
const HANDLERS: Handler[] = [tableProperty, boxProperty, flexProperty, bordersProperty, backgroundsProperty, textProperty, miscProperty, transformProperty, listStyleProperty, imagesProperty, gridProperty, containProperty, animationsProperty, effectsProperty, multicolProperty];

/** Compiles one declaration into numeric declarations. Returns null on success or a warning. */
export function compileProperty(prop: string, value: string, out: Decl[], fonts?: FontContext, loc?: Loc, content?: ContentContext): string | null {
  for (const handle of HANDLERS) {
    const result = handle(prop, value, out, fonts, loc, content);
    if (result === undefined) continue;
    // The box module lists its own display keywords; the table ones are supported too.
    if (prop === "display" && typeof result === "string" && result.endsWith(")") && result.includes("(supported: ")) {
      return result.slice(0, -1) + ", " + Object.keys(TABLE_DISPLAY).join(", ") + ")";
    }
    return result;
  }
  return `'${prop}' is not supported yet; ignored`;
}
