import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { FrameEvent, StatusItemState, WebViewPane } from "@native-sdk/core/events";

export type Page = "example" | "docs";
export interface Model {
  readonly page: Page;
  readonly reload_token: number;
  readonly reload_count: number;
  readonly gpu_frames_seen: boolean;
}
export type Msg =
  | { readonly kind: "show_example" }
  | { readonly kind: "show_docs" }
  | { readonly kind: "reload" }
  | { readonly kind: "frame_presented" };
export const viewUnbound = ["reload_token"] as const;
export function initialModel(): Model {
  return { page: "example", reload_token: 0, reload_count: 0, gpu_frames_seen: false };
}
export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "show_example": return { ...model, page: "example" };
    case "show_docs": return { ...model, page: "docs" };
    case "reload": {
      return { ...model, reload_token: model.reload_token + 1, reload_count: (model.reload_count + 1) >>> 0 };
    }
    case "frame_presented": return { ...model, gpu_frames_seen: true };
  }
}
function pageUrl(page: Page): Uint8Array {
  return page === "example" ? asciiBytes("https://example.com/") : asciiBytes("https://native-sdk.dev/");
}
export function urlLabel(model: Model): Uint8Array { return asciiBytes(model.page === "example" ? "URL: https://example.com/" : "URL: https://native-sdk.dev/"); }
export function reloadLabel(model: Model): Uint8Array { return utf8Bytes(`Reloads: ${model.reload_count}`); }
export function presentingLabel(model: Model): Uint8Array {
  return model.gpu_frames_seen ? utf8Bytes("canvas presenting + webview live") : utf8Bytes("waiting for first frame");
}
export type PageVariant = "primary" | "secondary";
export function exampleVariant(model: Model): PageVariant { return model.page === "example" ? "primary" : "secondary"; }
export function docsVariant(model: Model): PageVariant { return model.page === "docs" ? "primary" : "secondary"; }
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  return model.gpu_frames_seen ? null : { kind: "frame_presented" };
}
export function commandMsg(name: string): Msg | null {
  if (name === "app.example") return { kind: "show_example" };
  if (name === "app.docs") return { kind: "show_docs" };
  if (name === "app.reload") return { kind: "reload" };
  return null;
}
export function webPanes(model: Model): readonly WebViewPane[] {
  return [{ label: asciiBytes("preview"), anchor: asciiBytes("preview-pane"), x: 0, y: 0,
    width: 0, height: 0, url: pageUrl(model.page), reloadToken: model.reload_token }];
}
export function statusItem(model: Model): StatusItemState {
  return { iconPath: asciiBytes(""), tooltip: utf8Bytes("Native SDK Canvas Preview"),
    activationCommand: asciiBytes(""), alternateActivationCommand: asciiBytes(""), openCommand: asciiBytes(""),
    presentation: { title: asciiBytes("NS"), width: 0, tone: "normal", iconOpacity: 1, monospaced: false, fontSize: 0 },
    items: [
      { id: 1, label: utf8Bytes("Show Example"), command: asciiBytes("app.example"), separator: false,
        enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""),
        modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 2, label: utf8Bytes("Show Docs"), command: asciiBytes("app.docs"), separator: false,
        enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""),
        modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 0, label: asciiBytes(""), command: asciiBytes(""), separator: true,
        enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""),
        modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
      { id: 3, label: utf8Bytes("Reload Preview"), command: asciiBytes("app.reload"), separator: false,
        enabled: true, detail: asciiBytes(""), role: "command", key: asciiBytes(""),
        modifiers: { primary: false, command: false, control: false, option: false, shift: false } },
    ] };
}
