// The compiled-core stage's restatement of @native-sdk/core: the SAME
// inert Cmd/Sub data values the reference module's factories build
// (packages/core/sdk/core.ts — the transpiler lane lowers references by
// identity and never runs that module's code), restated inside an
// external toolchain's static surface: no overloaded members, no
// generic value instantiation — the routing/arm-name rigor those
// generics carry is tsc's job in the authoring lane, and the paired
// e2e batteries hold every produced byte to the transpiler lane's
// output. Every external-compile stage copies this ONE file in as its
// ./sdk/core.ts: the fixture driver (tests/compiled-core/build_core.sh)
// and the product lane's stager (packages/core/scripts/
// stage_external_core.mjs) alike.

export function asciiBytes(s: string): Uint8Array {
  for (let i = 0; i < s.length; i++) {
    if (s.charCodeAt(i) > 0x7f) {
      throw new RangeError("asciiBytes accepts ASCII only; use utf8Bytes for Unicode text");
    }
  }
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function utf8Bytes(s: string): Uint8Array {
  let byteLength = 0;
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code <= 0x7f) {
      byteLength += 1;
    } else if (code <= 0x7ff) {
      byteLength += 2;
    } else if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        byteLength += 4;
        i += 1;
      } else {
        byteLength += 3;
      }
    } else {
      byteLength += 3;
    }
  }

  const out = new Uint8Array(byteLength);
  let at = 0;
  for (let i = 0; i < s.length; i++) {
    let code = s.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < s.length) {
      const next = s.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i += 1;
      } else {
        code = 0xfffd;
      }
    } else if (code >= 0xd800 && code <= 0xdfff) {
      code = 0xfffd;
    }

    if (code <= 0x7f) {
      out[at] = code;
      at += 1;
    } else if (code <= 0x7ff) {
      out[at] = 0xc0 | (code >> 6);
      out[at + 1] = 0x80 | (code & 0x3f);
      at += 2;
    } else if (code <= 0xffff) {
      out[at] = 0xe0 | (code >> 12);
      out[at + 1] = 0x80 | ((code >> 6) & 0x3f);
      out[at + 2] = 0x80 | (code & 0x3f);
      at += 3;
    } else {
      out[at] = 0xf0 | (code >> 18);
      out[at + 1] = 0x80 | ((code >> 12) & 0x3f);
      out[at + 2] = 0x80 | ((code >> 6) & 0x3f);
      out[at + 3] = 0x80 | (code & 0x3f);
      at += 4;
    }
  }
  return out;
}

export type Msgish = { readonly kind: string };

import { type WindowDescriptor, type WindowDescriptorSpec } from "./events.ts";

export function windowDescriptor(spec: WindowDescriptorSpec): WindowDescriptor {
  return {
    label: spec.label,
    canvasLabel: spec.canvasLabel,
    title: spec.title ?? new Uint8Array(0),
    width: spec.width ?? 480,
    height: spec.height ?? 360,
    x: spec.x ?? null,
    y: spec.y ?? null,
    resizable: spec.resizable ?? true,
    minWidth: spec.minWidth ?? 0,
    minHeight: spec.minHeight ?? 0,
    titlebar: spec.titlebar ?? "standard",
    transparent: spec.transparent ?? false,
    alwaysOnTop: spec.alwaysOnTop ?? false,
    clickThrough: spec.clickThrough ?? false,
    activateOnShow: spec.activateOnShow ?? true,
    allowsFullscreen: spec.allowsFullscreen ?? true,
    closePolicy: spec.closePolicy ?? "quit",
    onCloseCommand: spec.onCloseCommand ?? new Uint8Array(0),
  };
}

/** Cooperative cancellation capability supplied by generated service hosts. */
export interface ServiceCancellation {
  readonly cancelled: () => boolean;
  readonly throwIfCancelled: () => void;
}

export interface EnvMsg<M extends Msgish> {
  readonly env: string;
  readonly msg: M["kind"];
}

export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";
export type VideoState = "loaded" | "position" | "completed" | "failed" | "rejected";
export type ImageState =
  | "loaded"
  | "rejected"
  | "not_found"
  | "io_failed"
  | "connect_failed"
  | "tls_failed"
  | "protocol_failed"
  | "timed_out"
  | "http_status"
  | "cancelled"
  | "too_large"
  | "unsupported"
  | "decode_failed"
  | "registry_full"
  | "alloc_failed";
export type ChannelState = "data" | "closed" | "rejected";
export type PtyState = "output" | "exit";
export type PtyExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";

export type HostScalar = number | boolean | Uint8Array;
export type HostRecord = { readonly [field: string]: HostScalar };

export interface RequestRoute<M extends Msgish> {
  readonly key?: string;
  readonly ok: M["kind"];
  readonly err: M["kind"];
}

export interface ServiceRoute<M extends Msgish, P> {
  readonly key?: string;
  readonly ok: M["kind"];
  readonly err: M["kind"];
}

export interface ServiceStreamRoute<M extends Msgish, P> extends ServiceRoute<M, P> {
  readonly channelKey: number;
  readonly event: M["kind"];
}

export interface WriteRoute<M extends Msgish> {
  readonly key?: string;
  readonly ok: M["kind"];
  readonly err: M["kind"];
}

export interface FileReadStreamRoute<M extends Msgish> {
  readonly key?: string;
  readonly chunk: M["kind"];
  readonly done: M["kind"];
  readonly err: M["kind"];
}

export interface FileStatArm { readonly exists: boolean; readonly size: number; readonly mtimeMs: number; }
export interface FileStatRoute<M extends Msgish> { readonly key?: string; readonly ok: M["kind"]; readonly err: M["kind"]; }

export interface StoreScanOptions {
  readonly limit?: number;
  readonly after?: string | Uint8Array;
}

export interface DbText {
  readonly __dbText: true;
  readonly bytes: ReadonlyArray<number>;
}

export function dbText(bytes: Uint8Array): DbText {
  const out: number[] = [];
  for (let i = 0; i < bytes.length; i++) out.push(bytes[i]!);
  return { __dbText: true, bytes: out };
}

export type DbValue = null | number | string | Uint8Array | boolean | DbText;
export type DbStatement = readonly [sql: string, params: ReadonlyArray<DbValue>];

export interface DbRowsRoute<M extends Msgish> {
  readonly key?: string;
  readonly page: M["kind"];
  readonly done: M["kind"];
  readonly err: M["kind"];
}

export interface TypedRowsRoute<Row, M extends Msgish> extends DbRowsRoute<M> {
  readonly __row?: Row;
}

export interface TypedDbStatement {
  readonly sql: string;
  readonly params: ReadonlyArray<DbValue>;
  readonly __typedDbStatement: true;
}

// @native-sqlite-generated-types

export interface FetchRoute<M extends Msgish> {
  readonly key?: string;
  readonly ok: M["kind"];
  readonly err: M["kind"];
}

export interface FetchStreamRoute<M extends Msgish> {
  readonly key?: string;
  readonly line: M["kind"];
  readonly ok: M["kind"];
  readonly err: M["kind"];
}

export interface SpawnRoute<M extends Msgish> {
  readonly key?: string;
  readonly stdin?: Uint8Array;
  readonly line?: M["kind"];
  readonly exit: M["kind"];
  readonly err: M["kind"];
}

export interface SpawnCollectRoute<M extends Msgish> {
  readonly key?: string;
  readonly stdin?: Uint8Array;
  readonly collect: true;
  readonly exit: M["kind"];
  readonly err: M["kind"];
}

export interface AudioSource {
  readonly path?: Uint8Array;
  readonly url?: Uint8Array;
  readonly cachePath?: Uint8Array;
  readonly expectedBytes?: number;
}

export interface AudioRoute<M extends Msgish> {
  readonly event: M["kind"];
}

export interface VideoSource {
  readonly surface: number;
  readonly path?: Uint8Array;
  readonly url?: Uint8Array;
  readonly autoplay?: boolean;
  readonly loop?: boolean;
  readonly muted?: boolean;
}

export interface VideoRoute<M extends Msgish> {
  readonly event: M["kind"];
}

export interface ImageSource {
  readonly path?: Uint8Array;
  readonly url?: Uint8Array;
  readonly cachePath?: Uint8Array;
  readonly expectedBytes?: number;
}

export interface ImageRoute<M extends Msgish> {
  readonly event: M["kind"];
}

export interface ChannelRoute<M extends Msgish> {
  readonly event: M["kind"];
}

export type AudioCaptureSource = "microphone" | "system";
export type AudioCaptureState = "started" | "data" | "failed" | "stopped" | "rejected";
export type AudioCaptureSampleRate = 16000 | 24000 | 48000;
export type AudioCaptureChannels = 1 | 2;

export interface AudioCaptureSpec {
  // Inline the event-module alias here: the external-compile stager
  // deliberately deduplicates aliases shared by core.ts and events.ts.
  readonly source: "microphone" | "system";
  readonly sampleRate?: AudioCaptureSampleRate;
  readonly channels?: AudioCaptureChannels;
}

export type AudioCaptureEventArm = {
  readonly key: number;
  readonly state: "started" | "data" | "failed" | "stopped" | "rejected";
  readonly source: "microphone" | "system";
  readonly sampleRate: number;
  readonly channels: number;
  readonly timestampMs: number;
  readonly frames: number;
  readonly pcm: Uint8Array;
  readonly droppedPending: number;
  readonly droppedTotal: number;
};

export interface AudioCaptureRoute<M extends Msgish> {
  readonly event: M["kind"];
}

export interface PtyRoute<M extends Msgish> {
  readonly key?: string;
  readonly cols?: number;
  readonly rows?: number;
  readonly term?: string;
  readonly event: M["kind"];
}

export type FetchMethod = "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD";

export interface FetchSpec {
  readonly url: Uint8Array;
  readonly method?: FetchMethod;
  readonly headers?: { readonly [name: string]: string | Uint8Array };
  readonly body?: Uint8Array;
  readonly timeoutMs?: number;
}

export interface FetchStreamSpec extends FetchSpec {
  readonly maxLineBytes?: number;
}

export interface NotificationSpec {
  readonly id?: Uint8Array;
  readonly title: Uint8Array;
  readonly subtitle?: Uint8Array;
  readonly body?: Uint8Array;
  readonly actionLabel?: Uint8Array;
  readonly actionCommand?: Uint8Array;
}

export type LocalTimeStyle = "date" | "time" | "datetime";

/// The inert command data — the reference module's Cmd<M> union with
/// the type parameter erased (M constrains only the factories' arm-name
/// checking, never the data).
export type CmdData =
  | { readonly op: "none" }
  | { readonly op: "persist" }
  | { readonly op: "now"; readonly msgKind: string }
  | { readonly op: "host"; readonly name: string; readonly args: readonly number[] }
  | { readonly op: "host_bytes"; readonly name: string; readonly payload: Uint8Array }
  | {
      readonly op: "request";
      readonly name: string;
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly typedService: boolean;
      readonly payload: Uint8Array;
    }
  | {
      readonly op: "service_stream_request";
      readonly name: string;
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly typedService: true;
      readonly channelKey: number;
      readonly eventKind: string;
      readonly maxPending: number;
      readonly payload: Uint8Array;
    }
  | { readonly op: "cancel"; readonly key: string }
  | {
      readonly op: "read_file";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly path: Uint8Array;
    }
  | {
      readonly op: "write_file";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly path: Uint8Array;
      readonly bytes: Uint8Array;
    }
  | { readonly op: "append_file"; readonly key: string; readonly okKind: string; readonly errKind: string; readonly path: Uint8Array; readonly bytes: Uint8Array }
  | { readonly op: "stat_file"; readonly key: string; readonly okKind: string; readonly errKind: string; readonly path: Uint8Array }
  | { readonly op: "delete_file"; readonly key: string; readonly okKind: string; readonly errKind: string; readonly path: Uint8Array }
  | { readonly op: "read_file_stream"; readonly key: string; readonly chunkKind: string; readonly doneKind: string; readonly errKind: string; readonly path: Uint8Array }
  | { readonly op: "write_file_stream"; readonly key: string; readonly okKind: string; readonly errKind: string; readonly path: Uint8Array }
  | { readonly op: "write_file_chunk"; readonly key: string; readonly okKind: string; readonly errKind: string; readonly bytes: Uint8Array }
  | { readonly op: "write_file_close"; readonly key: string; readonly okKind: string; readonly errKind: string }
  | {
      readonly op: "store_set";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly storeKey: string;
      readonly bytes: Uint8Array;
    }
  | {
      readonly op: "store_get" | "store_delete";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly storeKey: string;
    }
  | {
      readonly op: "store_scan";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly prefix: string;
      readonly limit: number;
      readonly after: string | Uint8Array;
    }
  | {
      readonly op: "store_set_many";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly entries: ReadonlyArray<readonly [string, Uint8Array]>;
    }
  | {
      readonly op: "db_query";
      readonly key: string;
      readonly pageKind: string;
      readonly doneKind: string;
      readonly errKind: string;
      readonly sql: string;
      readonly params: ReadonlyArray<DbValue>;
    }
  | {
      readonly op: "db_exec";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly statements: ReadonlyArray<DbStatement>;
    }
  | {
      readonly op: "fetch";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly method: FetchMethod;
      readonly timeoutMs: number;
      readonly url: Uint8Array;
      readonly headers: readonly { readonly name: string; readonly value: string | Uint8Array }[];
      readonly body: Uint8Array;
    }
  | {
      readonly op: "fetch_stream";
      readonly key: string;
      readonly lineKind: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly method: FetchMethod;
      readonly timeoutMs: number;
      readonly maxLineBytes: number;
      readonly url: Uint8Array;
      readonly headers: readonly { readonly name: string; readonly value: string | Uint8Array }[];
      readonly body: Uint8Array;
    }
  | { readonly op: "clip_write"; readonly bytes: Uint8Array }
  | { readonly op: "clip_read"; readonly key: string; readonly okKind: string; readonly errKind: string }
  | { readonly op: "show_notification"; readonly id: Uint8Array; readonly title: Uint8Array; readonly subtitle: Uint8Array; readonly body: Uint8Array; readonly actionLabel: Uint8Array; readonly actionCommand: Uint8Array }
  | { readonly op: "delay"; readonly key: string; readonly afterMs: number; readonly msgKind: string }
  | {
      readonly op: "spawn";
      readonly key: string;
      readonly lineKind: string;
      readonly exitKind: string;
      readonly errKind: string;
      readonly collect: boolean;
      readonly argv: readonly Uint8Array[];
      readonly stdin: Uint8Array;
    }
  | {
      readonly op: "audio_play";
      readonly key: string;
      readonly eventKind: string;
      readonly path: Uint8Array;
      readonly url: Uint8Array;
      readonly cachePath: Uint8Array;
      readonly expectedBytes: number;
    }
  | {
      readonly op: "audio_ctl";
      readonly key: string;
      readonly verb: "pause" | "resume" | "stop" | "seek" | "volume";
      readonly value: number;
    }
  | {
      readonly op: "video_load";
      readonly key: string;
      readonly eventKind: string;
      readonly surface: number;
      readonly path: Uint8Array;
      readonly url: Uint8Array;
      readonly autoplay: boolean;
      readonly loop: boolean;
      readonly muted: boolean;
    }
  | {
      readonly op: "video_ctl";
      readonly key: string;
      readonly verb: "play" | "pause" | "stop" | "seek" | "volume" | "muted" | "loop";
      readonly value: number;
    }
  | { readonly op: "window_show"; readonly label: string }
  | { readonly op: "window_hide"; readonly label: string }
  | { readonly op: "dock_presence"; readonly visible: boolean }
  | { readonly op: "quit_app" }
  | {
      readonly op: "image_load";
      readonly id: number;
      readonly eventKind: string;
      readonly path: Uint8Array;
      readonly url: Uint8Array;
      readonly cachePath: Uint8Array;
      readonly expectedBytes: number;
    }
  | { readonly op: "image_cancel"; readonly id: number }
  | { readonly op: "image_unregister"; readonly id: number }
  | { readonly op: "channel_open"; readonly key: number; readonly eventKind: string; readonly maxPending: number }
  | { readonly op: "channel_close"; readonly key: number }
  | { readonly op: "audio_capture_start"; readonly key: number; readonly source: "microphone" | "system"; readonly sampleRate: number; readonly channels: number; readonly eventKind: string }
  | { readonly op: "audio_capture_stop"; readonly key: number }
  | {
      readonly op: "pty_spawn";
      readonly key: string;
      readonly eventKind: string;
      readonly cols: number;
      readonly rows: number;
      readonly term: string;
      readonly argv: readonly Uint8Array[];
    }
  | { readonly op: "pty_write"; readonly key: string; readonly bytes: Uint8Array }
  | { readonly op: "pty_resize"; readonly key: string; readonly cols: number; readonly rows: number }
  | { readonly op: "pty_kill"; readonly key: string }
  | { readonly op: "batch"; readonly cmds: readonly CmdData[] };

export type Cmd<M extends Msgish> = CmdData;

/// The wire encoding of a host record payload — byte-identical to the
/// reference module's hostRecordBytes (fields sorted by name, no field
/// headers; number -> f64 LE, boolean -> one byte, bytes -> u32 LE
/// length + bytes).
export function hostRecordBytes(payload: HostRecord): Uint8Array {
  const names = Object.keys(payload).sort();
  let len = 0;
  for (const n of names) {
    const v = payload[n]!;
    if (typeof v === "number") len += 8;
    else if (typeof v === "boolean") len += 1;
    else len += 4 + v.length;
  }
  const out = new Uint8Array(len);
  let off = 0;
  for (const n of names) {
    const v = payload[n]!;
    if (typeof v === "number") {
      const buf = Buffer.alloc(8);
      buf.writeDoubleLE(v, 0);
      for (let i = 0; i < 8; i++) out[off + i] = buf[i]!;
      off += 8;
    } else if (typeof v === "boolean") {
      out[off] = v ? 1 : 0;
      off += 1;
    } else {
      out[off] = v.length % 256;
      out[off + 1] = Math.floor(v.length / 256) % 256;
      out[off + 2] = Math.floor(v.length / 65536) % 256;
      out[off + 3] = Math.floor(v.length / 16777216) % 256;
      off += 4;
      for (let i = 0; i < v.length; i++) out[off + i] = v[i]!;
      off += v.length;
    }
  }
  return out;
}

function serviceU32(value: number): Uint8Array {
  const out = new Uint8Array(4);
  out[0] = value % 256;
  out[1] = Math.floor(value / 256) % 256;
  out[2] = Math.floor(value / 65536) % 256;
  out[3] = Math.floor(value / 16777216) % 256;
  return out;
}

export function serviceConcat(parts: readonly Uint8Array[]): Uint8Array {
  let length = 0;
  for (const part of parts) length += part.length;
  const out = new Uint8Array(length);
  let at = 0;
  for (const part of parts) {
    for (let i = 0; i < part.length; i++) out[at + i] = part[i]!;
    at += part.length;
  }
  return out;
}

export function serviceBoolBytes(value: boolean): Uint8Array {
  return new Uint8Array([value ? 1 : 0]);
}

export function serviceF64Bytes(value: number): Uint8Array {
  const out = new Uint8Array(8);
  const buf = Buffer.alloc(8);
  buf.writeDoubleLE(Number.isNaN(value) ? Number.NaN : value, 0);
  for (let i = 0; i < 8; i++) out[i] = buf[i]!;
  return out;
}

export function serviceI64Bytes(value: number): Uint8Array {
  const base = 4294967296;
  let low = value % base;
  if (low < 0) low += base;
  let high = Math.floor(value / base);
  if (high < 0) high += base;
  return serviceConcat([serviceU32(low), serviceU32(high)]);
}

export function serviceBytes(value: Uint8Array): Uint8Array {
  return serviceConcat([serviceU32(value.length), value]);
}

export function serviceEnumBytes(index: number): Uint8Array {
  return serviceU32(index);
}

export function serviceUnionBytes(index: number): Uint8Array {
  return new Uint8Array([index]);
}

export function serviceOptionalBytes(value: Uint8Array | null): Uint8Array {
  return value === null ? new Uint8Array([0]) : serviceConcat([new Uint8Array([1]), value]);
}

export function serviceSliceBytes(values: readonly Uint8Array[]): Uint8Array {
  return serviceConcat([serviceU32(values.length), ...values]);
}

/// A host command by name — the reference module's overloaded `host`
/// restated as the raw-bytes form (the whole corpus's usage; overloads,
/// rest-args, and the `Uint8Array | HostRecord` runtime discrimination
/// all sit outside the static surface). The record and scalar-args
/// forms stay reachable through `hostRecord`/`hostArgs`, byte-identical
/// data either way.
function hostCmd(name: string, payload: Uint8Array): CmdData {
  return { op: "host_bytes", name, payload: payload };
}

export function hostRecord(name: string, payload: HostRecord): CmdData {
  return { op: "host_bytes", name, payload: hostRecordBytes(payload) };
}

export function hostArgs(name: string, args: readonly number[]): CmdData {
  return { op: "host", name, args };
}

export const Cmd = {
  none: { op: "none" } as CmdData,

  /// Snapshot the just-committed Model through the capability-gated,
  /// engine-owned persistence store. Wire output remains the reserved 0x01.
  persist(): CmdData {
    return { op: "persist" };
  },

  now(msgKind: string): CmdData {
    return { op: "now", msgKind };
  },

  host: hostCmd,

  request(name: string, payload: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return {
      op: "request",
      name,
      key: route.key ?? "",
      okKind: route.ok,
      errKind: route.err,
      typedService: false,
      payload: payload,
    };
  },

  serviceRequest(
    name: string,
    payload: Uint8Array,
    route: { readonly key?: string; readonly ok: string; readonly err: string },
  ): CmdData {
    return {
      op: "request",
      name,
      key: route.key ?? "",
      okKind: route.ok,
      errKind: route.err,
      typedService: true,
      payload,
    };
  },

  serviceStreamRequest(
    name: string,
    channelKey: number,
    payload: Uint8Array,
    route: { readonly key?: string; readonly ok: string; readonly err: string; readonly event: string },
    maxPending: number,
  ): CmdData {
    return {
      op: "service_stream_request",
      name,
      key: route.key ?? "",
      okKind: route.ok,
      errKind: route.err,
      typedService: true,
      channelKey,
      eventKind: route.event,
      maxPending,
      payload: serviceConcat([serviceF64Bytes(channelKey), payload]),
    };
  },

  cancel(key: string): CmdData {
    return { op: "cancel", key };
  },

  readFile(path: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "read_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path };
  },

  writeFile(path: Uint8Array, bytes: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "write_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path, bytes };
  },
  appendFile(path: Uint8Array, bytes: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "append_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path, bytes };
  },
  statFile(path: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "stat_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path };
  },
  deleteFile(path: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "delete_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path };
  },
  readFileStream(path: Uint8Array, route: { readonly key?: string; readonly chunk: string; readonly done: string; readonly err: string }): CmdData {
    return { op: "read_file_stream", key: route.key ?? "", chunkKind: route.chunk, doneKind: route.done, errKind: route.err, path };
  },
  writeFileStream(key: string, path: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "write_file_stream", key, okKind: route.ok, errKind: route.err, path };
  },
  writeFileChunk(key: string, bytes: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "write_file_chunk", key, okKind: route.ok, errKind: route.err, bytes };
  },
  writeFileClose(key: string, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "write_file_close", key, okKind: route.ok, errKind: route.err };
  },

  store: {
    set(storeKey: string, bytes: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "store_set", key: route.key ?? "", okKind: route.ok, errKind: route.err, storeKey, bytes };
    },
    get(storeKey: string, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "store_get", key: route.key ?? "", okKind: route.ok, errKind: route.err, storeKey };
    },
    delete(storeKey: string, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "store_delete", key: route.key ?? "", okKind: route.ok, errKind: route.err, storeKey };
    },
    scan(prefix: string, options: StoreScanOptions, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "store_scan", key: route.key ?? "", okKind: route.ok, errKind: route.err, prefix, limit: options.limit ?? 0, after: options.after ?? "" };
    },
    setMany(entries: ReadonlyArray<readonly [string, Uint8Array]>, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "store_set_many", key: route.key ?? "", okKind: route.ok, errKind: route.err, entries };
    },
  },

  credentials: {
    set(credentialKey: string, secret: Uint8Array, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "request", name: "core.credentials.set", key: route.key ?? "", okKind: route.ok, errKind: route.err, typedService: false, payload: hostRecordBytes({ key: utf8Bytes(credentialKey), secret }) };
    },
    get(credentialKey: string, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return Cmd.request("core.credentials.get", hostRecordBytes({ key: utf8Bytes(credentialKey) }), route);
    },
    delete(credentialKey: string, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "request", name: "core.credentials.delete", key: route.key ?? "", okKind: route.ok, errKind: route.err, typedService: false, payload: hostRecordBytes({ key: utf8Bytes(credentialKey) }) };
    },
  },

  db: {
    query(sql: string, params: ReadonlyArray<DbValue>, route: { readonly key?: string; readonly page: string; readonly done: string; readonly err: string }): CmdData {
      return { op: "db_query", key: route.key ?? "", pageKind: route.page, doneKind: route.done, errKind: route.err, sql, params };
    },
    exec(statements: ReadonlyArray<DbStatement>, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
      return { op: "db_exec", key: route.key ?? "", okKind: route.ok, errKind: route.err, statements };
    },
  },

  // @native-sqlite-generated-cmds

  fetch(
    spec: FetchStreamSpec,
    route: { readonly key?: string; readonly line?: string; readonly ok: string; readonly err: string },
  ): CmdData {
    const names = Object.keys(spec.headers ?? {}).sort();
    const headers: { readonly name: string; readonly value: string | Uint8Array }[] = [];
    for (const n of names) {
      headers.push({ name: n, value: spec.headers![n]! });
    }
    if (route.line !== undefined) {
      return {
        op: "fetch_stream",
        key: route.key ?? "",
        lineKind: route.line,
        okKind: route.ok,
        errKind: route.err,
        method: spec.method ?? "GET",
        timeoutMs: spec.timeoutMs ?? 0,
        maxLineBytes: spec.maxLineBytes ?? 0,
        url: spec.url,
        headers: headers,
        body: spec.body ?? new Uint8Array(0),
      };
    }
    return {
      op: "fetch",
      key: route.key ?? "",
      okKind: route.ok,
      errKind: route.err,
      method: spec.method ?? "GET",
      timeoutMs: spec.timeoutMs ?? 0,
      url: spec.url,
      headers: headers,
      body: spec.body ?? new Uint8Array(0),
    };
  },

  clipboardWrite(bytes: Uint8Array): CmdData {
    return { op: "clip_write", bytes };
  },

  clipboardRead(route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return { op: "clip_read", key: route.key ?? "", okKind: route.ok, errKind: route.err };
  },

  showNotification(spec: NotificationSpec): CmdData {
    return {
      op: "show_notification",
      id: spec.id ?? new Uint8Array(0),
      title: spec.title,
      subtitle: spec.subtitle ?? new Uint8Array(0),
      body: spec.body ?? new Uint8Array(0),
      actionLabel: spec.actionLabel ?? new Uint8Array(0),
      actionCommand: spec.actionCommand ?? new Uint8Array(0),
    };
  },

  openExternalUrl(url: Uint8Array): CmdData {
    return { op: "host_bytes", name: "native-sdk.os.openUrl", payload: url };
  },

  revealPath(path: Uint8Array): CmdData {
    return { op: "host_bytes", name: "native-sdk.os.revealPath", payload: path };
  },

  formatLocalTime(
    timestampMs: number,
    style: LocalTimeStyle,
    route: { readonly key?: string; readonly ok: string; readonly err: string },
  ): CmdData {
    const styleCode = style === "date" ? 0 : style === "time" ? 1 : 2;
    return Cmd.request("native-sdk.time.formatLocal", hostRecordBytes({ style: styleCode, timestampMs }), route);
  },

  delay(key: string, ms: number, msgKind: string): CmdData {
    return { op: "delay", key, afterMs: ms, msgKind };
  },

  spawn(
    argv: readonly Uint8Array[],
    route: { readonly key?: string; readonly stdin?: Uint8Array; readonly line?: string; readonly collect?: boolean; readonly exit: string; readonly err: string },
  ): CmdData {
    const collect = route.collect === true;
    return {
      op: "spawn",
      key: route.key ?? "",
      lineKind: collect ? "" : (route.line ?? ""),
      exitKind: route.exit,
      errKind: route.err,
      collect,
      argv,
      stdin: route.stdin ?? new Uint8Array(0),
    };
  },

  audioPlay(key: string, source: AudioSource, route: { readonly event: string }): CmdData {
    return {
      op: "audio_play",
      key,
      eventKind: route.event,
      path: source.path ?? new Uint8Array(0),
      url: source.url ?? new Uint8Array(0),
      cachePath: source.cachePath ?? new Uint8Array(0),
      expectedBytes: source.expectedBytes ?? 0,
    };
  },

  audioPause(key: string): CmdData {
    return { op: "audio_ctl", key, verb: "pause", value: 0 };
  },

  audioResume(key: string): CmdData {
    return { op: "audio_ctl", key, verb: "resume", value: 0 };
  },

  audioStop(key: string): CmdData {
    return { op: "audio_ctl", key, verb: "stop", value: 0 };
  },

  audioSeek(key: string, ms: number): CmdData {
    return { op: "audio_ctl", key, verb: "seek", value: ms };
  },

  audioSetVolume(key: string, volume: number): CmdData {
    return { op: "audio_ctl", key, verb: "volume", value: volume };
  },

  videoLoad(key: string, source: VideoSource, route: { readonly event: string }): CmdData {
    return {
      op: "video_load",
      key,
      eventKind: route.event,
      surface: source.surface,
      path: source.path ?? new Uint8Array(0),
      url: source.url ?? new Uint8Array(0),
      autoplay: source.autoplay ?? true,
      loop: source.loop ?? false,
      muted: source.muted ?? false,
    };
  },

  videoPlay(key: string): CmdData {
    return { op: "video_ctl", key, verb: "play", value: 0 };
  },

  videoPause(key: string): CmdData {
    return { op: "video_ctl", key, verb: "pause", value: 0 };
  },

  videoStop(key: string): CmdData {
    return { op: "video_ctl", key, verb: "stop", value: 0 };
  },

  videoSeek(key: string, ms: number): CmdData {
    return { op: "video_ctl", key, verb: "seek", value: ms };
  },

  videoSetVolume(key: string, volume: number): CmdData {
    return { op: "video_ctl", key, verb: "volume", value: volume };
  },

  videoSetMuted(key: string, muted: boolean): CmdData {
    return { op: "video_ctl", key, verb: "muted", value: muted ? 1 : 0 };
  },

  videoSetLoop(key: string, loop: boolean): CmdData {
    return { op: "video_ctl", key, verb: "loop", value: loop ? 1 : 0 };
  },

  showWindow(label: string): CmdData {
    return { op: "window_show", label };
  },

  hideWindow(label: string): CmdData {
    return { op: "window_hide", label };
  },

  setDockPresence(visible: boolean): CmdData {
    return { op: "dock_presence", visible };
  },

  launchAtLoginStatus(route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return Cmd.request("native-sdk.launch-at-login.status", new Uint8Array(0), route);
  },

  setLaunchAtLogin(enabled: boolean, route: { readonly key?: string; readonly ok: string; readonly err: string }): CmdData {
    return Cmd.request("native-sdk.launch-at-login.set", new Uint8Array([enabled ? 1 : 0]), route);
  },

  quitApp(): CmdData {
    return { op: "quit_app" };
  },

  imageLoad(id: number, source: ImageSource, route: { readonly event: string }): CmdData {
    return {
      op: "image_load",
      id,
      eventKind: route.event,
      path: source.path ?? new Uint8Array(0),
      url: source.url ?? new Uint8Array(0),
      cachePath: source.cachePath ?? new Uint8Array(0),
      expectedBytes: source.expectedBytes ?? 0,
    };
  },

  imageCancel(id: number): CmdData {
    return { op: "image_cancel", id };
  },

  imageUnregister(id: number): CmdData {
    return { op: "image_unregister", id };
  },

  channelOpen(key: number, route: { readonly event: string }): CmdData {
    return { op: "channel_open", key, eventKind: route.event, maxPending: 64 };
  },

  channelClose(key: number): CmdData {
    return { op: "channel_close", key };
  },

  audioCaptureStart(key: number, spec: AudioCaptureSpec, route: { readonly event: string }): CmdData {
    return {
      op: "audio_capture_start",
      key,
      source: spec.source,
      sampleRate: spec.sampleRate ?? 48000,
      channels: spec.channels ?? 1,
      eventKind: route.event,
    };
  },

  audioCaptureStop(key: number): CmdData {
    return { op: "audio_capture_stop", key };
  },

  ptySpawn(argv: readonly Uint8Array[], route: { readonly key?: string; readonly cols?: number; readonly rows?: number; readonly term?: string; readonly event: string }): CmdData {
    return {
      op: "pty_spawn",
      key: route.key ?? "",
      eventKind: route.event,
      cols: route.cols ?? 80,
      rows: route.rows ?? 24,
      term: route.term ?? "",
      argv,
    };
  },

  ptyWrite(key: string, bytes: Uint8Array): CmdData {
    return { op: "pty_write", key, bytes };
  },

  ptyResize(key: string, cols: number, rows: number): CmdData {
    return { op: "pty_resize", key, cols, rows };
  },

  ptyKill(key: string): CmdData {
    return { op: "pty_kill", key };
  },

  batch(cmds: readonly CmdData[]): CmdData {
    return { op: "batch", cmds };
  },
};

export type SubData =
  | { readonly op: "none" }
  | { readonly op: "timer"; readonly key: string; readonly everyMs: number; readonly msgKind: string }
  | { readonly op: "db_live"; readonly key: string; readonly pageKind: string; readonly doneKind: string; readonly errKind: string; readonly sql: string; readonly params: ReadonlyArray<DbValue>; readonly tables: readonly string[] }
  | { readonly op: "batch"; readonly subs: readonly SubData[] };

export type Sub<M extends Msgish> = SubData;

export const Sub = {
  none: { op: "none" } as SubData,

  timer(key: string, everyMs: number, msgKind: string): SubData {
    return { op: "timer", key, everyMs, msgKind };
  },

  // @native-sqlite-generated-subs

  batch(subs: readonly SubData[]): SubData {
    return { op: "batch", subs };
  },
};
