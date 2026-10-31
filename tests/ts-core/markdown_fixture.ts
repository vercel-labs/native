import { Cmd, asciiBytes } from "@native-sdk/core";

export interface ResolvedImage {
  readonly source: Uint8Array;
  readonly image: number;
  readonly width: number;
  readonly height: number;
}
export interface Model {
  readonly body: Uint8Array;
  readonly issue: Uint8Array;
  readonly expanded: readonly boolean[];
  readonly images: readonly ResolvedImage[];
  readonly lastLink: Uint8Array;
}
export type Msg =
  | { readonly kind: "open_url"; readonly url: Uint8Array }
  | { readonly kind: "toggle_details"; readonly index: number }
  | { readonly kind: "reset" };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ body: asciiBytes("# Document\n[go](target)\n<details>\n<summary>More</summary>\nbody\n</details>"), issue: asciiBytes("issue://"), expanded: [false, true], images: [{ source: asciiBytes("asset"), image: 1, width: 240.25, height: 120.125 }], lastLink: asciiBytes("") }, Cmd.none];
}
export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
  if (msg.kind === "reset") return initialModel();
  if (msg.kind === "open_url") return [{ ...model, lastLink: msg.url }, Cmd.persist()];
  const expanded: boolean[] = [];
  for (let i = 0; i < model.expanded.length; i++) expanded.push(i === msg.index ? !model.expanded[i] : model.expanded[i]!);
  return [{ ...model, expanded }, Cmd.persist()];
}
export const viewUnbound = ["lastLink", "reset"] as const;
