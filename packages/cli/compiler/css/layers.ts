// The cascade layer registry lives with the shared CSS code now: the runtime parses the layers of
// a style sheet a script writes with the same rules the build uses.
export { LayerRegistry } from "../../shared/css/layers.ts";
export type { Layer } from "../../shared/css/layers.ts";
