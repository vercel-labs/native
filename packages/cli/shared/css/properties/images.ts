// CSS Images properties that size and scale replaced content: object-fit, object-position,
// image-rendering and image-orientation, which decides whether an image's EXIF rotation is
// applied. The paint code fits an image into the content box with them.

import * as P from "../../props.ts";
import { kw } from "../declarations.ts";
import { parsePosition, positionRows } from "../position.ts";
import type { Decl } from "../types.ts";

export function imagesProperty(prop: string, value: string, out: Decl[]): string | null | undefined {
  switch (prop) {
    case "object-fit":
      return kw(prop, value, {
        fill: P.OF_FILL, contain: P.OF_CONTAIN, cover: P.OF_COVER, none: P.OF_NONE, "scale-down": P.OF_SCALE_DOWN,
      }, P.P_OBJECT_FIT, out);
    case "object-position": {
      const pos = parsePosition(value, prop);
      if (typeof pos === "string") return pos;
      out.push({ p: P.P_OBJECT_POSITION, v: positionRows.register(pos), u: P.U_LIST });
      return null;
    }
    case "image-rendering":
      // `crisp-edges` and `pixelated` both ask for no interpolation here; CoreGraphics' nearest
      // neighbour is what each one wants when an image is scaled up.
      return kw(prop, value, {
        auto: P.IR_AUTO, pixelated: P.IR_PIXELATED, "crisp-edges": P.IR_CRISP_EDGES,
      }, P.P_IMAGE_RENDERING, out);
    case "image-orientation":
      // CSS Images 3 allows `from-image` and `none`; the deprecated <angle> values are not
      // supported.
      return kw(prop, value, { "from-image": P.IO_FROM_IMAGE, none: P.IO_NONE }, P.P_IMAGE_ORIENTATION, out);
    default:
      return undefined;
  }
}
