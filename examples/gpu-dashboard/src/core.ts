import { asciiBytes, utf8Bytes } from "@native-sdk/core";
import type { CanvasAnimation, CanvasChromeCommand, CanvasChromeContext, CanvasColor, CanvasFrameEvent, CanvasFrameRisk, ChromeButtons, ChromeInsets, ColorScheme, ScrollState, ThemeState } from "@native-sdk/core/events";
import type { ThemeDesignTokenOverrides } from "@native-sdk/core/theme";

export interface Model {
  readonly refresh_count: number;
  readonly perf_animation_armed: boolean;
  readonly mode_count: number;
  readonly live_count: number;
  readonly nav_selection: number;
  readonly metric_selection: number | null;
  readonly activity_selection: number | null;
  readonly filter_selection: number | null;
  readonly auto_refresh: boolean;
  readonly confidence: number;
  readonly activity_scroll: number;
  readonly chrome_leading: number;
  readonly color_scheme: ColorScheme;
  readonly reduce_motion: boolean;
  readonly high_contrast: boolean;
  readonly reported_planned_frame: boolean;
  readonly status_storage: Uint8Array;
  readonly status_len: number;
}

export type FrameStatus = {
  readonly risk: CanvasFrameRisk;
  readonly work_units: Uint8Array;
  readonly commands: Uint8Array;
  readonly batches: Uint8Array;
  readonly representable: boolean;
  readonly dirty_ratio: number;
};
// A helper exports its result subset, sharing the dispatch payload's exact
// record rather than exporting the entire dispatch union a second time.
export type FrameMsg =
  | { readonly kind: "frame_status"; readonly frame: FrameStatus }
  | { readonly kind: "refresh" };

export type Msg =
  | { readonly kind: "refresh" }
  | { readonly kind: "perf_animation" }
  | { readonly kind: "perf_animation_stop" }
  | { readonly kind: "set_mode" }
  | { readonly kind: "toggle_live" }
  | { readonly kind: "select_nav"; readonly index: number }
  | { readonly kind: "select_metric"; readonly index: number }
  | { readonly kind: "select_activity"; readonly index: number }
  | { readonly kind: "toggle_auto" }
  | { readonly kind: "confidence_changed"; readonly value: number }
  | { readonly kind: "select_filter"; readonly index: number }
  | { readonly kind: "open_deployment" }
  | { readonly kind: "submit_forecast" }
  | { readonly kind: "submit_search" }
  | { readonly kind: "activity_scrolled"; readonly state: ScrollState }
  | { readonly kind: "set_appearance"; readonly colorScheme: ColorScheme; readonly reduceMotion: boolean; readonly highContrast: boolean }
  | { readonly kind: "chrome_changed"; readonly insets: ChromeInsets; readonly buttons: ChromeButtons; readonly tabsProjected: boolean }
  | { readonly kind: "frame_status"; readonly frame: FrameStatus };

export const appearanceMsg = "set_appearance";
export const chromeMsg = "chrome_changed";
export const viewUnbound = ["refresh_count", "mode_count", "live_count", "perf_animation_armed", "color_scheme", "reduce_motion", "high_contrast", "reported_planned_frame", "status_storage", "status_len", "perf_animation", "perf_animation_stop", "set_appearance", "chrome_changed", "frame_status"] as const;

export function initialModel(): Model {
  return { refresh_count: 0, perf_animation_armed: false, mode_count: 0, live_count: 0, nav_selection: 0, metric_selection: null, activity_selection: null, filter_selection: null, auto_refresh: true, confidence: Math.fround(0.62), activity_scroll: 18, chrome_leading: 0, color_scheme: "light", reduce_motion: false, high_contrast: false, reported_planned_frame: false, status_storage: new Uint8Array(192), status_len: 0 };
}

function joined(parts: readonly Uint8Array[]): Uint8Array {
  let length = 0;
  for (const part of parts) length += part.length;
  const out = new Uint8Array(length);
  let at = 0;
  for (const part of parts) { out.set(part, at); at += part.length; }
  return out;
}
function withStatus(model: Model, text: Uint8Array): Model {
  const storage = model.status_storage.slice();
  const raw = text.length;
  const length = raw >= 0 && raw <= 192 ? Math.trunc(raw) : 192;
  for (let i = 0; i < length; i++) storage[i] = text[i];
  return { ...model, status_storage: storage, status_len: length };
}
function dirtyPercent(ratio: number): Uint8Array {
  const percent = Math.round(Math.fround(Math.fround(Math.max(0, Math.min(1, Math.fround(ratio)))) * 100));
  return asciiBytes(`${percent}`);
}
export function status(model: Model): Uint8Array {
  if (model.status_len === 0) return utf8Bytes("Canvas scene waiting for the first GPU frame.");
  return model.status_storage.subarray(0, model.status_len);
}
export function auto_refresh_value(model: Model): number { return model.auto_refresh ? 1 : 0; }

type DashboardOverflow = { readonly kind: "counter_overflow" };

export function update(model: Model, msg: Msg): Model {
  switch (msg.kind) {
    case "refresh": {
      if (!(model.refresh_count >= 0 && model.refresh_count < 4294967295)) throw { kind: "counter_overflow" } as DashboardOverflow;
      const refresh_count = model.refresh_count >= 0 && model.refresh_count < 4294967295 ? Math.trunc(model.refresh_count) + 1 : 0;
      return withStatus({ ...model, refresh_count }, utf8Bytes(`Dashboard canvas refreshed. Count ${refresh_count}.`));
    }
    case "perf_animation": return withStatus({ ...model, perf_animation_armed: true }, utf8Bytes("Retained animation performance probe armed."));
    case "perf_animation_stop": return withStatus({ ...model, perf_animation_armed: false }, utf8Bytes("Retained animation performance probe stopped."));
    case "set_mode": {
      if (!(model.mode_count >= 0 && model.mode_count < 4294967295)) throw { kind: "counter_overflow" } as DashboardOverflow;
      const mode_count = model.mode_count >= 0 && model.mode_count < 4294967295 ? Math.trunc(model.mode_count) + 1 : 0;
      return withStatus({ ...model, mode_count }, utf8Bytes(`Dashboard mode changed. Count ${mode_count}.`));
    }
    case "toggle_live": {
      if (!(model.live_count >= 0 && model.live_count < 4294967295)) throw { kind: "counter_overflow" } as DashboardOverflow;
      const live_count = model.live_count >= 0 && model.live_count < 4294967295 ? Math.trunc(model.live_count) + 1 : 0;
      return withStatus({ ...model, live_count }, utf8Bytes(`Live render pulse restarted. Count ${live_count}.`));
    }
    case "select_nav": return withStatus({ ...model, nav_selection: msg.index }, joined([utf8Bytes("Selected "), nav_entries[msg.index].title, asciiBytes(".")]));
    case "select_metric": return withStatus({ ...model, metric_selection: msg.index }, joined([utf8Bytes("Metric highlighted: "), metric_entries[msg.index].title, asciiBytes(".")]));
    case "select_activity": return withStatus({ ...model, activity_selection: msg.index }, joined([utf8Bytes("Activity noted: "), activity_entries[msg.index].title, asciiBytes(".")]));
    case "toggle_auto": return withStatus({ ...model, auto_refresh: !model.auto_refresh }, model.auto_refresh ? utf8Bytes("Auto refresh off.") : utf8Bytes("Auto refresh on."));
    case "confidence_changed": {
      const confidence = Math.fround(msg.value);
      return withStatus({ ...model, confidence }, joined([utf8Bytes("Confidence threshold "), dirtyPercent(confidence), asciiBytes("%.")]));
    }
    case "select_filter": return withStatus({ ...model, filter_selection: msg.index }, joined([utf8Bytes("Filter "), filter_entries[msg.index].title, asciiBytes(" applied.")]));
    case "open_deployment": return withStatus(model, utf8Bytes("Deployment iad1 latency opened."));
    case "activity_scrolled": return { ...model, activity_scroll: Math.fround(msg.state.offsetY) };
    case "submit_forecast": return withStatus(model, utf8Bytes("Forecast amount submitted."));
    case "submit_search": return withStatus(model, utf8Bytes("Segment search submitted."));
    case "chrome_changed": return { ...model, chrome_leading: Math.fround(msg.insets.left) };
    case "set_appearance": {
      const changed = model.color_scheme !== msg.colorScheme || model.reduce_motion !== msg.reduceMotion || model.high_contrast !== msg.highContrast;
      const next: Model = { ...model, color_scheme: msg.colorScheme, reduce_motion: msg.reduceMotion, high_contrast: msg.highContrast };
      return changed ? withStatus(next, utf8Bytes(`Dashboard theme: ${msg.colorScheme} from system appearance.`)) : next;
    }
    case "frame_status": return withStatus({ ...model, reported_planned_frame: true }, joined([utf8Bytes(`Canvas frame: ${msg.frame.risk} risk, `), msg.frame.work_units, utf8Bytes(" work units, "), msg.frame.commands, utf8Bytes(" commands, "), msg.frame.batches, msg.frame.representable ? utf8Bytes(" batches, packet ok, dirty ") : utf8Bytes(" batches, packet fallback, dirty "), dirtyPercent(msg.frame.dirty_ratio), asciiBytes("%.")]));
  }
}

export interface DashboardEntry { readonly index: number; readonly title: Uint8Array; readonly selected: boolean; }
const nav_entries: readonly DashboardEntry[] = [{ index: 0, selected: false, title: utf8Bytes("Overview") }, { index: 1, selected: false, title: utf8Bytes("Customers") }, { index: 2, selected: false, title: utf8Bytes("Latency") }];
const metric_entries: readonly DashboardEntry[] = [{ index: 0, selected: false, title: utf8Bytes("ARR $12.8M, up 18.4%") }, { index: 1, selected: false, title: utf8Bytes("Activation 74.2%, up 6.1%") }];
const activity_entries: readonly DashboardEntry[] = [{ index: 0, selected: false, title: utf8Bytes("Enterprise renewal") }, { index: 1, selected: false, title: utf8Bytes("EU usage spike") }, { index: 2, selected: false, title: utf8Bytes("Latency recovered") }, { index: 3, selected: false, title: utf8Bytes("Queued invoices") }];
const filter_entries: readonly DashboardEntry[] = [{ index: 0, selected: false, title: utf8Bytes("Last 30 days") }, { index: 1, selected: false, title: utf8Bytes("Enterprise") }, { index: 2, selected: false, title: utf8Bytes("High intent") }];
export function navEntries(model: Model): readonly DashboardEntry[] { return nav_entries.map(entry => ({ index: entry.index, title: entry.title, selected: entry.index === model.nav_selection })); }
export function metricEntries(model: Model): readonly DashboardEntry[] { return metric_entries.map(entry => ({ index: entry.index, title: entry.title, selected: entry.index === model.metric_selection })); }
export function activityEntries(model: Model): readonly DashboardEntry[] { return activity_entries.map(entry => ({ index: entry.index, title: entry.title, selected: entry.index === model.activity_selection })); }
export function filterEntries(model: Model): readonly DashboardEntry[] { return filter_entries.map(entry => ({ index: entry.index, title: entry.title, selected: entry.index === model.filter_selection })); }

export function commandMsg(name: string): Msg | null {
  if (name === "dashboard.refresh") return { kind: "refresh" };
  if (name === "dashboard.mode") return { kind: "set_mode" };
  if (name === "dashboard.perf-animation") return { kind: "perf_animation" };
  if (name === "dashboard.perf-animation-stop") return { kind: "perf_animation_stop" };
  return null;
}
export function canvasFrameMsg(model: Model, frame: CanvasFrameEvent): FrameMsg | null {
  if (model.reported_planned_frame || (frame.commands.length === 1 && frame.commands[0] === 48)) return null;
  return { kind: "frame_status", frame: { risk: frame.risk, work_units: frame.workUnits, commands: frame.commands, batches: frame.batches, representable: frame.representable, dirty_ratio: frame.dirtyRatio } };
}
export function themeState(model: Model): ThemeState {
  return { colorScheme: model.color_scheme, highContrast: model.high_contrast, reduceMotion: model.reduce_motion };
}
export function tokenOverrides(model: Model): ThemeDesignTokenOverrides {
  if (model.reduce_motion) return { blur: { sm: 8, md: 14 }, pixel_snap: { geometry: true, text: true } };
  return { blur: { sm: 8, md: 14 }, motion: { slow_ms: 900, easing: "emphasized" }, pixel_snap: { geometry: true, text: true } };
}

function rgb(r: number, g: number, b: number): CanvasColor {
  return { r: Math.fround(r / 255), g: Math.fround(g / 255), b: Math.fround(b / 255), a: 1 };
}
export function canvasChrome(model: Model, context: CanvasChromeContext): readonly CanvasChromeCommand[] {
  const invalid = context.width <= 0 || context.height <= 0;
  const width = invalid ? 1240 : Math.max(1, context.width);
  const height = invalid ? 780 : Math.max(1, context.height);
  const statusHeight = Math.min(34, Math.max(0, Math.fround(height - 1)));
  const contentY = Math.min(54, Math.max(0, Math.fround(Math.fround(height - statusHeight) - 1)));
  const contentHeight = Math.max(1, Math.fround(Math.fround(height - contentY) - statusHeight));
  const heroY = Math.fround(contentY + 38);
  const heroHeight = Math.max(444, Math.fround(contentHeight - 76));
  return [
    { kind: "rect", id: asciiBytes("1"), rect: { x: 0, y: 0, width, height }, fill: { kind: "color", color: context.background } },
    { kind: "rect", id: asciiBytes("80"), rect: { x: 0, y: 0, width, height: 54 }, fill: { kind: "color", color: context.surface } },
    { kind: "rect", id: asciiBytes("84"), rect: { x: 0, y: 53, width, height: 1 }, fill: { kind: "color", color: context.border } },
    { kind: "rect", id: asciiBytes("260"), rect: { x: 0, y: Math.fround(contentY + contentHeight), width, height: 1 }, fill: { kind: "color", color: context.border } },
    { kind: "rounded_rect", id: asciiBytes("4"), rect: { x: 38, y: heroY, width: 168, height: heroHeight }, radius: 16, fill: { kind: "linear_gradient", start: { x: 38, y: heroY }, end: { x: 206, y: Math.fround(heroY + heroHeight) }, stops: [{ offset: 0, color: rgb(18, 24, 38) }, { offset: Math.fround(0.58), color: rgb(27, 72, 100) }, { offset: 1, color: rgb(17, 161, 153) }] } },
  ];
}
export function canvasAnimations(model: Model): readonly CanvasAnimation[] {
  const durationMs = model.perf_animation_armed || !model.reduce_motion ? 900 : 0;
  const easing = model.perf_animation_armed || !model.reduce_motion ? "emphasized" : "linear";
  const loop = model.perf_animation_armed ? "wrap" : "none";
  const fromTransform = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: -7 };
  const toTransform = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
  return [
    { label: utf8Bytes("Live render status"), index: 0, part: "fill", durationMs, easing, loop, fromOpacity: Math.fround(0.72), toOpacity: 1, fromTransform, toTransform },
    { label: utf8Bytes("Live render status"), index: 0, part: "text", durationMs, easing, loop, fromOpacity: Math.fround(0.72), toOpacity: 1, fromTransform, toTransform },
  ];
}
