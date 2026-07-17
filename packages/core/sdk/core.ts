// @native-sdk/core — the SDK module an app core imports. The subset program
// maps the "@native-sdk/core" specifier onto this file, so stock tsc types
// it; the transpiler lowers references to it onto the rt kernel and never
// emits this module's own code.
//
// `Cmd` is the typed-effects surface (spec section 2): `update` (and, since
// v2, `initialModel`) may return `[model, cmd]`, where the cmd is INERT DATA
// describing effects for the runtime to perform after the returned model
// commits. Commands are built only from these factories, and only in that
// return path (NS1017) — they never live in the Model, in a Msg, in a local,
// or in a helper.
//
// The v3 command set:
//
//   Cmd.none                     no effects (what a bare `return model` means)
//   Cmd.persist()                ask the host to persist the committed model
//   Cmd.now("tick")              request a timestamp; the runtime dispatches
//                                the named Msg arm with the time (ms) as its
//                                single number payload field
//   Cmd.host(name, ...args)      a host command by name with scalar args —
//                                the host interprets the name
//   Cmd.host(name, payload)      the same, carrying one bytes payload — a
//                                Uint8Array, or a flat record of number /
//                                boolean / Uint8Array fields that lowers to
//                                bytes (hostRecordBytes below)
//   Cmd.request(name, payload,   a routed host command: the host performs it
//               { key?, ok, err })  and dispatches the `ok` Msg arm with the
//                                result bytes, or the `err` arm with the error
//                                bytes — each arm carries exactly one
//                                Uint8Array payload field, checked by tsc. The
//                                optional `key` names the in-flight effect:
//                                re-issuing a live key replaces it, and
//                                Cmd.cancel(key) drops it.
//   Cmd.cancel(key)              drop the in-flight keyed effect — request,
//                                readFile/writeFile/fetch/clipboardRead, or
//                                delay — SILENTLY (no terminal arm dispatch).
//                                Aimed at a live spawn it stays LOUD: the
//                                child dies and the err arm runs with
//                                "cancelled" — killing a process is an
//                                observable event
//   Cmd.batch([a, b, ...])       several commands from one dispatch
//
// The named engine ops (each maps onto the host's effect engine directly;
// routing follows the request rules — string-literal arm names, tsc-checked
// arm shapes):
//
//   Cmd.readFile(path, { key?, ok, err })
//                                whole-file read; ok arm carries the bytes
//                                (one Uint8Array field), err arm the reason
//                                bytes ("not_found", "io_failed", "truncated",
//                                "rejected")
//   Cmd.writeFile(path, bytes, { key?, ok, err })
//                                whole-file write (parents created, replaced
//                                whole); ok arm carries NOTHING (an arm with
//                                no payload fields), err arm the reason bytes
//   Cmd.fetch({ url, method?, headers?, body?, timeoutMs? }, { key?, ok, err })
//                                buffered HTTP(S) exchange; ok arm carries a
//                                two-field record — one number field (the real
//                                HTTP status, non-2xx included) and one
//                                Uint8Array field (the whole body) — err arm
//                                the reason bytes ("connect_failed",
//                                "tls_failed", "protocol_failed", "timed_out",
//                                "rejected", "truncated")
//   Cmd.clipboardWrite(bytes)    fire-and-forget clipboard write
//   Cmd.clipboardRead({ key?, ok, err })
//                                clipboard read; ok arm carries the text bytes,
//                                err arm the reason bytes ("failed",
//                                "rejected")
//   Cmd.delay(key, ms, "fired")  a keyed ONE-SHOT timer: dispatches the named
//                                arm once after `ms`, with the fire time (ms)
//                                as its single number payload; re-issuing a
//                                live key re-arms from now (debounce), and
//                                Cmd.cancel(key) drops it silently
//
// The streaming ops (one issue, MANY result Msgs across dispatches, a keyed
// lifecycle the app drives):
//
//   Cmd.spawn(argv, { key?, stdin?, line?, exit, err })
//   Cmd.spawn(argv, { key?, stdin?, collect: true, exit, err })
//                                run a subprocess. Line mode streams each
//                                stdout line to the `line` arm (one Uint8Array
//                                field; omit `line` to drop lines); collect
//                                mode buffers whole stdout instead. Exactly one
//                                terminal follows: a clean exit dispatches
//                                `exit` — line mode: one number field (the exit
//                                code); collect mode: a two-field record, one
//                                number (the code) and one Uint8Array (the
//                                collected stdout), matched by type — and every
//                                other end dispatches `err` with the reason
//                                bytes ("signaled", "cancelled", "rejected",
//                                "spawn_failed", "truncated"). Cmd.cancel(key)
//                                ends the child mid-stream (err arm
//                                "cancelled" — never silent).
//   Cmd.audioPlay(key, { path?, url?, cachePath?, expectedBytes? }, { event })
//                                open (or replace — one player is the whole
//                                surface) the audio event stream: every
//                                playback event dispatches the `event` arm (the
//                                six-field record below) until Cmd.audioStop
//                                closes the stream.
//   Cmd.audioPause(key) / audioResume(key) / audioStop(key)
//   Cmd.audioSeek(key, ms) / Cmd.audioSetVolume(key, volume)
//                                drive the open stream in place — fire-and-
//                                forget control verbs whose consequences arrive
//                                on the event stream; aimed at a key with no
//                                open stream they no-op.
//   Cmd.imageLoad(id, { path?, url?, cachePath?, expectedBytes? }, { event })
//                                load an image at runtime by its model-owned
//                                numeric ImageId (the id markup binds:
//                                <image image="{id}"/>, avatar likewise): the
//                                host resolves the source cascade (local path
//                                first, then a verified cache entry, then the
//                                network), decodes through the platform codec,
//                                registers the pixels under the id, and
//                                dispatches exactly ONE `event` arm (the
//                                four-field record below) — state "loaded"
//                                with the decoded width/height, or one failure
//                                class. One load per id at a time: a duplicate
//                                live id dispatches state "rejected".
//
// The window verbs (fire-and-forget, no result Msg — the window's own
// frame event carries the state):
//
//   Cmd.showWindow(label)        un-hide + activate the window with the
//                                declared label — the counterpart to a
//                                `close_policy = "hide"` hide and the tray
//                                "Open" consequence; also restores a
//                                minimized window. An unknown label is a
//                                no-op.
//   Cmd.quitApp()                graceful terminate, the tray "Quit"
//                                consequence: the host quits through the
//                                SAME shutdown path a last-window close
//                                takes, so the stop hook runs exactly once
//                                and a recording session seals its journal.
//
// The keyed-effect discipline is ONE rule: a keyed effect REPLACES its live
// predecessor (the superseded effect's result is dropped — no message), and
// Cmd.cancel drops it silently. That holds for request, readFile, writeFile,
// fetch, clipboardRead, and delay alike. The ONE exception is a live spawn
// key: a duplicate REJECTS the new spawn (err arm "rejected") — a running
// subprocess is never killed implicitly; cancel it first. And spawn's cancel
// stays loud (err arm "cancelled"): killing a process is an observable event.
//
// `Sub` is the recurring-effects surface: an app may export
// `subscriptions(model): Sub<Msg>` returning declarative descriptors the
// host reconciles after every commit (Sub.timer fires the named arm with the
// current time on each interval). Like Cmd, Sub values are inert data, legal
// only in that function's return path (NS1025). Sub and the streaming Cmds
// are different animals on purpose: a Sub is DECLARED from the model (the
// host starts/stops it by reconciliation; the app never opens one), while
// spawn/audioPlay streams are Cmd-INITIATED — imperative opens with a keyed
// lifecycle the app drives and cancels.
//
// The factories return plain frozen-shape objects so the same core runs
// under node: a dev harness can interpret the `op` tags directly.

// The byte-text method surface (s.toUpperCase(), s.split(sep), ... on
// Uint8Array): the transpiler adds the ambient file to every core's program
// itself; this reference carries the same surface into EDITORS of apps that
// import "@native-sdk/core", so tsc-in-the-editor and `native check` agree.
/// <reference path="./bytes_text_methods.d.ts" />

/// The text intrinsic: turn a string literal or template into bytes. The
/// transpiler recognizes calls BY IDENTITY (this import, renames honored)
/// and folds them at compile time — a literal argument becomes rodata, a
/// template becomes frame-arena bytes via bufPrint — so no string ever
/// exists at native runtime. Under node this body runs as-is, byte for
/// byte the same result. Arguments must be literals or templates; dynamic
/// text lives in the model as Uint8Array from the start.
export function asciiBytes(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/// Every app Msg is a discriminated union on a string `kind` tag.
export type Msgish = { readonly kind: string };

/// The Msg arms `Cmd.now` may target: arms whose payload is exactly one
/// number-typed field (the runtime dispatches the arm with the timestamp in
/// that field). Anything else is unrepresentable — the runtime has only a
/// number to give back.
export type TimestampKind<M extends Msgish> = M extends Msgish
  ? {
      [K in Exclude<keyof M, "kind">]-?: M[K] extends number
        ? [Exclude<keyof M, "kind">] extends [K]
          ? M["kind"]
          : never
        : never;
    }[Exclude<keyof M, "kind">]
  : never;

/// The Msg arms a routed host result may target: arms whose payload is
/// exactly one Uint8Array-typed field (the runtime dispatches the arm with
/// the result/error bytes in that field).
export type BytesKind<M extends Msgish> = M extends Msgish
  ? {
      [K in Exclude<keyof M, "kind">]-?: M[K] extends Uint8Array
        ? [Exclude<keyof M, "kind">] extends [K]
          ? M["kind"]
          : never
        : never;
    }[Exclude<keyof M, "kind">]
  : never;

/// The Msg arms a payload-less routed result may target: arms with no
/// payload fields at all (`Cmd.writeFile`'s ok route — a successful write
/// has nothing to report beyond success).
export type EmptyKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [never]
    ? M["kind"]
    : never
  : never;

/// The Msg arms a buffered fetch response may target: arms whose payload is
/// exactly two fields — one number (the HTTP status) and one Uint8Array (the
/// body). The runtime matches the fields by TYPE, so their names are yours.
export type FetchedKind<M extends Msgish> = M extends Msgish
  ? {
      [K in Exclude<keyof M, "kind">]-?: M[K] extends Uint8Array
        ? Exclude<keyof M, "kind" | K> extends infer O
          ? O extends keyof M
            ? M[O] extends number
              ? [Exclude<keyof M, "kind" | K | O>] extends [never]
                ? M["kind"]
                : never
              : never
            : never
          : never
        : never;
    }[Exclude<keyof M, "kind">]
  : never;

// ------------------------------------------------- wiring channel shapes
// The generated wiring's opt-in host-event channels: export the channel
// and it is wired (`commandMsg(name: string): Msg | null` is the same
// family — menus, shortcuts, chrome tabs — and predates these). Event
// RECORD shapes (`frameMsg`'s FrameEvent, `keyMsg`'s KeyEvent, the
// appearanceMsg/chromeMsg arm payloads) are DECLARED IN YOUR CORE and
// matched by field name, the TextInputEvent rule — they must emit as your
// module's own records, so an SDK interface cannot stand in for them.

/// One `envMsgs` entry: `export const envMsgs = [{ env: "NAME", msg:
/// "<arm>" }] as const` — each named environment variable present at launch
/// dispatches its value through the arm (exactly one `Uint8Array` field) as
/// an ordinary journaled Msg right after the boot command. The core itself
/// never reads the environment (NS1005); replay carries the recorded values.
export interface EnvMsg<M extends Msgish> {
  readonly env: string;
  readonly msg: BytesKind<M>;
}

/// The audio event states, mirroring the engine's event vocabulary: `loaded`
/// acknowledges a successful load with the player's duration estimate;
/// `position` ticks at the platform's honest cadence (~500ms) while playing;
/// `completed` fires exactly once at the natural end; `failed` reports a
/// load/decode/device failure; `rejected` a command the effects layer refused
/// (an empty or over-long source); `spectrum` carries a band-magnitude
/// analysis frame from hosts that analyze their playback.
export type AudioState = "loaded" | "position" | "completed" | "failed" | "rejected" | "spectrum";

/// The payload shape of an audio event arm — six fields, matched by NAME (the
/// one SDK-fixed record shape, so the host can build it from your union).
/// `state` must be a named string-literal-union alias carrying exactly the
/// six AudioState members (any declaration order — the host matches members
/// by name). `positionMs`/`durationMs` are milliseconds; `playing` is the
/// player's transport state; `buffering` is true while a streamed source is
/// stalled waiting for network bytes; `bands` is the 32 spectrum band
/// magnitudes (0..255 each, all zeros outside "spectrum" events).
export type AudioEventArm = {
  readonly state: AudioState;
  readonly positionMs: number;
  readonly durationMs: number;
  readonly playing: boolean;
  readonly buffering: boolean;
  readonly bands: Uint8Array;
};

/// The Msg arms an audio event stream may target: arms whose payload is
/// exactly the six AudioEventArm fields.
export type AudioEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof AudioEventArm]
    ? [keyof AudioEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & AudioEventArm
        ? M["kind"]
        : never
      : never
    : never
  : never;

/// The image load result states, mirroring the engine's outcome vocabulary:
/// "loaded" means the pixels are registered under the requested id (width and
/// height carry what the codec decoded); every other state is the failure
/// class — "rejected" (a refused command: invalid id, no source, a duplicate
/// live id), "not_found" (missing local file, no url), "io_failed" (a local
/// read failure), "connect_failed"/"tls_failed"/"protocol_failed"/"timed_out"
/// (the fetch taxonomy), "http_status" (a non-2xx answer; `status` carries
/// it), "cancelled", "too_large" (source or decoded pixels over budget),
/// "unsupported" (no platform codec), "decode_failed", and "registry_full".
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
  | "registry_full";

/// The payload shape of an image result arm — four fields, matched by NAME
/// (the AudioEventArm convention). `state` must be a named string-literal-
/// union alias carrying exactly the fourteen ImageState members (any
/// declaration order — the host matches members by name); `width`/`height`
/// are the decoded pixel dimensions ("loaded" only, 0 otherwise); `status`
/// is the HTTP status for url sources (0 otherwise).
export type ImageEventArm = {
  readonly state: ImageState;
  readonly width: number;
  readonly height: number;
  readonly status: number;
};

/// The Msg arms an image load result may target: arms whose payload is
/// exactly the four ImageEventArm fields.
export type ImageEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof ImageEventArm]
    ? [keyof ImageEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & ImageEventArm
        ? M["kind"]
        : never
      : never
    : never
  : never;

/// One field of a host record payload; see hostRecordBytes for the encoding.
export type HostScalar = number | boolean | Uint8Array;

/// A structured host payload: a flat record of scalar/bytes fields, lowered
/// to one bytes payload at build time (natively) and by hostRecordBytes
/// (under node) — the same bytes either way.
export type HostRecord = { readonly [field: string]: HostScalar };

/// How a `Cmd.request` result comes back: the host dispatches the `ok` arm
/// with the result bytes on success, or the `err` arm with the error bytes.
/// Arm names are string literals — the routing is data, never a callback.
/// `key` (optional) names the in-flight effect for replace/cancel semantics.
export interface RequestRoute<M extends Msgish> {
  readonly key?: string;
  readonly ok: BytesKind<M>;
  readonly err: BytesKind<M>;
}

/// `Cmd.writeFile` routing: the ok arm carries no payload (success has
/// nothing to report); the err arm carries the reason bytes.
export interface WriteRoute<M extends Msgish> {
  readonly key?: string;
  readonly ok: EmptyKind<M>;
  readonly err: BytesKind<M>;
}

/// `Cmd.fetch` routing: the ok arm carries `{ status, body }` (one number
/// field, one bytes field — matched by type); the err arm the reason bytes.
export interface FetchRoute<M extends Msgish> {
  readonly key?: string;
  readonly ok: FetchedKind<M>;
  readonly err: BytesKind<M>;
}

/// `Cmd.spawn` routing, line mode: each stdout line dispatches the optional
/// `line` arm (one bytes field; omitted = lines dropped), a clean exit the
/// `exit` arm (one number field — the exit code), every other end the `err`
/// arm with the reason bytes.
export interface SpawnRoute<M extends Msgish> {
  readonly key?: string;
  readonly stdin?: Uint8Array;
  readonly line?: BytesKind<M>;
  readonly exit: TimestampKind<M>;
  readonly err: BytesKind<M>;
}

/// `Cmd.spawn` routing, collect mode: whole stdout buffers until the exit,
/// which dispatches the `exit` arm as a two-field record — one number field
/// (the exit code) and one bytes field (the collected stdout), matched by
/// type so the names are yours. No line arm: there is no line framing.
export interface SpawnCollectRoute<M extends Msgish> {
  readonly key?: string;
  readonly stdin?: Uint8Array;
  readonly collect: true;
  readonly exit: FetchedKind<M>;
  readonly err: BytesKind<M>;
}

/// A `Cmd.audioPlay` source: the resolution cascade of the engine underneath.
/// The local `path` is tried first; a missing file falls through to `url`
/// (streamed progressively, cached at `cachePath` when given and verified
/// against `expectedBytes` — 0/omitted means unknown size, existence alone
/// qualifies a cache entry). At least one of path/url must be present.
export interface AudioSource {
  readonly path?: Uint8Array;
  readonly url?: Uint8Array;
  readonly cachePath?: Uint8Array;
  readonly expectedBytes?: number;
}

/// `Cmd.audioPlay` routing: every playback event dispatches the `event` arm
/// (the six-field AudioEventArm record, matched by field name).
export interface AudioRoute<M extends Msgish> {
  readonly event: AudioEventKind<M>;
}

/// A `Cmd.imageLoad` source: the audio cascade's shape exactly. The local
/// `path` is tried first; a missing file falls through to `url` (fetched
/// whole, installed at `cachePath` when given and verified against
/// `expectedBytes` — 0/omitted means unknown size, existence alone qualifies
/// a cache entry; omit `cachePath` and the host derives the conventional
/// content-addressed path when a caches directory is configured). At least
/// one of path/url must be present.
export interface ImageSource {
  readonly path?: Uint8Array;
  readonly url?: Uint8Array;
  readonly cachePath?: Uint8Array;
  readonly expectedBytes?: number;
}

/// `Cmd.imageLoad` routing: the ONE terminal result dispatches the `event`
/// arm (the four-field ImageEventArm record, matched by field name).
export interface ImageRoute<M extends Msgish> {
  readonly event: ImageEventKind<M>;
}

/// The closed HTTP verb set of `Cmd.fetch` (wire value = declaration order).
export type FetchMethod = "GET" | "POST" | "PUT" | "DELETE" | "PATCH" | "HEAD";

/// A `Cmd.fetch` request. `url` is bytes (asciiBytes for literals); headers
/// are a flat record whose NAMES are compile-time text and whose VALUES are
/// string literals or runtime bytes (`Uint8Array` — how a launch-supplied
/// credential rides an `Authorization` header); `timeoutMs` omitted means
/// the host engine's default.
export interface FetchSpec {
  readonly url: Uint8Array;
  readonly method?: FetchMethod;
  readonly headers?: { readonly [name: string]: string | Uint8Array };
  readonly body?: Uint8Array;
  readonly timeoutMs?: number;
}

/// An inert command value, parameterized by the app's Msg union so the
/// factories can validate message targets. Opaque to app code: build with
/// the `Cmd.*` factories, return from `update`/`initialModel`, never inspect
/// or store.
export type Cmd<M extends Msgish> =
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
  | {
      readonly op: "fetch";
      readonly key: string;
      readonly okKind: string;
      readonly errKind: string;
      readonly method: FetchMethod;
      readonly timeoutMs: number;
      readonly url: Uint8Array;
      /// Header pairs, already in TS-field-name (code-unit) sort order.
      /// A string value is compile-time text; a Uint8Array value is
      /// runtime bytes (both encode as the record's length-prefixed
      /// value field).
      readonly headers: readonly { readonly name: string; readonly value: string | Uint8Array }[];
      readonly body: Uint8Array;
    }
  | { readonly op: "clip_write"; readonly bytes: Uint8Array }
  | { readonly op: "clip_read"; readonly key: string; readonly okKind: string; readonly errKind: string }
  | { readonly op: "delay"; readonly key: string; readonly afterMs: number; readonly msgKind: string }
  | {
      readonly op: "spawn";
      readonly key: string;
      /// "" = no line routing (collect mode, or a line spawn that only
      /// cares about the exit).
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
      /// Seek position (ms) / volume (0..1); 0 for the value-less verbs.
      readonly value: number;
    }
  | { readonly op: "window_show"; readonly label: string }
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
  | { readonly op: "batch"; readonly cmds: readonly Cmd<M>[] };

/// The wire encoding of a host record payload, byte-identical to what the
/// transpiler derives from the record's TS shape at build time: fields
/// sorted by name (code-unit order), concatenated with no field headers —
/// number -> f64 little-endian (8 bytes), boolean -> one 0/1 byte,
/// Uint8Array -> u32 little-endian length + bytes.
export function hostRecordBytes(payload: HostRecord): Uint8Array {
  const names = Object.keys(payload).sort();
  let len = 0;
  for (const n of names) {
    const v = payload[n];
    if (typeof v === "number") len += 8;
    else if (typeof v === "boolean") len += 1;
    else len += 4 + v.length;
  }
  const out = new Uint8Array(len);
  const dv = new DataView(out.buffer);
  let off = 0;
  for (const n of names) {
    const v = payload[n];
    if (typeof v === "number") {
      dv.setFloat64(off, v, true);
      off += 8;
    } else if (typeof v === "boolean") {
      out[off] = v ? 1 : 0;
      off += 1;
    } else {
      dv.setUint32(off, v.length, true);
      off += 4;
      out.set(v, off);
      off += v.length;
    }
  }
  return out;
}

function lowerHostPayload(payload: Uint8Array | HostRecord): Uint8Array {
  return payload instanceof Uint8Array ? payload : hostRecordBytes(payload);
}

/// A host command by name; the host decides what the name means. The name is
/// a string literal. Args are scalar numbers, or exactly one bytes payload
/// (a Uint8Array, or a flat record that lowers to bytes).
function hostCmd(name: string, payload: Uint8Array | HostRecord): Cmd<never>;
function hostCmd(name: string, ...args: readonly number[]): Cmd<never>;
function hostCmd(name: string, ...rest: readonly (number | Uint8Array | HostRecord)[]): Cmd<never> {
  const first = rest[0];
  if (rest.length === 1 && typeof first === "object" && first !== null) {
    return { op: "host_bytes", name, payload: lowerHostPayload(first) };
  }
  return { op: "host", name, args: rest as readonly number[] };
}

export const Cmd = {
  /// No effects. `return model` is sugar for `return [model, Cmd.none]`.
  none: { op: "none" } as Cmd<never>,

  /// Ask the host to persist the committed model.
  persist(): Cmd<never> {
    return { op: "persist" };
  },

  /// Request the current time. The runtime dispatches the named Msg arm with
  /// the timestamp (milliseconds, a plain number) as its single payload field.
  now<M extends Msgish>(msgKind: TimestampKind<M>): Cmd<M> {
    return { op: "now", msgKind };
  },

  host: hostCmd,

  /// A routed host command: the host performs `name` with the payload and
  /// dispatches exactly one result Msg back — the `ok` arm with the result
  /// bytes, or the `err` arm with the error bytes. Both arms must carry
  /// exactly one Uint8Array payload field (tsc checks that). An optional
  /// `key` names the in-flight effect: re-issuing a live key replaces it,
  /// and Cmd.cancel(key) drops it.
  request<M extends Msgish>(
    name: string,
    payload: Uint8Array | HostRecord,
    route: RequestRoute<M>,
  ): Cmd<M> {
    return {
      op: "request",
      name,
      key: route.key ?? "",
      okKind: route.ok,
      errKind: route.err,
      payload: lowerHostPayload(payload),
    };
  },

  /// Drop the in-flight keyed effect — request, named engine op, or delay —
  /// with this key, if any, SILENTLY (neither routing arm is dispatched for
  /// it). The exception is a live spawn: cancel ends the child and its err
  /// arm runs with "cancelled" — killing a process is an observable event.
  cancel(key: string): Cmd<never> {
    return { op: "cancel", key };
  },

  /// Read a whole file. Exactly one terminal Msg: the `ok` arm with the
  /// content bytes (one Uint8Array field), or the `err` arm with the reason
  /// bytes ("not_found", "io_failed", "truncated", "rejected").
  readFile<M extends Msgish>(path: Uint8Array, route: RequestRoute<M>): Cmd<M> {
    return { op: "read_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path };
  },

  /// Write a whole file (parent directories created, an existing file
  /// replaced whole). Exactly one terminal Msg: the `ok` arm — which carries
  /// no payload — or the `err` arm with the reason bytes.
  writeFile<M extends Msgish>(path: Uint8Array, bytes: Uint8Array, route: WriteRoute<M>): Cmd<M> {
    return { op: "write_file", key: route.key ?? "", okKind: route.ok, errKind: route.err, path, bytes };
  },

  /// A buffered HTTP(S) exchange. Exactly one terminal Msg: the `ok` arm
  /// with `{ status, body }` (one number field, one bytes field — a non-2xx
  /// status is still ok: an HTTP-level error is a delivered response), or
  /// the `err` arm with the reason bytes.
  fetch<M extends Msgish>(spec: FetchSpec, route: FetchRoute<M>): Cmd<M> {
    const names = Object.keys(spec.headers ?? {}).sort();
    return {
      op: "fetch",
      key: route.key ?? "",
      okKind: route.ok,
      errKind: route.err,
      method: spec.method ?? "GET",
      timeoutMs: spec.timeoutMs ?? 0,
      url: spec.url,
      headers: names.map((n) => ({ name: n, value: spec.headers![n] })),
      body: spec.body ?? new Uint8Array(0),
    };
  },

  /// Put bytes on the system clipboard, fire-and-forget (an over-bound or
  /// refused write is dropped — there is no route to report on).
  clipboardWrite(bytes: Uint8Array): Cmd<never> {
    return { op: "clip_write", bytes };
  },

  /// Read the system clipboard. Exactly one terminal Msg: the `ok` arm with
  /// the text bytes, or the `err` arm with the reason bytes ("failed",
  /// "rejected").
  clipboardRead<M extends Msgish>(route: RequestRoute<M>): Cmd<M> {
    return { op: "clip_read", key: route.key ?? "", okKind: route.ok, errKind: route.err };
  },

  /// A keyed one-shot delay: dispatch the named Msg arm once, `ms` from now,
  /// with the fire time (milliseconds) as its single number payload field.
  /// Re-issuing a live key re-arms it from now (the debounce discipline);
  /// `Cmd.cancel(key)` drops it silently.
  delay<M extends Msgish>(key: string, ms: number, msgKind: TimestampKind<M>): Cmd<M> {
    return { op: "delay", key, afterMs: ms, msgKind };
  },

  /// Run a subprocess as a STREAM: each stdout line dispatches the `line`
  /// arm as it arrives (line mode), or whole stdout buffers to the exit
  /// (`collect: true`); exactly one terminal follows — the `exit` arm on a
  /// clean exit, the `err` arm with the reason bytes on every other end.
  /// The key stays live for the whole stream: `Cmd.cancel(key)` ends the
  /// child mid-stream (err arm "cancelled" — loud on purpose: killing a
  /// process is an observable event), and a spawn whose key is already
  /// streaming is rejected, never replaced — a running subprocess is never
  /// killed implicitly; cancel it first.
  spawn<M extends Msgish>(
    argv: readonly Uint8Array[],
    route: SpawnRoute<M> | SpawnCollectRoute<M>,
  ): Cmd<M> {
    const collect = "collect" in route && route.collect === true;
    return {
      op: "spawn",
      key: route.key ?? "",
      lineKind: collect ? "" : ((route as SpawnRoute<M>).line ?? ""),
      exitKind: route.exit,
      errKind: route.err,
      collect,
      argv,
      stdin: route.stdin ?? new Uint8Array(0),
    };
  },

  /// Open (or replace — one player is the whole surface) the keyed audio
  /// event stream: resolve the source cascade (local path, then url, cached
  /// and integrity-gated) and start playback. Every playback event
  /// dispatches the `event` arm until `Cmd.audioStop(key)` closes the
  /// stream. Failure is never silent: an unplayable source arrives as a
  /// "failed" event, a refused command as "rejected".
  audioPlay<M extends Msgish>(key: string, source: AudioSource, route: AudioRoute<M>): Cmd<M> {
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

  /// Pause the keyed playback in place (no event echo — the caller
  /// commanded it). A key with no open stream no-ops.
  audioPause(key: string): Cmd<never> {
    return { op: "audio_ctl", key, verb: "pause", value: 0 };
  },

  /// Resume the keyed playback. A player that can no longer resume reports
  /// one "failed" event on the stream instead of silence.
  audioResume(key: string): Cmd<never> {
    return { op: "audio_ctl", key, verb: "resume", value: 0 };
  },

  /// Stop the keyed playback and CLOSE its event stream: no events for the
  /// key after this. Stop is the audio stream's cancel.
  audioStop(key: string): Cmd<never> {
    return { op: "audio_ctl", key, verb: "stop", value: 0 };
  },

  /// Jump the keyed playback to `ms` (the platform clamps to the duration).
  /// No event echo — the next position tick reports from there.
  audioSeek(key: string, ms: number): Cmd<never> {
    return { op: "audio_ctl", key, verb: "seek", value: ms };
  },

  /// Set playback volume, clamped to 0..1 and remembered across tracks: the
  /// next audioPlay re-applies it.
  audioSetVolume(key: string, volume: number): Cmd<never> {
    return { op: "audio_ctl", key, verb: "volume", value: volume };
  },

  /// Show the window with the declared `label`: un-hide + activate — the
  /// counterpart to a `close_policy = "hide"` hide and the tray "Open"
  /// consequence; also restores a minimized window. Fire-and-forget: no
  /// result Msg (the window's own frame event carries the state), and an
  /// unknown label is a no-op. The label is a string literal — window
  /// labels are declarations.
  showWindow(label: string): Cmd<never> {
    return { op: "window_show", label };
  },

  /// Quit the app for real — the graceful terminate, and the tray "Quit"
  /// consequence. The host quits through the SAME shutdown path a
  /// last-window close takes, so the stop hook runs exactly once and a
  /// recording session seals its journal. Fire-and-forget.
  quitApp(): Cmd<never> {
    return { op: "quit_app" };
  },

  /// Load an image at runtime under the model-owned numeric ImageId your
  /// markup binds (`<image image="{id}"/>`, `<avatar image="{id}"/>`):
  /// resolve the source cascade (local path first, then a verified cache
  /// entry, then the network), decode through the platform codec, register
  /// the pixels under `id`, and dispatch exactly ONE `event` arm — state
  /// "loaded" with the decoded width/height, or one failure class. Failure
  /// is never silent, and views referencing the id repaint on the next
  /// frame. One load per id at a time: a duplicate live id dispatches state
  /// "rejected" (finish or re-key instead — ids are model data). Ids are
  /// positive integers below 2^53 outside the reserved bit-63 namespace;
  /// 0 is the no-image sentinel and dispatches "rejected".
  imageLoad<M extends Msgish>(id: number, source: ImageSource, route: ImageRoute<M>): Cmd<M> {
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

  /// Several commands from one dispatch, performed in order.
  batch<M extends Msgish>(cmds: readonly Cmd<M>[]): Cmd<M> {
    return { op: "batch", cmds };
  },
};

/// An inert subscription descriptor: recurring effects declared FROM the
/// model. An app that needs them exports `subscriptions(model): Sub<Msg>`;
/// after every commit the host reconciles the returned set against its
/// active timers by key (new key or changed interval re-arms; a missing key
/// cancels). Like Cmd, Sub values are data, legal only in that function's
/// return path (NS1025).
export type Sub<M extends Msgish> =
  | { readonly op: "none" }
  | { readonly op: "timer"; readonly key: string; readonly everyMs: number; readonly msgKind: string }
  | { readonly op: "batch"; readonly subs: readonly Sub<M>[] };

export const Sub = {
  /// No subscriptions (e.g. everything paused).
  none: { op: "none" } as Sub<never>,

  /// A repeating timer named by `key`, firing every `everyMs` milliseconds.
  /// Each fire dispatches the named Msg arm with the current time (ms) as
  /// its single number payload field.
  timer<M extends Msgish>(key: string, everyMs: number, msgKind: TimestampKind<M>): Sub<M> {
    return { op: "timer", key, everyMs, msgKind };
  },

  /// Several subscriptions at once.
  batch<M extends Msgish>(subs: readonly Sub<M>[]): Sub<M> {
    return { op: "batch", subs };
  },
};
