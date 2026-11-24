// CSS parsing and value compilation, all at build time; the runtime only sees numeric declarations. Implementation lives in ./css/ for the selector and style-sheet parser, and in ../shared/css/ for the value parsing the runtime shares.

export { GENERIC_FAMILIES, COMB_DESCENDANT, COMB_CHILD, COMB_ADJACENT, COMB_GENERAL } from "./css/types.ts";
export type { Decl, FontContext, ContentContext, CounterStyleContext, KeyframesContext, Compound, ChainLink, Selector, CssRule, PropertyRule } from "./css/types.ts";
export { parseCss } from "./css/parse.ts";
export { encodeCompound, compoundStates, parseSelector, ATTR_SEP } from "./css/selectors.ts";
export { compileDeclarations } from "./css/declarations.ts";
export { parseLength } from "../shared/css/declarations.ts";
export { firstFamily, scanFontFaces, scanFontFeatureValues, scanPaletteValues, fontPalettes, fontFileWeight } from "./css/fonts.ts";
export { scanNamespaces, setSelectorNamespaces } from "../shared/css/selectors.ts";
export type { FontFaceDecl, FontPaletteDecl } from "./css/fonts.ts";
export { pack, parseColor } from "../shared/css/colors.ts";
