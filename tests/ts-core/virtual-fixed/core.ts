import type { VirtualListRange } from "@native-sdk/core/events";
import { Cmd } from "@native-sdk/core";
export interface Model { readonly count: number }
export type Msg = { readonly kind: "append" } | { readonly kind: "reset" };
export function initialModel(): Model { return { count: 100 }; }
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  return [{ count: msg.kind === "reset" ? 100 : model.count < 1000 ? model.count + 1 : 100 }, Cmd.none];
}
export interface Row { readonly ordinal: number }
export function rows(model: Model, range: VirtualListRange): readonly Row[] {
  const result: Row[] = [];
  const first = range.start_index >= 0 && range.start_index <= 9007199254740991 ? Math.trunc(range.start_index) : 0;
  const last = range.end_index >= first && range.end_index <= 9007199254740991 ? Math.trunc(range.end_index) : first;
  for (let index = first; index < last; index++) result.push({ ordinal: index });
  return result;
}
