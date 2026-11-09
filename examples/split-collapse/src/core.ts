import { Cmd, asciiBytes } from "@native-sdk/core";
import type { ColorScheme, FrameEvent, LayoutTween, ExactWebViewPane } from "@native-sdk/core/events";
import { zeroClock, parseClock, clockZero, clockNumber, clockSubtract, clockDecimal } from "./clock.ts";

export interface Tween {
  readonly from: number; readonly to: number; readonly start_ns: Uint8Array;
}
export interface Model {
  readonly color_scheme: ColorScheme; readonly reduce_motion: boolean; readonly high_contrast: boolean;
  readonly collapsed: boolean; readonly fraction: number; readonly tween: Tween | null;
  readonly tween_frame_count: number; readonly last_frame_ns: Uint8Array;
  readonly manual_requested: boolean; readonly markup_mode: boolean; readonly web_enabled: boolean;
}
export type TimerOutcome = "fired" | "rejected";
export type Msg =
  | { readonly kind: "toggle" }
  | { readonly kind: "auto_toggle"; readonly key: Uint8Array; readonly timestampNs: Uint8Array; readonly outcome: TimerOutcome }
  | { readonly kind: "frame_tick"; readonly timestamp: Uint8Array }
  | { readonly kind: "split_resized"; readonly fraction: number }
  | { readonly kind: "set_appearance"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "configure_manual"; readonly value: Uint8Array }
  | { readonly kind: "configure_markup"; readonly value: Uint8Array }
  | { readonly kind: "configure_web"; readonly value: Uint8Array }
  | { readonly kind: "configure_auto"; readonly value: Uint8Array };
export const appearanceMsg = "set_appearance";
export const envMsgs = [
  { env: "SPLIT_COLLAPSE_MANUAL", msg: "configure_manual" },
  { env: "SPLIT_COLLAPSE_MARKUP", msg: "configure_markup" },
  { env: "SPLIT_COLLAPSE_WEB", msg: "configure_web" },
  { env: "SPLIT_COLLAPSE_AUTO_MS", msg: "configure_auto" },
] as const;
export const viewUnbound = ["color_scheme", "reduce_motion", "high_contrast", "collapsed", "tween", "tween_frame_count", "last_frame_ns", "manual_requested", "web_enabled", "frame_tick", "auto_toggle", "configure_auto", "layoutTweens", "webPanes"] as const;

export function initialModel(): Model {
  return { color_scheme: "light", reduce_motion: false, high_contrast: false, collapsed: false,
    fraction: Math.fround(0.35), tween: null, tween_frame_count: 0, last_frame_ns: zeroClock(),
    manual_requested: false, markup_mode: false, web_enabled: false };
}
export function manual_mode(model: Model): boolean { return model.manual_requested && !model.markup_mode; }
export function pane_fraction(model: Model): number { return Math.fround(model.collapsed ? 0.06 : 0.35); }
export function toggle_label(model: Model): Uint8Array { return asciiBytes(model.collapsed ? "Expand sidebar" : "Collapse sidebar"); }
export function content_hint(model: Model): Uint8Array {
  return asciiBytes(model.collapsed ? "The sidebar is collapsed; this pane reflowed to fill the width." : "The sidebar is expanded; drag the divider or press the button.");
}
export function mode_label(model: Model): Uint8Array { return asciiBytes(model.markup_mode ? "markup tween" : manual_mode(model) ? "manual ticks" : "runtime tween"); }
export function split_value(model: Model): number { return model.markup_mode ? pane_fraction(model) : model.fraction; }
export function resize_duration(model: Model): number { return model.markup_mode ? 180 : 0; }
export function frameMsg(model: Model, frame: FrameEvent): Msg | null {
  return model.tween === null ? null : { kind: "frame_tick", timestamp: frame.timestampNs };
}
export function layoutTweens(model: Model): readonly LayoutTween[] {
  return manual_mode(model) || model.markup_mode ? [] : [{ label: null, index: 0, to: pane_fraction(model), durationMs: 180, easing: "standard" }];
}
export function webPanes(model: Model): readonly ExactWebViewPane[] {
  return model.web_enabled ? [{ label: asciiBytes("content-web"), anchor: asciiBytes("content-web-pane"), x: 0, y: 0, width: 0, height: 0, url: asciiBytes("https://example.com"), reloadToken: asciiBytes("0") }] : [];
}
function enabled(value: Uint8Array): boolean { return value.length !== 1 || value[0] !== 48; }
function ease(t: number): number {
  if (t < 0.5) return Math.fround(Math.fround(Math.fround(4 * t) * t) * t);
  const back = Math.fround(Math.fround(-2 * t) + 2);
  return Math.fround(1 - Math.fround(Math.fround(Math.fround(back * back) * back) / 2));
}
function toggle(model: Model): Model {
  const collapsed = !model.collapsed;
  return manual_mode(model) ? { ...model, collapsed, tween: { from: model.fraction, to: Math.fround(collapsed ? 0.06 : 0.35), start_ns: zeroClock() }, tween_frame_count: 0, last_frame_ns: zeroClock() } : { ...model, collapsed };
}
export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "toggle": case "auto_toggle": return toggle(model);
    case "configure_manual": return { ...model, manual_requested: enabled(msg.value) };
    case "configure_markup": return { ...model, markup_mode: enabled(msg.value) };
    case "configure_web": return { ...model, web_enabled: enabled(msg.value) };
    case "configure_auto": {
      const interval = parseClock(msg.value);
      if (clockZero(interval)) return model;
      return [model, Cmd.timerResultExact("auto", clockDecimal(interval), "repeating", { result: "auto_toggle" })];
    }
    case "set_appearance": return { ...model, color_scheme: msg.colorScheme, reduce_motion: msg.reduceMotion, high_contrast: msg.highContrast };
    case "split_resized": {
      if (model.tween !== null) return model;
      const fraction = Math.fround(msg.fraction);
      const next = { ...model, fraction };
      if (!manual_mode(model) && fraction !== model.fraction) return [next, Cmd.host("native-sdk.debug.log", asciiBytes(`tween-echo fraction=${fraction.toFixed(3)}\n`))];
      return next;
    }
    case "frame_tick": {
      if (model.tween === null) return model;
      const timestamp = parseClock(msg.timestamp), tween = model.tween;
      const start = clockZero(tween.start_ns) ? timestamp : tween.start_ns;
      const elapsed = clockNumber(clockSubtract(timestamp, start));
      const count = (model.tween_frame_count + 1) % 4294967296;
      const dt = clockZero(model.last_frame_ns) ? asciiBytes("start") : asciiBytes((clockNumber(clockSubtract(timestamp, model.last_frame_ns)) / 1000000).toFixed(1));
      const prefix = asciiBytes("tween-frame dt_ms="), suffix = asciiBytes(` fraction=${model.fraction.toFixed(3)}\n`);
      const trace = new Uint8Array(prefix.length + dt.length + suffix.length);
      trace.set(prefix); trace.set(dt, prefix.length); trace.set(suffix, prefix.length + dt.length);
      if (elapsed >= 180000000) return [{ ...model, fraction: tween.to, tween: null, tween_frame_count: count, last_frame_ns: timestamp }, Cmd.batch([Cmd.host("native-sdk.debug.log", trace), Cmd.host("native-sdk.debug.log", asciiBytes(`tween-done frames=${count}\n`))])];
      const t = Math.fround(Math.fround(elapsed) / Math.fround(180000000));
      const fraction = Math.fround(tween.from + Math.fround(Math.fround(tween.to - tween.from) * ease(t)));
      return [{ ...model, fraction, tween: { ...tween, start_ns: start }, tween_frame_count: count, last_frame_ns: timestamp }, Cmd.host("native-sdk.debug.log", trace)];
    }
  }
}
