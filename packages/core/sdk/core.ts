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
//   Cmd.videoLoad(key, { surface, path?, url?, autoplay?, loop?, muted? }, { event })
//                                open (or replace — one player is the whole
//                                surface) the video event stream feeding the
//                                media-surface `surface` names (the same
//                                model-owned id the markup binds): every
//                                playback event dispatches the `event` arm (the
//                                seven-field record below) until Cmd.videoStop
//                                closes the stream. Pixels never ride the
//                                events — decoded frames flow platform-side
//                                into the bound surface.
//   Cmd.videoPlay(key) / videoPause(key) / videoStop(key)
//   Cmd.videoSeek(key, ms) / Cmd.videoSetVolume(key, volume)
//   Cmd.videoSetMuted(key, muted) / Cmd.videoSetLoop(key, loop)
//                                drive the open playback in place — fire-and-
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
//                                five-field record below, the requested id
//                                echoed) — state "loaded" with the decoded
//                                width/height, or one failure class. One load
//                                per id at a time: a duplicate live id
//                                dispatches state "rejected".
//   Cmd.imageCancel(id)          end the in-flight load under the id, if any
//                                — loud, the spawn discipline: the load's
//                                event arm delivers state "cancelled" and the
//                                id frees for a fresh load once it lands. An
//                                id with no live load no-ops.
//   Cmd.imageUnregister(id)      free the registry slot under the id: the
//                                pixels are released, views referencing the
//                                id draw their fallback, and the slot is
//                                open for another load. Synchronous registry
//                                surgery like registration itself — not an
//                                effect, no Msg follows; an id with no
//                                registration no-ops. A load IN FLIGHT under
//                                the id is untouched: its terminal still
//                                registers — cancel the load first to keep
//                                the slot free.
//   Cmd.channelOpen(key, { event })
//                                open an EXTERNAL-SOURCE CHANNEL under the
//                                app's numeric key: the host stages a
//                                long-lived, thread-safe posting seam its
//                                NATIVE side feeds — embedders and
//                                platform-services extensions post bytes
//                                from their own threads (sockets, watchers,
//                                workers), and each accepted post arrives as
//                                one "data" event through the `event` arm
//                                (the five-field record below) with the
//                                honest back-pressure counters aboard. The
//                                TS tier opens, closes, and receives;
//                                POSTING is not a TS verb — transpiled cores
//                                are single-threaded by design, so the
//                                posting handle lives on the native side
//                                (`Effects.channelHandle(key)`). One channel
//                                per key at a time: a duplicate live key
//                                dispatches state "rejected". No timer
//                                polling anywhere: the source wakes the
//                                loop itself.
//   Cmd.channelClose(key)        close the open channel under the key, if
//                                any: staged posts flush, exactly one
//                                "closed" event (final drop totals)
//                                dispatches the event arm, and the key
//                                frees. A key with no open channel no-ops.
//   Cmd.ptySpawn(argv, { key?, cols?, rows?, term?, event })
//                                open a PSEUDO-TERMINAL SESSION — a spawn
//                                with a different transport: run argv on a
//                                fresh pty whose initial grid is cols x rows
//                                (80x24 by default) and whose TERM is `term`
//                                (omitted = the engine's default). Every
//                                session event dispatches the `event` arm
//                                (the six-field record below): "output"
//                                events carry coalesced batches of child
//                                output across dispatches — feed them to the
//                                terminal emulator — until the exactly-one
//                                "exit" terminal (a refused spawn is one
//                                "exit" with reason "rejected"; a transport
//                                that could not start, one with
//                                "spawn_failed"). One session per key at a
//                                time, never replaced implicitly — kill it
//                                first, the spawn discipline.
//   Cmd.ptyWrite(key, bytes)     write bytes toward the session's child —
//                                keystrokes and pastes, fire-and-forget: a
//                                key with no open session no-ops, and
//                                refused payloads count into the exit's
//                                droppedWrites, never silence.
//   Cmd.ptyResize(key, cols, rows)
//                                push a new grid to the session so the child
//                                receives SIGWINCH — fire-and-forget like
//                                ptyWrite; a key with no open session
//                                no-ops.
//   Cmd.ptyKill(key)             terminate the session's child — LOUD, the
//                                spawn cancel discipline: the session's one
//                                "exit" terminal arrives through its own
//                                event arm with reason "cancelled" and the
//                                key frees once it lands. A key with no open
//                                session no-ops. Sessions are their own
//                                family's to end: the string-keyed
//                                Cmd.cancel never touches them, the way
//                                Cmd.audioStop is audio's close.
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
// spawn/audioPlay/videoLoad streams are Cmd-INITIATED — imperative opens
// with a keyed lifecycle the app drives and cancels.
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
/// exactly the six AudioEventArm fields. The `state` check runs BOTH
/// directions: the `&` constraint holds the arm's states to AudioState,
/// and the tuple-wrapped reverse check holds AudioState to the arm's
/// states — a narrower union would silently drop event states the host
/// emits, so it is refused here, not discovered at runtime.
export type AudioEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof AudioEventArm]
    ? [keyof AudioEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & AudioEventArm
        ? [AudioState] extends [M["state"]]
          ? M["kind"]
          : never
        : never
      : never
    : never
  : never;

/// The video event states, the audio vocabulary without spectrum: `loaded`
/// acknowledges a successful load with the player's duration estimate and
/// the stream's decoded pixel dimensions; `position` ticks at the
/// platform's honest cadence (~500ms) while playing; `completed` fires
/// exactly once when a NON-LOOPING playback reaches its natural end (a
/// looping playback wraps and never completes); `failed` reports a
/// load/decode/device failure; `rejected` a command the effects layer
/// refused (an empty or over-long source, a non-http(s) url, an invalid
/// surface id).
export type VideoState = "loaded" | "position" | "completed" | "failed" | "rejected";

/// The payload shape of a video event arm — seven fields, matched by NAME
/// (the AudioEventArm convention). `state` must be a named
/// string-literal-union alias carrying exactly the five VideoState members
/// (any declaration order — the host matches members by name).
/// `positionMs`/`durationMs` are milliseconds; `playing` is the player's
/// transport state; `buffering` is true while a streamed source is stalled
/// waiting for network bytes; `width`/`height` are the stream's decoded
/// pixel dimensions (delivered on "loaded", 0 elsewhere).
export type VideoEventArm = {
  readonly state: VideoState;
  readonly positionMs: number;
  readonly durationMs: number;
  readonly playing: boolean;
  readonly buffering: boolean;
  readonly width: number;
  readonly height: number;
};

/// The Msg arms a video event stream may target: arms whose payload is
/// exactly the seven VideoEventArm fields. The `state` check runs BOTH
/// directions (the AudioEventKind convention): the `&` constraint holds
/// the arm's states to VideoState, and the tuple-wrapped reverse check
/// holds VideoState to the arm's states — a narrower union would
/// silently drop event states the host emits, so it is refused here,
/// not discovered at runtime.
export type VideoEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof VideoEventArm]
    ? [keyof VideoEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & VideoEventArm
        ? [VideoState] extends [M["state"]]
          ? M["kind"]
          : never
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
/// "unsupported" (no platform codec), "decode_failed", "registry_full", and
/// "alloc_failed" (the host refused the memory the registration needed —
/// resource exhaustion, not corrupt bytes: the same source may load once
/// memory frees).
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

/// The payload shape of an image result arm — five fields, matched by NAME
/// (the AudioEventArm convention). `id` is the requested ImageId echoed
/// verbatim, so two concurrent loads sharing one event arm stay
/// distinguishable in `update` (an id the wire cannot carry exactly — 0,
/// negatives, fractions, 2^53 and past — echoes 0, the no-image sentinel:
/// there is no honest integer to echo); `state` must be a named
/// string-literal-union alias carrying exactly the fifteen ImageState
/// members (any declaration order — the host matches members by name);
/// `width`/`height` are the decoded pixel dimensions ("loaded" only, 0
/// otherwise); `status` is the HTTP status for url loads that performed an
/// exchange, 0 when none occurred (local paths, cache hits) — 0 is signal,
/// not a missing value: a cache hit is a real "loaded" with no exchange
/// behind it, so apps can distinguish a network load from a cached one.
export type ImageEventArm = {
  readonly id: number;
  readonly state: ImageState;
  readonly width: number;
  readonly height: number;
  readonly status: number;
};

/// The Msg arms an image load result may target: arms whose payload is
/// exactly the five ImageEventArm fields. The `state` check runs BOTH
/// directions (the AudioEventKind convention): the `&` constraint holds
/// the arm's states to ImageState, and the tuple-wrapped reverse check
/// holds ImageState to the arm's states — a narrower union would
/// silently drop result states the host emits, so it is refused here,
/// not discovered at runtime.
export type ImageEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof ImageEventArm]
    ? [keyof ImageEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & ImageEventArm
        ? [ImageState] extends [M["state"]]
          ? M["kind"]
          : never
        : never
      : never
    : never
  : never;

/// The external-source channel event states, mirroring the engine's
/// vocabulary: "data" is one delivered post from the native side's
/// thread-safe handle; "closed" is the exactly-one terminal
/// `Cmd.channelClose` produces (final drop totals aboard); "rejected" is
/// the exactly-one terminal of a refused open (duplicate live key, a
/// full channel table, an occupied engine key).
export type ChannelState = "data" | "closed" | "rejected";

/// The payload shape of a channel event arm — five fields, matched by
/// NAME (the AudioEventArm convention). `key` is the channel key echoed
/// verbatim, so concurrent channels sharing one arm stay
/// distinguishable (a key the wire cannot carry exactly echoes 0);
/// `state` must be a named string-literal-union alias carrying exactly
/// the three ChannelState members (any declaration order — the host
/// matches members by name); `bytes` is the post's payload ("data"
/// events only, empty otherwise); `droppedPending`/`droppedTotal` are
/// the back-pressure counters — posts the native side's handle refused
/// since the previous delivered event, and over the channel's whole
/// life. Never silent drops: the counters ride every event.
export type ChannelEventArm = {
  readonly key: number;
  readonly state: ChannelState;
  readonly bytes: Uint8Array;
  readonly droppedPending: number;
  readonly droppedTotal: number;
};

/// The Msg arms a channel event stream may target: arms whose payload is
/// exactly the five ChannelEventArm fields. The `state` check runs BOTH
/// directions (the AudioEventKind convention): the `&` constraint holds
/// the arm's states to ChannelState, and the tuple-wrapped reverse check
/// holds ChannelState to the arm's states — a narrower union would
/// silently drop event states the host emits, so it is refused here,
/// not discovered at runtime.
export type ChannelEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof ChannelEventArm]
    ? [keyof ChannelEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & ChannelEventArm
        ? [ChannelState] extends [M["state"]]
          ? M["kind"]
          : never
        : never
      : never
    : never
  : never;

/// `Cmd.channelOpen` routing: every channel event dispatches the `event`
/// arm (the five-field ChannelEventArm record, matched by field name).
export interface ChannelRoute<M extends Msgish> {
  readonly event: ChannelEventKind<M>;
}

/// The pty session event states, mirroring the engine's vocabulary:
/// "output" is one coalesced batch of child output; "exit" is the
/// exactly-one terminal every session produces — a clean end, a signal,
/// a `Cmd.ptyKill`, a refused spawn, or a transport that could not
/// start (the `reason` field tells which).
export type PtyState = "output" | "exit";

/// How a pty session ended, the spawn exit vocabulary: "exited" with
/// the child's code, "signaled" with the signal, "cancelled" after
/// `Cmd.ptyKill`, "rejected" for a spawn refused before a child existed
/// (duplicate live key, full table, bad grid), "spawn_failed" when the
/// pty or exec could not start.
export type PtyExitReason = "exited" | "signaled" | "cancelled" | "rejected" | "spawn_failed";

/// The payload shape of a pty event arm — seven fields, matched by NAME
/// (the AudioEventArm convention). `key` is the app's own session key
/// (the `Cmd.ptySpawn` `key`, or "" when the spawn named none) — two
/// sessions routing one event arm are told apart by this field. `state`
/// must be a named string-literal-union alias carrying exactly the two
/// PtyState members and `reason` one carrying exactly the five
/// PtyExitReason members (any declaration order — the host matches
/// members by name); `bytes` is the coalesced output batch ("output"
/// events only, empty otherwise); `code` is the child's exit code on an
/// "exited" end, -1 otherwise; `signal` is the fatal signal after a
/// "signaled" end, else 0; `droppedWrites` counts `Cmd.ptyWrite`
/// payloads refused over the session's life — zero means every write
/// reached the child, never a silent drop.
export type PtyEventArm = {
  readonly key: string;
  readonly state: PtyState;
  readonly bytes: Uint8Array;
  readonly code: number;
  readonly reason: PtyExitReason;
  readonly signal: number;
  readonly droppedWrites: number;
};

/// The Msg arms a pty session may target: arms whose payload is exactly
/// the six PtyEventArm fields. The `state` and `reason` checks run BOTH
/// directions (the AudioEventKind convention): the `&` constraint holds
/// the arm's unions to PtyState/PtyExitReason, and the tuple-wrapped
/// reverse checks hold them to the arm's — a narrower union would
/// silently drop events the host emits, so it is refused here, not
/// discovered at runtime.
export type PtyEventKind<M extends Msgish> = M extends Msgish
  ? [Exclude<keyof M, "kind">] extends [keyof PtyEventArm]
    ? [keyof PtyEventArm] extends [Exclude<keyof M, "kind">]
      ? M extends Msgish & PtyEventArm
        ? [PtyState] extends [M["state"]]
          ? [PtyExitReason] extends [M["reason"]]
            ? M["kind"]
            : never
          : never
        : never
      : never
    : never
  : never;

/// `Cmd.ptySpawn` routing: every session event dispatches the `event`
/// arm (the six-field PtyEventArm record, matched by field name).
/// `cols`/`rows` are the initial grid the child observes (80x24 when
/// omitted); `term` is the TERM the child starts with (omitted = the
/// engine's default). The optional `key` names the session for
/// ptyWrite/ptyResize/ptyKill.
export interface PtyRoute<M extends Msgish> {
  readonly key?: string;
  readonly cols?: number;
  readonly rows?: number;
  readonly term?: string;
  readonly event: PtyEventKind<M>;
}

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

/// A `Cmd.videoLoad` source. `surface` is the model-owned media-surface id
/// the markup binds — the texture channel the decoded frames feed. The
/// local `path` is tried first; a missing file falls through to `url`
/// (streamed progressively, playable before the download finishes). At
/// least one of path/url must be present. `autoplay` (default true) starts
/// playback as soon as the load lands — false loads paused at position
/// zero, the poster-frame shape; `loop` wraps from the natural end back to
/// zero (a looping playback never delivers "completed"); `muted` starts
/// the audio track muted, independent of the remembered volume.
export interface VideoSource {
  readonly surface: number;
  readonly path?: Uint8Array;
  readonly url?: Uint8Array;
  readonly autoplay?: boolean;
  readonly loop?: boolean;
  readonly muted?: boolean;
}

/// `Cmd.videoLoad` routing: every playback event dispatches the `event`
/// arm (the seven-field VideoEventArm record, matched by field name).
export interface VideoRoute<M extends Msgish> {
  readonly event: VideoEventKind<M>;
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
/// arm (the five-field ImageEventArm record, matched by field name).
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
      /// Seek position (ms) / volume (0..1) / the muted-loop switch
      /// (0 = off, 1 = on); 0 for the value-less verbs.
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
  | { readonly op: "image_cancel"; readonly id: number }
  | { readonly op: "image_unregister"; readonly id: number }
  | { readonly op: "channel_open"; readonly key: number; readonly eventKind: string }
  | { readonly op: "channel_close"; readonly key: number }
  | {
      readonly op: "pty_spawn";
      readonly key: string;
      readonly eventKind: string;
      readonly cols: number;
      readonly rows: number;
      /// "" = the engine's default TERM (the wire never bakes it in).
      readonly term: string;
      readonly argv: readonly Uint8Array[];
    }
  | { readonly op: "pty_write"; readonly key: string; readonly bytes: Uint8Array }
  | { readonly op: "pty_resize"; readonly key: string; readonly cols: number; readonly rows: number }
  | { readonly op: "pty_kill"; readonly key: string }
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

  /// Open (or replace — one player is the whole surface) the keyed video
  /// event stream: claim the media-surface the source names, resolve the
  /// source cascade (local path, then url) and start playback (autoplay,
  /// the default). Every playback event dispatches the `event` arm until
  /// `Cmd.videoStop(key)` closes the stream. Pixels never ride the
  /// events: decoded frames flow platform-side into the bound surface.
  /// Failure is never silent: an unplayable source arrives as a "failed"
  /// event, a refused command as "rejected". Replacing is not stopping:
  /// a replaced load still delivers the terminal it owes (its failure is
  /// never silent either), routed to ITS OWN event arm — only
  /// `Cmd.videoStop` cancels a stream's undelivered answers.
  videoLoad<M extends Msgish>(key: string, source: VideoSource, route: VideoRoute<M>): Cmd<M> {
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

  /// Start or resume the loaded playback — the poster-frame counterpart
  /// of `autoplay: false`, and un-pause. A key with no open stream
  /// no-ops; a player that can no longer start reports one "failed"
  /// event on the stream instead of silence.
  videoPlay(key: string): Cmd<never> {
    return { op: "video_ctl", key, verb: "play", value: 0 };
  },

  /// Pause the keyed playback in place; the surface keeps its last frame
  /// (no event echo — the caller commanded it). A key with no open
  /// stream no-ops.
  videoPause(key: string): Cmd<never> {
    return { op: "video_ctl", key, verb: "pause", value: 0 };
  },

  /// Stop the keyed playback, release the surface claim, and CLOSE its
  /// event stream: no events for the key after this. Stop is the video
  /// stream's cancel, exactly `Cmd.audioStop`'s discipline.
  videoStop(key: string): Cmd<never> {
    return { op: "video_ctl", key, verb: "stop", value: 0 };
  },

  /// Jump the keyed playback to `ms` (the platform clamps to the
  /// duration; a paused seek still pushes the sought frame, so scrubbing
  /// is visible). No event echo — the next position tick reports from
  /// there.
  videoSeek(key: string, ms: number): Cmd<never> {
    return { op: "video_ctl", key, verb: "seek", value: ms };
  },

  /// Set playback volume, clamped to 0..1 and remembered across loads:
  /// the next videoLoad re-applies it. Independent of mute.
  videoSetVolume(key: string, volume: number): Cmd<never> {
    return { op: "video_ctl", key, verb: "volume", value: volume };
  },

  /// Mute or unmute the playback's audio track without touching the
  /// remembered volume (a fresh load's `muted` option is the way to
  /// start muted).
  videoSetMuted(key: string, muted: boolean): Cmd<never> {
    return { op: "video_ctl", key, verb: "muted", value: muted ? 1 : 0 };
  },

  /// Enable or disable looping on the open playback (a fresh load's
  /// `loop` option covers the start-looping case). A looping playback
  /// never delivers "completed".
  videoSetLoop(key: string, loop: boolean): Cmd<never> {
    return { op: "video_ctl", key, verb: "loop", value: loop ? 1 : 0 };
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
  /// "loaded" with the decoded width/height, or one failure class, always
  /// echoing the requested id so concurrent loads sharing the arm stay
  /// distinguishable. Failure is never silent, and views referencing the
  /// id repaint on the next
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

  /// End the in-flight image load under `id`, if any — LOUDLY: the load's
  /// one terminal arrives as its own `event` arm with state "cancelled"
  /// (ending an in-flight load is an observable event, the spawn cancel
  /// discipline), and the id is free for a fresh load once that terminal
  /// lands. Aimed at an id with no live load it no-ops (the load it aimed
  /// at already delivered its terminal). Image loads are keyed by their
  /// numeric id, so the string-keyed `Cmd.cancel` never touches them —
  /// this is their cancel, the way `Cmd.audioStop` is audio's.
  imageCancel(id: number): Cmd<never> {
    return { op: "image_cancel", id };
  },

  /// Free the registry slot under `id`: the pixels are released, views
  /// referencing the id draw their fallback (avatar initials) on the next
  /// frame, and the slot — one of the registry's 16 — is open for another
  /// load (the gallery eviction move: unregister the evictee, load the
  /// newcomer under a fresh id). Like registration itself this is
  /// synchronous registry surgery, not an effect: no Msg follows, and an
  /// id with no registration no-ops (whatever it aimed at is already
  /// gone, `Cmd.imageCancel`'s idle rule). It frees only the CURRENT
  /// registration — a load IN FLIGHT under the id is untouched and its
  /// terminal still registers the pixels; to keep the slot free, end the
  /// load with `Cmd.imageCancel(id)` first.
  imageUnregister(id: number): Cmd<never> {
    return { op: "image_unregister", id };
  },

  /// Open an external-source channel under your numeric `key`: the
  /// host stages a long-lived, thread-safe posting seam its NATIVE
  /// side feeds — an embedder or platform-services extension resolves
  /// the handle (`Effects.channelHandle(key)`) and posts bytes from
  /// its own threads (a socket reader, a file watcher, a worker), and
  /// each accepted post arrives as one "data" event through the
  /// `event` arm, waking the loop itself — no timer polling anywhere.
  /// POSTING is deliberately not a TS verb: transpiled cores are
  /// single-threaded, so the TS tier opens, closes, and receives while
  /// the native side feeds. Back-pressure is part of the contract:
  /// the native `post` answers a four-way `ChannelHandle.PostResult`
  /// (accepted / dropped_full / dropped_oversized / closed), so a
  /// producer tells transient back-pressure from closure, and refused
  /// posts count into `droppedPending`/`droppedTotal` on the next
  /// delivered event, never silence. The native post never blocks its
  /// producer given a conforming host wake — the platform's `wake_fn`
  /// is contractually a bounded, enqueue-only nudge (see
  /// `PlatformServices.wake_fn`; every first-party host conforms), and
  /// the runtime holds no channel lock across it. One channel per key at a
  /// time — a duplicate live key dispatches state "rejected" — and the
  /// key shares the engine's effect-key space (a same-key fetch is
  /// blocked while the channel lives). Keys are positive integers
  /// below 2^53; the events are journaled at the effect boundary, so
  /// a recorded session replays the whole stream from the journal and
  /// never NEEDS the source — under replay the open parks and the
  /// native handle is inert (every post answers closed). The opening
  /// update still re-executes, so a native producer launched
  /// unconditionally really starts and is stopped at its first post;
  /// one that consults the handle's live() before launching never
  /// starts, keeping replay fully offline.
  channelOpen<M extends Msgish>(key: number, route: ChannelRoute<M>): Cmd<M> {
    return { op: "channel_open", key, eventKind: route.event };
  },

  /// Close the open channel under `key`: posts stop landing, the
  /// staged backlog flushes, and exactly one "closed" event (final
  /// drop totals aboard) dispatches the event arm — then the key is
  /// free again. A key with no open channel no-ops. Channels are keyed
  /// by their numeric key, so the string-keyed `Cmd.cancel` never
  /// touches them — this is their close, the way `Cmd.audioStop` is
  /// audio's.
  channelClose(key: number): Cmd<never> {
    return { op: "channel_close", key };
  },

  /// Open a pseudo-terminal session — a spawn with a different
  /// transport: run `argv` on a fresh pty (same argv budgets, same
  /// child environment policy) whose initial grid is `cols` x `rows`
  /// (80x24 by default) and whose TERM is `term` (omitted = the
  /// engine's default). Every session event dispatches the `event` arm:
  /// "output" events carry coalesced batches of child output across
  /// dispatches — feed them to the terminal emulator and move on —
  /// until the exactly-one "exit" terminal retires the session (a
  /// refused spawn is one "exit" with reason "rejected"; a transport
  /// that could not start, one with "spawn_failed" — failure is never
  /// silent). One session per key at a time, never replaced implicitly:
  /// a running terminal's child is a running subprocess — kill it
  /// first, the spawn discipline.
  ptySpawn<M extends Msgish>(argv: readonly Uint8Array[], route: PtyRoute<M>): Cmd<M> {
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

  /// Write bytes toward the keyed session's child — keystrokes and
  /// pastes, fire-and-forget: a key with no open session no-ops (the
  /// exit was already on its way), and refused payloads (over the
  /// engine's per-write bound, or a child that stopped reading) count
  /// into the exit event's droppedWrites — never silence.
  ptyWrite(key: string, bytes: Uint8Array): Cmd<never> {
    return { op: "pty_write", key, bytes };
  },

  /// Push a new grid to the keyed session so the child receives
  /// SIGWINCH — fire-and-forget like ptyWrite; a key with no open
  /// session no-ops.
  ptyResize(key: string, cols: number, rows: number): Cmd<never> {
    return { op: "pty_resize", key, cols, rows };
  },

  /// Terminate the keyed session's child — LOUD, the spawn cancel
  /// discipline: the session's one "exit" terminal arrives through its
  /// own event arm with reason "cancelled" and the key frees once it
  /// lands. A key with no open session no-ops. Sessions are their own
  /// family's to end: the string-keyed `Cmd.cancel` never touches them
  /// — this is their kill, the way `Cmd.audioStop` is audio's close.
  ptyKill(key: string): Cmd<never> {
    return { op: "pty_kill", key };
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
