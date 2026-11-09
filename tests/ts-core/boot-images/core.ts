import { Cmd, asciiBytes } from "@native-sdk/core";
import type { BootImageResult } from "@native-sdk/core/events";

export interface Report { readonly id: Uint8Array; readonly registered: boolean; readonly width: number; readonly height: number; readonly errorName: Uint8Array; }
export interface Model {
  readonly reports: readonly Report[];
  readonly booted: boolean;
  readonly bootReportCount: number;
}
export type Msg =
  | { readonly kind: "image"; readonly id: Uint8Array; readonly registered: boolean; readonly width: number; readonly height: number; readonly errorName: Uint8Array }
  | { readonly kind: "ignore" }
  | { readonly kind: "booted"; readonly milliseconds: number };
export type ImageMsg =
  | { readonly kind: "image"; readonly id: Uint8Array; readonly registered: boolean; readonly width: number; readonly height: number; readonly errorName: Uint8Array }
  | { readonly kind: "ignore" };
export function initialModel(): [Model, Cmd<Msg>] {
  return [{ reports: [], booted: false, bootReportCount: 0 }, Cmd.now("booted")];
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "image": return { ...model, reports: [...model.reports, { id: msg.id, registered: msg.registered, width: msg.width, height: msg.height, errorName: msg.errorName }] };
    case "ignore": return model;
    case "booted": {
      const count = model.reports.length;
      return { ...model, booted: true, bootReportCount: count >= 0 && count <= 4294967295 ? Math.trunc(count) : 0 };
    }
  }
}
export function bootImageMsg(model: Model, result: BootImageResult): ImageMsg | null {
  if (result.id.length === 2 && result.id[0] === 52 && result.id[1] === 49) return null;
  return { kind: "image", id: result.id, registered: result.registered, width: result.width, height: result.height, errorName: result.errorName };
}
export function reportCount(model: Model): number { return model.bootReportCount; }
export const viewUnbound = ["reports", "booted", "bootReportCount", "reportCount", "image", "ignore", "booted"] as const;
