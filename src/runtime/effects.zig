//! The effect system: TEA's `Cmd` half for `UiApp`.
//!
//! `Effects(Msg)` runs subprocesses, HTTP fetches, and whole-file
//! reads/writes on worker threads
//! owned by the app loop, streams subprocess stdout lines back as typed
//! `Msg` values (or, in `.collect` mode, accumulates whole stdout plus a
//! stderr tail and delivers both on the exit Msg), reports process exits
//! the same way, and delivers each fetch's terminal outcome as exactly
//! one `Msg` — with `.response = .stream` framing the response body into
//! `on_line` Msgs first (the spawn `.lines` contract over HTTP, for
//! NDJSON/SSE endpoints that hold the connection open). File effects
//! (`writeFile`/`readFile`) follow the fetch shape: one bounded
//! operation, one terminal Msg with an explicit outcome
//! (ok / not_found / io_failed / truncated / rejected / cancelled) —
//! TEA-friendly persistence without smuggling an `Io` handle into
//! `update`. Clipboard effects (`writeClipboard`/`readClipboard`) keep
//! the same shape over the platform pasteboard — the seam the
//! runtime's cmd+C copy uses — executed synchronously on the loop
//! thread (pasteboards are main-thread services), so apps stop
//! spawning `pbcopy`. The model is
//! never touched off-thread: workers post
//! fixed-size completion records into a bounded MPSC queue, nudge the
//! platform loop through `PlatformServices.wake_fn`, and the loop thread
//! drains the queue and dispatches Msgs through the app's `update`.
//!
//! Design points, mirroring the framework's fixed-capacity philosophy:
//!
//! - Caller-chosen `u64` keys identify effects (store them in the model);
//!   there are no handles to leak. `cancel(key)` kills and reaps.
//! - Execution is thread-per-effect with a hard cap (`max_effects` slots
//!   shared between spawns and fetches). Subprocess streaming and HTTP
//!   exchanges are blocking-I/O-dominated, so a shared pool would need
//!   multiplexing for zero gain at this scale; one thread whose lifetime
//!   equals its effect keeps cancellation and reaping local to a slot.
//!   A real fetch additionally borrows one `std.Io.Threaded` task thread
//!   for the blocking HTTP exchange so the worker can interrupt it on
//!   cancel or timeout.
//! - Overflow is NEVER silent: a spawn that cannot run surfaces as an
//!   `on_exit` Msg with reason `.rejected` and a fetch that cannot run as
//!   an `on_response` Msg with outcome `.rejected`; a line dropped on a
//!   full queue is counted into the next delivered line's
//!   `dropped_before` and the exit's `dropped_lines`; an over-long line
//!   is delivered truncated with `truncated = true`; a response body over
//!   `max_effect_body_bytes` arrives truncated with `truncated = true`;
//!   collected stdout over `max_effect_collect_bytes` and a stderr tail
//!   over `max_effect_stderr_tail_bytes` arrive cut with
//!   `output_truncated`/`stderr_truncated` set.
//! - Spawned children inherit the host process environment (HOME, PATH,
//!   ...): the app runner threads it from `std.process.Init` through
//!   `Runtime.Options.environ` into `bindEnviron`; hosts without a
//!   process `Init` (embed/mobile) get `fallbackEnviron()`.
//! - Cancel semantics: after `cancel(key)` returns, no further `on_line`
//!   Msgs for that spawn are dispatched (already-queued lines are
//!   discarded at drain), and exactly one `on_exit` Msg with reason
//!   `.cancelled` follows once the process is reaped. No zombies: the
//!   worker always waits on its child. A cancelled fetch keeps the same
//!   promise: exactly one `on_response` Msg with outcome `.cancelled`,
//!   and nothing for that fetch after it.
//!
//! Payload lifetime: `EffectLine.line`, `EffectResponse.body`,
//! `EffectExit.output`, and `EffectExit.stderr_tail` point into drain
//! scratch that is recycled on the next drained Msg — `update` must copy
//! what it keeps, exactly like `canvas.TextInputEvent` payloads.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("canvas");
const canvas_limits = @import("canvas_limits.zig");
const platform = @import("../platform/root.zig");
const runtime_clock = @import("clock.zig");

/// Maximum in-flight effects (spawn slots / worker threads).
pub const max_effects: usize = 16;
/// Maximum argv entries per spawn.
pub const max_effect_argv: usize = 16;
/// Maximum total bytes across all argv entries of one spawn.
pub const max_effect_argv_bytes: usize = 2048;
/// Maximum stdin payload per spawn (written once, then closed).
pub const max_effect_stdin_bytes: usize = 4096;
/// Default maximum bytes per delivered stdout line; longer lines are
/// truncated (delivered with `truncated = true`, the remainder
/// discarded). Applies to `.lines` spawns and `.stream` fetches only —
/// `.collect` spawns have no line framing. Override per effect with
/// `SpawnOptions.max_line_bytes` / `FetchOptions.max_line_bytes` (agent
/// CLIs emit whole NDJSON events as single lines far beyond 4 KiB).
pub const max_effect_line_bytes: usize = 4096;
/// Hard ceiling for per-effect `max_line_bytes` overrides. A request
/// above it is rejected (reason `.rejected` / outcome `.rejected`) —
/// never silently clamped. Lines beyond the granted bound still arrive
/// truncated and flagged. Overrides above the default heap-allocate one
/// line buffer per accepted effect plus one transfer buffer per
/// oversized line in flight — the ceiling only bounds what an app may
/// ask for; nothing is allocated until an effect opts in. Sized so an
/// envelope protocol (NDJSON wrapping another stream's lines as
/// JSON-escaped `data` fields, e.g. sandbox exec rechunking an agent's
/// stream-json) can carry a full 64 KiB inner line with escaping
/// overhead and framing to spare: the previous 64 KiB ceiling made a
/// near-ceiling inner line unrecoverable because the WRAPPED line blew
/// the same bound both layers individually fit in.
pub const max_effect_line_bytes_ceiling: usize = 256 * 1024;
/// Maximum collected stdout bytes per `.collect` spawn (whole-stdout
/// delivery for tools like `gh --json` that emit one giant line); the
/// overflow is discarded and the exit arrives with
/// `output_truncated = true`. Heap-allocated per accepted collect spawn,
/// like a fetch's body buffer.
pub const max_effect_collect_bytes: usize = 512 * 1024;
/// Stderr tail bytes kept per `.collect` spawn: the LAST bytes the child
/// wrote, delivered on the exit Msg (diagnose failures without an sh
/// re-route). Earlier bytes are discarded and flagged through
/// `stderr_truncated`. `.lines` spawns ignore stderr entirely.
pub const max_effect_stderr_tail_bytes: usize = 4096;

comptime {
    // The stderr tail rides in a queue entry's line buffer.
    std.debug.assert(max_effect_stderr_tail_bytes <= max_effect_line_bytes);
    // File paths ride in a slot's URL storage.
    std.debug.assert(max_effect_file_path_bytes <= max_effect_url_bytes);
}
/// Completion queue depth (lines + exits from all workers combined).
pub const max_effect_queue_entries: usize = 64;
/// Main-thread pending-exit ring (spawn rejections, fake-executor exits
/// that found the queue full). Sized above the slot count so a burst of
/// rejected spawns in one update still surfaces individually.
pub const max_effect_pending_exits: usize = 32;
/// Inline capacity of the loop-side image-terminal stage — the
/// allocation-free everyday case. Unlike the pending ring the stage
/// never evicts: a burst past this spills to a heap ring sized by the
/// burst itself (each staged entry is one `loadImage` call's only
/// terminal, so storage is bounded by the caller's own call count
/// between drains).
pub const max_effect_pending_images_inline: usize = max_effect_pending_exits;

/// Maximum bytes of one fetch's URL.
pub const max_effect_url_bytes: usize = 2048;
/// Maximum extra headers per fetch.
pub const max_effect_fetch_headers: usize = 8;
/// Maximum total bytes across all header names and values of one fetch.
pub const max_effect_fetch_header_bytes: usize = 1024;
/// Maximum request payload per fetch (the body sent to the server).
pub const max_effect_fetch_payload_bytes: usize = 64 * 1024;
/// Maximum response body bytes delivered per fetch; longer bodies arrive
/// truncated (delivered with `truncated = true`, the remainder
/// discarded). Generous next to `max_effect_line_bytes` because fetch
/// bodies are one-shot (JSON API responses, small images), not a stream;
/// full-size image fetches (I1) will revisit this with a per-fetch bound.
pub const max_effect_body_bytes: usize = 256 * 1024;
/// Default per-fetch timeout covering the whole exchange (DNS, connect,
/// TLS, headers, and body). Override per fetch with
/// `FetchOptions.timeout_ms`.
pub const default_effect_fetch_timeout_ms: u32 = 30_000;

/// Maximum bytes of one file effect's path.
pub const max_effect_file_path_bytes: usize = 1024;
/// Maximum file-effect payload: the bytes one `writeFile` writes, and
/// the most one `readFile` delivers (larger files arrive cut with
/// outcome `.truncated`). Sized for JSON session snapshots and app
/// state, not media. An over-bound WRITE is rejected outright — a cut
/// write would corrupt the file on disk, which truncation flags cannot
/// undo.
pub const max_effect_file_bytes: usize = 1024 * 1024;
/// How long teardown waits (total, in milliseconds) for file workers
/// stuck in blocking I/O before abandoning them — the default of the
/// channel's injectable `file_join_deadline_ms`. File I/O is the one
/// effect with no converging force at teardown (nothing to kill, no
/// flag the OS call polls): a write to a FIFO with no reader or a read
/// against a stalled network filesystem can block forever. Halfway
/// through this budget teardown cancels the blocked task (best-effort
/// syscall interruption); a worker still stuck when it expires is
/// abandoned with a bounded, loud leak (see `Effects.deinit`). Generous
/// on purpose — healthy local I/O finishes in milliseconds and never
/// meets this bound.
pub const default_effect_file_join_deadline_ms: u64 = 15_000;

/// Maximum clipboard-effect payload: what one `writeClipboard` writes
/// and the most one `readClipboard` delivers — the platform clipboard
/// bound (`platform.max_clipboard_data_bytes`). Over-bound writes are
/// rejected outright, mirroring `writeFile` (a cut clipboard string
/// must never pass for the whole one).
pub const max_effect_clipboard_bytes: usize = platform.max_clipboard_data_bytes;

/// Maximum bytes of a host request's (or fire-and-forget host send's)
/// name. Mirrors the transpiled-core command wire format, whose name
/// field carries a one-byte length.
pub const max_effect_host_name_bytes: usize = 255;

/// Maximum bytes of a host request's outbound payload (mirrors
/// `max_effect_fetch_payload_bytes`: a command argument, not a bulk
/// transfer).
pub const max_effect_host_payload_bytes: usize = 64 * 1024;

/// Maximum bytes of a host request's result. Mirrors the fetch body
/// bound: the result lands in `update` as one bytes payload, sized for
/// API-shaped answers. An over-bound feed delivers the err route with a
/// teaching message, never a silent cut.
pub const max_effect_host_result_bytes: usize = 256 * 1024;

/// The exit `code` reported for every non-`.exited` reason.
pub const effect_error_exit_code: i32 = -1;

/// Type-erased handle to the runtime's canvas image registry, bound onto
/// the effects channel (`bindImages`) so `update` can turn fetched bytes
/// into drawable ImageIds without reaching for the runtime. Constructed
/// by `Runtime.canvasImageRegistryBinding()`.
pub const ImageRegistryBinding = struct {
    context: *anyopaque,
    register_fn: *const fn (context: *anyopaque, id: u64, width: usize, height: usize, rgba8: []const u8) anyerror!void,
    register_bytes_fn: *const fn (context: *anyopaque, id: u64, bytes: []const u8) anyerror!RegisteredImage,
    unregister_fn: *const fn (context: *anyopaque, id: u64) bool,
};

/// Dimensions of a successfully registered image (what the platform
/// codec decoded).
pub const RegisteredImage = struct {
    width: usize = 0,
    height: usize = 0,
};

/// Type-erased handle to the runtime's window verbs, bound onto the
/// effects channel (`bindWindowActions`) so `update` can drive REAL OS
/// window actions — the seam behind app-drawn close/minimize controls
/// on chromeless windows and the menu-bar-app lifecycle (tray "Open"
/// shows the hidden window, tray "Quit" quits for real). Label-addressed
/// because labels are what apps declare (`ShellWindow.label`,
/// `WindowDescriptor.label`); the runtime side resolves them to live
/// window ids. `quit_fn` alone is app-scoped, not window-scoped.
/// Constructed by `UiApp`.
pub const WindowActionBinding = struct {
    context: *anyopaque,
    close_fn: *const fn (context: *anyopaque, window_label: []const u8) bool,
    minimize_fn: *const fn (context: *anyopaque, window_label: []const u8) bool,
    show_fn: *const fn (context: *anyopaque, window_label: []const u8) bool,
    quit_fn: *const fn (context: *anyopaque) bool,
};

/// Type-erased handle to the embedding host's named-command services,
/// bound onto the effects channel (`bindHostCalls`). This is the seam
/// behind `hostRequest`/`hostSend` — the generic named host call a
/// transpiled app core's command channel (`host`/`host_bytes`/`request`
/// wire records) rides into the host. Both callbacks run on the loop
/// thread during dispatch; `name` and `payload` are valid only for the
/// duration of the call (copy what outlives it). A host answers a
/// request by calling `Effects.feedHostResult(key, ok, bytes)` on the
/// loop thread — synchronously from `request_fn`, or later from an
/// event the host marshals back.
pub const HostCallBinding = struct {
    context: *anyopaque,
    /// Fire-and-forget named host command: no key, no result, no Msg.
    send_fn: *const fn (context: *anyopaque, name: []const u8, payload: []const u8) void,
    /// Keyed routed host command: perform `name` and answer through
    /// `feedHostResult` with this `key`.
    request_fn: *const fn (context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void,
    /// Optional abort notice: the request with `key` was replaced or
    /// cancelled — any late `feedHostResult` for it reports
    /// `error.EffectNotFound` and delivers nothing.
    cancel_fn: ?*const fn (context: *anyopaque, key: u64) void = null,
};

/// Window-action label capacity (`Effects.closeWindow`/`minimizeWindow`/
/// `showWindow`): the mirror copies the last requested label so tests
/// can pin it.
pub const max_window_action_label = 64;

/// The window-action mirror: observable state for every close/minimize/
/// show/quit request made through the channel, recorded before the
/// runtime call (and INSTEAD of it under the fake executor — hermetic
/// tests pin the counts, live runs also perform the verb).
pub const WindowActionState = struct {
    close_count: u32 = 0,
    minimize_count: u32 = 0,
    show_count: u32 = 0,
    quit_count: u32 = 0,
    last_label_buffer: [max_window_action_label]u8 = @splat(0),
    last_label_len: usize = 0,

    pub fn lastLabel(self: *const WindowActionState) []const u8 {
        return self.last_label_buffer[0..self.last_label_len];
    }

    fn record(self: *WindowActionState, label: []const u8) void {
        const len = @min(label.len, max_window_action_label);
        @memcpy(self.last_label_buffer[0..len], label[0..len]);
        self.last_label_len = len;
    }
};

/// How a spawn's stdout comes back. `.lines` streams each line as an
/// `on_line` Msg as it arrives (the default; long-running streams).
/// `.collect` accumulates whole stdout — single-line JSON far beyond the
/// line cap included — and delivers it once, on the exit Msg
/// (`EffectExit.output`), together with the child's stderr tail; collect
/// spawns dispatch no `on_line` Msgs. Both bounded, both flag truncation,
/// neither is ever silent.
pub const EffectOutputMode = enum { lines, collect };

/// How a fetch's response body comes back. `.buffered` (the default)
/// delivers the whole body once, on the terminal `on_response` Msg.
/// `.stream` frames the body into lines as they arrive — each line is
/// an `on_line` Msg (the spawn `.lines` contract over HTTP; NDJSON and
/// SSE endpoints that hold the connection open for a command's whole
/// lifetime are the driver) — and the terminal `on_response` Msg then
/// carries the status with an empty body. The fetch promise holds:
/// exactly one terminal Msg per fetch, and after `cancel(key)` no
/// further line Msgs are dispatched. The whole-exchange timeout applies
/// to the stream's full lifetime — long-lived streams should raise
/// `timeout_ms` accordingly.
pub const FetchResponseMode = enum { buffered, stream };

pub const EffectExitReason = enum {
    /// The process exited on its own; `code` is its exit code.
    exited,
    /// The process died to a signal it was not sent by `cancel`.
    signaled,
    /// `cancel(key)` ended it (or it exited while the cancel was in
    /// flight — after `cancel` the exit always reports `.cancelled`).
    cancelled,
    /// The spawn request never ran: all slots busy, a duplicate active
    /// key, or argv/stdin over capacity.
    rejected,
    /// The process could not be started (missing binary, bad argv).
    spawn_failed,
};

/// Payload for `on_line` Msg constructors. `line` is valid only during
/// the `update` call that receives it — copy what the model keeps.
pub const EffectLine = struct {
    key: u64,
    line: []const u8,
    /// The source line exceeded the effect's line bound (the
    /// `max_effect_line_bytes` default or its per-effect
    /// `max_line_bytes` override); this is its first bound bytes and
    /// the rest was discarded.
    truncated: bool = false,
    /// Whole lines dropped on a full completion queue immediately before
    /// this one. Never silently zero when drops happened: undelivered
    /// drops also accumulate into the exit's `dropped_lines`.
    dropped_before: u32 = 0,
};

/// Payload for `on_exit` Msg constructors. Exactly one is delivered per
/// accepted spawn, and one per rejected spawn (reason `.rejected`).
/// `output` and `stderr_tail` are drain scratch, valid only during the
/// `update` call that receives them — copy what the model keeps (the
/// scalar fields are plain data and safe to store whole for `.lines`
/// spawns, whose slices are always empty).
pub const EffectExit = struct {
    key: u64,
    code: i32 = effect_error_exit_code,
    reason: EffectExitReason = .exited,
    /// Total stdout lines dropped over the effect's lifetime (full
    /// completion queue). Zero means every line was delivered. Always
    /// zero for `.collect` spawns (no line framing, nothing to drop).
    dropped_lines: u32 = 0,
    /// Whole collected stdout for `.collect` spawns; `""` for `.lines`
    /// spawns and for cancelled/rejected exits.
    output: []const u8 = "",
    /// stdout exceeded `max_effect_collect_bytes`: `output` is its first
    /// bytes and the rest was discarded. Never silent.
    output_truncated: bool = false,
    /// The last `max_effect_stderr_tail_bytes` of the child's stderr for
    /// `.collect` spawns (`""` for `.lines`, whose stderr is ignored).
    /// Delivered on every collect exit — check it when `code != 0`.
    stderr_tail: []const u8 = "",
    /// stderr exceeded the tail capacity: `stderr_tail` is its LAST
    /// bytes and earlier output was discarded.
    stderr_truncated: bool = false,
};

/// The terminal outcome of one fetch. Every started fetch delivers
/// exactly one `on_response` Msg carrying one of these — failure is
/// never silent.
pub const EffectFetchOutcome = enum {
    /// A response arrived. `status` is the real HTTP status — including
    /// non-2xx; an HTTP-level error is still a delivered response — and
    /// `body` is its (possibly truncated) body.
    ok,
    /// The fetch never started: all slots busy, a duplicate active key,
    /// a malformed URL or non-http(s) scheme, URL/headers/payload over
    /// capacity, or the executor could not start the exchange as a
    /// cancelable task (an uncancelable exchange would evade `cancel`,
    /// the timeout, and teardown, so it is refused up front).
    rejected,
    /// DNS resolution or the TCP connect failed (unknown host,
    /// connection refused, network unreachable).
    connect_failed,
    /// TLS setup or certificate validation failed.
    tls_failed,
    /// The connection was established but the exchange failed mid-flight
    /// (reset, malformed response, redirect loop, send failure).
    protocol_failed,
    /// No complete response within the fetch's timeout.
    timed_out,
    /// `cancel(key)` ended it.
    cancelled,
};

/// Payload for `on_response` Msg constructors. Exactly one is delivered
/// per fetch — terminal, nothing for that key after it. `body` is
/// binary-safe bytes (zeros and high bits round-trip) valid only during
/// the `update` call that receives it — copy what the model keeps.
pub const EffectResponse = struct {
    key: u64,
    outcome: EffectFetchOutcome = .ok,
    /// The HTTP status code when `outcome == .ok`; 0 otherwise.
    status: u16 = 0,
    /// Response body bytes; empty for every non-`.ok` outcome.
    body: []const u8 = "",
    /// The response body exceeded `max_effect_body_bytes`: this is its
    /// first `max_effect_body_bytes` bytes and the rest was discarded.
    truncated: bool = false,
    /// Loop-side terminal notices evicted from the pending ring to make
    /// room before this one (only under extreme rejection bursts). For
    /// `.stream` fetches this additionally carries stream lines dropped
    /// on a full completion queue that no later line reported. Never
    /// silently zero when something was lost.
    dropped_before: u32 = 0,
};

/// Which file operation a file effect performs.
pub const EffectFileOp = enum { read, write };

/// The terminal outcome of one file effect. Every started file effect
/// delivers exactly one Msg carrying one of these — failure is never
/// silent. `truncated` is a full outcome rather than a flag on `.ok`:
/// a cut JSON snapshot must not be mistaken for a whole one.
pub const EffectFileOutcome = enum {
    /// The operation completed. Reads carry the whole file in `bytes`;
    /// writes wrote every byte (parent directories created as needed).
    ok,
    /// The file does not exist (reads only — writes create the path).
    not_found,
    /// The OS refused: permissions, the path names a directory, disk
    /// errors, an unwritable parent — anything but absence.
    io_failed,
    /// The file exceeds `max_effect_file_bytes` (reads only): `bytes`
    /// is its first bound bytes and the rest was NOT read.
    truncated,
    /// The request never ran: all slots busy, a duplicate active key,
    /// an empty or over-long path, or write bytes over
    /// `max_effect_file_bytes`.
    rejected,
    /// `cancel(key)` ended it before the result was delivered. The
    /// operation itself may still have completed on disk.
    cancelled,
};

/// Payload for file-effect Msg constructors. Exactly one is delivered
/// per `readFile`/`writeFile` — terminal, nothing for that key after
/// it. `bytes` is a read's content (binary-safe), valid only during
/// the `update` call that receives it — copy what the model keeps.
/// Writes always deliver empty `bytes`.
pub const EffectFileResult = struct {
    key: u64,
    op: EffectFileOp = .read,
    outcome: EffectFileOutcome = .ok,
    /// Read contents: the whole file for `.ok`, the first
    /// `max_effect_file_bytes` for `.truncated`, `""` otherwise (and
    /// always for writes).
    bytes: []const u8 = "",
    /// Loop-side terminal notices evicted from the pending ring to make
    /// room before this one (only under extreme rejection bursts).
    /// Never silently zero when something was lost.
    dropped_before: u32 = 0,
};

/// Which clipboard operation a clipboard effect performs.
pub const EffectClipboardOp = enum { read, write };

/// The terminal outcome of one clipboard effect. Every started
/// clipboard effect delivers exactly one Msg carrying one of these —
/// failure is never silent. The taxonomy is deliberately small: the
/// pasteboard is one bounded synchronous platform call, so everything
/// the OS refuses (no clipboard service on the host, content over the
/// read bound, a pasteboard error) is one explicit `.failed`.
pub const EffectClipboardOutcome = enum {
    /// The operation completed: a write's text is on the system
    /// clipboard whole; a read's content is in `text`.
    ok,
    /// The platform clipboard refused or is absent: a host without a
    /// clipboard service, clipboard content over
    /// `max_effect_clipboard_bytes` on read, or a pasteboard error.
    failed,
    /// The request never ran: all slots busy, a duplicate active key,
    /// write text over `max_effect_clipboard_bytes`, or no platform
    /// services bound.
    rejected,
    /// `cancel(key)` ended it before the result was delivered. The
    /// operation itself may still have completed (real clipboard ops
    /// run synchronously at request time).
    cancelled,
};

/// Payload for clipboard-effect Msg constructors. Exactly one is
/// delivered per `writeClipboard`/`readClipboard` — terminal, nothing
/// for that key after it. `text` is a read's clipboard content, valid
/// only during the `update` call that receives it — copy what the
/// model keeps. Writes always deliver empty `text`.
pub const EffectClipboardResult = struct {
    key: u64,
    op: EffectClipboardOp = .write,
    outcome: EffectClipboardOutcome = .ok,
    /// Read contents for `.ok`; `""` otherwise (and always for writes).
    text: []const u8 = "",
    /// Loop-side terminal notices evicted from the pending ring to make
    /// room before this one (only under extreme rejection bursts).
    /// Never silently zero when something was lost.
    dropped_before: u32 = 0,
};

/// Payload for `on_result` Msg constructors of host requests
/// (`hostRequest` — the generic named host call behind transpiled
/// cores' `request` wire records). Exactly one terminal per request,
/// routed by `ok`: true is the success route with the result bytes,
/// false the error route with the error bytes. Unlike the other keyed
/// effects there is no outcome enum and no cancelled terminal — the
/// request contract is REPLACE on key reuse and SILENT drop on cancel,
/// so the only deliveries are the host's answer and the loud rejection
/// (`ok = false`, bytes `"rejected"`) for a request the channel refused
/// (over-bound payload, key collision with another effect kind, no
/// slot, no bound host service).
pub const EffectHostResult = struct {
    key: u64,
    /// True routes the request's ok arm; false its err arm.
    ok: bool = true,
    /// Result (or error) bytes; drain scratch — copy what the model
    /// keeps.
    bytes: []const u8 = "",
};

/// Maximum concurrently armed fx timers per app. Timers are their own
/// fixed table: they do NOT consume `max_effects` slots or worker
/// threads (a timer is a platform service arm, not a blocking effect),
/// and timer keys are their own namespace — an fx timer key never
/// collides with a spawn/fetch/file key.
pub const max_effect_timers: usize = 16;

/// Whether an fx timer fires once and retires or keeps firing until
/// `cancelTimer`.
pub const TimerMode = enum { one_shot, repeating };

/// How an fx timer Msg came to be. Rejection is never silent: a full
/// timer table, a zero interval, or a missing platform timer service
/// delivers exactly one Msg with outcome `.rejected`.
pub const EffectTimerOutcome = enum { fired, rejected };

/// Payload for `on_fire` Msg constructors of fx timers. `timestamp_ns`
/// is the platform's fire timestamp (0 from the fake executor's
/// `fireTimer`, which has no clock).
pub const EffectTimer = struct {
    key: u64,
    timestamp_ns: u64 = 0,
    outcome: EffectTimerOutcome = .fired,
};

/// Longest audio file path `playAudio` accepts, mirroring the platform
/// bound. Longer paths deliver exactly one `.rejected` audio event Msg.
pub const max_effect_audio_path_bytes: usize = platform.max_audio_path_bytes;

/// How an audio event Msg came to be. `loaded` acknowledges a successful
/// `playAudio` load with the platform player's duration readout — the
/// player's own estimate, NOT a measured truth: a source without a seek
/// header is extrapolated from bitrate, and a progressive stream's
/// early readout can be minutes off (later ticks may revise it). An app
/// holding an authoritative duration of its own (a catalog manifest)
/// should prefer it for display; `position` ticks at
/// the platform's coarse honest cadence (~500ms) only while playing;
/// `completed` fires exactly once at the track's natural end; `failed`
/// reports a load/decode/device failure or a platform without audio
/// playback — always as a Msg, never a crash and never silence;
/// `rejected` reports a command the effects layer refused before the
/// platform was asked (an empty or oversized path); `spectrum` carries
/// the platform's real band-magnitude analysis of the playing audio
/// (see `EffectAudio.bands`) at a steady ~25 Hz while audio is audibly
/// playing — hosts that cannot analyze simply never send it (the
/// `audio_spectrum` platform feature names the difference).
pub const EffectAudioEventKind = enum(u8) {
    loaded,
    position,
    completed,
    failed,
    rejected,
    spectrum,
};

/// Payload for `on_event` Msg constructors of audio effects. Positions
/// and durations are milliseconds; `playing` is the player's honest
/// state when the event was produced; `buffering` is true while a
/// streamed URL source is stalled waiting for network bytes — distinct
/// from `playing` (the transport intent): a stream can be un-paused yet
/// silent until bytes arrive, and honest UI shows that difference.
/// Local files and verified cache hits never buffer. All fields are
/// plain data — safe to store in the model, unlike the borrowed byte
/// slices other effect families carry.
pub const EffectAudio = struct {
    key: u64,
    kind: EffectAudioEventKind,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    playing: bool = false,
    buffering: bool = false,
    /// `.spectrum` payload, verbatim from the platform event: 32 band
    /// magnitudes, log-spaced 50 Hz..16 kHz, each byte linear-in-dB from
    /// the -60 dBFS floor (0) to full scale (255) — divide by 255 for a
    /// 0..1 level. All zeros on every other kind. Plain bytes like the
    /// rest of this struct: safe to store in the model.
    bands: [platform.audio_spectrum_band_count]u8 = @splat(0),
};

/// Where the active playback's bytes actually come from — the resolved
/// end of the `playAudio` source cascade (local file, then verified
/// cache entry, then network stream). Exposed in the snapshot and the
/// fake executor's request so tests and automation can pin the
/// resolution order, not just hear audio events.
pub const EffectAudioSource = enum(u8) {
    local,
    cache,
    stream,
};

/// Derive the conventional cache file path for a URL audio source:
/// `<cache_dir>/audio/<hash>.<ext>`, where `<hash>` is the first 16
/// bytes of the URL's SHA-256 in lowercase hex and `<ext>` is the URL's
/// file extension (kept as a decoder hint; dropped when absent or
/// implausibly long). Keying by URL hash makes the cache content-
/// addressed by source: no name collisions, no path-escaping concerns,
/// and clearing it is deleting one directory — `cache_dir` should be
/// the platform caches directory (`app_dirs` kind `.cache`), so the OS
/// already treats it as reclaimable.
pub fn audioCachePath(buffer: []u8, cache_dir: []const u8, url: []const u8) ![]const u8 {
    if (cache_dir.len == 0 or url.len == 0) return error.InvalidAudioOptions;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    const tail = if (std.mem.lastIndexOfScalar(u8, url, '/')) |slash| url[slash + 1 ..] else url;
    var extension: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, tail, '.')) |dot| {
        const candidate = tail[dot..];
        // A plausible extension only: short, and free of query/fragment
        // syntax that would smuggle URL machinery into a file name.
        if (candidate.len <= 8 and std.mem.indexOfAny(u8, candidate, "?#&") == null) {
            extension = candidate;
        }
    }
    return std.fmt.bufPrint(buffer, "{s}/audio/{s}{s}", .{ cache_dir, hex, extension });
}

/// Derive the conventional cache file path for a URL image source:
/// `<cache_dir>/images/<hash>.<ext>` — `audioCachePath`'s convention
/// (first 16 bytes of the URL's SHA-256 in lowercase hex, the extension
/// kept as a decoder hint) under its own `images/` segment so the two
/// caches never collide and each clears independently.
pub fn imageCachePath(buffer: []u8, cache_dir: []const u8, url: []const u8) ![]const u8 {
    if (cache_dir.len == 0 or url.len == 0) return error.InvalidImageOptions;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
    const tail = if (std.mem.lastIndexOfScalar(u8, url, '/')) |slash| url[slash + 1 ..] else url;
    var extension: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, tail, '.')) |dot| {
        const candidate = tail[dot..];
        // A plausible extension only: short, and free of query/fragment
        // syntax that would smuggle URL machinery into a file name.
        if (candidate.len <= 8 and std.mem.indexOfAny(u8, candidate, "?#&") == null) {
            extension = candidate;
        }
    }
    return std.fmt.bufPrint(buffer, "{s}/images/{s}{s}", .{ cache_dir, hex, extension });
}

/// The temp path one cache install writes before its atomic rename
/// into `cache_path`. The name must be WRITER-unique, not merely
/// url-unique or channel-unique: two concurrent loads of the same URL
/// install toward the same cache path, and a shared temp would let one
/// writer truncate the other's bytes mid-write — or rename a
/// half-written file into place. The slot generation alone cannot
/// carry that uniqueness: it is channel-local, so two Effects channels
/// in one process — or two app processes sharing the platform cache
/// directory — can reach the same generation concurrently and collide.
/// `token` is the install's own random draw (`installImageCache` takes
/// it from the operation's executor io), unique across channels and
/// processes alike; the generation stays in the name purely as debris
/// provenance — a leftover `.partial` names which in-flight operation
/// a hard crash interrupted. This function stays a pure formatter on
/// every compile target: the entropy lives with the caller, and no
/// freestanding build can ever run an install (there is no executor io
/// and no cache directory there), so no target gate is needed here.
pub fn imageCachePartialPath(buffer: []u8, cache_path: []const u8, generation: u32, token: u64) ![]const u8 {
    if (cache_path.len == 0) return error.InvalidImageOptions;
    return std.fmt.bufPrint(buffer, "{s}.{d}-{x:0>16}.partial", .{ cache_path, generation, token });
}

/// Longest local path (and cache path) one `loadImage` source may name,
/// mirroring the file effect's path bound; the URL keeps the fetch
/// bound (`max_effect_url_bytes`). Longer strings deliver exactly one
/// `.rejected` image result Msg.
pub const max_effect_image_path_bytes: usize = max_effect_file_path_bytes;

/// Maximum ENCODED source bytes one `loadImage` accepts — from a local
/// file, the URL cache, or the network alike. Sized past the decoded
/// pixel bound (`canvas_limits.max_registered_canvas_image_pixel_bytes`)
/// by the same 1/4 margin the decode scratch carries: an encoded stream
/// larger than that cannot decode inside the registered-image budget on
/// any host, so hauling more bytes would only defer the same
/// `.too_large` answer. Unlike fetch bodies there is no truncated
/// delivery — a cut image can never decode, so over-bound sources fail
/// whole with `.too_large`, never arrive clipped.
pub const max_effect_image_bytes: usize = canvas_limits.max_registered_canvas_image_pixel_bytes +
    canvas_limits.max_registered_canvas_image_pixel_bytes / 4;

/// Bytes of an image effect result's content address in the session
/// journal: the first half of the source bytes' SHA-256, the
/// `audioCachePath` hashing convention. The journal record carries hash
/// and length; the bytes themselves live in the session blob store.
pub const effect_image_blob_hash_len: usize = 16;

/// The terminal outcome of one `loadImage` effect — exactly one Msg per
/// load, `.loaded` or one failure class, never silence. The classes are
/// the union of the source stages and the registered-image API's own
/// errors, so the effect fails with the same vocabulary the direct
/// `registerCanvasImageBytes` path uses.
pub const EffectImageOutcome = enum(u8) {
    /// The pixels are registered under the requested id; `width` and
    /// `height` report what the platform codec decoded.
    loaded,
    /// The request never ran: an invalid id (0, or the reserved
    /// media-surface namespace), no source at all, an over-bound
    /// path/url, a non-http(s) url, all slots busy, or a duplicate
    /// active key.
    rejected,
    /// The local path does not exist and no url was given to fall
    /// through to.
    not_found,
    /// The local read failed for any reason but absence (permissions, a
    /// directory, disk errors). A present-but-unreadable file never
    /// falls through to the url — retrying a different source would
    /// mask the real problem, the audio cascade's rule.
    io_failed,
    /// DNS, TCP, or the connect phase failed (the fetch taxonomy).
    connect_failed,
    /// TLS setup failed.
    tls_failed,
    /// The HTTP exchange broke mid-protocol.
    protocol_failed,
    /// The whole cascade exceeded the effect timeout.
    timed_out,
    /// The server answered with a non-2xx status — carried in
    /// `EffectImageResult.status`. The body is discarded, never decoded
    /// (an error page is not an image).
    http_status,
    /// `cancel(id)` ended the load before its result was delivered.
    cancelled,
    /// The source bytes exceed `max_effect_image_bytes`, or the decoded
    /// pixels exceed the registered-image slot bound
    /// (`error.ImageTooLarge`) — one budget class either way.
    too_large,
    /// The host has no image codec (`error.UnsupportedService`), or no
    /// image registry is bound to this channel.
    unsupported,
    /// The platform codec could not decode the bytes
    /// (`error.ImageDecodeFailed`, impossible decoded dimensions).
    decode_failed,
    /// Every registered-image slot holds another id
    /// (`error.ImageRegistryFull`).
    registry_full,
    /// The host refused the memory the registration needed
    /// (`error.OutOfMemory` — the registry slot's lazily allocated
    /// pixel buffer). The bytes may be perfectly valid: this is
    /// resource exhaustion, not corruption, so it gets its own class —
    /// calling it `decode_failed` would tell the app to distrust a
    /// source that decodes fine on retry. Named for the failing stage
    /// like its siblings (`io_failed`, `decode_failed`): the
    /// allocation failed.
    alloc_failed,
};

/// Payload for `on_result` Msg constructors of image loads. All plain
/// data — safe to store in the model (the decoded pixels live in the
/// runtime's registered-image storage, referenced by id from views).
pub const EffectImageResult = struct {
    /// The requested ImageId, echoed verbatim (it doubles as the effect
    /// key — see `LoadImageOptions.id`).
    id: u64,
    outcome: EffectImageOutcome = .loaded,
    /// Decoded dimensions for `.loaded`; 0 otherwise.
    width: usize = 0,
    height: usize = 0,
    /// The HTTP status for url loads that performed an exchange
    /// (`.http_status`, and `.loaded` from the network); 0 when none
    /// occurred — local paths and cache hits. 0 is signal, not a
    /// missing value: a cache hit is a real `.loaded` with no exchange
    /// behind it, so apps can distinguish a network load from a cached
    /// one, and fabricating the origin's status for it would lie.
    status: u16 = 0,
};

/// Base platform timer id for fx timers: slot N arms the platform timer
/// `effect_timer_platform_id_base + N`. Lives in the framework-reserved
/// id range (`platform.reserved_timer_id_base`) with an `0x00f7_0000`
/// ("eff") offset, distinct from the ui-app markup watch id
/// (`0xffff_ffff_2e70_a11c`) — `UiApp.handleTimer` routes ids in this
/// range back through `Effects.takeTimerMsg` and they never reach the
/// app's `on_timer` callback.
pub const effect_timer_platform_id_base: u64 = platform.reserved_timer_id_base | 0x00f7_0000;

/// Executor selection: `.real` spawns processes on worker threads;
/// `.fake` records spawn requests for tests to inspect and answer with
/// `feedLine`/`feedExit` — fully deterministic, no processes, no threads.
pub const EffectExecutor = enum { real, fake };

/// Which effect channel a journaled result came from (the session
/// record/replay taxonomy — one value per drain-delivered Msg shape,
/// plus `.clock` for journaled wall-clock reads).
pub const EffectResultKind = enum(u8) {
    line = 1,
    exit = 2,
    response = 3,
    file = 4,
    clipboard = 5,
    timer = 6,
    clock = 7,
    audio = 8,
    /// A host-request terminal (`EffectHostResult`). Additive over the
    /// v3 journal layout — no new record fields: the ok/err route rides
    /// `code` (0 ok, 1 err) and a channel-refused rejection is marked
    /// by `exit_reason == .rejected` (rejections regenerate from the
    /// same deterministic validation under replay and are never fed).
    host = 9,
    /// One launch-environment delivery (the TS adapter's `envMsgs`
    /// channel): journaled as the adapter dispatches each launch value,
    /// so replay feeds the RECORDED values instead of re-reading the
    /// replay launch's environment. Additive over the v3 journal layout
    /// — no new record fields: the value rides `payload`, the target
    /// Msg arm name rides `stderr_tail`, and `key` is the dispatch
    /// index. Journals without env records (older recordings, or
    /// launches with no variables set) re-derive from the launch
    /// configuration exactly as before.
    env = 10,
    /// One `loadImage` terminal (`EffectImageResult`). The record's
    /// `payload` carries the ENCODED source bytes as they leave the
    /// drain — the loaded bytes ARE the effect result — and the session
    /// recorder moves them into the content-addressed blob store,
    /// journaling `image_blob_hash`/`image_blob_len` in their place
    /// (journal format v7).
    image = 11,
};

/// Journaled wall-clock reads buffered for replay (`Effects.wallMs`).
/// Bounded like everything else: more reads per drain window than this
/// is a runaway loop, not a session shape.
pub const max_effect_replay_clock_entries: usize = 64;

/// Journaled launch-env deliveries buffered for replay (the `.env`
/// record feed). Bounded like the clock queue: more launch variables
/// than this is a wiring bug, not a session shape.
pub const max_effect_replay_env_entries: usize = 32;

/// One queued launch-env delivery: the target Msg arm name and the
/// recorded value bytes (both reference the journal, which outlives the
/// replay).
pub const ReplayEnvEntry = struct {
    msg: []const u8,
    value: []const u8,
};

/// One drained effect result, flattened for the session journal: the
/// exact payload `update` received, Msg-type-erased so the recorder and
/// replayer need no knowledge of the app's Msg union. Only the fields
/// for `kind` are meaningful; the rest keep their defaults.
pub const EffectResultRecord = struct {
    kind: EffectResultKind,
    key: u64,
    /// Line bytes / collected stdout / response body / file bytes /
    /// clipboard text.
    payload: []const u8 = "",
    /// Collect-exit stderr tail.
    stderr_tail: []const u8 = "",
    truncated: bool = false,
    /// `dropped_before` for lines/terminals, `dropped_lines` for exits.
    dropped: u32 = 0,
    code: i32 = 0,
    exit_reason: EffectExitReason = .exited,
    output_truncated: bool = false,
    stderr_truncated: bool = false,
    status: u16 = 0,
    fetch_outcome: EffectFetchOutcome = .ok,
    file_op: EffectFileOp = .read,
    file_outcome: EffectFileOutcome = .ok,
    clipboard_op: EffectClipboardOp = .write,
    clipboard_outcome: EffectClipboardOutcome = .ok,
    timer_timestamp_ns: u64 = 0,
    timer_outcome: EffectTimerOutcome = .fired,
    /// `.clock` records: the wall-clock value `Effects.wallMs` returned.
    clock_wall_ms: i64 = 0,
    /// `.audio` records: the delivered audio event, verbatim.
    audio_kind: EffectAudioEventKind = .position,
    audio_position_ms: u64 = 0,
    audio_duration_ms: u64 = 0,
    audio_playing: bool = false,
    audio_buffering: bool = false,
    /// `.spectrum` audio records: the delivered band bytes, verbatim —
    /// the honest non-determinism (a real FFT of real audio) recorded at
    /// the boundary so replay repaints identical bars.
    audio_bands: [platform.audio_spectrum_band_count]u8 = @splat(0),
    /// `.image` records: the delivered terminal outcome and the decoded
    /// dimensions (0 unless `.loaded`); the HTTP status rides the
    /// shared `status` field (0 when no exchange occurred — local
    /// paths, cache hits — see `EffectImageResult.status`).
    image_outcome: EffectImageOutcome = .loaded,
    image_width: u64 = 0,
    image_height: u64 = 0,
    /// `.image` records: the content address of the journaled source
    /// bytes in the session blob store, filled by the recorder when it
    /// moves `payload` out of line. All-zero when the terminal carried
    /// no bytes (source-stage failures).
    image_blob_hash: [effect_image_blob_hash_len]u8 = @splat(0),
    image_blob_len: u64 = 0,
};

/// Type-erased sink the drain reports every delivered result to while a
/// session is being recorded (`bindJournal`). Called on the loop thread,
/// immediately before the Msg constructed from the same payload runs
/// through `update` — so the journal holds exactly what the app saw.
pub const EffectJournal = struct {
    context: *anyopaque,
    record_fn: *const fn (context: *anyopaque, record: EffectResultRecord) void,
};

/// Tiny spin lock over `std.atomic.Mutex` (0.16 has no blocking
/// thread mutex outside `Io`). Every guarded section here is a bounded
/// copy of at most one queue entry, so spinning is microseconds worst
/// case and never blocks on I/O.
const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
};

/// The spawned-child environment when the host never bound one through
/// `bindEnviron` (embed and mobile hosts have no `std.process.Init` to
/// take it from). Windows reads the live PEB block (`.global`); POSIX
/// hosts that link libc read `std.c.environ`; anything else falls back
/// to `.empty` — spawn and fetch still work, children just start with
/// a clean environment.
fn fallbackEnviron() std.process.Environ {
    if (std.process.Environ.Block == std.process.Environ.GlobalBlock) {
        return .{ .block = .global };
    } else if (builtin.link_libc and std.process.Environ.Block == std.process.Environ.PosixBlock) {
        const envp = std.c.environ;
        var count: usize = 0;
        while (envp[count] != null) : (count += 1) {}
        return .{ .block = .{ .slice = envp[0..count :null] } };
    } else {
        return .empty;
    }
}

/// `std.Io.Threaded` (the real executor's io) does not exist on
/// freestanding targets — the docs' live-preview wasm host compiles
/// this runtime to wasm32-freestanding. There the executor io compiles
/// away: `ensureIo` reports unsupported, which surfaces through the
/// standard `.rejected` outcome. Effects never actually run in that
/// host, so nothing is lost.
const io_threaded_supported = builtin.target.os.tag != .freestanding;
const IoThreaded = if (io_threaded_supported) std.Io.Threaded else void;
/// Worker-thread handles exist only where the threaded executor does
/// (the same seam as `IoThreaded`): on freestanding targets no worker
/// ever spawns, so the slot field compiles away to a `?void`.
const WorkerThread = if (io_threaded_supported) std.Thread else void;

/// Process-lifetime allocator backing everything an ABANDONED file
/// worker can still reach: its `FileWorkerContext`, that context's
/// data buffer, and the shared executor io (`IoThreaded` and its
/// internals). The channel's own `allocator` is the OWNER's — an
/// arena or GPA typically deinitialized right after `Effects.deinit`
/// returns — so "leaking" caller-allocator memory under a live thread
/// would only reintroduce the use-after-free the abandon path exists
/// to prevent; abandonable memory must come from storage nothing ever
/// tears down. The page allocator is that storage: process-lived by
/// construction (it has no deinit), thread-safe, and available on
/// every target including the docs' wasm32-freestanding preview.
/// Page granularity is irrelevant here — file effects allocate one
/// small context and one bounded (~1 MiB) buffer per op, and the
/// executor io is created once, none of it on a hot path. The happy
/// path frees through this same allocator: `joinWorker` releases the
/// context and its buffer, `deinit` releases the executor io.
const process_allocator: std.mem.Allocator = std.heap.page_allocator;

/// Everything a real file worker's BLOCKING phase may touch, held
/// out-of-line from the channel on its own heap block. File I/O is the
/// one effect teardown cannot always interrupt (a write to a FIFO with
/// no reader, a stalled network filesystem), so `deinit` bounds its
/// wait and may ABANDON the worker: it detaches the thread and
/// deliberately leaks this context together with the buffer it points
/// at. The invariant that makes the leak safe: an abandoned worker may
/// wake at ANY later time, so everything it can still reach — this
/// context, `buffer`, and the executor io — lives in process-lifetime
/// storage (`process_allocator`, never the channel's caller-owned
/// allocator) and stays allocated forever, while everything it must
/// never touch again (the slot, the queue, the channel itself) is
/// fenced off by the commit/abandon handshake under `mutex`. The leak
/// is bounded (at most one context and buffer per file slot per
/// torn-down channel, plus the shared executor io) and loud (`deinit`
/// warns with the stuck op and path when it gives up).
const FileWorkerContext = struct {
    /// Serializes the worker's commit-to-publish transition against
    /// teardown's abandon decision: whoever locks first decides
    /// whether the worker may still touch the channel (teardown
    /// joins it) or must walk away (teardown leaks it).
    mutex: SpinMutex = .{},
    /// Teardown gave up on this worker: it must never touch the
    /// channel again — the owner is about to free that memory.
    abandoned: bool = false,
    /// The worker finished its blocking phase while the channel was
    /// still alive: teardown must join it (its epilogue touches the
    /// slot and queue, and converges within milliseconds because the
    /// terminal post gives up on shutdown).
    committed: bool = false,
    /// Set by `deinit` halfway through its file deadline: the
    /// supervisor cancels the blocking task (best-effort syscall
    /// interruption through the threaded io).
    interrupt: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the task after `outcome`/`read_len` are recorded.
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    op: EffectFileOp,
    /// The worker's PRIVATE data buffer (a write's payload copy, a
    /// read's content space) — its own `process_allocator` allocation,
    /// distinct from the slot's caller-allocated delivery buffer,
    /// leaked alongside this context on abandon and freed with it by
    /// `joinWorker` otherwise. A committed read's bytes are copied
    /// into the slot's delivery buffer by the worker epilogue.
    buffer: []u8,
    payload_len: usize,
    read_len: usize = 0,
    outcome: EffectFileOutcome = .io_failed,
    /// Copy of the effect's path: the slot's copy lives inside the
    /// channel, which the owner frees right after an abandoning
    /// teardown returns.
    path_storage: [max_effect_file_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn path(ctx: *const FileWorkerContext) []const u8 {
        return ctx.path_storage[0..ctx.path_len];
    }

    fn payload(ctx: *const FileWorkerContext) []const u8 {
        return ctx.buffer[0..ctx.payload_len];
    }
};

/// Map a fetch-side error onto the delivered failure taxonomy. The
/// worker refines `.cancelled` into `.timed_out` when the deadline (not
/// the app) interrupted the exchange.
fn classifyFetchError(err: anyerror) EffectFetchOutcome {
    return switch (err) {
        error.Canceled => .cancelled,
        // DNS resolution.
        error.UnknownHostName,
        error.ResolvConfParseFailed,
        error.InvalidDnsARecord,
        error.InvalidDnsAAAARecord,
        error.InvalidDnsCnameRecord,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.DetectingNetworkConfigurationFailed,
        // TCP connect.
        error.AddressUnavailable,
        error.AddressFamilyUnsupported,
        error.ConnectionPending,
        error.ConnectionRefused,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.Timeout,
        // The worker's marker for an untyped failure while establishing
        // the connection (see `runFetch`).
        error.ConnectPhaseFailed,
        => .connect_failed,
        // TLS.
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => .tls_failed,
        // Requests that could never be sent (pre-validated in `fetch`,
        // so reaching these here still reports honestly).
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        => .rejected,
        else => .protocol_failed,
    };
}

/// Map a registered-image API error onto the image effect's failure
/// taxonomy — the SAME classes the direct `registerCanvasImageBytes`
/// path raises, flattened for the one terminal Msg.
fn classifyImageRegisterError(err: anyerror) EffectImageOutcome {
    return switch (err) {
        error.UnsupportedService => .unsupported,
        error.ImageTooLarge => .too_large,
        error.ImageRegistryFull => .registry_full,
        // Resource exhaustion is its own class, never `decode_failed`:
        // the registry allocates each slot's pixel buffer lazily at its
        // first registration, and an OOM there says nothing about the
        // bytes — reporting valid bytes as corrupt would send the app
        // chasing its source instead of its memory.
        error.OutOfMemory => .alloc_failed,
        // Invalid ids are refused at issue time, before any I/O; a
        // decode that produced impossible dimensions is a decode
        // failure like any other undecodable stream.
        error.InvalidImageId => .rejected,
        else => .decode_failed,
    };
}

/// Map a network-phase error of the image cascade onto the image
/// taxonomy, riding the fetch classifier so the two effects never
/// disagree about what a DNS failure is called.
fn classifyImageFetchError(err: anyerror) EffectImageOutcome {
    return switch (classifyFetchError(err)) {
        .connect_failed => .connect_failed,
        .tls_failed => .tls_failed,
        .timed_out => .timed_out,
        .cancelled => .cancelled,
        .rejected => .rejected,
        .ok, .protocol_failed => .protocol_failed,
    };
}

pub fn Effects(comptime Msg: type) type {
    return struct {
        const Self = @This();

        pub const LineMsgFn = *const fn (line: EffectLine) Msg;
        pub const ExitMsgFn = *const fn (exit: EffectExit) Msg;
        pub const ResponseMsgFn = *const fn (response: EffectResponse) Msg;
        pub const FileMsgFn = *const fn (result: EffectFileResult) Msg;
        pub const ClipboardMsgFn = *const fn (result: EffectClipboardResult) Msg;
        pub const TimerMsgFn = *const fn (timer: EffectTimer) Msg;
        pub const AudioMsgFn = *const fn (event: EffectAudio) Msg;
        pub const HostMsgFn = *const fn (result: EffectHostResult) Msg;
        pub const ImageMsgFn = *const fn (result: EffectImageResult) Msg;

        /// Comptime Msg constructor for `on_line`, following
        /// `canvas.Ui(Msg).inputMsg`: `lineMsg(.agent_line)` builds
        /// `Msg{ .agent_line = line }` — the variant's payload type must
        /// be `native_sdk.EffectLine`.
        pub fn lineMsg(comptime tag: std.meta.Tag(Msg)) LineMsgFn {
            return struct {
                fn make(line: EffectLine) Msg {
                    return @unionInit(Msg, @tagName(tag), line);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_exit`: `exitMsg(.agent_done)`
        /// builds `Msg{ .agent_done = exit }` — the variant's payload
        /// type must be `native_sdk.EffectExit`.
        pub fn exitMsg(comptime tag: std.meta.Tag(Msg)) ExitMsgFn {
            return struct {
                fn make(exit: EffectExit) Msg {
                    return @unionInit(Msg, @tagName(tag), exit);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_response`:
        /// `responseMsg(.issues_fetched)` builds
        /// `Msg{ .issues_fetched = response }` — the variant's payload
        /// type must be `native_sdk.EffectResponse`.
        pub fn responseMsg(comptime tag: std.meta.Tag(Msg)) ResponseMsgFn {
            return struct {
                fn make(response: EffectResponse) Msg {
                    return @unionInit(Msg, @tagName(tag), response);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_result` of file effects:
        /// `fileMsg(.snapshot_saved)` builds
        /// `Msg{ .snapshot_saved = result }` — the variant's payload
        /// type must be `native_sdk.EffectFileResult`.
        pub fn fileMsg(comptime tag: std.meta.Tag(Msg)) FileMsgFn {
            return struct {
                fn make(result: EffectFileResult) Msg {
                    return @unionInit(Msg, @tagName(tag), result);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_result` of clipboard
        /// effects: `clipboardMsg(.copied)` builds
        /// `Msg{ .copied = result }` — the variant's payload type must
        /// be `native_sdk.EffectClipboardResult`.
        pub fn clipboardMsg(comptime tag: std.meta.Tag(Msg)) ClipboardMsgFn {
            return struct {
                fn make(result: EffectClipboardResult) Msg {
                    return @unionInit(Msg, @tagName(tag), result);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_fire` of fx timers:
        /// `timerMsg(.refresh_tick)` builds
        /// `Msg{ .refresh_tick = timer }` — the variant's payload type
        /// must be `native_sdk.EffectTimer`.
        pub fn timerMsg(comptime tag: std.meta.Tag(Msg)) TimerMsgFn {
            return struct {
                fn make(timer: EffectTimer) Msg {
                    return @unionInit(Msg, @tagName(tag), timer);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_event` of audio playback:
        /// `audioMsg(.audio_event)` builds
        /// `Msg{ .audio_event = event }` — the variant's payload type
        /// must be `native_sdk.EffectAudio`.
        pub fn audioMsg(comptime tag: std.meta.Tag(Msg)) AudioMsgFn {
            return struct {
                fn make(event: EffectAudio) Msg {
                    return @unionInit(Msg, @tagName(tag), event);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_result` of host requests:
        /// `hostMsg(.store_answered)` builds
        /// `Msg{ .store_answered = result }` — the variant's payload
        /// type must be `native_sdk.EffectHostResult`.
        pub fn hostMsg(comptime tag: std.meta.Tag(Msg)) HostMsgFn {
            return struct {
                fn make(result: EffectHostResult) Msg {
                    return @unionInit(Msg, @tagName(tag), result);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_result` of image loads:
        /// `imageMsg(.cover_loaded)` builds
        /// `Msg{ .cover_loaded = result }` — the variant's payload type
        /// must be `native_sdk.EffectImageResult`.
        pub fn imageMsg(comptime tag: std.meta.Tag(Msg)) ImageMsgFn {
            return struct {
                fn make(result: EffectImageResult) Msg {
                    return @unionInit(Msg, @tagName(tag), result);
                }
            }.make;
        }

        pub const SpawnOptions = struct {
            /// Caller-chosen identity, stored in the model. Must not
            /// collide with another still-running effect.
            key: u64,
            argv: []const []const u8,
            /// Written to the child's stdin once, then stdin closes.
            stdin: ?[]const u8 = null,
            /// `.lines` (default) streams stdout through `on_line`;
            /// `.collect` accumulates whole stdout (up to
            /// `max_effect_collect_bytes`) plus the stderr tail and
            /// delivers both on the exit Msg — `on_line` is never called
            /// for a collect spawn.
            output: EffectOutputMode = .lines,
            /// Per-spawn delivered-line bound for `.lines` output.
            /// Line-oriented agent CLIs (`claude -p --output-format
            /// stream-json`) emit whole events as single NDJSON lines
            /// far beyond the 4 KiB default; raise this up to
            /// `max_effect_line_bytes_ceiling` (256 KiB) to receive them
            /// intact. Requests above the ceiling (or zero) are
            /// rejected through `on_exit`, never silently clamped.
            /// Bounds above the default heap-allocate the spawn's line
            /// buffer. Ignored by `.collect` spawns.
            max_line_bytes: usize = max_effect_line_bytes,
            on_line: ?LineMsgFn = null,
            on_exit: ?ExitMsgFn = null,
        };

        /// A recorded spawn request, exposed by the fake executor for
        /// test assertions. Slices point into slot storage and stay
        /// valid until the slot's effect exits.
        pub const SpawnRequest = struct {
            key: u64,
            argv: []const []const u8,
            stdin: []const u8,
            output: EffectOutputMode = .lines,
            max_line_bytes: usize = max_effect_line_bytes,
        };

        pub const FetchOptions = struct {
            /// Caller-chosen identity, stored in the model. Must not
            /// collide with another still-running effect (spawn or
            /// fetch — they share the key space and the slots).
            key: u64,
            method: std.http.Method = .GET,
            /// http:// or https:// URL, at most `max_effect_url_bytes`.
            url: []const u8,
            /// Extra request headers; names and values are copied into
            /// slot storage at call time.
            headers: []const std.http.Header = &.{},
            /// Request payload (sent with a content-length). `null`
            /// sends no body.
            body: ?[]const u8 = null,
            /// Whole-exchange timeout in milliseconds; expiry delivers
            /// the terminal Msg with outcome `.timed_out`. For
            /// `.stream` fetches this covers the stream's entire
            /// lifetime — raise it for endpoints that hold the
            /// connection open (sandbox exec, agent event streams).
            timeout_ms: u32 = default_effect_fetch_timeout_ms,
            /// `.buffered` (default) delivers the whole body on the
            /// terminal Msg; `.stream` frames the body into `on_line`
            /// Msgs as lines arrive (the spawn `.lines` contract over
            /// HTTP) with the terminal Msg carrying only the status.
            response: FetchResponseMode = .buffered,
            /// Line Msg constructor for `.stream` fetches; unused (and
            /// never called) in `.buffered` mode.
            on_line: ?LineMsgFn = null,
            /// Per-fetch delivered-line bound for `.stream` responses,
            /// mirroring `SpawnOptions.max_line_bytes` (same ceiling,
            /// same rejection of over-ceiling or zero requests).
            /// Ignored by `.buffered` fetches.
            max_line_bytes: usize = max_effect_line_bytes,
            on_response: ?ResponseMsgFn = null,
        };

        /// A recorded fetch request, exposed by the fake executor for
        /// test assertions. Slices point into slot storage and stay
        /// valid until the fetch's response is drained.
        pub const FetchRequest = struct {
            key: u64,
            method: std.http.Method,
            url: []const u8,
            headers: []const std.http.Header,
            body: []const u8,
            response: FetchResponseMode = .buffered,
            max_line_bytes: usize = max_effect_line_bytes,
        };

        pub const WriteFileOptions = struct {
            /// Caller-chosen identity, stored in the model. Shares the
            /// key space and the `max_effects` slots with spawns and
            /// fetches.
            key: u64,
            /// The file to write, at most `max_effect_file_path_bytes`.
            /// Missing parent directories are created; an existing file
            /// is replaced whole.
            path: []const u8,
            /// The whole file content, at most `max_effect_file_bytes`
            /// — larger is rejected outright (a partial write would
            /// corrupt the file; there is no write-side truncation).
            /// Copied at call time; the caller's buffer may be reused
            /// immediately.
            bytes: []const u8,
            on_result: ?FileMsgFn = null,
        };

        pub const ReadFileOptions = struct {
            /// Caller-chosen identity, stored in the model. Shares the
            /// key space and the `max_effects` slots with spawns and
            /// fetches.
            key: u64,
            /// The file to read, at most `max_effect_file_path_bytes`.
            path: []const u8,
            on_result: ?FileMsgFn = null,
        };

        /// A recorded file request, exposed by the fake executor for
        /// test assertions. Slices point into slot storage and stay
        /// valid until the result is fed and drained.
        pub const FileRequest = struct {
            key: u64,
            op: EffectFileOp,
            path: []const u8,
            /// The bytes a `writeFile` would write; `""` for reads.
            bytes: []const u8 = "",
        };

        pub const WriteClipboardOptions = struct {
            /// Caller-chosen identity, stored in the model. Shares the
            /// key space and the `max_effects` slots with spawns,
            /// fetches, and file effects.
            key: u64,
            /// The text to place on the system clipboard, at most
            /// `max_effect_clipboard_bytes` — larger is rejected
            /// outright (a cut clipboard string must never pass for the
            /// whole one). Copied at call time; the caller's buffer may
            /// be reused immediately.
            text: []const u8,
            on_result: ?ClipboardMsgFn = null,
        };

        pub const ReadClipboardOptions = struct {
            /// Caller-chosen identity, stored in the model. Shares the
            /// key space and the `max_effects` slots with spawns,
            /// fetches, and file effects.
            key: u64,
            on_result: ?ClipboardMsgFn = null,
        };

        /// A recorded clipboard request, exposed by the fake executor
        /// for test assertions. `text` points into slot storage and
        /// stays valid until the result is fed and drained.
        pub const ClipboardRequest = struct {
            key: u64,
            op: EffectClipboardOp,
            /// The text a `writeClipboard` would write; `""` for reads.
            text: []const u8 = "",
        };

        pub const HostRequestOptions = struct {
            /// Caller-chosen identity. Same key space and slots as
            /// spawn/fetch/file/clipboard, but with the request key
            /// discipline: issuing a key whose HOST request is still in
            /// flight REPLACES it (the old result is dropped, silently),
            /// while a collision with another effect kind rejects.
            key: u64,
            /// Host service name (what the host dispatches on), at most
            /// `max_effect_host_name_bytes`; copied into slot storage.
            name: []const u8,
            /// Outbound payload, at most
            /// `max_effect_host_payload_bytes`; copied into the slot's
            /// buffer at call time.
            payload: []const u8 = "",
            on_result: ?HostMsgFn = null,
        };

        /// A recorded host request, exposed by the fake executor for
        /// test assertions. Slices point into slot storage and stay
        /// valid until the request retires.
        pub const HostRequest = struct {
            key: u64,
            name: []const u8,
            payload: []const u8 = "",
        };

        pub const StartTimerOptions = struct {
            /// Caller-chosen identity, stored in the model. Timer keys
            /// are their own namespace: they never collide with (and are
            /// never checked against) spawn/fetch/file keys. Starting a
            /// key that is already an active timer REPLACES it — the
            /// interval, mode, and `on_fire` update in place and the
            /// same platform timer re-arms, the friendly behavior for an
            /// auto-refresh whose cadence the model changes.
            key: u64,
            /// Fire interval in milliseconds. Zero is rejected (one Msg
            /// with outcome `.rejected`), never silently clamped.
            interval_ms: u64,
            /// `.one_shot` (default) fires once and retires the timer;
            /// `.repeating` fires until `cancelTimer(key)`.
            mode: TimerMode = .one_shot,
            on_fire: ?TimerMsgFn = null,
        };

        pub const PlayAudioOptions = struct {
            /// Caller-chosen identity, stored in the model and echoed in
            /// every event for this playback. Audio keys are their own
            /// namespace (like timer keys); a new `playAudio` replaces
            /// the previous playback outright — one player is the whole
            /// surface.
            key: u64,
            /// Local file path, tried FIRST. May be empty when `url` is
            /// set (URL-only playback). A present-but-missing file falls
            /// through to `url` when one is given; with no `url` (or any
            /// other load failure) one `.failed` event reports it. Every
            /// string here is copied at call time — the caller's buffers
            /// may be reused immediately — and each is bounded by
            /// `max_effect_audio_path_bytes` (longer, or path AND url
            /// both empty, is rejected with one `.rejected` event).
            path: []const u8 = "",
            /// http(s) source, tried when the local path is absent or
            /// missing. The platform resolves it honestly: a verified
            /// cache entry at `cache_path` plays locally (no network);
            /// otherwise playback STREAMS progressively — audible before
            /// the download finishes — while the bytes fill the cache
            /// for next time. Empty means local-only (today's behavior).
            url: []const u8 = "",
            /// Where the URL's bytes are cached, and the cache policy in
            /// one field: empty disables caching (stream-only). The
            /// platform writes beside this path and atomically renames
            /// into place only after the size verifies, so a partial
            /// download never occupies the cache name.
            cache_path: []const u8 = "",
            /// The track's known byte size (from a manifest), the cache
            /// integrity gate: a cache entry whose size disagrees is
            /// discarded and re-streamed, and a finished download that
            /// disagrees is never installed. Zero means "unknown" —
            /// existence alone then qualifies a cache entry.
            expected_bytes: u64 = 0,
            /// Msg constructor every playback event flows through (see
            /// `audioMsg`). Without one, playback still runs; the app
            /// just hears nothing back.
            on_event: ?AudioMsgFn = null,
        };

        pub const LoadImageOptions = struct {
            /// The ImageId the decoded pixels register under — model-
            /// owned, chosen by the app, exactly the id `image`/`avatar`
            /// widgets reference. It doubles as the effect key: image
            /// loads share the `max_effects` slots and the key space
            /// with spawns, fetches, and file effects. Id 0 (the
            /// no-image sentinel) and the reserved media-surface
            /// namespace (`canvas.media_surface_image_id_bit`) are
            /// refused with one `.rejected` result, mirroring
            /// `registerCanvasImage`.
            id: u64,
            /// Local file path, tried FIRST — the audio cascade's rule:
            /// a present-but-missing file falls through to `url` when
            /// one is given; every other local failure is terminal
            /// (retrying a different source would mask the real
            /// problem). Bounded by `max_effect_image_path_bytes`.
            path: []const u8 = "",
            /// http(s) source, tried when the local path is absent or
            /// missing. A verified cache entry at `cache_path` loads
            /// locally (no network); otherwise the bytes are fetched
            /// whole and installed into the cache for next time. Empty
            /// means local-only.
            url: []const u8 = "",
            /// Where the URL's bytes are cached, and the cache policy
            /// in one field: empty disables caching. Derive it with
            /// `imageCachePath` for the content-addressed convention.
            /// The fetch writes beside this path and atomically renames
            /// into place only after the size verifies, so a partial
            /// download never occupies the cache name.
            cache_path: []const u8 = "",
            /// The source's known byte size (from a manifest), the
            /// cache integrity gate: a cache entry whose size disagrees
            /// is discarded and re-fetched, and a finished download
            /// that disagrees is never installed. Zero means "unknown"
            /// — existence alone then qualifies a cache entry.
            expected_bytes: u64 = 0,
            /// Whole-cascade timeout in milliseconds (local probe,
            /// cache read, and network fetch together); expiry delivers
            /// the result with outcome `.timed_out`.
            timeout_ms: u32 = default_effect_fetch_timeout_ms,
            /// Msg constructor the ONE terminal result flows through.
            /// Without one the load still runs (and registers on
            /// success); the app just hears nothing back.
            on_result: ?ImageMsgFn = null,
        };

        /// A recorded image-load request, exposed by the fake executor
        /// for test assertions. Slices point into slot storage and stay
        /// valid until the result is fed and drained.
        pub const ImageLoadRequest = struct {
            id: u64,
            path: []const u8,
            url: []const u8,
            cache_path: []const u8,
            expected_bytes: u64,
        };

        /// A recorded fx timer, exposed by the fake executor for test
        /// assertions.
        pub const TimerRequest = struct {
            key: u64,
            interval_ms: u64,
            mode: TimerMode,
        };

        const TimerSlot = struct {
            active: bool = false,
            fake: bool = false,
            key: u64 = 0,
            mode: TimerMode = .one_shot,
            interval_ms: u64 = 0,
            on_fire: ?TimerMsgFn = null,
        };

        /// The single audio playback channel — one player is the whole
        /// platform surface, so the effects layer holds exactly one.
        /// Like timers it is a platform service arm, not a worker-thread
        /// effect: it consumes no `max_effects` slots and its key is its
        /// own namespace. The mirrors below track what the app has been
        /// told (commands optimistically, platform events authoritatively)
        /// so the automation snapshot can report playback state honestly.
        const AudioChannel = struct {
            active: bool = false,
            fake: bool = false,
            key: u64 = 0,
            on_event: ?AudioMsgFn = null,
            playing: bool = false,
            /// Where the resolved playback's bytes come from: `.local`
            /// until the URL branch of the cascade runs, then whatever
            /// the platform answered (`.cache` or `.stream`).
            source: EffectAudioSource = .local,
            /// True while a stream is stalled waiting for bytes. Set
            /// optimistically when a stream starts (nothing has arrived
            /// yet), cleared by the platform's `.loaded` acknowledgment
            /// and tracked from event flags after that.
            buffering: bool = false,
            position_ms: u64 = 0,
            duration_ms: u64 = 0,
            volume: f32 = 1.0,
            /// The latest `.spectrum` band bytes and a lifetime delivery
            /// count for THIS playback — snapshot evidence that analysis
            /// is flowing (the count moves) and freezing on pause (it
            /// holds). Reset with the channel on every new `playAudio`.
            spectrum_bands: [platform.audio_spectrum_band_count]u8 = @splat(0),
            spectrum_events: u64 = 0,
            path_buffer: [max_effect_audio_path_bytes]u8 = undefined,
            path_len: usize = 0,
            url_buffer: [max_effect_audio_path_bytes]u8 = undefined,
            url_len: usize = 0,
            cache_path_buffer: [max_effect_audio_path_bytes]u8 = undefined,
            cache_path_len: usize = 0,
            expected_bytes: u64 = 0,

            fn path(channel: *const AudioChannel) []const u8 {
                return channel.path_buffer[0..channel.path_len];
            }

            fn url(channel: *const AudioChannel) []const u8 {
                return channel.url_buffer[0..channel.url_len];
            }

            fn cachePath(channel: *const AudioChannel) []const u8 {
                return channel.cache_path_buffer[0..channel.cache_path_len];
            }
        };

        /// Playback state the automation snapshot exposes: honest — it
        /// reports what the platform has told us, not what the UI wishes.
        pub const AudioSnapshot = struct {
            active: bool = false,
            key: u64 = 0,
            playing: bool = false,
            buffering: bool = false,
            source: EffectAudioSource = .local,
            position_ms: u64 = 0,
            duration_ms: u64 = 0,
            /// Spectrum mirrors (see `AudioChannel`): zero events means
            /// no analysis has arrived for this playback — an honest
            /// "this host does not analyze" is visible right here.
            spectrum_bands: [platform.audio_spectrum_band_count]u8 = @splat(0),
            spectrum_events: u64 = 0,
        };

        /// A recorded audio playback request, exposed by the fake
        /// executor for test assertions. The strings borrow the
        /// channel's storage — valid until the next `playAudio`.
        pub const AudioRequest = struct {
            key: u64,
            path: []const u8,
            url: []const u8,
            cache_path: []const u8,
            expected_bytes: u64,
            playing: bool,
            position_ms: u64,
            volume: f32,
        };

        /// `draining`: the worker is done and the terminal entry is
        /// queued, but the slot still owns a heap buffer (a fetch's body
        /// or a collect spawn's stdout) until the drain delivers (and
        /// thereby retires) it.
        const SlotState = enum(u8) { idle, running, done, draining };

        const SlotKind = enum(u8) { spawn, fetch, file, clipboard, host, image };

        const EntryKind = enum(u8) { line, exit, response, file, clipboard, host, image };

        const Entry = struct {
            kind: EntryKind = .line,
            slot_index: u16 = 0,
            generation: u32 = 0,
            key: u64 = 0,
            /// Line length for `.line` entries; body length for
            /// `.response` entries (the bytes live in the slot's fetch
            /// buffer, not here).
            line_len: u32 = 0,
            truncated: bool = false,
            dropped_before: u32 = 0,
            code: i32 = 0,
            reason: EffectExitReason = .exited,
            dropped_lines: u32 = 0,
            status: u16 = 0,
            outcome: EffectFetchOutcome = .ok,
            /// `.file` entries: the operation and its terminal outcome.
            /// A read's bytes stay in the slot's heap buffer (taken at
            /// drain, exactly like a fetch body) with their length in
            /// `line_len`.
            file_op: EffectFileOp = .read,
            file_outcome: EffectFileOutcome = .ok,
            /// `.clipboard` entries: the operation and its terminal
            /// outcome. A read's text stays in the slot's heap buffer
            /// (taken at drain, like a fetch body) with its length in
            /// `line_len`.
            clipboard_op: EffectClipboardOp = .write,
            clipboard_outcome: EffectClipboardOutcome = .ok,
            /// `.host` entries: which route the result takes (true = the
            /// ok arm). The bytes stay in the slot's heap buffer (taken
            /// at drain, like a fetch body) with their length in
            /// `line_len`.
            host_ok: bool = true,
            /// `.exit` entries of `.collect` spawns: the collected stdout
            /// stays in the slot's heap buffer (taken at drain, like a
            /// fetch body); the stderr tail rides in `line_bytes` with
            /// its length in `line_len`.
            collect: bool = false,
            collect_len: u32 = 0,
            collect_truncated: bool = false,
            stderr_truncated: bool = false,
            /// `.image` entries: the source stage's outcome (`.loaded`
            /// means bytes are staged in the slot buffer and the drain
            /// decodes + registers them; anything else is the terminal
            /// failure class as-is).
            image_outcome: EffectImageOutcome = .loaded,
            /// `.image` entries fed with a RECORDED terminal (session
            /// replay): the drain delivers the journaled outcome and
            /// dimensions verbatim — re-registration is best-effort
            /// presentation, never the Msg source — so a replay host
            /// whose codec differs from the recording host's still
            /// replays the identical Msg stream.
            image_fed: bool = false,
            image_fed_width: u64 = 0,
            image_fed_height: u64 = 0,
            line_fn: ?LineMsgFn = null,
            exit_fn: ?ExitMsgFn = null,
            response_fn: ?ResponseMsgFn = null,
            file_fn: ?FileMsgFn = null,
            clipboard_fn: ?ClipboardMsgFn = null,
            host_fn: ?HostMsgFn = null,
            image_fn: ?ImageMsgFn = null,
            /// `.line` entries whose payload exceeds the inline buffer
            /// (a raised `max_line_bytes` bound): the bytes ride in this
            /// heap allocation instead of `line_bytes`. Owned by the
            /// entry once enqueued — the drain takes it (freed when the
            /// next line drains) and every queue-clearing path frees it.
            heap_line: ?[]u8 = null,
            line_bytes: [max_effect_line_bytes]u8 = undefined,
        };

        /// A loop-thread-produced terminal Msg awaiting drain: a spawn
        /// rejection or fake exit (`.exit`) or a fetch rejection or fake
        /// cancel (`.response`). Response bodies are always empty here.
        const PendingMsg = union(enum) {
            exit: struct { exit: EffectExit, exit_fn: ?ExitMsgFn },
            response: struct { response: EffectResponse, response_fn: ?ResponseMsgFn },
            file: struct { result: EffectFileResult, file_fn: ?FileMsgFn },
            clipboard: struct { result: EffectClipboardResult, clipboard_fn: ?ClipboardMsgFn },
            timer: struct { timer: EffectTimer, timer_fn: ?TimerMsgFn },
            /// `.host` terminals produced on the loop thread: rejections
            /// (`rejected = true`, static bytes, regenerated under
            /// replay) and feed fallbacks. Bytes here are never a host
            /// answer's — those ride the queue with their slot buffer.
            host: struct { result: EffectHostResult, host_fn: ?HostMsgFn, rejected: bool },
            /// `resolve`: a fed audio event (fake executor / replay)
            /// whose key and handler come from the live channel at
            /// delivery time — exactly how a platform event resolves in
            /// `takeAudioMsg`. Non-resolving entries (rejections and
            /// synchronous failures) are fully formed at enqueue.
            audio: struct { event: EffectAudio, audio_fn: ?AudioMsgFn, resolve: bool },
            /// Loop-thread image terminals (rejections, fake cancels,
            /// feed fallbacks) — always payload-free, fully formed at
            /// enqueue. `regenerates` is true only for pre-executor
            /// validation refusals: the same deterministic checks in
            /// `loadImage` refuse again under session replay, so their
            /// journaled records are skipped rather than fed. Every
            /// other loop-side terminal — fake cancels, feed fallbacks,
            /// an executor that could not start the load — is executor
            /// truth the replayed request cannot reproduce and must be
            /// fed from the journal. Image terminals never occupy the
            /// lossy ring itself: they stage in `pending_images` (see
            /// there for why they must be non-lossy) and take this
            /// union shape only at drain time, in `takePendingMsg`.
            image: struct { result: EffectImageResult, image_fn: ?ImageMsgFn, regenerates: bool },

            fn addDropped(pending: *PendingMsg, count: u32) void {
                switch (pending.*) {
                    .exit => |*entry| entry.exit.dropped_lines +|= count,
                    .response => |*entry| entry.response.dropped_before +|= count,
                    .file => |*entry| entry.result.dropped_before +|= count,
                    .clipboard => |*entry| entry.result.dropped_before +|= count,
                    // EffectTimer carries no drop counter; a repeating
                    // timer's next fire replaces the lost one anyway.
                    .timer => {},
                    // EffectAudio carries no drop counter either; the
                    // next position tick supersedes a lost one.
                    .audio => {},
                    // EffectHostResult carries none: its terminals are
                    // one-per-request by construction.
                    .host => {},
                    // Image terminals never enter the ring (they stage
                    // in the non-lossy `pending_images`), so neither
                    // overflow arm can ever see one. EffectImageResult
                    // carries no drop counter to fold a loss into —
                    // eviction here would silently break the
                    // exactly-one-terminal-per-load contract.
                    .image => unreachable,
                }
            }

            fn droppedCount(pending: *const PendingMsg) u32 {
                return switch (pending.*) {
                    .exit => |entry| entry.exit.dropped_lines,
                    .response => |entry| entry.response.dropped_before,
                    .file => |entry| entry.result.dropped_before,
                    .clipboard => |entry| entry.result.dropped_before,
                    .timer => 0,
                    .audio => 0,
                    .host => 0,
                    // Never in the ring; see `addDropped`.
                    .image => unreachable,
                };
            }
        };

        /// One loop-side image terminal awaiting drain, staged outside
        /// the shared pending ring. The stage is NON-LOSSY, unlike the
        /// ring: an image load's contract is exactly one terminal per
        /// load, `EffectImageResult` carries no drop counter to make a
        /// loss visible, and loop-side validation rejections are
        /// unbounded per dispatch — every refused `loadImage` stages
        /// one entry here before the next drain runs, so ring eviction
        /// would leave the issuing model waiting forever on a terminal
        /// that silently vanished. Worker-origin image terminals are
        /// bounded by the effect slots and ride the completion queue,
        /// never this stage. `seq` orders staged entries against ring
        /// entries so the drain preserves enqueue order across both
        /// structures (`takePendingMsg` merges by it).
        const PendingImage = struct {
            seq: u64,
            result: EffectImageResult,
            image_fn: ?ImageMsgFn,
            regenerates: bool,
        };

        /// Everything a real spawn worker's BLOCKING phase may touch,
        /// held out-of-line from the channel on its own heap block —
        /// the spawn twin of `FileWorkerContext`, and the same
        /// invariant: teardown may ABANDON a spawn worker whose child's
        /// group-kill did not converge it (a descendant that escaped
        /// the process group — `setsid`, a shell's `set -m` background
        /// job — keeps the inherited stdout write end open, so the
        /// worker's read never sees EOF), and everything the abandoned
        /// worker can still wake into must live in process-lifetime
        /// storage (`process_allocator`) and stay allocated forever.
        /// The blocking phase therefore runs against copies: argv,
        /// stdin, the line-framing and collect buffers, the stderr
        /// tail ring, and the published-child handshake all live here,
        /// never in the slot. Unlike a file op, a spawn DELIVERS while
        /// it blocks (streaming lines ride the queue as the child
        /// produces them), so the commit/abandon handshake fences two
        /// things: every mid-stream channel touch happens under
        /// `mutex` with `abandoned` re-checked (see
        /// `produceSpawnLine`), and the terminal epilogue (publishing
        /// collect payloads into the slot, posting the exit) runs only
        /// after `committed` is taken while the channel provably
        /// lives. Generic over the channel because it carries the
        /// effect's Msg-typed `on_line` constructor.
        const SpawnWorkerContext = struct {
            /// Serializes the worker's channel touches (mid-stream
            /// line enqueues, the commit-to-publish transition)
            /// against teardown's abandon decision: whoever locks
            /// first decides whether the worker may still touch the
            /// channel (teardown joins it) or must walk away
            /// (teardown leaks it).
            mutex: SpinMutex = .{},
            /// Teardown gave up on this worker: it must never touch
            /// the channel again — the owner is about to free that
            /// memory.
            abandoned: bool = false,
            /// The worker finished its blocking phase while the
            /// channel was still alive: teardown must join it (its
            /// epilogue touches the slot and queue, and converges
            /// within milliseconds because the terminal post gives up
            /// on shutdown).
            committed: bool = false,
            /// Set by `deinit` halfway through its spawn deadline:
            /// the supervisor cancels the blocking task (best-effort
            /// syscall interruption through the threaded io — the net
            /// under a group-kill that could not converge the child).
            interrupt: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            /// Set by the task after `exit` is recorded.
            done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            /// Guards `child_id`/`reaping` between the blocking task
            /// and `killPublishedChild` (cancel on the loop thread,
            /// teardown): a kill is only sent while the task has not
            /// started reaping, so the pid/handle is guaranteed
            /// un-reaped (alive or zombie) when signaled. Lives here —
            /// not on the slot — so the handshake works against
            /// process-lived memory: the task locks it mid-blocking-
            /// phase, which an abandoned worker may do long after the
            /// channel is freed (the exact stale-slot `child_mutex`
            /// crash the join discipline exists to prevent).
            child_mutex: SpinMutex = .{},
            child_id: ?std.process.Child.Id = null,
            reaping: bool = false,
            /// A kill was requested (cancel or teardown). Read by the
            /// task so a kill that raced the child's publish still
            /// lands, and so the recorded exit reports `.cancelled` —
            /// the context's copy of the slot's `cancel_requested`,
            /// readable without touching the channel.
            kill_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            /// The task's terminal result, published to the committed
            /// epilogue (never read on abandon).
            exit: EffectExit = .{ .key = 0, .code = effect_error_exit_code, .reason = .spawn_failed },
            // ---- blocking-phase copies of the effect's parameters ----
            key: u64 = 0,
            on_line: ?LineMsgFn = null,
            output_mode: EffectOutputMode = .lines,
            line_limit: usize = max_effect_line_bytes,
            /// Raised-bound line-framing buffer (its own
            /// `process_allocator` allocation, leaked on abandon,
            /// freed with the context by `joinWorker`); null means the
            /// task frames into its stack buffer. Distinct from the
            /// slot's `line_buffer`, which the fake executor keeps
            /// using.
            line_buffer: ?[]u8 = null,
            /// Collect-mode stdout accumulation — the worker-private
            /// twin of the slot's caller-allocated `collect_buffer`
            /// (the committed epilogue publishes into that one).
            collect_buffer: ?[]u8 = null,
            collect_len: usize = 0,
            collect_truncated: bool = false,
            stderr_ring: [max_effect_stderr_tail_bytes]u8 = undefined,
            stderr_total: usize = 0,
            /// Producer-side drop accounting (the context twin of the
            /// slot fields the fake executor uses).
            dropped_pending: u32 = 0,
            dropped_total: u32 = 0,
            argv_slices: [max_effect_argv][]const u8 = undefined,
            argv_count: usize = 0,
            argv_storage: [max_effect_argv_bytes]u8 = undefined,
            stdin_storage: [max_effect_stdin_bytes]u8 = undefined,
            stdin_len: usize = 0,

            fn argv(ctx: *const SpawnWorkerContext) []const []const u8 {
                return ctx.argv_slices[0..ctx.argv_count];
            }

            fn stdinBytes(ctx: *const SpawnWorkerContext) []const u8 {
                return ctx.stdin_storage[0..ctx.stdin_len];
            }
        };

        const Slot = struct {
            state: std.atomic.Value(SlotState) = std.atomic.Value(SlotState).init(.idle),
            generation: u32 = 0,
            key: u64 = 0,
            kind: SlotKind = .spawn,
            fake: bool = false,
            on_line: ?LineMsgFn = null,
            on_exit: ?ExitMsgFn = null,
            on_response: ?ResponseMsgFn = null,
            on_file: ?FileMsgFn = null,
            on_clipboard: ?ClipboardMsgFn = null,
            on_host: ?HostMsgFn = null,
            /// Set by `cancel` before any kill attempt; read by the
            /// worker so a cancel that lands before the process spawns
            /// still kills it.
            cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            /// Loop-thread bookkeeping: the generation whose queued
            /// lines the drain discards and whose exit reports
            /// `.cancelled`. Zero means none (generations start at 1).
            cancelled_generation: u32 = 0,
            /// The worker thread driving this occupancy (real spawn,
            /// fetch, and file effects; null for fake slots, host
            /// requests, and idle slots). Loop-thread bookkeeping:
            /// stored where the thread spawns, cleared by `joinWorker`.
            /// A worker holds pointers into the whole channel (its
            /// slot, the completion queue, the executor io) for its
            /// entire thread lifetime, so the channel's memory must
            /// never be freed while a handle here is outstanding —
            /// `deinit` joins every one before it returns, except a
            /// file or spawn worker stuck past its teardown deadline,
            /// which is detached after the handshake that guarantees
            /// it will never touch the channel again (see
            /// `FileWorkerContext` / `SpawnWorkerContext`).
            worker_thread: ?WorkerThread = null,
            /// The out-of-line world of a real file worker (null for
            /// every other occupancy). Created alongside the worker
            /// thread, freed by `joinWorker` once the join proves the
            /// worker is gone — or deliberately leaked when teardown
            /// abandons the worker (see `FileWorkerContext`).
            file_ctx: ?*FileWorkerContext = null,
            /// The out-of-line world of a real spawn worker (null for
            /// every other occupancy, and for fake spawns). Same
            /// lifecycle as `file_ctx`: freed by `joinWorker`, leaked
            /// on abandon (see `SpawnWorkerContext`). Also where
            /// `killPublishedChild` finds the published-child
            /// handshake — the loop thread only dereferences it while
            /// the channel is alive.
            spawn_ctx: ?*SpawnWorkerContext = null,
            /// Producer-side drop accounting (worker in real mode, loop
            /// thread in fake mode; never both).
            dropped_pending: u32 = 0,
            dropped_total: u32 = 0,
            argv_slices: [max_effect_argv][]const u8 = undefined,
            argv_count: usize = 0,
            argv_storage: [max_effect_argv_bytes]u8 = undefined,
            stdin_storage: [max_effect_stdin_bytes]u8 = undefined,
            stdin_len: usize = 0,
            // ---- line-framing fields (.lines spawns, .stream fetches) ----
            /// Effective per-line bound: the default or the accepted
            /// `max_line_bytes` override.
            line_limit: usize = max_effect_line_bytes,
            /// Heap line-accumulation buffer, allocated per accepted
            /// effect whose `max_line_bytes` exceeds the default (the
            /// worker frames lines into it instead of its stack
            /// buffer). Owned by the slot; freed on reuse and deinit.
            line_buffer: ?[]u8 = null,
            // ---- collect-mode fields (kind == .spawn, output == .collect) ----
            output_mode: EffectOutputMode = .lines,
            /// Heap buffer per accepted `.collect` spawn
            /// (`max_effect_collect_bytes` of stdout space). Owned by the
            /// slot until the drain delivers the exit (taken into
            /// `drain_collect_output`) or `deinit` sweeps it.
            collect_buffer: ?[]u8 = null,
            collect_len: usize = 0,
            collect_truncated: bool = false,
            /// A `.lines` spawn's posted-but-undelivered exit marker:
            /// set alongside the exit entry's enqueue (worker commit or
            /// feed), cleared by the drain the moment it dequeues the
            /// generation-matched exit — the delivery instant the other
            /// families mark by their buffer handoff (`fetch_buffer`,
            /// `collect_buffer`). While set, the slot parks in
            /// `.draining` and its key stays occupied
            /// (`findUndeliveredTerminalSlot`). Written by the worker
            /// before its `.draining` release store (the worker's last
            /// slot access); loop-thread only after that.
            exit_undelivered: bool = false,
            /// Ring of the child's most recent stderr bytes. Written by
            /// the stderr reader (worker-side thread in real mode, loop
            /// thread in fake mode); read only after the child is done.
            stderr_ring: [max_effect_stderr_tail_bytes]u8 = undefined,
            /// Total stderr bytes seen; beyond the ring capacity means
            /// the tail is truncated.
            stderr_total: usize = 0,
            // ---- file-only fields (kind == .file) ----
            file_op: EffectFileOp = .read,
            // ---- clipboard-only fields (kind == .clipboard) ----
            clipboard_op: EffectClipboardOp = .write,
            // ---- image-only fields (kind == .image) ----
            on_image: ?ImageMsgFn = null,
            /// The local source path (the URL rides `url_storage`, a
            /// slot being one occupancy at a time — but path and url
            /// COEXIST in an image cascade, so the path gets its own
            /// storage).
            image_path_storage: [max_effect_image_path_bytes]u8 = undefined,
            image_path_len: usize = 0,
            image_cache_storage: [max_effect_image_path_bytes]u8 = undefined,
            image_cache_len: usize = 0,
            image_expected_bytes: u64 = 0,
            /// Terminal source-stage state, written by the image task
            /// before `fetch_done` (the shared completion latch):
            /// `.loaded` means encoded bytes are staged in
            /// `fetch_buffer` for the drain to decode + register.
            image_outcome: EffectImageOutcome = .loaded,
            // ---- fetch/file fields ----
            /// `.stream` frames the response body into line entries;
            /// `.buffered` delivers it whole on the terminal entry.
            fetch_response_mode: FetchResponseMode = .buffered,
            method: std.http.Method = .GET,
            /// A fetch's URL — and a file effect's path (they never
            /// coexist in one slot; `max_effect_file_path_bytes` fits).
            url_storage: [max_effect_url_bytes]u8 = undefined,
            url_len: usize = 0,
            header_storage: [max_effect_fetch_header_bytes]u8 = undefined,
            header_slices: [max_effect_fetch_headers]std.http.Header = undefined,
            header_count: usize = 0,
            timeout_ms: u32 = default_effect_fetch_timeout_ms,
            /// Heap buffer per accepted fetch: request payload copy
            /// followed by `max_effect_body_bytes` of response space.
            /// File effects use it too: a write's payload copy, or a
            /// read's `max_effect_file_bytes + 1` of content space (the
            /// spare byte detects over-bound files). Owned by the slot
            /// until the drain delivers the terminal Msg (taken into
            /// `drain_fetch_body`) or `deinit` sweeps it.
            fetch_buffer: ?[]u8 = null,
            payload_len: usize = 0,
            /// Terminal fetch state, written by the fetch task before
            /// `fetch_done`, published to the loop thread by the queue.
            body_len: usize = 0,
            fetch_status: u16 = 0,
            fetch_outcome: EffectFetchOutcome = .protocol_failed,
            fetch_truncated: bool = false,
            /// Set by the fetch task after its final slot writes; the
            /// supervising worker distinguishes "completed" from
            /// "interrupted by cancel/timeout" through it.
            fetch_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

            fn argv(slot: *const Slot) []const []const u8 {
                return slot.argv_slices[0..slot.argv_count];
            }

            fn stdinBytes(slot: *const Slot) []const u8 {
                return slot.stdin_storage[0..slot.stdin_len];
            }

            fn fetchUrl(slot: *const Slot) []const u8 {
                return slot.url_storage[0..slot.url_len];
            }

            fn fetchHeaders(slot: *const Slot) []const std.http.Header {
                return slot.header_slices[0..slot.header_count];
            }

            fn fetchPayload(slot: *const Slot) []const u8 {
                const buffer = slot.fetch_buffer orelse return "";
                return buffer[0..slot.payload_len];
            }

            fn filePath(slot: *const Slot) []const u8 {
                return slot.url_storage[0..slot.url_len];
            }

            /// A host request's service name (they share the fetch URL
            /// storage — a slot is one occupancy at a time).
            fn hostName(slot: *const Slot) []const u8 {
                return slot.url_storage[0..slot.url_len];
            }

            fn imagePath(slot: *const Slot) []const u8 {
                return slot.image_path_storage[0..slot.image_path_len];
            }

            fn imageCache(slot: *const Slot) []const u8 {
                return slot.image_cache_storage[0..slot.image_cache_len];
            }
        };

        allocator: std.mem.Allocator,
        executor: EffectExecutor = .real,
        /// Fake-executor convention: while set, every `loadImage` that
        /// parks a fake request completes IMMEDIATELY with these bytes
        /// (through `feedImageBytes`, the full decode→register path) —
        /// still at `loadImage` time, before the caller's dispatch
        /// returns. This is the deterministic stand-in for a real
        /// local-path or cache load finishing before the drain pass
        /// that spawned it ends: the chained-completion shape the
        /// drain's causal boundary (`DrainBoundary`) exists for. Test
        /// seam only; never set under session replay, where journaled
        /// terminals are the only delivery.
        fake_instant_image_bytes: ?[]const u8 = null,
        /// Session-record sink: every drain-delivered result is reported
        /// here (loop thread, right before its Msg runs through
        /// `update`). Null outside recording.
        journal: ?EffectJournal = null,
        /// The clock behind `wallMs` — the swap seam tests use
        /// (`TestClock`), exactly like the fake executor. Session replay
        /// never consults it: journaled values win there.
        clock: runtime_clock.Clock = .system,
        /// Session replay: the executor is `.fake` AND terminal delivery
        /// comes exclusively from journaled results (`armReplay`). In
        /// this mode `cancel` never self-delivers a `.cancelled`
        /// terminal — the journaled terminal (recorded as `.cancelled`)
        /// is fed instead, so replay delivers exactly what the recorded
        /// session delivered, in the same order.
        replay: bool = false,
        /// Journaled wall-clock values queued for replay-mode `wallMs`
        /// reads (FIFO; fed from `.clock` records before the consuming
        /// event dispatches).
        replay_clock: [max_effect_replay_clock_entries]i64 = [_]i64{0} ** max_effect_replay_clock_entries,
        replay_clock_head: usize = 0,
        replay_clock_len: usize = 0,
        /// Replay `wallMs` reads that found no journaled value: a
        /// divergence signal (the replayed update read the clock more
        /// often than the recorded one). Reported loudly once.
        replay_clock_underflows: u64 = 0,
        /// Journaled launch-env deliveries queued for the replay-mode
        /// envMsgs dispatch (FIFO; fed from `.env` records before the
        /// installing event dispatches). Empty under replay means the
        /// journal carried none — the adapter re-derives from the
        /// launch configuration, the pre-`.env`-record behavior.
        replay_env: [max_effect_replay_env_entries]ReplayEnvEntry = undefined,
        replay_env_head: usize = 0,
        replay_env_len: usize = 0,
        /// Set once from the loop thread before the first dispatch;
        /// workers call `services.wake()` through it (the one
        /// thread-safe PlatformServices entry).
        services: ?*const platform.PlatformServices = null,
        /// The runtime's canvas image registry, bound by `UiApp`
        /// alongside the services so `update` can register fetched
        /// pixels synchronously (loop-thread only, not an effect).
        images: ?ImageRegistryBinding = null,
        /// The runtime's window verbs (close/minimize by label), bound
        /// by `UiApp` alongside the services — the seam behind
        /// app-drawn window controls (loop-thread only).
        window_actions: ?WindowActionBinding = null,
        /// The embedding host's named-command services (`hostSend` /
        /// `hostRequest`), bound by whoever hosts a transpiled app core
        /// (loop-thread only). Null means no host services: sends drop,
        /// requests reject loudly in real mode, and the fake executor
        /// parks requests for `feedHostResult` regardless.
        host_calls: ?HostCallBinding = null,
        /// Window-action mirror: counts and the last requested label,
        /// observable in tests (`windowActionState`).
        window_action_state: WindowActionState = .{},
        /// The environment spawned children inherit and fetch honors
        /// (PATH for `spawnPath`-style lookups, proxy variables).
        /// Bound once from the loop thread before the first real
        /// spawn/fetch; `null` means "resolve a fallback at first use"
        /// (see `fallbackEnviron`).
        environ: ?std.process.Environ = null,
        io_threaded: ?*IoThreaded = null,
        shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Teardown budget (total milliseconds) for file workers stuck
        /// in blocking I/O that nothing can force to converge; see
        /// `deinit` and `default_effect_file_join_deadline_ms`.
        /// Injectable so tests pin the interrupt and abandon paths
        /// with a tiny bound.
        file_join_deadline_ms: u64 = default_effect_file_join_deadline_ms,
        /// Best-effort interruption switch: halfway through the file
        /// deadline, teardown cancels a stuck file worker's blocking
        /// task (the threaded io interrupts the blocked syscall —
        /// pthread_kill(SIG.IO)/tgkill on POSIX,
        /// NtCancelSynchronousIoFile on Windows). Always true in real
        /// use; tests disable it to reach the abandon-and-leak safety
        /// net deterministically.
        file_join_interrupt: bool = true,
        /// How many file workers teardown has abandoned (each one a
        /// bounded, warned leak — see `FileWorkerContext`). The seam
        /// tests assert against: zero on every healthy teardown.
        abandoned_file_workers: u32 = 0,
        /// Teardown budget (total milliseconds) for spawn workers the
        /// group-kill could not converge — a descendant that escaped
        /// the child's process group (`setsid`, a shell's `set -m`
        /// background job) keeps the inherited stdout write end open,
        /// so the worker's read never sees EOF. Shares the file
        /// deadline's default deliberately (the rationale is
        /// identical: generous, and a healthy teardown — the kill
        /// forcing EOF within milliseconds — never meets it) but stays
        /// its own field so tests pin each worker class independently.
        spawn_join_deadline_ms: u64 = default_effect_file_join_deadline_ms,
        /// Best-effort interruption switch for spawn workers,
        /// mirroring `file_join_interrupt`: halfway through the spawn
        /// deadline, teardown cancels a stuck worker's blocking task
        /// (the threaded io interrupts the blocked pipe read). Always
        /// true in real use; tests disable it to reach the
        /// abandon-and-leak safety net deterministically.
        spawn_join_interrupt: bool = true,
        /// How many spawn workers teardown has abandoned (each one a
        /// bounded, warned leak — see `SpawnWorkerContext`). The seam
        /// tests assert against: zero on every healthy teardown.
        abandoned_spawn_workers: u32 = 0,
        /// Injectable concurrent-start switch for fetch supervisors,
        /// following `file_join_interrupt`: always true in real use;
        /// tests disable it to pin the no-capacity rejection path
        /// deterministically (the real trigger — the executor refusing
        /// `std.Io.concurrent` — needs resource exhaustion). See
        /// `fetchWorkerMain`.
        fetch_concurrent_start: bool = true,
        /// How many fetches were REFUSED because the executor could
        /// not start their exchange as a cancelable task (each one a
        /// `.rejected` terminal and a one-time warning — never an
        /// uncancelable inline exchange). Incremented by worker
        /// threads; read it from the loop thread after the terminal
        /// drained.
        fetch_start_rejections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        next_generation: u32 = 1,
        slots: [max_effects]Slot = [_]Slot{.{}} ** max_effects,
        /// Fixed fx timer table (see `max_effect_timers`): timers live
        /// beside the effect slots, never in them. Loop-thread only.
        timer_slots: [max_effect_timers]TimerSlot = [_]TimerSlot{.{}} ** max_effect_timers,
        /// The single audio playback channel (see `AudioChannel`).
        /// Loop-thread only, like the timer table.
        audio: AudioChannel = .{},
        queue_mutex: SpinMutex = .{},
        queue: [max_effect_queue_entries]Entry = undefined,
        queue_head: usize = 0,
        queue_len: usize = 0,
        /// Mirror of `queue_len` readable without the lock, so the frame
        /// path can skip idle drains cheaply.
        queue_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// Loop-thread-only ring: spawn/fetch rejections and fake-executor
        /// terminals that found the queue full. Drained before the queue.
        pending_exits: [max_effect_pending_exits]PendingMsg = undefined,
        /// Enqueue-order stamps for the ring entries (parallel to
        /// `pending_exits`), so the drain can merge ring entries with
        /// the separately staged image terminals in original order.
        pending_exit_seqs: [max_effect_pending_exits]u64 = undefined,
        pending_exit_head: usize = 0,
        pending_exit_len: usize = 0,
        /// Monotonic enqueue stamp shared by the pending ring and the
        /// image stage — the drain's merge key.
        pending_seq: u64 = 0,
        /// Loop-thread-only image-terminal stage (see `PendingImage`
        /// for the non-lossy contract). FIFO over `pending_images`
        /// until a burst outgrows it, then over `pending_image_spill`
        /// (freed when the stage drains empty, and at `deinit`).
        pending_images: [max_effect_pending_images_inline]PendingImage = undefined,
        pending_image_spill: []PendingImage = &.{},
        pending_image_head: usize = 0,
        pending_image_len: usize = 0,
        /// Scratch the drained entry is copied into so its line slice
        /// stays valid while `update` runs (recycled per drained Msg).
        drain_scratch: Entry = .{},
        /// The heap payload of the most recently drained oversized line
        /// (raised `max_line_bytes`), keeping `EffectLine.line` valid
        /// while `update` runs (freed when the next line drains, or at
        /// `deinit`).
        drain_heap_line: ?[]u8 = null,
        /// The buffer of the most recently delivered fetch response or
        /// file result, keeping `EffectResponse.body` /
        /// `EffectFileResult.bytes` valid while `update` runs (freed
        /// when the next response or file result drains, or at
        /// `deinit`).
        drain_fetch_body: ?[]u8 = null,
        /// The collect buffer of the most recently delivered collect
        /// exit, keeping `EffectExit.output` valid while `update` runs
        /// (freed when the next collect exit drains, or at `deinit`).
        drain_collect_output: ?[]u8 = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Kill every running effect, wait for the workers to finish
        /// (draining their final queue posts), JOIN every worker
        /// thread, and release the executor io. Fetch joins are
        /// unconditional — fetch supervisors cancel on the shutdown
        /// flag (and an exchange that cannot start cancellably is
        /// rejected up front), so no fetch worker survives this call.
        /// Spawn and file workers get a deadline each
        /// (`spawn_join_deadline_ms` / `file_join_deadline_ms`), with
        /// a best-effort cancel of the blocked task at the halfway
        /// mark: a spawn normally converges from the process-group
        /// kill within milliseconds, but a descendant that escaped the
        /// group (`setsid`, a shell's `set -m` background job) keeps
        /// the stdout pipe open past every kill, and file I/O has no
        /// converging force at all (a write to a FIFO with no reader,
        /// a stalled network filesystem). A worker still stuck when
        /// its budget expires is ABANDONED — thread detached, its
        /// out-of-line context, private buffers, and the executor io
        /// deliberately leaked, one warning naming the stuck op (see
        /// `FileWorkerContext` / `SpawnWorkerContext` for the
        /// invariant). Either way the owner may free the channel's
        /// memory — and tear down the allocator behind it — the moment
        /// this returns: nothing an abandoned worker can still reach
        /// lives in the channel or in caller-allocator storage (the
        /// leakable set is allocated from `process_allocator`). All
        /// three worker classes share one terminal guarantee: teardown
        /// returns bounded, and every byte a live thread can still
        /// touch stays valid forever.
        ///
        /// Idempotent, and only the FIRST call may touch platform
        /// services — it ends by severing the services binding, so a
        /// repeat call answers inert. That property carries the app
        /// teardown ordering contract: the UiApp stop hook runs this
        /// while the platform is still alive (the runtime guarantees the
        /// hook fires before its loop returns), and the app owner's own
        /// deinit — typically a main() defer that runs after the runner
        /// has destroyed platform and runtime — reaches this a second
        /// time, where any service call would dereference freed memory.
        pub fn deinit(self: *Self) void {
            self.shutdown.store(true, .release);
            // Disarm live platform timers (best effort) and clear the table.
            for (&self.timer_slots, 0..) |*timer_slot, index| {
                if (timer_slot.active and !timer_slot.fake) {
                    if (self.services) |services| {
                        services.cancelTimer(effectTimerPlatformId(index)) catch {};
                    }
                }
                timer_slot.* = .{};
            }
            // Silence the platform audio player (best effort) and clear
            // the channel.
            if (self.audio.active and !self.audio.fake) {
                if (self.services) |services| services.audioStop() catch {};
            }
            self.audio = .{};
            // Host requests park on the loop thread with no worker to
            // wait for: retire them here so the worker wait below never
            // stalls on one, and any late host answer reports
            // EffectNotFound instead of touching a freed buffer.
            for (&self.slots) |*slot| {
                if (slot.kind == .host and slot.state.load(.acquire) == .running) {
                    self.releaseFetchSlot(slot);
                    slot.generation = 0;
                }
            }
            for (&self.slots) |*slot| {
                if (slot.state.load(.acquire) == .running and !slot.fake) {
                    slot.cancel_requested.store(true, .release);
                    // Fetch workers poll `cancel_requested`/`shutdown`
                    // and cancel their blocking task themselves.
                    if (slot.kind == .spawn) self.killPublishedChild(slot);
                }
            }
            if (io_threaded_supported) {
                if (self.io_threaded) |threaded| {
                    // Wait for every worker's terminal post, then JOIN
                    // every worker thread. For fetch workers the wait
                    // is unbounded on purpose: a worker holds pointers
                    // into this struct (its slot, the completion
                    // queue, this io) for its whole thread lifetime,
                    // and the owner frees this memory right after
                    // deinit returns — a bounded give-up here once
                    // left an abandoned worker writing into freed
                    // memory, which is exactly how a torn-down app
                    // crashed inside a stale slot's `child_mutex`.
                    // Fetch convergence is the shutdown flag's doing:
                    // supervisors poll it and cancel their exchange
                    // (one that cannot start cancellably is rejected
                    // up front, never run inline), and the
                    // terminal-post retry loops give up on `shutdown`
                    // within a millisecond. Spawn and file workers get
                    // a deadline each instead, because their blocking
                    // phase can outlive every converging force: the
                    // group-kill above forces most spawn reads to EOF
                    // within milliseconds (`child.wait` then reaps a
                    // dead process, and a raced pre-publish cancel is
                    // re-checked by the task itself), but a descendant
                    // that escaped the process group keeps the pipe
                    // open past every kill; file I/O has nothing to
                    // kill at all. Halfway through each deadline the
                    // supervisor is asked to cancel the blocked task
                    // (the threaded io interrupts blocked syscalls
                    // with a no-op signal on POSIX and
                    // NtCancelSynchronousIoFile on Windows), and a
                    // worker still stuck at the end is abandoned below
                    // instead of hanging teardown forever. The queue
                    // is still drained while waiting so posts that
                    // landed before the flag retire promptly.
                    const io = threaded.io();
                    const file_deadline_ms = self.file_join_deadline_ms;
                    const spawn_deadline_ms = self.spawn_join_deadline_ms;
                    var waited_ms: u64 = 0;
                    var file_interrupt_sent = false;
                    var spawn_interrupt_sent = false;
                    while (true) {
                        var converging = false;
                        var file_pending = false;
                        var spawn_pending = false;
                        for (&self.slots) |*slot| {
                            if (slot.fake or slot.state.load(.acquire) != .running) continue;
                            switch (slot.kind) {
                                .file => file_pending = true,
                                .spawn => spawn_pending = true,
                                else => converging = true,
                            }
                        }
                        if (!converging and
                            (!file_pending or waited_ms >= file_deadline_ms) and
                            (!spawn_pending or waited_ms >= spawn_deadline_ms)) break;
                        if (file_pending and !file_interrupt_sent and self.file_join_interrupt and waited_ms >= file_deadline_ms / 2) {
                            file_interrupt_sent = true;
                            for (&self.slots) |*slot| {
                                if (slot.kind != .file or slot.fake) continue;
                                if (slot.state.load(.acquire) != .running) continue;
                                if (slot.file_ctx) |ctx| ctx.interrupt.store(true, .release);
                            }
                        }
                        if (spawn_pending and !spawn_interrupt_sent and self.spawn_join_interrupt and waited_ms >= spawn_deadline_ms / 2) {
                            spawn_interrupt_sent = true;
                            for (&self.slots) |*slot| {
                                if (slot.kind != .spawn or slot.fake) continue;
                                if (slot.state.load(.acquire) != .running) continue;
                                if (slot.spawn_ctx) |ctx| ctx.interrupt.store(true, .release);
                            }
                        }
                        self.clearQueue();
                        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch break;
                        waited_ms += 1;
                    }
                    var abandoned_any = false;
                    for (&self.slots) |*slot| {
                        if (slot.kind != .file or slot.fake) continue;
                        if (slot.state.load(.acquire) != .running) continue;
                        const ctx = slot.file_ctx orelse continue;
                        // The commit/abandon handshake: whoever locks
                        // first decides. A worker that just finished
                        // has committed — it is touching the slot and
                        // queue right now and converges in
                        // milliseconds, so the unconditional join
                        // below collects it like any other worker.
                        ctx.mutex.lock();
                        const committed = ctx.committed;
                        if (!committed) ctx.abandoned = true;
                        ctx.mutex.unlock();
                        if (committed) continue;
                        std.debug.print(
                            "effects teardown: a file {s} against '{s}' is still blocked in I/O after {d}ms; abandoning its worker thread and leaking its buffers so teardown can return safely\n",
                            .{ @tagName(slot.file_op), slot.filePath(), file_deadline_ms },
                        );
                        // DELIBERATE LEAK — the invariant that makes it
                        // safe: the abandoned worker may wake at any
                        // later time, so everything it can still reach
                        // must stay allocated forever — its context
                        // (`ctx`, dropped here without freeing), that
                        // context's data buffer, and the executor io
                        // (leaked after the joins). All three live in
                        // process-lifetime storage
                        // (`process_allocator`), NOT the channel's
                        // caller-owned allocator, so the leak survives
                        // the owner deinitializing its arena or GPA
                        // right after this returns. The handshake above
                        // guarantees the worker touches nothing else —
                        // not this slot (whose caller-owned delivery
                        // buffer the sweep below frees normally), not
                        // the queue, not the channel — so the owner may
                        // free the channel's memory the moment deinit
                        // returns. Bounded (one context and buffer per
                        // abandoned worker, one executor io per
                        // abandoning teardown) and loud (the warning
                        // above).
                        if (slot.worker_thread) |thread| {
                            slot.worker_thread = null;
                            thread.detach();
                        }
                        slot.file_ctx = null;
                        slot.generation = 0;
                        slot.state.store(.idle, .release);
                        self.abandoned_file_workers += 1;
                        abandoned_any = true;
                    }
                    for (&self.slots) |*slot| {
                        if (slot.kind != .spawn or slot.fake) continue;
                        if (slot.state.load(.acquire) != .running) continue;
                        const ctx = slot.spawn_ctx orelse continue;
                        // The same commit/abandon handshake as the file
                        // block above: a worker that committed is in
                        // its epilogue right now and the unconditional
                        // join below collects it; one still blocked is
                        // fenced off the channel forever.
                        ctx.mutex.lock();
                        const committed = ctx.committed;
                        if (!committed) ctx.abandoned = true;
                        ctx.mutex.unlock();
                        if (committed) continue;
                        std.debug.print(
                            "effects teardown: spawned command '{s}' still holds its worker after {d}ms (an escaped descendant is keeping its pipe open past the group kill); abandoning the worker thread and leaking its context so teardown can return safely\n",
                            .{ if (slot.argv_count > 0) slot.argv_slices[0] else "", spawn_deadline_ms },
                        );
                        // DELIBERATE LEAK, same invariant as the file
                        // abandon above: the worker may wake at any
                        // later time (the escaped descendant exits and
                        // EOF finally arrives), so its context — the
                        // argv/stdin copies, the child handshake it
                        // will still lock to reap, its private
                        // framing/collect buffers — and the executor
                        // io stay allocated forever in
                        // `process_allocator` storage. The handshake
                        // guarantees it touches nothing else: not this
                        // slot (whose caller-owned collect buffer the
                        // sweep below frees normally), not the queue
                        // (`produceSpawnLine` re-checks the abandon
                        // under the fence), not the channel. Bounded
                        // and loud, exactly like the file leak.
                        if (slot.worker_thread) |thread| {
                            slot.worker_thread = null;
                            thread.detach();
                        }
                        slot.spawn_ctx = null;
                        slot.generation = 0;
                        slot.state.store(.idle, .release);
                        self.abandoned_spawn_workers += 1;
                        abandoned_any = true;
                    }
                    for (&self.slots) |*slot| joinWorker(slot);
                    if (abandoned_any) {
                        // Leak the executor io too: the abandoned
                        // worker's blocked syscall runs inside it, and
                        // `IoThreaded.deinit` would wait on (or free
                        // under) that thread.
                        self.io_threaded = null;
                    }
                }
                if (self.io_threaded) |threaded| {
                    threaded.deinit();
                    process_allocator.destroy(threaded);
                    self.io_threaded = null;
                }
            }
            self.clearQueue();
            for (&self.slots) |*slot| {
                if (slot.fetch_buffer) |buffer| {
                    self.allocator.free(buffer);
                    slot.fetch_buffer = null;
                }
                if (slot.collect_buffer) |buffer| {
                    self.allocator.free(buffer);
                    slot.collect_buffer = null;
                }
                if (slot.line_buffer) |buffer| {
                    self.allocator.free(buffer);
                    slot.line_buffer = null;
                }
            }
            if (self.drain_fetch_body) |buffer| {
                self.allocator.free(buffer);
                self.drain_fetch_body = null;
            }
            if (self.drain_collect_output) |buffer| {
                self.allocator.free(buffer);
                self.drain_collect_output = null;
            }
            if (self.drain_heap_line) |buffer| {
                self.allocator.free(buffer);
                self.drain_heap_line = null;
            }
            // Undrained staged image terminals are plain data — only a
            // burst's spill ring owns heap.
            if (self.pending_image_spill.len > 0) {
                self.allocator.free(self.pending_image_spill);
                self.pending_image_spill = &.{};
            }
            self.pending_image_head = 0;
            self.pending_image_len = 0;
            // Sever the services binding last: the platform this pointer
            // reaches into may be destroyed before the next call arrives
            // (main's deferred app deinit runs after the runner's platform
            // teardown), and a severed channel already answers every
            // transport command inert through its existing no-services
            // paths instead of dereferencing freed memory.
            self.services = null;
            // Sever the host-call binding for the same reason: its
            // context belongs to the embedding host.
            self.host_calls = null;
        }

        /// Discard every queued completion, freeing heap line payloads
        /// (raised `max_line_bytes` lines own an allocation each).
        /// Shutdown-only; the drain path retires entries one by one.
        fn clearQueue(self: *Self) void {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            while (self.queue_len > 0) {
                const entry = &self.queue[self.queue_head];
                if (entry.heap_line) |heap| {
                    self.allocator.free(heap);
                    entry.heap_line = null;
                }
                self.queue_head = (self.queue_head + 1) % max_effect_queue_entries;
                self.queue_len -= 1;
            }
            self.queue_head = 0;
            self.queue_count.store(0, .release);
        }

        /// Point workers at the platform's wake service. Loop-thread
        /// only; the first bind sticks (the services value lives on the
        /// runtime and is stable for its lifetime).
        pub fn bindServices(self: *Self, services: *const platform.PlatformServices) void {
            if (self.services == null) self.services = services;
        }

        /// Point spawned children at the host process environment (the
        /// runner takes it from `std.process.Init`). Loop-thread only;
        /// the first non-null bind sticks, and it must land before the
        /// first real spawn/fetch creates the executor io — after that
        /// the environment is frozen into `std.Io.Threaded`. Hosts that
        /// never bind (embed/mobile) get `fallbackEnviron()`.
        pub fn bindEnviron(self: *Self, environ: ?std.process.Environ) void {
            if (self.environ == null) self.environ = environ;
        }

        /// Point image registration at the runtime's canvas image
        /// registry (`Runtime.canvasImageRegistryBinding()`). Loop-thread
        /// only; the first bind sticks.
        pub fn bindImages(self: *Self, binding: ImageRegistryBinding) void {
            if (self.images == null) self.images = binding;
        }

        /// Point the drain's result reporting at a session recorder.
        /// Loop-thread only; the first bind sticks.
        pub fn bindJournal(self: *Self, binding: EffectJournal) void {
            if (self.journal == null) self.journal = binding;
        }

        /// Point window actions at the runtime's window verbs (bound by
        /// `UiApp.bindEffectsChannel`, which resolves labels against the
        /// live window table). Loop-thread only; the first bind sticks.
        pub fn bindWindowActions(self: *Self, binding: WindowActionBinding) void {
            if (self.window_actions == null) self.window_actions = binding;
        }

        /// Point named host commands at the embedding host's services
        /// (see `HostCallBinding`). Loop-thread only; the first bind
        /// sticks.
        pub fn bindHostCalls(self: *Self, binding: HostCallBinding) void {
            if (self.host_calls == null) self.host_calls = binding;
        }

        /// Switch this channel into session-replay mode: the fake
        /// executor (no processes, no network, no file or pasteboard
        /// I/O — requests park in their slots) with journaled results as
        /// the only terminal source. Must run before the first
        /// spawn/fetch, i.e. before the replayed `app_start` dispatches.
        pub fn armReplay(self: *Self) void {
            self.executor = .fake;
            self.replay = true;
        }

        /// Report one delivered result to the bound session recorder.
        fn journalNote(self: *Self, record: EffectResultRecord) void {
            const binding = self.journal orelse return;
            binding.record_fn(binding.context, record);
        }

        /// Wall-clock milliseconds since the Unix epoch, AS AN EFFECT:
        /// the ledger-timestamp read for `update`/`init_fx` that stays
        /// deterministic under session replay. Recording journals every
        /// value returned; replay returns the journaled values in the
        /// same order instead of touching the OS clock — so "stamp the
        /// note's edited time" replays byte-identical. This is the one
        /// sanctioned wall-clock read inside update: a direct
        /// `Clock.system` read there is nondeterminism outside the
        /// effect boundary and will fail replay verification at the
        /// next checkpoint.
        pub fn wallMs(self: *Self) i64 {
            if (self.replay) {
                if (self.replay_clock_len == 0) {
                    self.replay_clock_underflows += 1;
                    if (self.replay_clock_underflows == 1) {
                        std.debug.print(
                            "session replay: a wallMs read found no journaled value - the replayed update reads the clock more often than the recording did (nondeterministic control flow); returning 0\n",
                            .{},
                        );
                    }
                    return 0;
                }
                const value = self.replay_clock[self.replay_clock_head];
                self.replay_clock_head = (self.replay_clock_head + 1) % max_effect_replay_clock_entries;
                self.replay_clock_len -= 1;
                return value;
            }
            const value = self.clock.wallMs();
            self.journalNote(.{ .kind = .clock, .key = 0, .clock_wall_ms = value });
            return value;
        }

        /// Queue one journaled clock value for a replay-mode `wallMs`
        /// read (the `.clock` record feed).
        pub fn pushReplayClock(self: *Self, value: i64) error{EffectNotFound}!void {
            if (self.replay_clock_len >= max_effect_replay_clock_entries) return error.EffectNotFound;
            const index = (self.replay_clock_head + self.replay_clock_len) % max_effect_replay_clock_entries;
            self.replay_clock[index] = value;
            self.replay_clock_len += 1;
        }

        /// Journal one launch-env delivery (an `.env` record): the TS
        /// adapter reports each `envMsgs` value as it dispatches it, so
        /// replay carries the recorded values instead of re-reading the
        /// environment. No-op when no session is being recorded.
        pub fn journalEnvValue(self: *Self, index: u64, msg: []const u8, value: []const u8) void {
            self.journalNote(.{ .kind = .env, .key = index, .payload = value, .stderr_tail = msg });
        }

        /// Queue one journaled launch-env delivery for the replay-mode
        /// envMsgs dispatch (the `.env` record feed). The slices must
        /// outlive the replay (journal bytes do).
        pub fn pushReplayEnv(self: *Self, msg: []const u8, value: []const u8) error{EffectNotFound}!void {
            if (self.replay_env_len >= max_effect_replay_env_entries) return error.EffectNotFound;
            const index = (self.replay_env_head + self.replay_env_len) % max_effect_replay_env_entries;
            self.replay_env[index] = .{ .msg = msg, .value = value };
            self.replay_env_len += 1;
        }

        /// Pop the next journaled launch-env delivery (FIFO), or null
        /// when none remain. An empty queue at the first pop means the
        /// journal carried no `.env` records — the caller re-derives
        /// from the launch configuration (older recordings).
        pub fn takeReplayEnv(self: *Self) ?ReplayEnvEntry {
            if (self.replay_env_len == 0) return null;
            const entry = self.replay_env[self.replay_env_head];
            self.replay_env_head = (self.replay_env_head + 1) % max_effect_replay_env_entries;
            self.replay_env_len -= 1;
            return entry;
        }

        // ------------------------------------------------------------- API

        /// Register (or replace) decoded straight-alpha RGBA8 pixels
        /// under the caller-chosen ImageId `id`, so image/icon/avatar
        /// widgets referencing it draw them. Synchronous (the pixels are
        /// copied before this returns), not an effect: no Msg follows.
        /// Errors are the registry's (`error.InvalidImageId`,
        /// `error.InvalidImageDimensions`, `error.ImageTooLarge`,
        /// `error.ImageRegistryFull`, `error.OutOfMemory` — the slot's
        /// lazy pixel buffer could not be allocated; the registry is
        /// unchanged and the registration can be retried) plus
        /// `error.UnsupportedService` when no registry is bound.
        pub fn registerImage(self: *Self, id: u64, width: usize, height: usize, rgba8: []const u8) anyerror!void {
            const binding = self.images orelse return error.UnsupportedService;
            return binding.register_fn(binding.context, id, width, height, rgba8);
        }

        /// Decode encoded image bytes (PNG, JPEG, ... — whatever the
        /// platform codec supports) and register the pixels under `id` in
        /// one step: the fetch-avatar path. Call it from `update` on the
        /// `on_response` Msg with the delivered body; store `id` in the
        /// model only on success, so views fall back (avatar initials)
        /// while the image is loading or after it failed. On top of
        /// `registerImage`'s errors: `error.ImageDecodeFailed`
        /// (undecodable bytes) and `error.UnsupportedService` (platform
        /// without a codec or no registry bound).
        pub fn registerImageBytes(self: *Self, id: u64, bytes: []const u8) anyerror!RegisteredImage {
            const binding = self.images orelse return error.UnsupportedService;
            return binding.register_bytes_fn(binding.context, id, bytes);
        }

        /// Remove `id` from the registry, freeing its slot. Returns
        /// whether the id was registered; widgets still referencing it
        /// draw their fallback (avatar initials) on the next frame.
        pub fn unregisterImage(self: *Self, id: u64) bool {
            const binding = self.images orelse return false;
            return binding.unregister_fn(binding.context, id);
        }

        /// Run a subprocess and stream its stdout back as Msgs. Never
        /// fails from the caller's view: requests that cannot run are
        /// reported through `on_exit` with reason `.rejected` on the
        /// next drain.
        pub fn spawn(self: *Self, options: SpawnOptions) void {
            self.reclaimSlots();
            if (options.argv.len == 0 or options.argv.len > max_effect_argv) {
                return self.reject(options);
            }
            var total_bytes: usize = 0;
            for (options.argv) |arg| total_bytes += arg.len;
            if (total_bytes > max_effect_argv_bytes) return self.reject(options);
            const stdin_bytes = options.stdin orelse "";
            if (stdin_bytes.len > max_effect_stdin_bytes) return self.reject(options);
            if (options.max_line_bytes == 0 or options.max_line_bytes > max_effect_line_bytes_ceiling) {
                return self.reject(options);
            }
            if (self.keyOccupiedUntilDelivery(options.key)) return self.reject(options);
            const slot_index = self.findIdleSlot() orelse return self.reject(options);

            const slot = &self.slots[slot_index];
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = options.key;
            slot.kind = .spawn;
            slot.on_line = options.on_line;
            slot.on_exit = options.on_exit;
            slot.on_response = null;
            slot.exit_undelivered = false;
            slot.cancel_requested.store(false, .release);
            // `cancelled_generation` is deliberately NOT reset: entries
            // from a cancelled previous occupant may still sit in the
            // queue, and the sticky value keeps filtering them after the
            // slot is reused (the new generation never matches it).
            slot.dropped_pending = 0;
            slot.dropped_total = 0;
            slot.argv_count = options.argv.len;
            var offset: usize = 0;
            for (options.argv, 0..) |arg, index| {
                @memcpy(slot.argv_storage[offset .. offset + arg.len], arg);
                slot.argv_slices[index] = slot.argv_storage[offset .. offset + arg.len];
                offset += arg.len;
            }
            @memcpy(slot.stdin_storage[0..stdin_bytes.len], stdin_bytes);
            slot.stdin_len = stdin_bytes.len;
            slot.output_mode = options.output;
            slot.collect_len = 0;
            slot.collect_truncated = false;
            slot.stderr_total = 0;
            if (slot.collect_buffer) |old| {
                self.allocator.free(old);
                slot.collect_buffer = null;
            }
            if (slot.line_buffer) |old| {
                self.allocator.free(old);
                slot.line_buffer = null;
            }
            slot.line_limit = options.max_line_bytes;
            if (options.output == .collect) {
                // The slot's CHANNEL-owned collect buffer: the drain
                // hands it to `update` (real mode receives the bytes
                // from the worker context at commit; fake mode
                // accumulates into it directly).
                slot.collect_buffer = self.allocator.alloc(u8, max_effect_collect_bytes) catch {
                    return self.reject(options);
                };
            }
            // No slot-side line buffer for spawns: a real worker frames
            // raised-bound lines into its context's process-lived
            // buffer (see `SpawnWorkerContext.line_buffer`), and the
            // fake executor's `feedLine` never frames. (`.stream`
            // fetches still allocate the slot buffer in `fetch`.)
            slot.fake = self.executor == .fake;
            slot.state.store(.running, .release);

            if (slot.fake) return;

            const io = self.ensureIo() catch {
                self.releaseSpawnSlot(slot);
                return self.reject(options);
            };
            // The worker's blocking phase touches only this out-of-line
            // context (argv/stdin copies, the child handshake, its own
            // framing/collect buffers), never the channel — the seam
            // that lets teardown abandon a worker whose child's
            // group-kill did not converge it and still free the channel
            // (see `SpawnWorkerContext`). Context and buffers come from
            // `process_allocator`, never `self.allocator`: teardown may
            // leak them under a live thread, and the channel's
            // caller-owned allocator dies with the owner. The happy
            // path frees them in `joinWorker`, through the same
            // process-lifetime seam.
            const ctx = process_allocator.create(SpawnWorkerContext) catch {
                self.releaseSpawnSlot(slot);
                return self.reject(options);
            };
            ctx.* = .{
                .key = options.key,
                .on_line = options.on_line,
                .output_mode = options.output,
                .line_limit = options.max_line_bytes,
                .exit = .{ .key = options.key, .code = effect_error_exit_code, .reason = .spawn_failed },
                .argv_count = options.argv.len,
                .stdin_len = stdin_bytes.len,
            };
            // Slices must point into the heap context, so they are
            // built in place after the copy above.
            var ctx_offset: usize = 0;
            for (options.argv, 0..) |arg, index| {
                @memcpy(ctx.argv_storage[ctx_offset .. ctx_offset + arg.len], arg);
                ctx.argv_slices[index] = ctx.argv_storage[ctx_offset .. ctx_offset + arg.len];
                ctx_offset += arg.len;
            }
            @memcpy(ctx.stdin_storage[0..stdin_bytes.len], stdin_bytes);
            if (options.output == .collect) {
                ctx.collect_buffer = process_allocator.alloc(u8, max_effect_collect_bytes) catch {
                    process_allocator.destroy(ctx);
                    self.releaseSpawnSlot(slot);
                    return self.reject(options);
                };
            } else if (options.max_line_bytes > max_effect_line_bytes) {
                ctx.line_buffer = process_allocator.alloc(u8, options.max_line_bytes) catch {
                    process_allocator.destroy(ctx);
                    self.releaseSpawnSlot(slot);
                    return self.reject(options);
                };
            }
            slot.spawn_ctx = ctx;
            const thread = std.Thread.spawn(.{}, spawnWorkerMain, .{ self, slot_index, slot.generation, io, ctx }) catch {
                destroySpawnContext(ctx);
                slot.spawn_ctx = null;
                self.releaseSpawnSlot(slot);
                return self.reject(options);
            };
            slot.worker_thread = thread;
        }

        /// Run an HTTP(S) request on a worker thread and deliver its
        /// terminal outcome — response, failure, timeout, or cancel —
        /// as exactly one Msg. Never fails from the caller's view:
        /// requests that cannot run are reported through `on_response`
        /// with outcome `.rejected` on the next drain. Fetches share
        /// the spawn slots (`max_effects` in-flight effects combined)
        /// and the same key space.
        pub fn fetch(self: *Self, options: FetchOptions) void {
            self.reclaimSlots();
            if (options.url.len == 0 or options.url.len > max_effect_url_bytes) {
                return self.rejectFetch(options);
            }
            const uri = std.Uri.parse(options.url) catch return self.rejectFetch(options);
            const scheme_ok = std.ascii.eqlIgnoreCase(uri.scheme, "http") or
                std.ascii.eqlIgnoreCase(uri.scheme, "https");
            if (!scheme_ok) return self.rejectFetch(options);
            if (options.headers.len > max_effect_fetch_headers) return self.rejectFetch(options);
            var header_bytes: usize = 0;
            for (options.headers) |header| {
                header_bytes += header.name.len + header.value.len;
                // Names/values that would corrupt the request line are
                // rejected here rather than asserted on the worker.
                if (header.name.len == 0) return self.rejectFetch(options);
                if (std.mem.findScalar(u8, header.name, ':') != null) return self.rejectFetch(options);
                if (std.mem.findPosLinear(u8, header.name, 0, "\r\n") != null) return self.rejectFetch(options);
                if (std.mem.findPosLinear(u8, header.value, 0, "\r\n") != null) return self.rejectFetch(options);
            }
            if (header_bytes > max_effect_fetch_header_bytes) return self.rejectFetch(options);
            const payload = options.body orelse "";
            if (payload.len > max_effect_fetch_payload_bytes) return self.rejectFetch(options);
            if (options.max_line_bytes == 0 or options.max_line_bytes > max_effect_line_bytes_ceiling) {
                return self.rejectFetch(options);
            }
            if (self.keyOccupiedUntilDelivery(options.key)) return self.rejectFetch(options);
            const slot_index = self.findIdleSlot() orelse return self.rejectFetch(options);

            const slot = &self.slots[slot_index];
            // Stream fetches never buffer a body: the buffer holds only
            // the request payload copy.
            const body_space: usize = if (options.response == .stream) 0 else max_effect_body_bytes;
            const buffer = self.allocator.alloc(u8, payload.len + body_space) catch {
                return self.rejectFetch(options);
            };
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = options.key;
            slot.kind = .fetch;
            slot.on_line = if (options.response == .stream) options.on_line else null;
            slot.on_exit = null;
            slot.on_response = options.on_response;
            slot.fetch_response_mode = options.response;
            slot.method = options.method;
            slot.timeout_ms = options.timeout_ms;
            slot.line_limit = options.max_line_bytes;
            if (slot.line_buffer) |old| {
                self.allocator.free(old);
                slot.line_buffer = null;
            }
            if (options.response == .stream and options.max_line_bytes > max_effect_line_bytes) {
                slot.line_buffer = self.allocator.alloc(u8, options.max_line_bytes) catch {
                    self.allocator.free(buffer);
                    return self.rejectFetch(options);
                };
            }
            slot.cancel_requested.store(false, .release);
            slot.fetch_done.store(false, .release);
            // `cancelled_generation` stays sticky, exactly as in `spawn`.
            slot.dropped_pending = 0;
            slot.dropped_total = 0;
            @memcpy(slot.url_storage[0..options.url.len], options.url);
            slot.url_len = options.url.len;
            var offset: usize = 0;
            for (options.headers, 0..) |header, index| {
                @memcpy(slot.header_storage[offset .. offset + header.name.len], header.name);
                const name = slot.header_storage[offset .. offset + header.name.len];
                offset += header.name.len;
                @memcpy(slot.header_storage[offset .. offset + header.value.len], header.value);
                const value = slot.header_storage[offset .. offset + header.value.len];
                offset += header.value.len;
                slot.header_slices[index] = .{ .name = name, .value = value };
            }
            slot.header_count = options.headers.len;
            if (slot.fetch_buffer) |old| self.allocator.free(old);
            slot.fetch_buffer = buffer;
            @memcpy(buffer[0..payload.len], payload);
            slot.payload_len = payload.len;
            slot.body_len = 0;
            slot.fetch_status = 0;
            slot.fetch_outcome = .protocol_failed;
            slot.fetch_truncated = false;
            slot.fake = self.executor == .fake;
            slot.state.store(.running, .release);

            if (slot.fake) return;

            const io = self.ensureIo() catch {
                self.releaseFetchSlot(slot);
                return self.rejectFetch(options);
            };
            const thread = std.Thread.spawn(.{}, fetchWorkerMain, .{ self, slot_index, slot.generation, io }) catch {
                self.releaseFetchSlot(slot);
                return self.rejectFetch(options);
            };
            slot.worker_thread = thread;
        }

        /// Write a whole file on a worker thread — TEA-friendly
        /// persistence (session snapshots, app state) without smuggling
        /// an `Io` handle into `update`. Missing parent directories are
        /// created; an existing file is replaced whole. Exactly one
        /// terminal Msg follows through `on_result` — `.ok` means every
        /// byte is on disk; failure is never silent. Never fails from
        /// the caller's view: requests that cannot run are reported with
        /// outcome `.rejected` on the next drain. File effects share the
        /// `max_effects` slots and the key space with spawns and fetches.
        pub fn writeFile(self: *Self, options: WriteFileOptions) void {
            if (options.bytes.len > max_effect_file_bytes) {
                return self.rejectFile(options.key, .write, options.on_result);
            }
            self.startFile(options.key, .write, options.path, options.bytes, options.on_result);
        }

        /// Read a whole file on a worker thread and deliver it as
        /// exactly one terminal Msg: `.ok` with the content in
        /// `EffectFileResult.bytes`, `.not_found`, `.io_failed`, or
        /// `.truncated` with the first `max_effect_file_bytes` when the
        /// file is bigger (its own outcome, not a flag — a cut JSON
        /// snapshot must not parse as whole). The bytes are drain
        /// scratch: copy what the model keeps.
        pub fn readFile(self: *Self, options: ReadFileOptions) void {
            self.startFile(options.key, .read, options.path, "", options.on_result);
        }

        fn startFile(self: *Self, key: u64, op: EffectFileOp, file_path: []const u8, bytes: []const u8, on_result: ?FileMsgFn) void {
            self.reclaimSlots();
            if (file_path.len == 0 or file_path.len > max_effect_file_path_bytes) {
                return self.rejectFile(key, op, on_result);
            }
            if (self.keyOccupiedUntilDelivery(key)) return self.rejectFile(key, op, on_result);
            const slot_index = self.findIdleSlot() orelse return self.rejectFile(key, op, on_result);

            const slot = &self.slots[slot_index];
            // A write's buffer holds its payload copy; a read's holds
            // the content space plus one spare byte that detects
            // over-bound files without a stat round trip. This is the
            // slot's CHANNEL-owned buffer (fake-mode storage, real-mode
            // delivery space the drain hands to `update`); a real
            // worker's blocking phase gets its own process-lived copy
            // in `FileWorkerContext.buffer` below.
            const buffer_len = if (op == .write) bytes.len else max_effect_file_bytes + 1;
            const buffer = self.allocator.alloc(u8, buffer_len) catch {
                return self.rejectFile(key, op, on_result);
            };
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = key;
            slot.kind = .file;
            slot.file_op = op;
            slot.on_line = null;
            slot.on_exit = null;
            slot.on_response = null;
            slot.on_file = on_result;
            slot.cancel_requested.store(false, .release);
            // `cancelled_generation` stays sticky, exactly as in `spawn`.
            slot.dropped_pending = 0;
            slot.dropped_total = 0;
            @memcpy(slot.url_storage[0..file_path.len], file_path);
            slot.url_len = file_path.len;
            if (slot.line_buffer) |old| {
                self.allocator.free(old);
                slot.line_buffer = null;
            }
            if (slot.fetch_buffer) |old| self.allocator.free(old);
            slot.fetch_buffer = buffer;
            if (op == .write) {
                @memcpy(buffer[0..bytes.len], bytes);
                slot.payload_len = bytes.len;
            } else {
                slot.payload_len = 0;
            }
            slot.body_len = 0;
            slot.fake = self.executor == .fake;
            slot.state.store(.running, .release);

            if (slot.fake) return;

            const io = self.ensureIo() catch {
                self.releaseFetchSlot(slot);
                return self.rejectFile(key, op, on_result);
            };
            // The worker's blocking phase touches only this out-of-line
            // context (path copy, op, its own data buffer), never the
            // channel — the seam that lets teardown abandon a stuck
            // worker and still free the channel (see
            // `FileWorkerContext`). Context and buffer both come from
            // `process_allocator`, never `self.allocator`: teardown may
            // leak them under a live thread, and the channel's
            // caller-owned allocator dies with the owner. The happy
            // path frees both in `joinWorker`, through the same
            // process-lifetime seam.
            const ctx = process_allocator.create(FileWorkerContext) catch {
                self.releaseFetchSlot(slot);
                return self.rejectFile(key, op, on_result);
            };
            const worker_buffer = process_allocator.alloc(u8, buffer_len) catch {
                process_allocator.destroy(ctx);
                self.releaseFetchSlot(slot);
                return self.rejectFile(key, op, on_result);
            };
            ctx.* = .{
                .op = op,
                .buffer = worker_buffer,
                .payload_len = slot.payload_len,
            };
            if (op == .write) @memcpy(worker_buffer[0..bytes.len], bytes);
            @memcpy(ctx.path_storage[0..file_path.len], file_path);
            ctx.path_len = file_path.len;
            slot.file_ctx = ctx;
            const thread = std.Thread.spawn(.{}, fileWorkerMain, .{ self, slot_index, slot.generation, io, ctx }) catch {
                process_allocator.free(worker_buffer);
                process_allocator.destroy(ctx);
                slot.file_ctx = null;
                self.releaseFetchSlot(slot);
                return self.rejectFile(key, op, on_result);
            };
            slot.worker_thread = thread;
        }

        /// Load an image at runtime — the `Cmd.imageLoad` executor: the
        /// source cascade (local file first, then a verified cache
        /// entry, then the network) runs on a worker thread; the bytes
        /// it produces decode through the platform codec and register
        /// under `options.id` in the runtime's registered-image storage
        /// (the `registerCanvasImageBytes` seam — same slot budget,
        /// same pixel bound, same error classes); and exactly ONE
        /// terminal Msg follows through `on_result`: `.loaded` with the
        /// decoded width/height, or one failure class — never a crash,
        /// never silence. Views referencing the id repaint with the
        /// pixels on their next frame; `update` stays pure. Decode and
        /// registration run at drain time on the loop thread (the
        /// registry and its decode scratch are loop-thread state), so
        /// the journal records the encoded bytes exactly as the effect
        /// boundary delivered them and replay re-runs the same
        /// decode-and-register offline. Never fails from the caller's
        /// view: requests that cannot run deliver one `.rejected`
        /// result on the next drain. Image loads share the
        /// `max_effects` slots and the key space (keyed by `id`) with
        /// spawns, fetches, and file effects.
        pub fn loadImage(self: *Self, options: LoadImageOptions) void {
            self.reclaimSlots();
            // The same ids `registerCanvasImage` refuses, refused before
            // any I/O: 0 is the no-image sentinel, and the high bit is
            // the media-surface texture namespace.
            const id_invalid = options.id == 0 or (options.id & canvas.media_surface_image_id_bit) != 0;
            if (id_invalid or
                (options.path.len == 0 and options.url.len == 0) or
                options.path.len > max_effect_image_path_bytes or
                options.cache_path.len > max_effect_image_path_bytes or
                options.url.len > max_effect_url_bytes)
            {
                return self.rejectImage(options.id, options.on_result, true);
            }
            if (options.url.len > 0) {
                const uri = std.Uri.parse(options.url) catch return self.rejectImage(options.id, options.on_result, true);
                const scheme_ok = std.ascii.eqlIgnoreCase(uri.scheme, "http") or
                    std.ascii.eqlIgnoreCase(uri.scheme, "https");
                if (!scheme_ok) return self.rejectImage(options.id, options.on_result, true);
            }
            // Occupied = running (any kind — the key space is shared),
            // OR any slot in the posted-but-undelivered terminal
            // window (`keyOccupiedUntilDelivery`). Delivery ends the
            // window — the drain takes the slot's delivery marker
            // BEFORE the terminal Msg reaches update — so a handler
            // that answers its own terminal by reloading the same id
            // (the gallery-refresh idiom) still parks as a fresh load.
            if (self.keyOccupiedUntilDelivery(options.id)) {
                return self.rejectImage(options.id, options.on_result, true);
            }
            const slot_index = self.findIdleSlot() orelse return self.rejectImage(options.id, options.on_result, true);

            const slot = &self.slots[slot_index];
            // One spare byte past the source bound detects over-bound
            // files and bodies without a stat round trip (the file
            // effect's trick).
            // An allocation failure is NOT regenerable validation: the
            // replayed request allocates its own buffer and parks, so
            // this terminal must journal as executor truth and feed —
            // and the staged rejection holds the id until it drains
            // (`stagedImageOccupiesKey`), because replay's parked
            // request holds it through the same window.
            const buffer = self.allocator.alloc(u8, max_effect_image_bytes + 1) catch {
                return self.rejectImage(options.id, options.on_result, false);
            };
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = options.id;
            slot.kind = .image;
            slot.on_line = null;
            slot.on_exit = null;
            slot.on_response = null;
            slot.on_file = null;
            slot.on_image = options.on_result;
            slot.timeout_ms = options.timeout_ms;
            slot.cancel_requested.store(false, .release);
            slot.fetch_done.store(false, .release);
            // `cancelled_generation` stays sticky, exactly as in `spawn`.
            slot.dropped_pending = 0;
            slot.dropped_total = 0;
            @memcpy(slot.url_storage[0..options.url.len], options.url);
            slot.url_len = options.url.len;
            @memcpy(slot.image_path_storage[0..options.path.len], options.path);
            slot.image_path_len = options.path.len;
            @memcpy(slot.image_cache_storage[0..options.cache_path.len], options.cache_path);
            slot.image_cache_len = options.cache_path.len;
            slot.image_expected_bytes = options.expected_bytes;
            // Pessimistic default: a task interrupted before it records
            // a terminal state must never read as a staged success.
            slot.image_outcome = .io_failed;
            if (slot.line_buffer) |old| {
                self.allocator.free(old);
                slot.line_buffer = null;
            }
            if (slot.fetch_buffer) |old| self.allocator.free(old);
            slot.fetch_buffer = buffer;
            slot.payload_len = 0;
            slot.body_len = 0;
            slot.fetch_status = 0;
            slot.fake = self.executor == .fake;
            slot.state.store(.running, .release);

            if (slot.fake) {
                // Instant-load convention (see `fake_instant_image_bytes`):
                // complete the just-parked request before returning, the
                // deterministic mirror of a real local load racing the
                // drain pass that issued it. `EffectNotFound` cannot
                // happen (the slot parked two lines up), and a full
                // queue outside replay already delivered the loop-side
                // fallback terminal inside the feed — nothing is lost.
                if (self.fake_instant_image_bytes) |bytes| {
                    self.feedImageBytes(options.id, bytes) catch {};
                }
                return;
            }

            // Executor-start failures are NOT regenerable validation
            // either: under replay the fake executor parks the request
            // before ever touching io or threads, so these terminals
            // journal as executor truth and feed. Releasing the slot
            // here does not free the id — the staged rejection holds
            // it until the drain delivers (`stagedImageOccupiesKey`),
            // matching the parked replay request's window.
            const io = self.ensureIo() catch {
                self.releaseFetchSlot(slot);
                return self.rejectImage(options.id, options.on_result, false);
            };
            const thread = std.Thread.spawn(.{}, imageWorkerMain, .{ self, slot_index, slot.generation, io }) catch {
                self.releaseFetchSlot(slot);
                return self.rejectImage(options.id, options.on_result, false);
            };
            slot.worker_thread = thread;
        }

        /// Put text on the system clipboard through the platform
        /// pasteboard — the same seam the runtime's cmd+C copy uses —
        /// and deliver exactly one terminal Msg with an explicit
        /// outcome (`.ok` / `.failed` / `.rejected`). TEA apps stop
        /// spawning `pbcopy`: the write is one bounded synchronous
        /// platform call on the loop thread (pasteboards are
        /// main-thread services), so no worker thread is involved; the
        /// Msg still arrives through the ordinary drain, keeping the
        /// effect contract uniform. Never fails from the caller's view:
        /// requests that cannot run (slots busy, duplicate active key,
        /// text over `max_effect_clipboard_bytes`) are reported with
        /// outcome `.rejected` on the next drain. Clipboard effects
        /// share the `max_effects` slots and the key space with spawns,
        /// fetches, and file effects.
        pub fn writeClipboard(self: *Self, options: WriteClipboardOptions) void {
            if (options.text.len > max_effect_clipboard_bytes) {
                return self.rejectClipboard(options.key, .write, options.on_result);
            }
            self.startClipboard(options.key, .write, options.text, options.on_result);
        }

        /// Read the system clipboard's text and deliver it as exactly
        /// one terminal Msg: `.ok` with the content in
        /// `EffectClipboardResult.text` (drain scratch — copy what the
        /// model keeps), or `.failed` when the platform refuses (no
        /// clipboard service, content over
        /// `max_effect_clipboard_bytes`, pasteboard error). Synchronous
        /// like `writeClipboard`; same slots, same key space.
        pub fn readClipboard(self: *Self, options: ReadClipboardOptions) void {
            self.startClipboard(options.key, .read, "", options.on_result);
        }

        fn startClipboard(self: *Self, key: u64, op: EffectClipboardOp, text: []const u8, on_result: ?ClipboardMsgFn) void {
            self.reclaimSlots();
            const fake = self.executor == .fake;
            // Services are bound before init_fx/update ever run; a null
            // here means a host without the platform clipboard arm.
            if (!fake and self.services == null) return self.rejectClipboard(key, op, on_result);
            if (self.keyOccupiedUntilDelivery(key)) return self.rejectClipboard(key, op, on_result);
            const slot_index = self.findIdleSlot() orelse return self.rejectClipboard(key, op, on_result);

            const slot = &self.slots[slot_index];
            // A write's buffer holds its text copy; a read's holds the
            // clipboard content space.
            const buffer_len = if (op == .write) text.len else max_effect_clipboard_bytes;
            const buffer = self.allocator.alloc(u8, buffer_len) catch {
                return self.rejectClipboard(key, op, on_result);
            };
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = key;
            slot.kind = .clipboard;
            slot.clipboard_op = op;
            slot.on_line = null;
            slot.on_exit = null;
            slot.on_response = null;
            slot.on_file = null;
            slot.on_clipboard = on_result;
            slot.cancel_requested.store(false, .release);
            // `cancelled_generation` stays sticky, exactly as in `spawn`.
            slot.dropped_pending = 0;
            slot.dropped_total = 0;
            slot.url_len = 0;
            if (slot.line_buffer) |old| {
                self.allocator.free(old);
                slot.line_buffer = null;
            }
            if (slot.fetch_buffer) |old| self.allocator.free(old);
            slot.fetch_buffer = buffer;
            if (op == .write) {
                @memcpy(buffer[0..text.len], text);
                slot.payload_len = text.len;
            } else {
                slot.payload_len = 0;
            }
            slot.body_len = 0;
            slot.fake = fake;
            slot.state.store(.running, .release);

            if (fake) return;

            // Real mode: one bounded synchronous pasteboard call, right
            // here on the loop thread (the platform clipboard is a
            // loop-thread service — the cmd+C seam). The terminal entry
            // still rides the queue so delivery, cancel rewriting, and
            // payload lifetime are uniform with every other effect.
            const services = self.services.?;
            var outcome: EffectClipboardOutcome = .ok;
            var read_len: usize = 0;
            switch (op) {
                .write => services.writeClipboard(slot.fetchPayload()) catch {
                    outcome = .failed;
                },
                .read => {
                    if (services.readClipboard(buffer)) |content| {
                        read_len = content.len;
                    } else |_| {
                        outcome = .failed;
                    }
                },
            }
            slot.body_len = read_len;
            var entry: Entry = .{
                .kind = .clipboard,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = key,
                .line_len = @intCast(read_len),
                .clipboard_op = op,
                .clipboard_outcome = outcome,
                .clipboard_fn = on_result,
            };
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                // A read whose bytes were lost to a full queue reports
                // `.failed`, never a silent empty `.ok`.
                self.releaseFetchSlot(slot);
                self.deliverLoopClipboard(.{
                    .key = key,
                    .op = op,
                    .outcome = if (op == .read and outcome == .ok and read_len > 0) .failed else outcome,
                }, on_result);
            }
            self.wakeHost();
        }

        /// Fire-and-forget named host command: hand `name` + `payload`
        /// to the bound host services and move on — no key, no result,
        /// no Msg. This is the delivery path of a transpiled core's
        /// `host`/`host_bytes` wire records. A channel without bound
        /// host services drops the send (there is no result route to
        /// reject into — the honest degrade, documented rather than
        /// silent-by-accident); session replay never calls the host
        /// (the send's observable consequences replay through whatever
        /// results it caused, which ARE journaled).
        pub fn hostSend(self: *Self, name: []const u8, payload: []const u8) void {
            if (self.replay) return;
            if (name.len == 0 or name.len > max_effect_host_name_bytes) return;
            const binding = self.host_calls orelse return;
            binding.send_fn(binding.context, name, payload);
        }

        /// A keyed, routed host command — the generic named host call
        /// behind a transpiled core's `request` wire records: the host
        /// performs `name` with `payload` and answers with exactly one
        /// `feedHostResult(key, ok, bytes)`, delivered as one
        /// `on_result` Msg (`EffectHostResult`) on the next drain. Key
        /// discipline differs from spawn/fetch/file/clipboard on
        /// purpose (the wire contract): issuing a key whose host
        /// request is still in flight REPLACES it — the old request's
        /// result is dropped, silently — and `cancelHostRequest` drops
        /// one without dispatching anything. Rejection is never silent:
        /// an over-bound name/payload, a key colliding with another
        /// effect kind, a full slot table, or a real-mode channel with
        /// no bound host services delivers exactly one err-route Msg
        /// (`ok = false`, bytes `"rejected"`). Under the fake executor
        /// the request parks in its slot (inspect with `pendingHostAt`,
        /// answer with `feedHostResult`).
        pub fn hostRequest(self: *Self, options: HostRequestOptions) void {
            self.reclaimSlots();
            const fake = self.executor == .fake;
            if (options.name.len == 0 or options.name.len > max_effect_host_name_bytes or
                options.payload.len > max_effect_host_payload_bytes)
            {
                return self.rejectHost(options.key, options.on_result);
            }
            if (!fake and self.host_calls == null) return self.rejectHost(options.key, options.on_result);
            // A staged non-regenerating image terminal holds the key
            // exactly like the slot windows below (see
            // `stagedImageOccupiesKey`): under replay that image
            // request is still parked until its journaled terminal
            // feeds, and the parked fake is what rejects this request
            // there.
            if (self.stagedImageOccupiesKey(options.key)) return self.rejectHost(options.key, options.on_result);
            const slot_index = blk: {
                // In flight = running (no answer yet) OR draining with
                // an undelivered answer: both are replaced, dropping
                // the old result silently (its queued entry dies by
                // generation mismatch at drain). An occupancy of
                // another kind is a key collision and rejects — while
                // running AND through its posted-but-undelivered
                // terminal window (under session replay that request
                // is still a parked `.running` fake until its
                // journaled terminal feeds, so accepting the key here
                // live would diverge); a drained one is fully
                // delivered — its key is free.
                var replaced: ?usize = null;
                for (&self.slots, 0..) |*slot, index| {
                    const state = slot.state.load(.acquire);
                    if (state != .running and state != .draining) continue;
                    if (slot.key != options.key) continue;
                    if (slot.kind != .host) {
                        if (state == .running or slotTerminalUndelivered(slot)) {
                            return self.rejectHost(options.key, options.on_result);
                        }
                        continue;
                    }
                    // Tell the host first: a late answer for the old
                    // occupancy must find nothing.
                    if (state == .running and !slot.fake) self.notifyHostCancel(options.key);
                    self.releaseFetchSlot(slot);
                    slot.generation = 0;
                    replaced = index;
                }
                break :blk replaced orelse
                    (self.findIdleSlot() orelse return self.rejectHost(options.key, options.on_result));
            };

            const slot = &self.slots[slot_index];
            // The buffer holds the payload copy, then the result space.
            const buffer = self.allocator.alloc(u8, options.payload.len + max_effect_host_result_bytes) catch {
                return self.rejectHost(options.key, options.on_result);
            };
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = options.key;
            slot.kind = .host;
            slot.on_line = null;
            slot.on_exit = null;
            slot.on_response = null;
            slot.on_file = null;
            slot.on_clipboard = null;
            slot.on_host = options.on_result;
            slot.cancel_requested.store(false, .release);
            // `cancelled_generation` stays sticky, exactly as in `spawn`.
            slot.dropped_pending = 0;
            slot.dropped_total = 0;
            @memcpy(slot.url_storage[0..options.name.len], options.name);
            slot.url_len = options.name.len;
            if (slot.line_buffer) |old| {
                self.allocator.free(old);
                slot.line_buffer = null;
            }
            if (slot.fetch_buffer) |old| self.allocator.free(old);
            slot.fetch_buffer = buffer;
            @memcpy(buffer[0..options.payload.len], options.payload);
            slot.payload_len = options.payload.len;
            slot.body_len = 0;
            slot.fake = fake;
            slot.state.store(.running, .release);

            // Fake mode (tests and session replay) parks here: the feed
            // is the only terminal source.
            if (fake) return;
            const binding = self.host_calls.?;
            binding.request_fn(binding.context, slot.hostName(), options.key, slot.fetchPayload());
        }

        /// Drop the in-flight host request with `key` without
        /// dispatching either route — the wire contract's `cancel`
        /// record. Silent by design (unlike `cancel`, which delivers a
        /// `.cancelled` terminal): the request's own issuer asked for
        /// the drop, so there is nothing to report. Also drops a result
        /// already completed but not yet drained. Unknown keys (and
        /// keys naming a non-host effect) are a no-op.
        pub fn cancelHostRequest(self: *Self, key: u64) void {
            for (&self.slots) |*slot| {
                const state = slot.state.load(.acquire);
                if (state != .running and state != .draining) continue;
                if (slot.kind != .host or slot.key != key) continue;
                if (state == .running and !slot.fake) self.notifyHostCancel(key);
                self.releaseFetchSlot(slot);
                // A queued result entry (fed, undrained) dies by
                // generation mismatch; zero marks "no occupancy".
                slot.generation = 0;
            }
        }

        /// Tell the bound host services a request key is dead so the
        /// host can abort work; best effort, real executor only.
        fn notifyHostCancel(self: *Self, key: u64) void {
            const binding = self.host_calls orelse return;
            const cancel_fn = binding.cancel_fn orelse return;
            cancel_fn(binding.context, key);
        }

        fn rejectHost(self: *Self, key: u64, host_fn: ?HostMsgFn) void {
            self.deliverLoopHost(.{ .key = key, .ok = false, .bytes = "rejected" }, host_fn, true);
        }

        /// Queue a host terminal produced on the loop thread
        /// (rejections and feed fallbacks) for the next drain. Bytes
        /// here are always static.
        fn deliverLoopHost(self: *Self, result: EffectHostResult, host_fn: ?HostMsgFn, rejected: bool) void {
            if (host_fn == null) return;
            self.deliverPending(.{ .host = .{ .result = result, .host_fn = host_fn, .rejected = rejected } });
        }

        /// Cancel a running effect by key. After this returns, no
        /// further `on_line` Msgs for that spawn are dispatched; one
        /// `on_exit` Msg with reason `.cancelled` follows once the
        /// process is reaped. A cancel that races the natural exit
        /// (worker finished, completions still queued) keeps the same
        /// promise: queued lines are discarded and the queued exit is
        /// reported as `.cancelled`. Unknown keys are a no-op.
        /// Host-request slots keep their own contract instead: a cancel
        /// aimed at one drops it silently (`cancelHostRequest`).
        pub fn cancel(self: *Self, key: u64) void {
            const slot_index = self.findActiveSlot(key) orelse {
                // The worker may have finished with its exit still in
                // the queue: mark the finished generation cancelled so
                // the drain filters its lines and rewrites its exit.
                if (self.findFinishedSlot(key)) |finished_index| {
                    const finished = &self.slots[finished_index];
                    finished.cancelled_generation = finished.generation;
                }
                return;
            };
            const slot = &self.slots[slot_index];
            if (slot.kind == .host) return self.cancelHostRequest(key);
            slot.cancelled_generation = slot.generation;
            slot.cancel_requested.store(true, .release);
            if (slot.fake) {
                // Replay mode: never self-deliver — the recorded session
                // already journaled this effect's terminal (as
                // `.cancelled`, the drain rewrite the marked generation
                // guarantees), and feeding that record is the one
                // delivery. The slot stays parked until the feed.
                if (self.replay) return;
                if (slot.kind == .fetch) {
                    // No exchange: retire the slot and surface the
                    // terminal response now.
                    const response_fn = slot.on_response;
                    const key_copy = slot.key;
                    self.releaseFetchSlot(slot);
                    self.deliverLoopResponse(.{ .key = key_copy, .outcome = .cancelled }, response_fn);
                    return;
                }
                if (slot.kind == .file) {
                    // No IO: retire the slot and surface the terminal
                    // result now.
                    const file_fn = slot.on_file;
                    const op = slot.file_op;
                    const key_copy = slot.key;
                    self.releaseFetchSlot(slot);
                    self.deliverLoopFile(.{ .key = key_copy, .op = op, .outcome = .cancelled }, file_fn);
                    return;
                }
                if (slot.kind == .clipboard) {
                    // No pasteboard call happened: retire the slot and
                    // surface the terminal result now.
                    const clipboard_fn = slot.on_clipboard;
                    const op = slot.clipboard_op;
                    const key_copy = slot.key;
                    self.releaseFetchSlot(slot);
                    self.deliverLoopClipboard(.{ .key = key_copy, .op = op, .outcome = .cancelled }, clipboard_fn);
                    return;
                }
                if (slot.kind == .image) {
                    // No cascade ran: retire the slot and surface the
                    // terminal result now.
                    const image_fn = slot.on_image;
                    const key_copy = slot.key;
                    self.releaseFetchSlot(slot);
                    self.deliverLoopImage(.{ .id = key_copy, .outcome = .cancelled }, image_fn, false);
                    return;
                }
                // No process: retire the slot and surface the exit now.
                const exit_fn = slot.on_exit;
                const exit: EffectExit = .{
                    .key = slot.key,
                    .code = effect_error_exit_code,
                    .reason = .cancelled,
                    .dropped_lines = slot.dropped_total,
                };
                self.releaseSpawnSlot(slot);
                self.deliverLoopExit(exit, exit_fn);
                return;
            }
            // A real fetch is interrupted by its supervising worker,
            // which polls `cancel_requested`; a real file op is quick
            // and simply finishes (the drain rewrites its terminal to
            // `.cancelled`). Neither has a child to kill.
            if (slot.kind == .spawn) self.killPublishedChild(slot);
        }

        /// Start (or replace) a key-based timer on the effects channel:
        /// TEA's way to tick — an auto-refresh, a poll, a debounce —
        /// without reaching for the runtime. Each fire is delivered as
        /// one `on_fire` Msg through the ordinary update path. Key
        /// discipline mirrors `PlatformServices.startTimer`: starting a
        /// key that is already an active timer REPLACES it (interval,
        /// mode, and `on_fire` update; the same platform timer re-arms).
        /// Timer keys are their own namespace and never collide with
        /// spawn/fetch/file keys; timers consume none of the
        /// `max_effects` slots and no worker threads. Never fails from
        /// the caller's view — rejection is never silent: a full timer
        /// table (`max_effect_timers`), a zero `interval_ms`, or a
        /// platform without a timer service delivers exactly one Msg
        /// with outcome `.rejected` on the next drain.
        pub fn startTimer(self: *Self, options: StartTimerOptions) void {
            if (options.interval_ms == 0) return self.rejectTimer(options);
            const fake = self.executor == .fake;
            // Services are bound before init_fx/update ever run; a null
            // here means a host without the platform timer arm.
            if (!fake and self.services == null) return self.rejectTimer(options);
            const index = self.findActiveTimerIndex(options.key) orelse
                (self.findIdleTimerIndex() orelse return self.rejectTimer(options));
            const slot = &self.timer_slots[index];
            slot.key = options.key;
            slot.mode = options.mode;
            slot.interval_ms = options.interval_ms;
            slot.on_fire = options.on_fire;
            slot.fake = fake;
            slot.active = true;
            if (fake) return;
            self.services.?.startTimer(
                effectTimerPlatformId(index),
                options.interval_ms * std.time.ns_per_ms,
                options.mode == .repeating,
            ) catch {
                slot.active = false;
                return self.rejectTimer(options);
            };
        }

        /// Cancel the fx timer with `key`: no further `on_fire` Msgs for
        /// it are dispatched. Unknown keys are a no-op (a one-shot that
        /// already fired counts as unknown).
        pub fn cancelTimer(self: *Self, key: u64) void {
            const index = self.findActiveTimerIndex(key) orelse return;
            const slot = &self.timer_slots[index];
            slot.active = false;
            if (slot.fake) return;
            const services = self.services orelse return;
            services.cancelTimer(effectTimerPlatformId(index)) catch {};
        }

        /// Route a fired platform timer back into an fx-timer Msg: the
        /// on_fire Msg for the slot the reserved `platform_id` maps to,
        /// or null when the id is not an fx timer (or its slot has no
        /// `on_fire`). One-shot slots retire here — platform one-shot
        /// timers self-stop (macOS invalidates its NSTimer, the null
        /// platform deactivates on fire), so no cancel round trip is
        /// needed. Loop-thread only; called by `UiApp.handleTimer`.
        pub fn takeTimerMsg(self: *Self, platform_id: u64, timestamp_ns: u64) ?Msg {
            const index = timerIndexForPlatformId(platform_id) orelse return null;
            const slot = &self.timer_slots[index];
            if (!slot.active) return null;
            const on_fire = slot.on_fire;
            const key = slot.key;
            if (slot.mode == .one_shot) slot.active = false;
            const fire_fn = on_fire orelse return null;
            return fire_fn(.{ .key = key, .timestamp_ns = timestamp_ns, .outcome = .fired });
        }

        /// Load a track into the app's single audio player and start
        /// playing it, replacing whatever played before. Sources resolve
        /// in a fixed, honest order: the LOCAL `path` first; when it is
        /// absent (or the file is missing) the `url` — where the
        /// platform plays a verified cache entry locally, or STREAMS
        /// progressively (audible before the download finishes) while
        /// the bytes fill the cache for next time. TEA all the way down:
        /// every report — the load acknowledgment with the real
        /// duration, coarse position ticks while playing (carrying the
        /// stream's honest `buffering` flag), the one completion at
        /// natural end, failures — arrives as an `on_event` Msg (payload
        /// `EffectAudio`) through the ordinary update path. Never fails
        /// from the caller's view: an oversized string (or path and url
        /// both empty) delivers one `.rejected` event; a platform
        /// without audio playback (a Linux host missing GStreamer at
        /// runtime), an unreadable
        /// file with no url fallback, or a network failure delivers one
        /// `.failed` event — never a crash, never silence. The audio key
        /// is its own namespace (like timer keys) and identifies the
        /// playback in every event; it consumes no `max_effects` slots.
        pub fn playAudio(self: *Self, options: PlayAudioOptions) void {
            const rejected = (options.path.len == 0 and options.url.len == 0) or
                options.path.len > max_effect_audio_path_bytes or
                options.url.len > max_effect_audio_path_bytes or
                options.cache_path.len > max_effect_audio_path_bytes;
            if (rejected) {
                self.deliverLoopAudio(.{ .key = options.key, .kind = .rejected }, options.on_event);
                return;
            }
            const volume = self.audio.volume;
            self.audio = .{
                .active = true,
                .fake = self.executor == .fake,
                .key = options.key,
                .on_event = options.on_event,
                // Optimistic command mirror; the platform's events are
                // the authority from the `.loaded` acknowledgment on.
                .playing = true,
                // The fake executor cannot resolve the cascade, so it
                // records the requested shape: URL-only requests read as
                // streams, anything with a local path as local.
                .source = if (options.path.len == 0) .stream else .local,
                .volume = volume,
                .expected_bytes = options.expected_bytes,
            };
            @memcpy(self.audio.path_buffer[0..options.path.len], options.path);
            self.audio.path_len = options.path.len;
            @memcpy(self.audio.url_buffer[0..options.url.len], options.url);
            self.audio.url_len = options.url.len;
            @memcpy(self.audio.cache_path_buffer[0..options.cache_path.len], options.cache_path);
            self.audio.cache_path_len = options.cache_path.len;
            if (self.audio.fake) return;
            const services = self.services orelse return self.failAudioChannel();
            // The source cascade. A missing local file is the ONE local
            // failure that falls through to the url — everything else
            // (no player, decode failure) is terminal, because retrying
            // a different source would mask the real problem.
            resolve: {
                if (options.path.len > 0) {
                    if (services.audioLoad(options.path)) |_| {
                        self.audio.source = .local;
                        break :resolve;
                    } else |err| {
                        if (err != error.AudioSourceNotFound or options.url.len == 0) {
                            return self.failAudioChannel();
                        }
                    }
                }
                const resolution = services.audioLoadUrl(options.url, options.cache_path, options.expected_bytes) catch
                    return self.failAudioChannel();
                self.audio.source = switch (resolution) {
                    .cache => .cache,
                    .stream => .stream,
                };
                // A fresh stream has no bytes yet: buffering starts true
                // optimistically and the platform's `.loaded`
                // acknowledgment (and every event after) is the
                // authority from there.
                self.audio.buffering = resolution == .stream;
            }
            services.audioPlay() catch return self.failAudioChannel();
            if (volume != 1.0) services.audioSetVolume(volume) catch {};
        }

        /// Pause the current playback in place. Idle channels no-op; no
        /// event echoes — the caller commanded it, so the caller knows.
        pub fn pauseAudio(self: *Self) void {
            if (!self.audio.active) return;
            self.audio.playing = false;
            if (self.audio.fake) return;
            const services = self.services orelse return;
            services.audioPause() catch {};
        }

        /// Resume paused playback. Idle channels no-op; a player the
        /// platform can no longer resume (or a platform without audio)
        /// delivers one `.failed` event instead of silence.
        pub fn resumeAudio(self: *Self) void {
            if (!self.audio.active) return;
            self.audio.playing = true;
            if (self.audio.fake) return;
            const services = self.services orelse return self.failAudioChannel();
            services.audioPlay() catch return self.failAudioChannel();
        }

        /// Stop playback and release the player. No event echoes; the
        /// channel goes idle and later platform stragglers are swallowed.
        pub fn stopAudio(self: *Self) void {
            if (!self.audio.active) return;
            const fake = self.audio.fake;
            const volume = self.audio.volume;
            self.audio = .{ .volume = volume };
            if (fake) return;
            const services = self.services orelse return;
            services.audioStop() catch {};
        }

        /// Jump the current playback to `position_ms` (the platform
        /// clamps to the duration). Idle channels no-op; no event echoes
        /// — the next position tick reports from the new position.
        pub fn seekAudio(self: *Self, position_ms: u64) void {
            if (!self.audio.active) return;
            self.audio.position_ms = if (self.audio.duration_ms > 0)
                @min(position_ms, self.audio.duration_ms)
            else
                position_ms;
            if (self.audio.fake) return;
            const services = self.services orelse return;
            services.audioSeek(position_ms) catch {};
        }

        /// Close a window by its declared label — the REAL OS close,
        /// with the platform's full close semantics (closing the last
        /// window follows the app's existing exit behavior). The seam
        /// behind app-drawn close controls on chromeless windows;
        /// model-declared secondary windows should usually close
        /// DECLARATIVELY instead (stop declaring them in `windows_fn`).
        /// Fire-and-forget: no event echoes, an unknown label is a
        /// no-op, and the fake executor only records the request in the
        /// mirror (`windowActionState`).
        pub fn closeWindow(self: *Self, window_label: []const u8) void {
            self.window_action_state.close_count += 1;
            self.window_action_state.record(window_label);
            if (self.executor == .fake) return;
            const binding = self.window_actions orelse return;
            _ = binding.close_fn(binding.context, window_label);
        }

        /// Minimize a window by its declared label — the REAL OS verb
        /// (macOS genies into the Dock, Windows animates to the
        /// taskbar, GTK minimizes). The seam behind app-drawn minimize
        /// controls on chromeless windows. Fire-and-forget, same
        /// contract as `closeWindow`.
        pub fn minimizeWindow(self: *Self, window_label: []const u8) void {
            self.window_action_state.minimize_count += 1;
            self.window_action_state.record(window_label);
            if (self.executor == .fake) return;
            const binding = self.window_actions orelse return;
            _ = binding.minimize_fn(binding.context, window_label);
        }

        /// Show a window by its declared label: unhide + activate — the
        /// counterpart to a `close_policy = .hide` hide, and the tray
        /// "Open" consequence of the menu-bar-app loop (macOS
        /// deminiaturizes and orders front, Windows SW_RESTORE/SW_SHOW +
        /// foreground, GTK presents). Also brings back a minimized or
        /// merely backgrounded window. Fire-and-forget, same contract
        /// as `closeWindow`: no event echoes beyond the window's own
        /// frame event, an unknown label is a no-op, and the fake
        /// executor only records the request in the mirror.
        pub fn showWindow(self: *Self, window_label: []const u8) void {
            self.window_action_state.show_count += 1;
            self.window_action_state.record(window_label);
            if (self.executor == .fake) return;
            const binding = self.window_actions orelse return;
            _ = binding.show_fn(binding.context, window_label);
        }

        /// Quit the app for real — the graceful terminate, and the tray
        /// "Quit" consequence of the menu-bar-app loop. Rides the same
        /// shutdown event path as today's last-window close (the host
        /// emits `app_shutdown`, `app.stop` runs exactly once, a
        /// recording session seals its journal), so replay sees the
        /// identical journaled event. Like the window verbs it does not
        /// journal itself — the journaled `app_shutdown` it causes is
        /// the record — and under the fake executor only the mirror
        /// count moves.
        pub fn quitApp(self: *Self) void {
            self.window_action_state.quit_count += 1;
            if (self.executor == .fake) return;
            const binding = self.window_actions orelse return;
            _ = binding.quit_fn(binding.context);
        }

        /// The window-action mirror, for tests: how many close/minimize/
        /// show/quit requests rode the channel and the last label
        /// requested.
        pub fn windowActionState(self: *const Self) WindowActionState {
            return self.window_action_state;
        }

        /// Set playback volume, clamped to 0.0—1.0. Remembered across
        /// tracks: the next `playAudio` re-applies it.
        pub fn setAudioVolume(self: *Self, volume: f32) void {
            const clamped = std.math.clamp(volume, 0.0, 1.0);
            self.audio.volume = clamped;
            if (!self.audio.active or self.audio.fake) return;
            const services = self.services orelse return;
            services.audioSetVolume(clamped) catch {};
        }

        /// Route a platform audio event back into an `on_event` Msg for
        /// the active channel, updating the playback mirrors on the way.
        /// Null when the channel is idle (a straggler after `stopAudio`)
        /// or has no handler. Loop-thread only; called by
        /// `UiApp.handleEvent` for `.audio` platform events.
        pub fn takeAudioMsg(self: *Self, platform_event: platform.AudioEvent) ?Msg {
            // Under replay the journaled effect records are the ONLY
            // Msg source (fed through `feedAudioEvent`); the replayed
            // platform `.audio` events would double-deliver.
            if (self.replay) return null;
            const kind: EffectAudioEventKind = switch (platform_event.kind) {
                .loaded => .loaded,
                .position => .position,
                .completed => .completed,
                .failed => .failed,
                .spectrum => .spectrum,
            };
            const audio_fn = self.audio.on_event;
            const event = self.applyAudioEvent(.{
                .key = 0,
                .kind = kind,
                .position_ms = platform_event.position_ms,
                .duration_ms = platform_event.duration_ms,
                .playing = platform_event.playing,
                .buffering = platform_event.buffering,
                .bands = platform_event.bands,
            }) orelse return null;
            const event_fn = audio_fn orelse return null;
            self.journalNote(.{
                .kind = .audio,
                .key = event.key,
                .audio_kind = event.kind,
                .audio_position_ms = event.position_ms,
                .audio_duration_ms = event.duration_ms,
                .audio_playing = event.playing,
                .audio_buffering = event.buffering,
                .audio_bands = event.bands,
            });
            return event_fn(event);
        }

        /// The playback state mirrors, for the automation snapshot.
        pub fn audioSnapshot(self: *const Self) AudioSnapshot {
            return .{
                .active = self.audio.active,
                .key = self.audio.key,
                .playing = self.audio.playing,
                .buffering = self.audio.buffering,
                .source = self.audio.source,
                .position_ms = self.audio.position_ms,
                .duration_ms = self.audio.duration_ms,
                .spectrum_bands = self.audio.spectrum_bands,
                .spectrum_events = self.audio.spectrum_events,
            };
        }

        /// Fake executor: the recorded playback request on the single
        /// audio channel, or null when nothing was asked to play.
        pub fn pendingAudio(self: *const Self) ?AudioRequest {
            if (!self.audio.active) return null;
            return .{
                .key = self.audio.key,
                .path = self.audio.path(),
                .url = self.audio.url(),
                .cache_path = self.audio.cachePath(),
                .expected_bytes = self.audio.expected_bytes,
                .playing = self.audio.playing,
                .position_ms = self.audio.position_ms,
                .volume = self.audio.volume,
            };
        }

        /// Fake executor / replay: feed one audio event as the platform
        /// would deliver it. The event resolves against the live channel
        /// at drain time (key and handler from the channel, mirrors
        /// updated), mirroring `takeAudioMsg` exactly. Fails when no
        /// playback is active to receive it.
        pub fn feedAudioEvent(self: *Self, kind: EffectAudioEventKind, position_ms: u64, duration_ms: u64, playing: bool) !void {
            return self.feedAudioEventBuffering(kind, position_ms, duration_ms, playing, false);
        }

        /// `feedAudioEvent` with the stream-stall flag — the shape the
        /// replayer feeds (journal records carry buffering) and stream
        /// suites use; the plain feed keeps local-file tests terse.
        pub fn feedAudioEventBuffering(self: *Self, kind: EffectAudioEventKind, position_ms: u64, duration_ms: u64, playing: bool, buffering: bool) !void {
            if (!self.audio.active) return error.EffectNotFound;
            self.deliverPending(.{ .audio = .{
                .event = .{
                    .key = self.audio.key,
                    .kind = kind,
                    .position_ms = position_ms,
                    .duration_ms = duration_ms,
                    .playing = playing,
                    .buffering = buffering,
                },
                .audio_fn = null,
                .resolve = true,
            } });
        }

        /// Fake executor / replay: feed one `.spectrum` band report as
        /// the platform would deliver it — the band bytes ride the same
        /// resolve-at-drain path as every other fed audio event, so the
        /// journal and the channel mirrors see exactly what a live
        /// analysis tap produces.
        pub fn feedAudioSpectrum(self: *Self, bands: [platform.audio_spectrum_band_count]u8, position_ms: u64, duration_ms: u64) !void {
            if (!self.audio.active) return error.EffectNotFound;
            self.deliverPending(.{ .audio = .{
                .event = .{
                    .key = self.audio.key,
                    .kind = .spectrum,
                    .position_ms = position_ms,
                    .duration_ms = duration_ms,
                    .playing = true,
                    .bands = bands,
                },
                .audio_fn = null,
                .resolve = true,
            } });
        }

        /// Number of effects currently in flight (running slots).
        pub fn activeCount(self: *Self) usize {
            self.reclaimSlots();
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// True when a drain would dispatch at least one Msg.
        pub fn hasPending(self: *const Self) bool {
            return self.pending_exit_len > 0 or
                self.pending_image_len > 0 or
                self.queue_count.load(.acquire) > 0;
        }

        /// One drain pass's causal boundary: a snapshot of the
        /// completions that existed when the pass began. The session
        /// journal's ordering invariant — effect-result records precede
        /// the event record during whose dispatch they were drained, so
        /// replaying records in file order feeds each result before the
        /// event that consumes it — only holds if every result delivered
        /// during an event's dispatch answers a request that existed
        /// BEFORE that dispatch. A completion produced during the pass
        /// itself (an update handler starts a load fast enough to finish
        /// while the drain is still running) must therefore wait for the
        /// next wake: delivering it in the same pass would journal a
        /// result ahead of the event whose dispatch created its request,
        /// and replay's file-order feed would find no parked request to
        /// answer. Both producer paths (`enqueue` workers, the loop-side
        /// pending stages) nudge `wakeHost`, so a deferred completion
        /// always has its follow-up wake already scheduled.
        pub const DrainBoundary = struct {
            /// Loop-side pending entries staged before the pass: stamps
            /// below this deliver (both pending structures share the
            /// monotonic `pending_seq` stamp).
            pending_before: u64,
            /// Worker-queue entries enqueued before the pass. The queue
            /// is FIFO, so consuming exactly this many dequeues consumes
            /// exactly the pre-existing entries.
            queue_budget: usize,
        };

        /// Snapshot the completion backlog at the start of one drain
        /// pass. Loop-thread only, like the drain itself.
        pub fn drainBoundary(self: *Self) DrainBoundary {
            return .{
                .pending_before = self.pending_seq,
                .queue_budget = self.queue_count.load(.acquire),
            };
        }

        /// Pop the next completion as a Msg. Loop-thread only. The
        /// returned Msg's line payload stays valid until the next call.
        /// Unbounded: delivers completions produced while the caller
        /// drains, too. Runtime drain passes (`UiApp.drainEffects`, the
        /// ts-core host's `drain`) use `takeMsgWithin` instead so the
        /// journal's event boundaries stay causal (see `DrainBoundary`);
        /// this form serves callers that own their delivery timing —
        /// tests driving the channel directly.
        pub fn takeMsg(self: *Self) ?Msg {
            var unbounded: DrainBoundary = .{
                .pending_before = std.math.maxInt(u64),
                .queue_budget = std.math.maxInt(usize),
            };
            return self.takeMsgWithin(&unbounded);
        }

        /// `takeMsg` bounded to one drain pass: only completions inside
        /// `boundary` deliver; anything produced after the snapshot
        /// waits for the wake its producer already nudged.
        pub fn takeMsgWithin(self: *Self, boundary: *DrainBoundary) ?Msg {
            self.reclaimSlots();
            while (true) {
                if (self.takePendingMsg(boundary.pending_before)) |pending| {
                    switch (pending) {
                        .exit => |entry| {
                            const exit_fn = entry.exit_fn orelse continue;
                            self.journalNote(.{
                                .kind = .exit,
                                .key = entry.exit.key,
                                .payload = entry.exit.output,
                                .stderr_tail = entry.exit.stderr_tail,
                                .dropped = entry.exit.dropped_lines,
                                .code = entry.exit.code,
                                .exit_reason = entry.exit.reason,
                                .output_truncated = entry.exit.output_truncated,
                                .stderr_truncated = entry.exit.stderr_truncated,
                            });
                            return exit_fn(entry.exit);
                        },
                        .response => |entry| {
                            const response_fn = entry.response_fn orelse continue;
                            self.journalNote(.{
                                .kind = .response,
                                .key = entry.response.key,
                                .payload = entry.response.body,
                                .truncated = entry.response.truncated,
                                .dropped = entry.response.dropped_before,
                                .status = entry.response.status,
                                .fetch_outcome = entry.response.outcome,
                            });
                            return response_fn(entry.response);
                        },
                        .file => |entry| {
                            const file_fn = entry.file_fn orelse continue;
                            self.journalNote(.{
                                .kind = .file,
                                .key = entry.result.key,
                                .payload = entry.result.bytes,
                                .dropped = entry.result.dropped_before,
                                .file_op = entry.result.op,
                                .file_outcome = entry.result.outcome,
                            });
                            return file_fn(entry.result);
                        },
                        .clipboard => |entry| {
                            const clipboard_fn = entry.clipboard_fn orelse continue;
                            self.journalNote(.{
                                .kind = .clipboard,
                                .key = entry.result.key,
                                .payload = entry.result.text,
                                .dropped = entry.result.dropped_before,
                                .clipboard_op = entry.result.op,
                                .clipboard_outcome = entry.result.outcome,
                            });
                            return clipboard_fn(entry.result);
                        },
                        .timer => |entry| {
                            const timer_fn = entry.timer_fn orelse continue;
                            self.journalNote(.{
                                .kind = .timer,
                                .key = entry.timer.key,
                                .timer_timestamp_ns = entry.timer.timestamp_ns,
                                .timer_outcome = entry.timer.outcome,
                            });
                            return timer_fn(entry.timer);
                        },
                        .host => |entry| {
                            const host_fn = entry.host_fn orelse continue;
                            self.journalNote(.{
                                .kind = .host,
                                .key = entry.result.key,
                                .payload = entry.result.bytes,
                                // `.host` journal encoding (no new record
                                // fields): the route rides `code`, and
                                // rejections are marked regenerable.
                                .code = @intFromBool(!entry.result.ok),
                                .exit_reason = if (entry.rejected) .rejected else .exited,
                            });
                            return host_fn(entry.result);
                        },
                        .audio => |entry| {
                            var event = entry.event;
                            var audio_fn = entry.audio_fn;
                            if (entry.resolve) {
                                // Fed events resolve against the live
                                // channel exactly like a platform event:
                                // mirrors update, key and handler come
                                // from the channel, a stopped channel
                                // swallows the event. Capture the handler
                                // first — a `.failed` apply resets it.
                                audio_fn = self.audio.on_event;
                                event = self.applyAudioEvent(event) orelse continue;
                            }
                            const event_fn = audio_fn orelse continue;
                            self.journalNote(.{
                                .kind = .audio,
                                .key = event.key,
                                .audio_kind = event.kind,
                                .audio_position_ms = event.position_ms,
                                .audio_duration_ms = event.duration_ms,
                                .audio_playing = event.playing,
                                .audio_buffering = event.buffering,
                                .audio_bands = event.bands,
                            });
                            return event_fn(event);
                        },
                        .image => |entry| {
                            const image_fn = entry.image_fn orelse continue;
                            self.journalNote(.{
                                .kind = .image,
                                .key = entry.result.id,
                                .status = entry.result.status,
                                .image_outcome = entry.result.outcome,
                                .image_width = entry.result.width,
                                .image_height = entry.result.height,
                                // `.image` journal encoding, the `.host`
                                // records' convention: ONLY loop-side
                                // validation refusals — regenerated by
                                // the same checks under replay — mark
                                // themselves with the exit reason. Every
                                // other terminal (including worker-side
                                // `.rejected`, which rides the slot
                                // queue, not this ring) keeps `.exited`
                                // and is fed from the journal.
                                .exit_reason = if (entry.regenerates) .rejected else .exited,
                            });
                            return image_fn(entry.result);
                        },
                    }
                }
                if (boundary.queue_budget == 0) return null;
                if (!self.dequeueInto(&self.drain_scratch)) return null;
                boundary.queue_budget -= 1;
                const entry = &self.drain_scratch;
                const slot = &self.slots[entry.slot_index];
                const cancelled = slot.cancelled_generation == entry.generation and entry.generation != 0;
                switch (entry.kind) {
                    .line => {
                        // Oversized lines (raised `max_line_bytes`) own a
                        // heap payload: take it before any early-out so
                        // skipped entries still free (retired when the
                        // next line drains, like `drain_fetch_body`).
                        if (self.drain_heap_line) |old| {
                            self.allocator.free(old);
                            self.drain_heap_line = null;
                        }
                        if (entry.heap_line) |heap| {
                            self.drain_heap_line = heap;
                            entry.heap_line = null;
                        }
                        if (cancelled) continue;
                        const line_fn = entry.line_fn orelse continue;
                        const line_bytes: []const u8 = if (self.drain_heap_line) |heap|
                            heap[0..entry.line_len]
                        else
                            entry.line_bytes[0..entry.line_len];
                        const line: EffectLine = .{
                            .key = entry.key,
                            .line = line_bytes,
                            .truncated = entry.truncated,
                            .dropped_before = entry.dropped_before,
                        };
                        self.journalNote(.{
                            .kind = .line,
                            .key = line.key,
                            .payload = line.line,
                            .truncated = line.truncated,
                            .dropped = line.dropped_before,
                        });
                        return line_fn(line);
                    },
                    .exit => {
                        // Dequeueing the occupant's exit IS its delivery
                        // for key occupancy: clear the `.lines` marker
                        // before any early-out (absent handler, cancel
                        // rewrite) so the key frees exactly when the
                        // terminal reaches — or would have reached —
                        // update, and a handler that respawns its own
                        // key parks as a fresh effect.
                        if (entry.generation == slot.generation) slot.exit_undelivered = false;
                        // Collect exits own a heap stdout buffer: take it
                        // before any early-out so the slot retires even
                        // when the handler is absent. A mismatched
                        // generation means the occupant was already
                        // retired (and its buffer freed on slot reuse).
                        var output: []const u8 = "";
                        if (entry.collect and entry.generation == slot.generation) {
                            if (self.drain_collect_output) |old| self.allocator.free(old);
                            self.drain_collect_output = slot.collect_buffer;
                            slot.collect_buffer = null;
                            if (!cancelled) {
                                if (self.drain_collect_output) |buffer| output = buffer[0..entry.collect_len];
                            }
                        }
                        const exit_fn = entry.exit_fn orelse continue;
                        const exit: EffectExit = if (cancelled)
                            // Cancelled exits mirror cancelled fetches:
                            // no payload, just the terminal notice.
                            .{
                                .key = entry.key,
                                .code = effect_error_exit_code,
                                .reason = .cancelled,
                                .dropped_lines = entry.dropped_lines,
                            }
                        else
                            .{
                                .key = entry.key,
                                .code = entry.code,
                                .reason = entry.reason,
                                .dropped_lines = entry.dropped_lines,
                                .output = output,
                                .output_truncated = entry.collect_truncated,
                                .stderr_tail = if (entry.collect) entry.line_bytes[0..entry.line_len] else "",
                                .stderr_truncated = entry.stderr_truncated,
                            };
                        self.journalNote(.{
                            .kind = .exit,
                            .key = exit.key,
                            .payload = exit.output,
                            .stderr_tail = exit.stderr_tail,
                            .dropped = exit.dropped_lines,
                            .code = exit.code,
                            .exit_reason = exit.reason,
                            .output_truncated = exit.output_truncated,
                            .stderr_truncated = exit.stderr_truncated,
                        });
                        return exit_fn(exit);
                    },
                    .response => {
                        // One response per fetch occupancy: a mismatched
                        // generation means the occupant was already
                        // retired with its own terminal Msg.
                        if (entry.generation != slot.generation) continue;
                        // Take body ownership so the slot can be reused
                        // while `update` still reads the slice; the
                        // buffer is freed when the next response drains.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        const payload_len = slot.payload_len;
                        const response_fn = entry.response_fn orelse continue;
                        const body: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[payload_len .. payload_len + entry.line_len]
                        else
                            "";
                        const response: EffectResponse = if (cancelled)
                            .{ .key = entry.key, .outcome = .cancelled }
                        else
                            .{
                                .key = entry.key,
                                .outcome = entry.outcome,
                                .status = entry.status,
                                .body = body,
                                .truncated = entry.truncated,
                                .dropped_before = entry.dropped_before,
                            };
                        self.journalNote(.{
                            .kind = .response,
                            .key = response.key,
                            .payload = response.body,
                            .truncated = response.truncated,
                            .dropped = response.dropped_before,
                            .status = response.status,
                            .fetch_outcome = response.outcome,
                        });
                        return response_fn(response);
                    },
                    .file => {
                        // One terminal per file occupancy, mirroring
                        // `.response`: a mismatched generation means the
                        // occupant was already retired.
                        if (entry.generation != slot.generation) continue;
                        // Take buffer ownership so the slot can be
                        // reused while `update` still reads the bytes.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        const payload_len = slot.payload_len;
                        const file_fn = entry.file_fn orelse continue;
                        const bytes: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[payload_len .. payload_len + entry.line_len]
                        else
                            "";
                        const result: EffectFileResult = if (cancelled)
                            .{ .key = entry.key, .op = entry.file_op, .outcome = .cancelled }
                        else
                            .{
                                .key = entry.key,
                                .op = entry.file_op,
                                .outcome = entry.file_outcome,
                                .bytes = bytes,
                                .dropped_before = entry.dropped_before,
                            };
                        self.journalNote(.{
                            .kind = .file,
                            .key = result.key,
                            .payload = result.bytes,
                            .dropped = result.dropped_before,
                            .file_op = result.op,
                            .file_outcome = result.outcome,
                        });
                        return file_fn(result);
                    },
                    .clipboard => {
                        // One terminal per clipboard occupancy, mirroring
                        // `.file`: a mismatched generation means the
                        // occupant was already retired.
                        if (entry.generation != slot.generation) continue;
                        // Take buffer ownership so the slot can be
                        // reused while `update` still reads the text.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        const payload_len = slot.payload_len;
                        const clipboard_fn = entry.clipboard_fn orelse continue;
                        const text: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[payload_len .. payload_len + entry.line_len]
                        else
                            "";
                        const result: EffectClipboardResult = if (cancelled)
                            .{ .key = entry.key, .op = entry.clipboard_op, .outcome = .cancelled }
                        else
                            .{
                                .key = entry.key,
                                .op = entry.clipboard_op,
                                .outcome = entry.clipboard_outcome,
                                .text = text,
                                .dropped_before = entry.dropped_before,
                            };
                        self.journalNote(.{
                            .kind = .clipboard,
                            .key = result.key,
                            .payload = result.text,
                            .dropped = result.dropped_before,
                            .clipboard_op = result.op,
                            .clipboard_outcome = result.outcome,
                        });
                        return clipboard_fn(result);
                    },
                    .host => {
                        // One terminal per host occupancy, mirroring
                        // `.response`: a mismatched generation means the
                        // occupant was already retired (replaced or
                        // cancelled — its result drops silently, per the
                        // request contract).
                        if (entry.generation != slot.generation) continue;
                        // Take buffer ownership so the slot can be
                        // reused while `update` still reads the bytes.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        const payload_len = slot.payload_len;
                        // A cancel that raced the feed (the entry was
                        // already queued) still drops silently.
                        if (cancelled) continue;
                        const host_fn = entry.host_fn orelse continue;
                        const bytes: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[payload_len .. payload_len + entry.line_len]
                        else
                            "";
                        const result: EffectHostResult = .{
                            .key = entry.key,
                            .ok = entry.host_ok,
                            .bytes = bytes,
                        };
                        self.journalNote(.{
                            .kind = .host,
                            .key = result.key,
                            .payload = result.bytes,
                            // `.host` journal encoding: route in `code`.
                            .code = @intFromBool(!result.ok),
                        });
                        return host_fn(result);
                    },
                    .image => {
                        // One terminal per image occupancy, mirroring
                        // `.response`: a mismatched generation means the
                        // occupant was already retired.
                        if (entry.generation != slot.generation) continue;
                        // Take buffer ownership so the slot can be
                        // reused while `update` (and the journal sink)
                        // still read the bytes.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        // Retire the slot BEFORE the terminal reaches any
                        // handler. The real worker stores `.draining`
                        // only AFTER posting this entry, so a drain can
                        // race ahead of that store and dispatch the
                        // result while the slot still reads `.running` —
                        // and an update that reacts to the terminal by
                        // loading the same id again (reload-after-
                        // terminal is allowed) would reject as a
                        // duplicate active key. Storing here makes the
                        // slot reclaimable by the time any update code
                        // runs; the worker's own store stays as the
                        // pre-drain transition (cancel targeting and
                        // early thread reclaim still key off it), and
                        // re-storing `.draining` is idempotent.
                        slot.state.store(.draining, .release);
                        const image_fn = entry.image_fn;
                        const bytes: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[0..entry.line_len]
                        else
                            "";
                        var result: EffectImageResult = .{
                            .id = entry.key,
                            .outcome = entry.image_outcome,
                            .status = entry.status,
                        };
                        // The journal carries the source bytes whenever
                        // the cascade delivered them — even when the
                        // decode below fails, the bytes ARE the effect
                        // result the boundary produced. RECORD-TIME
                        // INVARIANT: a journaled `.loaded` always
                        // carries non-empty bytes, because `.loaded`
                        // reaches the journal only after
                        // `register_bytes_fn` decoded and registered
                        // these exact bytes (a failure rewrites the
                        // outcome below, and empty bytes cannot decode).
                        // Session replay refuses `.loaded` records with
                        // a zero-length blob on this invariant
                        // (`error.ReplayDamagedRecord`).
                        var journal_bytes: []const u8 = "";
                        if (entry.image_fed) {
                            // Session replay: the recorded terminal is
                            // the Msg, verbatim — checked BEFORE the
                            // cancelled rewrite. A live cancel that won
                            // journaled `.cancelled` and feeds back as
                            // such; a live cancel that LOST (a staged
                            // start-failure rejection has no slot to
                            // mark, so live delivered `.rejected`) must
                            // not be resurrected by the replayed
                            // cancel's mark on the parked fake slot,
                            // whose timing differs from the live seam.
                            // Re-registration is
                            // best-effort presentation — a replay host
                            // whose codec cannot decode the recorded
                            // bytes (the null platform decodes only the
                            // strict PNG subset) still replays the
                            // identical Msg stream; views just render
                            // without the pixels, and pixel checkpoints
                            // report the honest difference.
                            journal_bytes = bytes;
                            result.width = std.math.cast(usize, entry.image_fed_width) orelse 0;
                            result.height = std.math.cast(usize, entry.image_fed_height) orelse 0;
                            if (result.outcome == .loaded and bytes.len > 0) {
                                self.registerDrainedImage(entry.key, bytes);
                            }
                        } else if (cancelled) {
                            result = .{ .id = entry.key, .outcome = .cancelled };
                        } else if (result.outcome == .loaded) {
                            journal_bytes = bytes;
                            if (self.images) |binding| {
                                if (binding.register_bytes_fn(binding.context, entry.key, bytes)) |info| {
                                    result.width = info.width;
                                    result.height = info.height;
                                } else |err| {
                                    result.outcome = classifyImageRegisterError(err);
                                }
                            } else {
                                // No registry bound to this channel:
                                // nothing can hold the pixels — the
                                // same class as a host without a codec.
                                result.outcome = .unsupported;
                            }
                        }
                        self.journalNote(.{
                            .kind = .image,
                            .key = result.id,
                            .payload = journal_bytes,
                            .status = result.status,
                            .image_outcome = result.outcome,
                            .image_width = result.width,
                            .image_height = result.height,
                        });
                        const deliver_fn = image_fn orelse continue;
                        return deliver_fn(result);
                    },
                }
            }
        }

        /// Best-effort decode + register of a replayed image record's
        /// bytes. Failure is loud (once per process would hide repeats;
        /// once per failure is a bounded replay-time diagnostic) but
        /// never steers the Msg stream — the journaled terminal does.
        fn registerDrainedImage(self: *Self, id: u64, bytes: []const u8) void {
            const binding = self.images orelse return;
            _ = binding.register_bytes_fn(binding.context, id, bytes) catch |err| {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "session replay: re-registering image id {d} from the journaled bytes failed ({s}); the Msg stream replays the recorded result, views render without the pixels\n",
                        .{ id, @errorName(err) },
                    );
                }
                return;
            };
        }

        // --------------------------------------------------- fake executor

        /// Number of recorded (still-active) fake spawn requests.
        pub fn pendingSpawnCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.kind == .spawn and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake spawn request (slot order).
        pub fn pendingSpawnAt(self: *Self, index: usize) ?SpawnRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.kind == .spawn and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .argv = slot.argv(),
                        .stdin = slot.stdinBytes(),
                        .output = slot.output_mode,
                        .max_line_bytes = slot.line_limit,
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Number of recorded (still-active) fake fetch requests.
        pub fn pendingFetchCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.kind == .fetch and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake fetch request (slot order).
        pub fn pendingFetchAt(self: *Self, index: usize) ?FetchRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.kind == .fetch and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .method = slot.method,
                        .url = slot.fetchUrl(),
                        .headers = slot.fetchHeaders(),
                        .body = slot.fetchPayload(),
                        .response = slot.fetch_response_mode,
                        .max_line_bytes = slot.line_limit,
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Feed one synthetic stdout line to the fake effect with `key`.
        /// Mirrors the real executor per output mode: a `.lines` spawn
        /// (or `.stream` fetch) queues one `on_line` Msg (a full queue
        /// counts a drop instead of delivering); a `.collect` spawn
        /// accumulates the bytes plus their newline into the collected
        /// output (truncating over the collect bound with the flag set,
        /// exactly like a real child that printed that line).
        pub fn feedLine(self: *Self, key: u64, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .spawn) orelse blk: {
                const fetch_index = self.findActiveFakeSlot(key, .fetch) orelse return error.EffectNotFound;
                if (self.slots[fetch_index].fetch_response_mode != .stream) return error.EffectNotFound;
                break :blk fetch_index;
            };
            const slot = &self.slots[slot_index];
            if (slot.kind == .spawn and slot.output_mode == .collect) {
                appendCollected(slot, bytes);
                appendCollected(slot, "\n");
                return;
            }
            self.produceLine(slot, @intCast(slot_index), slot.generation, bytes, false);
        }

        /// Feed synthetic stderr bytes to the fake `.collect` effect with
        /// `key`. Mirrors the real tail: only the last
        /// `max_effect_stderr_tail_bytes` are kept and earlier bytes are
        /// flagged through `stderr_truncated`. `.lines` spawns ignore
        /// stderr, so feeding one reports EffectNotFound.
        pub fn feedStderr(self: *Self, key: u64, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .spawn) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            if (slot.output_mode != .collect) return error.EffectNotFound;
            appendStderrTail(slot, bytes);
        }

        /// Feed the synthetic exit for the fake effect with `key`,
        /// retiring its slot. A `.collect` exit carries the accumulated
        /// output and stderr tail, exactly like a real collect exit; if
        /// the completion queue is somehow full, the terminal still lands
        /// through the pending ring — with empty payloads and the
        /// truncation flags set, never silently.
        pub fn feedExit(self: *Self, key: u64, code: i32) error{EffectNotFound}!void {
            return self.feedExitReason(key, code, .exited);
        }

        /// `feedExit` with an explicit exit reason — the session-replay
        /// feed, which must deliver exactly the reason the recorded
        /// session delivered (`.signaled`, `.cancelled`, ...).
        pub fn feedExitReason(self: *Self, key: u64, code: i32, reason: EffectExitReason) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .spawn) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            var entry: Entry = .{
                .kind = .exit,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .code = code,
                .reason = reason,
                .dropped_lines = slot.dropped_total,
                .exit_fn = slot.on_exit,
            };
            const exit_fn = slot.on_exit;
            if (slot.output_mode == .collect) {
                stampCollectExit(slot, &entry);
                slot.state.store(.draining, .release);
                if (!self.enqueue(&entry)) {
                    self.releaseSpawnSlot(slot);
                    self.deliverLoopExit(.{
                        .key = entry.key,
                        .code = code,
                        .reason = reason,
                        .dropped_lines = entry.dropped_lines,
                        .output_truncated = true,
                        .stderr_truncated = true,
                    }, exit_fn);
                }
                self.wakeHost();
                return;
            }
            const delivered = self.enqueue(&entry);
            if (delivered) {
                // Park until the drain takes the exit: the key stays
                // occupied through the posted-but-undelivered window,
                // exactly like the real worker's commit.
                slot.exit_undelivered = true;
                slot.state.store(.draining, .release);
            } else {
                slot.state.store(.idle, .release);
                self.deliverLoopExit(.{
                    .key = entry.key,
                    .code = code,
                    .reason = reason,
                    .dropped_lines = entry.dropped_lines,
                }, exit_fn);
            }
            self.wakeHost();
        }

        /// Feed the synthetic response for the fake fetch with `key`,
        /// retiring its slot. Mirrors real truncation: bodies over
        /// `max_effect_body_bytes` are cut with `truncated = true`. A
        /// `.stream` fetch's terminal carries no body (feed its lines
        /// through `feedLine` first); any body bytes passed here are
        /// ignored, exactly like the real stream terminal. If the
        /// completion queue is somehow full, the terminal still lands
        /// through the pending ring — with an empty body and
        /// `truncated = true`, never silently.
        pub fn feedResponse(self: *Self, key: u64, status: u16, body: []const u8) error{EffectNotFound}!void {
            return self.feedResponseOutcome(key, .ok, status, body);
        }

        /// `feedResponse` with an explicit terminal outcome — the
        /// session-replay feed, which must deliver exactly the outcome
        /// the recorded session delivered (`.timed_out`,
        /// `.connect_failed`, ...). Non-`.ok` outcomes carry no body,
        /// mirroring the real executor.
        pub fn feedResponseOutcome(self: *Self, key: u64, outcome: EffectFetchOutcome, status: u16, body: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .fetch) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            if (slot.fetch_response_mode == .stream or outcome != .ok) {
                slot.body_len = 0;
                slot.fetch_truncated = false;
            } else {
                const capacity = buffer.len - slot.payload_len;
                const len = @min(body.len, capacity);
                @memcpy(buffer[slot.payload_len..][0..len], body[0..len]);
                slot.body_len = len;
                slot.fetch_truncated = body.len > capacity;
            }
            slot.fetch_status = status;
            slot.fetch_outcome = outcome;
            var entry: Entry = .{
                .kind = .response,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(slot.body_len),
                .truncated = slot.fetch_truncated,
                .dropped_before = slot.dropped_pending,
                .status = status,
                .outcome = outcome,
                .response_fn = slot.on_response,
            };
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                const response_fn = slot.on_response;
                self.releaseFetchSlot(slot);
                self.deliverLoopResponse(.{
                    .key = entry.key,
                    .outcome = outcome,
                    .status = status,
                    .truncated = true,
                }, response_fn);
            }
            self.wakeHost();
        }

        /// Append raw bytes to a fake `.collect` spawn's accumulated
        /// stdout WITHOUT line framing — the session-replay feed for a
        /// recorded collect exit's whole `output` payload (whose
        /// original line structure is already baked into the bytes).
        pub fn feedOutput(self: *Self, key: u64, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .spawn) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            if (slot.output_mode != .collect) return error.EffectNotFound;
            appendCollected(slot, bytes);
        }

        /// Number of recorded (still-active) fake file requests.
        pub fn pendingFileCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.kind == .file and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake file request (slot order).
        pub fn pendingFileAt(self: *Self, index: usize) ?FileRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.kind == .file and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .op = slot.file_op,
                        .path = slot.filePath(),
                        .bytes = if (slot.file_op == .write) slot.fetchPayload() else "",
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Feed the synthetic terminal for the fake file effect with
        /// `key`, retiring its slot. `bytes` is a read's content,
        /// delivered with outcome `.ok` or `.truncated` (over-bound
        /// content is cut at `max_effect_file_bytes` and the outcome
        /// rewritten to `.truncated`, mirroring the real reader);
        /// `bytes` is ignored for writes and for failure outcomes. If
        /// the completion queue is somehow full, the terminal still
        /// lands through the pending ring — a read whose bytes were
        /// lost that way reports `.truncated`, never silently.
        pub fn feedFileResult(self: *Self, key: u64, outcome: EffectFileOutcome, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .file) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            var delivered_len: usize = 0;
            var delivered_outcome = outcome;
            if (slot.file_op == .read and (outcome == .ok or outcome == .truncated)) {
                const capacity = @min(buffer.len, max_effect_file_bytes);
                delivered_len = @min(bytes.len, capacity);
                @memcpy(buffer[0..delivered_len], bytes[0..delivered_len]);
                if (bytes.len > capacity) delivered_outcome = .truncated;
            }
            slot.body_len = delivered_len;
            var entry: Entry = .{
                .kind = .file,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(delivered_len),
                .file_op = slot.file_op,
                .file_outcome = delivered_outcome,
                .file_fn = slot.on_file,
            };
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                const file_fn = slot.on_file;
                const op = slot.file_op;
                self.releaseFetchSlot(slot);
                self.deliverLoopFile(.{
                    .key = entry.key,
                    .op = op,
                    .outcome = if (op == .read and delivered_len > 0) .truncated else delivered_outcome,
                }, file_fn);
            }
            self.wakeHost();
        }

        /// Number of recorded (still-active) fake clipboard requests.
        pub fn pendingClipboardCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.kind == .clipboard and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake clipboard request (slot order).
        pub fn pendingClipboardAt(self: *Self, index: usize) ?ClipboardRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.kind == .clipboard and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .op = slot.clipboard_op,
                        .text = if (slot.clipboard_op == .write) slot.fetchPayload() else "",
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Feed the synthetic terminal for the fake clipboard effect
        /// with `key`, retiring its slot. `text` is a read's clipboard
        /// content, delivered with outcome `.ok`; content over
        /// `max_effect_clipboard_bytes` rewrites the outcome to
        /// `.failed` with empty text, mirroring the real reader (which
        /// fails whole rather than cutting — a cut clipboard string
        /// must never pass for the clipboard). `text` is ignored for
        /// writes and for failure outcomes. If the completion queue is
        /// somehow full, the terminal still lands through the pending
        /// ring — a read whose bytes were lost that way reports
        /// `.failed`, never silently.
        pub fn feedClipboardResult(self: *Self, key: u64, outcome: EffectClipboardOutcome, text: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .clipboard) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            var delivered_len: usize = 0;
            var delivered_outcome = outcome;
            if (slot.clipboard_op == .read and outcome == .ok) {
                const capacity = @min(buffer.len, max_effect_clipboard_bytes);
                if (text.len > capacity) {
                    delivered_outcome = .failed;
                } else {
                    delivered_len = text.len;
                    @memcpy(buffer[0..delivered_len], text[0..delivered_len]);
                }
            }
            slot.body_len = delivered_len;
            var entry: Entry = .{
                .kind = .clipboard,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(delivered_len),
                .clipboard_op = slot.clipboard_op,
                .clipboard_outcome = delivered_outcome,
                .clipboard_fn = slot.on_clipboard,
            };
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                const clipboard_fn = slot.on_clipboard;
                const op = slot.clipboard_op;
                self.releaseFetchSlot(slot);
                self.deliverLoopClipboard(.{
                    .key = entry.key,
                    .op = op,
                    .outcome = if (op == .read and delivered_len > 0) .failed else delivered_outcome,
                }, clipboard_fn);
            }
            self.wakeHost();
        }

        /// Number of recorded (still-active) fake image-load requests.
        pub fn pendingImageLoadCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.kind == .image and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake image-load request (slot order).
        pub fn pendingImageLoadAt(self: *Self, index: usize) ?ImageLoadRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.kind == .image and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{
                        .id = slot.key,
                        .path = slot.imagePath(),
                        .url = slot.fetchUrl(),
                        .cache_path = slot.imageCache(),
                        .expected_bytes = slot.image_expected_bytes,
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Feed synthetic ENCODED source bytes to the fake image load
        /// with `id`, retiring its slot — the test mirror of a real
        /// cascade that produced bytes: the drain decodes and registers
        /// them through the bound registry exactly like the real
        /// executor, so tests exercise the full decode→register→Msg
        /// path. Bytes over `max_effect_image_bytes` deliver `.too_large`
        /// without decoding, mirroring the real bound.
        pub fn feedImageBytes(self: *Self, id: u64, bytes: []const u8) error{ EffectNotFound, EffectQueueFull }!void {
            const slot_index = self.findActiveFakeSlot(id, .image) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            var staged_len: usize = 0;
            var outcome: EffectImageOutcome = .loaded;
            if (bytes.len > max_effect_image_bytes) {
                outcome = .too_large;
            } else {
                @memcpy(buffer[0..bytes.len], bytes);
                staged_len = bytes.len;
            }
            slot.body_len = staged_len;
            try self.finishFedImage(slot, .{
                .kind = .image,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(staged_len),
                .status = slot.fetch_status,
                .image_outcome = outcome,
                .image_fn = slot.on_image,
            });
        }

        /// Feed a RECORDED image terminal — the session-replay feed:
        /// the journaled outcome, dimensions, and status deliver
        /// verbatim (the Msg stream must replay byte-identical even on
        /// a host whose codec differs), and a `.loaded` record's bytes
        /// re-register best-effort so views repaint the recorded
        /// pixels. Also the failure-class feed for tests. Under replay
        /// a full completion queue reports `error.EffectQueueFull`
        /// with the request still parked — feed again after a drain
        /// (see `finishFedImage`).
        pub fn feedImageResult(self: *Self, id: u64, outcome: EffectImageOutcome, width: u64, height: u64, status: u16, bytes: []const u8) error{ EffectNotFound, EffectQueueFull }!void {
            const slot_index = self.findActiveFakeSlot(id, .image) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            const staged_len = @min(bytes.len, max_effect_image_bytes);
            @memcpy(buffer[0..staged_len], bytes[0..staged_len]);
            slot.body_len = staged_len;
            try self.finishFedImage(slot, .{
                .kind = .image,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(staged_len),
                .status = status,
                .image_outcome = outcome,
                .image_fed = true,
                .image_fed_width = width,
                .image_fed_height = height,
                .image_fn = slot.on_image,
            });
        }

        /// Queue a fed image terminal. Under session replay the queue
        /// is the ONLY path: a full queue back-pressures with
        /// `error.EffectQueueFull` — the slot returns to `.running`
        /// exactly as before the feed, bytes still in its buffer — so
        /// the replay pump can drain the loop and feed again. That is
        /// the loop-thread mirror of the real worker's `postImage`
        /// retry: everything goes THROUGH the queue, so the recorded
        /// bytes and the recorded delivery order both survive a
        /// recording whose drain pass carried more results than the
        /// queue holds.
        ///
        /// Outside replay (test feeds) a full queue keeps the
        /// pending-ring fallback: the terminal lands byte-free, and a
        /// DERIVED `.loaded` (a bytes feed) is rewritten `.rejected`
        /// there — nothing decoded, nothing registered; a success it
        /// cannot back would lie. A RECORDED terminal stands verbatim
        /// (only the best-effort re-registration is lost).
        fn finishFedImage(self: *Self, slot: *Slot, entry_value: Entry) error{EffectQueueFull}!void {
            var entry = entry_value;
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                if (self.replay) {
                    slot.state.store(.running, .release);
                    return error.EffectQueueFull;
                }
                const image_fn = slot.on_image;
                var outcome = entry.image_outcome;
                if (outcome == .loaded and !entry.image_fed) outcome = .rejected;
                self.releaseFetchSlot(slot);
                self.deliverLoopImage(.{
                    .id = entry.key,
                    .outcome = outcome,
                    .width = std.math.cast(usize, entry.image_fed_width) orelse 0,
                    .height = std.math.cast(usize, entry.image_fed_height) orelse 0,
                    .status = entry.status,
                }, image_fn, false);
            }
            self.wakeHost();
        }

        /// Number of parked (still-active) fake host requests.
        pub fn pendingHostCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.kind == .host and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th parked fake host request (slot order).
        pub fn pendingHostAt(self: *Self, index: usize) ?HostRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.kind == .host and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .name = slot.hostName(),
                        .payload = slot.fetchPayload(),
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// The host's (or the test's, or session replay's) answer to
        /// the in-flight host request with `key`, retiring its slot:
        /// one terminal Msg through `on_result`, `ok` choosing the
        /// route and `bytes` riding along. Works for fake-parked AND
        /// real-bound requests — this is the completion path
        /// `HostCallBinding.request_fn` answers through. A result over
        /// `max_effect_host_result_bytes` delivers the err route with a
        /// teaching message (an opaque payload must never pass for the
        /// whole one); if the completion queue is somehow full, the
        /// terminal still lands through the pending ring as an err —
        /// never a silent ok with lost bytes.
        pub fn feedHostResult(self: *Self, key: u64, ok: bool, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = blk: {
                const index = self.findActiveSlot(key) orelse return error.EffectNotFound;
                if (self.slots[index].kind != .host) return error.EffectNotFound;
                break :blk index;
            };
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            const capacity = buffer.len - slot.payload_len;
            var delivered_ok = ok;
            var delivered: []const u8 = bytes;
            if (bytes.len > capacity) {
                delivered_ok = false;
                delivered = "host result over budget";
            }
            @memcpy(buffer[slot.payload_len..][0..delivered.len], delivered);
            slot.body_len = delivered.len;
            var entry: Entry = .{
                .kind = .host,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(delivered.len),
                .host_ok = delivered_ok,
                .host_fn = slot.on_host,
            };
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                const host_fn = slot.on_host;
                self.releaseFetchSlot(slot);
                self.deliverLoopHost(.{ .key = entry.key, .ok = false }, host_fn, false);
            }
            self.wakeHost();
        }

        /// Number of recorded (still-armed) fake fx timers.
        pub fn pendingTimerCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.timer_slots) |*slot| {
                if (slot.active and slot.fake) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake fx timer (slot order).
        pub fn pendingTimerAt(self: *Self, index: usize) ?TimerRequest {
            var seen: usize = 0;
            for (&self.timer_slots) |*slot| {
                if (!(slot.active and slot.fake)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .interval_ms = slot.interval_ms,
                        .mode = slot.mode,
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Fire the fake fx timer with `key` by hand: its `on_fire` Msg
        /// (timestamp 0 — the fake executor has no clock) lands through
        /// the pending ring and drains on the next `.effects_wake`
        /// dispatch or frame pump, exactly like `feedExit`. One-shot
        /// timers retire after the fire; repeating timers stay armed.
        pub fn fireTimer(self: *Self, key: u64) error{EffectNotFound}!void {
            const index = self.findActiveTimerIndex(key) orelse return error.EffectNotFound;
            const slot = &self.timer_slots[index];
            if (!slot.fake) return error.EffectNotFound;
            const on_fire = slot.on_fire;
            const key_copy = slot.key;
            if (slot.mode == .one_shot) slot.active = false;
            self.deliverLoopTimer(.{ .key = key_copy, .timestamp_ns = 0 }, on_fire);
            self.wakeHost();
        }

        // ---------------------------------------------------------- internals

        fn ensureIo(self: *Self) !std.Io {
            if (io_threaded_supported) {
                if (self.io_threaded == null) {
                    // The executor and everything it allocates internally
                    // come from `process_allocator`, never the channel's
                    // caller-owned allocator: an abandoning teardown
                    // leaks the executor under a live worker's blocked
                    // syscall, so nothing the worker can reach through
                    // it may die with the owner. The healthy teardown
                    // frees it through the same seam (`deinit`).
                    const threaded = try process_allocator.create(IoThreaded);
                    // `environ` defaults to `.empty` in `InitOptions`, which
                    // would hand every spawned child a blank environment (no
                    // HOME, no PATH) — always pass the host environment.
                    threaded.* = IoThreaded.init(process_allocator, .{
                        .environ = self.environ orelse fallbackEnviron(),
                    });
                    self.io_threaded = threaded;
                }
                return self.io_threaded.?.io();
            } else {
                return error.IoUnsupported;
            }
        }

        fn wakeHost(self: *Self) void {
            const services = self.services orelse return;
            services.wake() catch {};
        }

        fn reject(self: *Self, options: SpawnOptions) void {
            self.deliverLoopExit(.{
                .key = options.key,
                .code = effect_error_exit_code,
                .reason = .rejected,
            }, options.on_exit);
        }

        fn rejectFetch(self: *Self, options: FetchOptions) void {
            self.deliverLoopResponse(.{
                .key = options.key,
                .outcome = .rejected,
            }, options.on_response);
        }

        fn rejectFile(self: *Self, key: u64, op: EffectFileOp, file_fn: ?FileMsgFn) void {
            self.deliverLoopFile(.{
                .key = key,
                .op = op,
                .outcome = .rejected,
            }, file_fn);
        }

        fn rejectClipboard(self: *Self, key: u64, op: EffectClipboardOp, clipboard_fn: ?ClipboardMsgFn) void {
            self.deliverLoopClipboard(.{
                .key = key,
                .op = op,
                .outcome = .rejected,
            }, clipboard_fn);
        }

        /// Queue a terminal clipboard result produced on the loop
        /// thread (rejections, fake cancels, feed fallbacks) for the
        /// next drain. Text here is always empty.
        fn deliverLoopClipboard(self: *Self, result: EffectClipboardResult, clipboard_fn: ?ClipboardMsgFn) void {
            if (clipboard_fn == null) return;
            self.deliverPending(.{ .clipboard = .{ .result = result, .clipboard_fn = clipboard_fn } });
        }

        /// `regenerates` distinguishes the rejection's provenance for
        /// the session journal: true for pre-executor validation
        /// refusals (deterministic — the replayed `loadImage` refuses
        /// again), false when the executor could not run an otherwise
        /// valid request (io/thread/buffer failures the replay's fake
        /// executor never reproduces — those journal as executor truth
        /// and feed at replay).
        fn rejectImage(self: *Self, id: u64, image_fn: ?ImageMsgFn, regenerates: bool) void {
            self.deliverLoopImage(.{
                .id = id,
                .outcome = .rejected,
            }, image_fn, regenerates);
        }

        /// Queue a terminal image result produced on the loop thread
        /// (rejections, fake cancels, feed fallbacks) for the next
        /// drain. No bytes ride here — nothing decodes, nothing
        /// registers. Staged outside the lossy pending ring: image
        /// terminals must never evict or be evicted (see
        /// `PendingImage`).
        fn deliverLoopImage(self: *Self, result: EffectImageResult, image_fn: ?ImageMsgFn, regenerates: bool) void {
            if (image_fn == null) return;
            self.stagePendingImage(.{
                .seq = self.nextPendingSeq(),
                .result = result,
                .image_fn = image_fn,
                .regenerates = regenerates,
            });
        }

        fn rejectTimer(self: *Self, options: StartTimerOptions) void {
            self.deliverLoopTimer(.{
                .key = options.key,
                .outcome = .rejected,
            }, options.on_fire);
        }

        /// Queue an fx-timer Msg produced on the loop thread (rejections
        /// and fake-executor fires) for the next drain.
        fn deliverLoopTimer(self: *Self, timer: EffectTimer, timer_fn: ?TimerMsgFn) void {
            if (timer_fn == null) return;
            self.deliverPending(.{ .timer = .{ .timer = timer, .timer_fn = timer_fn } });
        }

        /// Update the channel mirrors from one audio event and stamp the
        /// channel's key into it. Null when the channel is idle — a
        /// platform straggler after `stopAudio` (or a fed event racing a
        /// stop) is swallowed rather than misattributed. Position and
        /// duration are the platform's readout, taken verbatim;
        /// `.completed` pins position to the duration and `.failed`
        /// resets the channel (nothing is left to resume).
        fn applyAudioEvent(self: *Self, event: EffectAudio) ?EffectAudio {
            if (!self.audio.active) return null;
            var resolved = event;
            resolved.key = self.audio.key;
            switch (resolved.kind) {
                .loaded, .position => {
                    self.audio.position_ms = resolved.position_ms;
                    if (resolved.duration_ms > 0) self.audio.duration_ms = resolved.duration_ms;
                    self.audio.playing = resolved.playing;
                    // The platform is the buffering authority from its
                    // first report on: `.loaded` means bytes decoded
                    // (stream underway), so the optimistic start-of-
                    // stream flag clears here unless the event holds it.
                    self.audio.buffering = resolved.buffering;
                },
                .completed => {
                    if (resolved.duration_ms > 0) self.audio.duration_ms = resolved.duration_ms;
                    resolved.position_ms = self.audio.duration_ms;
                    resolved.playing = false;
                    resolved.buffering = false;
                    self.audio.position_ms = self.audio.duration_ms;
                    self.audio.playing = false;
                    self.audio.buffering = false;
                },
                .failed, .rejected => {
                    resolved.playing = false;
                    resolved.buffering = false;
                    self.audio = .{ .volume = self.audio.volume };
                },
                // Band reports never steer the transport mirrors — the
                // position ticks stay the clock authority; the channel
                // only mirrors the latest bands (and counts deliveries)
                // for the automation snapshot's live evidence.
                .spectrum => {
                    self.audio.spectrum_bands = resolved.bands;
                    self.audio.spectrum_events +%= 1;
                },
            }
            return resolved;
        }

        /// A synchronous platform refusal (`audioLoad`/`audioPlay`
        /// errored, or no services are bound): reset the channel and
        /// deliver one `.failed` event on the next drain — the honest
        /// degrade for hosts without audio playback.
        fn failAudioChannel(self: *Self) void {
            const key = self.audio.key;
            const on_event = self.audio.on_event;
            self.audio = .{ .volume = self.audio.volume };
            self.deliverLoopAudio(.{ .key = key, .kind = .failed }, on_event);
        }

        /// Queue an audio event Msg produced on the loop thread
        /// (rejections and synchronous failures) for the next drain.
        fn deliverLoopAudio(self: *Self, event: EffectAudio, audio_fn: ?AudioMsgFn) void {
            if (audio_fn == null) return;
            self.deliverPending(.{ .audio = .{ .event = event, .audio_fn = audio_fn, .resolve = false } });
        }

        fn effectTimerPlatformId(slot_index: usize) u64 {
            return effect_timer_platform_id_base + @as(u64, slot_index);
        }

        fn timerIndexForPlatformId(platform_id: u64) ?usize {
            if (platform_id < effect_timer_platform_id_base) return null;
            const index = platform_id - effect_timer_platform_id_base;
            if (index >= max_effect_timers) return null;
            return @intCast(index);
        }

        fn findActiveTimerIndex(self: *Self, key: u64) ?usize {
            for (&self.timer_slots, 0..) |*slot, index| {
                if (slot.active and slot.key == key) return index;
            }
            return null;
        }

        fn findIdleTimerIndex(self: *Self) ?usize {
            for (&self.timer_slots, 0..) |*slot, index| {
                if (!slot.active) return index;
            }
            return null;
        }

        /// Free a fetch slot's body and line buffers and return it to
        /// `.idle` (spawn-time failures and fake cancels). Loop-thread
        /// only.
        fn releaseFetchSlot(self: *Self, slot: *Slot) void {
            if (slot.fetch_buffer) |buffer| {
                self.allocator.free(buffer);
                slot.fetch_buffer = null;
            }
            if (slot.line_buffer) |buffer| {
                self.allocator.free(buffer);
                slot.line_buffer = null;
            }
            slot.state.store(.idle, .release);
        }

        /// Free a spawn slot's collect and line buffers (if any) and
        /// return it to `.idle` (spawn-time failures, fake cancels, and
        /// feed fallbacks). Loop-thread only.
        fn releaseSpawnSlot(self: *Self, slot: *Slot) void {
            if (slot.collect_buffer) |buffer| {
                self.allocator.free(buffer);
                slot.collect_buffer = null;
            }
            if (slot.line_buffer) |buffer| {
                self.allocator.free(buffer);
                slot.line_buffer = null;
            }
            slot.exit_undelivered = false;
            slot.state.store(.idle, .release);
        }

        /// Queue an exit produced on the loop thread (rejections, fake
        /// cancel/exit fallbacks) for the next drain.
        fn deliverLoopExit(self: *Self, exit: EffectExit, exit_fn: ?ExitMsgFn) void {
            if (exit_fn == null) return;
            self.deliverPending(.{ .exit = .{ .exit = exit, .exit_fn = exit_fn } });
        }

        /// Queue a terminal response produced on the loop thread (fetch
        /// rejections, fake cancels) for the next drain. Bodies here are
        /// always empty.
        fn deliverLoopResponse(self: *Self, response: EffectResponse, response_fn: ?ResponseMsgFn) void {
            if (response_fn == null) return;
            self.deliverPending(.{ .response = .{ .response = response, .response_fn = response_fn } });
        }

        /// Queue a terminal file result produced on the loop thread
        /// (file rejections, fake cancels, feed fallbacks) for the next
        /// drain. Bytes here are always empty.
        fn deliverLoopFile(self: *Self, result: EffectFileResult, file_fn: ?FileMsgFn) void {
            if (file_fn == null) return;
            self.deliverPending(.{ .file = .{ .result = result, .file_fn = file_fn } });
        }

        /// Push onto the loop-side pending ring. When the ring is full
        /// the oldest entry is replaced and the replacement carries the
        /// loss in its drop counter — overflow stays visible. Image
        /// terminals never come through here: they carry no drop
        /// counter to keep an eviction visible, so they stage in the
        /// non-lossy `pending_images` instead (`stagePendingImage`).
        fn deliverPending(self: *Self, pending: PendingMsg) void {
            const seq = self.nextPendingSeq();
            if (self.pending_exit_len == max_effect_pending_exits) {
                const oldest = &self.pending_exits[self.pending_exit_head];
                self.pending_exit_head = (self.pending_exit_head + 1) % max_effect_pending_exits;
                self.pending_exit_len -= 1;
                var replacement = pending;
                replacement.addDropped(oldest.droppedCount() +| 1);
                const tail = (self.pending_exit_head + self.pending_exit_len) % max_effect_pending_exits;
                self.pending_exits[tail] = replacement;
                self.pending_exit_seqs[tail] = seq;
                self.pending_exit_len += 1;
            } else {
                const tail = (self.pending_exit_head + self.pending_exit_len) % max_effect_pending_exits;
                self.pending_exits[tail] = pending;
                self.pending_exit_seqs[tail] = seq;
                self.pending_exit_len += 1;
            }
            self.wakeHost();
        }

        fn nextPendingSeq(self: *Self) u64 {
            const seq = self.pending_seq;
            self.pending_seq += 1;
            return seq;
        }

        /// The image stage's current backing storage: the inline buffer
        /// until a burst outgrows it, the heap ring after.
        fn pendingImageStorage(self: *Self) []PendingImage {
            if (self.pending_image_spill.len > 0) return self.pending_image_spill;
            return &self.pending_images;
        }

        /// Stage one loop-side image terminal for the next drain —
        /// never dropping one (the `PendingImage` contract). Growth is
        /// geometric and earned only by bursts that outgrow the inline
        /// buffer; each staged entry answers exactly one `loadImage`
        /// call, so the stage can never grow past the caller's own
        /// call count between drains. An allocation failure refuses
        /// LOUDLY: with no counter to fold a loss into and no error
        /// channel back to the void-returning `loadImage`, dropping
        /// the entry would strand its issuer forever — a crash names
        /// the problem, silence never would.
        fn stagePendingImage(self: *Self, entry: PendingImage) void {
            const storage = self.pendingImageStorage();
            if (self.pending_image_len == storage.len) {
                const grown = self.allocator.alloc(PendingImage, storage.len * 2) catch
                    @panic("effects: out of memory staging an image terminal - each staged entry is one loadImage call's only terminal and must never be dropped");
                for (grown[0..self.pending_image_len], 0..) |*slot, index| {
                    slot.* = storage[(self.pending_image_head + index) % storage.len];
                }
                if (self.pending_image_spill.len > 0) self.allocator.free(self.pending_image_spill);
                self.pending_image_spill = grown;
                self.pending_image_head = 0;
            }
            const active = self.pendingImageStorage();
            active[(self.pending_image_head + self.pending_image_len) % active.len] = entry;
            self.pending_image_len += 1;
            self.wakeHost();
        }

        /// Pop the image stage's head. Draining empty releases the
        /// spill: the burst that earned it is over, and the inline
        /// buffer covers the everyday case again.
        fn takePendingImage(self: *Self) PendingImage {
            const storage = self.pendingImageStorage();
            const entry = storage[self.pending_image_head];
            self.pending_image_head = (self.pending_image_head + 1) % storage.len;
            self.pending_image_len -= 1;
            if (self.pending_image_len == 0) {
                self.pending_image_head = 0;
                if (self.pending_image_spill.len > 0) {
                    self.allocator.free(self.pending_image_spill);
                    self.pending_image_spill = &.{};
                }
            }
            return entry;
        }

        /// Take the next loop-side pending terminal in enqueue order,
        /// merging the ring and the image stage by their shared stamp
        /// so splitting the storage never reordered delivery. Entries
        /// stamped at or past `before` stay staged: they were produced
        /// during the current drain pass and belong to the next one
        /// (the `DrainBoundary` causality contract). Both structures
        /// are FIFO over the monotonic stamp, so refusing the merged
        /// head refuses everything younger too.
        fn takePendingMsg(self: *Self, before: u64) ?PendingMsg {
            const ring_has = self.pending_exit_len > 0 and
                self.pending_exit_seqs[self.pending_exit_head] < before;
            const image_has = self.pending_image_len > 0 and
                self.pendingImageStorage()[self.pending_image_head].seq < before;
            if (!ring_has and !image_has) return null;
            const take_image = if (ring_has and image_has)
                self.pendingImageStorage()[self.pending_image_head].seq < self.pending_exit_seqs[self.pending_exit_head]
            else
                image_has;
            if (take_image) {
                const staged = self.takePendingImage();
                return .{ .image = .{
                    .result = staged.result,
                    .image_fn = staged.image_fn,
                    .regenerates = staged.regenerates,
                } };
            }
            const pending = self.pending_exits[self.pending_exit_head];
            self.pending_exit_head = (self.pending_exit_head + 1) % max_effect_pending_exits;
            self.pending_exit_len -= 1;
            return pending;
        }

        fn findIdleSlot(self: *Self) ?usize {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state.load(.acquire) == .idle) return index;
            }
            return null;
        }

        fn findActiveSlot(self: *Self, key: u64) ?usize {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state.load(.acquire) == .running and slot.key == key) return index;
            }
            return null;
        }

        /// The shared admission gate for the keyed effect families
        /// (spawn/fetch/file/clipboard/image — they share the slots
        /// and one key space): a key is occupied while its effect runs
        /// AND through the posted-but-undelivered terminal window that
        /// follows. Under session replay the same request is a parked
        /// `.running` fake until its journaled terminal feeds at the
        /// recorded delivery position, so any admission that accepted
        /// a key live inside that window would journal a Msg stream
        /// replay rejects (`ReplayEffectDivergence`). Delivery ends
        /// the window on both sides at the same causal instant — the
        /// drain retires the slot before the terminal Msg reaches
        /// update — so reissuing a key from its own terminal handler
        /// is always accepted.
        fn keyOccupiedUntilDelivery(self: *Self, key: u64) bool {
            if (self.findActiveSlot(key) != null) return true;
            if (self.findUndeliveredTerminalSlot(key) != null) return true;
            if (self.stagedImageOccupiesKey(key)) return true;
            return false;
        }

        /// A staged loop-side image terminal that is executor truth
        /// (`regenerates = false` — start failures, fake cancels)
        /// occupies its id until the drain delivers it. Those
        /// terminals journal as worker truth and FEED under session
        /// replay, where the request they answer stays parked in its
        /// slot until the recorded delivery position — so live
        /// admission must hold the key through the same window, or a
        /// key accepted here live is one replay rejects. Regenerating
        /// validation refusals deliberately do NOT occupy: replay
        /// re-runs the same loop-side validation at the same dispatch,
        /// so both sides refuse (and stage) identically with the key
        /// never held on either side.
        fn stagedImageOccupiesKey(self: *Self, id: u64) bool {
            const storage = self.pendingImageStorage();
            var index: usize = 0;
            while (index < self.pending_image_len) : (index += 1) {
                const entry = &storage[(self.pending_image_head + index) % storage.len];
                if (!entry.regenerates and entry.result.id == id) return true;
            }
            return false;
        }

        /// A slot of ANY kind holding `key` whose terminal is posted
        /// but not yet delivered: state `.draining` with its
        /// per-family delivery marker still set. Delivery IS the
        /// marker handoff, derived from how each family's drain
        /// retires the slot: the drain takes `fetch_buffer` (fetch,
        /// file, clipboard, host, and image terminals) or
        /// `collect_buffer` (collect spawns) before the terminal Msg
        /// reaches update, and clears `exit_undelivered` (`.lines`
        /// spawns, which own no delivery buffer) at the same instant;
        /// every loop-side retire (`releaseFetchSlot`,
        /// `releaseSpawnSlot`) resets the markers too. So a set marker
        /// under `.draining` means exactly "terminal still pending" —
        /// the moment update sees the result, the key is free for
        /// reuse. Loop-thread only: the state load is the acquire
        /// pairing with the worker's `.draining` release store (the
        /// worker's last slot access), and the markers are only ever
        /// cleared on the loop thread.
        fn findUndeliveredTerminalSlot(self: *Self, key: u64) ?usize {
            for (&self.slots, 0..) |*slot, index| {
                if (slot.key != key) continue;
                if (slot.state.load(.acquire) != .draining) continue;
                if (slotTerminalUndelivered(slot)) return index;
            }
            return null;
        }

        /// The per-family "terminal still pending" predicate for a
        /// slot already observed `.draining` (see
        /// `findUndeliveredTerminalSlot` for the marker derivations).
        fn slotTerminalUndelivered(slot: *const Slot) bool {
            return switch (slot.kind) {
                .spawn => slot.collect_buffer != null or slot.exit_undelivered,
                .fetch, .file, .clipboard, .host, .image => slot.fetch_buffer != null,
            };
        }

        /// The most recent no-longer-running occupant with `key` (done
        /// or already reclaimed to idle) — the spawn a racing cancel is
        /// aimed at.
        fn findFinishedSlot(self: *Self, key: u64) ?usize {
            var best: ?usize = null;
            for (&self.slots, 0..) |*slot, index| {
                if (slot.state.load(.acquire) == .running) continue;
                if (slot.generation == 0 or slot.key != key) continue;
                if (best == null or self.slots[best.?].generation < slot.generation) best = index;
            }
            return best;
        }

        fn findActiveFakeSlot(self: *Self, key: u64, kind: SlotKind) ?usize {
            const index = self.findActiveSlot(key) orelse return null;
            if (!self.slots[index].fake) return null;
            if (self.slots[index].kind != kind) return null;
            return index;
        }

        /// Join a finished worker's thread and clear its handle.
        /// Loop-thread only. The reclaim path reaches this only after
        /// the worker published a non-running slot state — its last
        /// slot access — so the join blocks for the thread's epilogue
        /// (a wake nudge and the OS exit), never on child I/O. The
        /// teardown path (`deinit`) may join a still-running worker;
        /// convergence there is the kill's and the shutdown flag's
        /// doing, as documented at that call site.
        fn joinWorker(slot: *Slot) void {
            if (io_threaded_supported) {
                const thread = slot.worker_thread orelse return;
                slot.worker_thread = null;
                thread.join();
                // The join proves the worker is gone: its out-of-line
                // context (file and spawn workers) has no user left.
                // Contexts and their buffers are process-lifetime
                // allocations (see `process_allocator`), so they free
                // through that seam, not the channel's allocator.
                if (slot.file_ctx) |ctx| {
                    process_allocator.free(ctx.buffer);
                    process_allocator.destroy(ctx);
                    slot.file_ctx = null;
                }
                if (slot.spawn_ctx) |ctx| {
                    destroySpawnContext(ctx);
                    slot.spawn_ctx = null;
                }
            }
        }

        /// Return a spawn worker context and its private buffers to
        /// `process_allocator` — the happy-path counterpart of the
        /// abandon leak (spawn-time failures and `joinWorker`).
        fn destroySpawnContext(ctx: *SpawnWorkerContext) void {
            if (ctx.line_buffer) |buffer| process_allocator.free(buffer);
            if (ctx.collect_buffer) |buffer| process_allocator.free(buffer);
            process_allocator.destroy(ctx);
        }

        fn reclaimSlots(self: *Self) void {
            for (&self.slots) |*slot| {
                switch (slot.state.load(.acquire)) {
                    .done => {
                        joinWorker(slot);
                        slot.state.store(.idle, .release);
                    },
                    // A draining slot is reusable once the drain
                    // delivered its terminal (took the fetch body or
                    // collected stdout, or cleared a `.lines` exit's
                    // marker). Its worker is already finished either
                    // way: retire the thread now.
                    .draining => {
                        joinWorker(slot);
                        if (slot.fetch_buffer == null and slot.collect_buffer == null and !slot.exit_undelivered) {
                            slot.state.store(.idle, .release);
                        }
                    },
                    else => {},
                }
            }
        }

        fn enqueue(self: *Self, entry: *const Entry) bool {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            if (self.queue_len == max_effect_queue_entries) return false;
            const tail = (self.queue_head + self.queue_len) % max_effect_queue_entries;
            self.queue[tail] = entry.*;
            self.queue_len += 1;
            self.queue_count.store(self.queue_len, .release);
            return true;
        }

        fn dequeueInto(self: *Self, out: *Entry) bool {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            if (self.queue_len == 0) return false;
            out.* = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % max_effect_queue_entries;
            self.queue_len -= 1;
            self.queue_count.store(self.queue_len, .release);
            return true;
        }

        /// Append stdout bytes to a collect spawn's buffer, truncating at
        /// the collect bound with the flag set. Single-writer: the worker
        /// in real mode, the loop thread (feedLine) in fake mode.
        fn appendCollected(slot: *Slot, bytes: []const u8) void {
            const buffer = slot.collect_buffer orelse return;
            const remaining = buffer.len - slot.collect_len;
            const take = @min(bytes.len, remaining);
            @memcpy(buffer[slot.collect_len..][0..take], bytes[0..take]);
            slot.collect_len += take;
            if (take < bytes.len) slot.collect_truncated = true;
        }

        /// Append stderr bytes to a collect spawn's tail ring (the last
        /// `max_effect_stderr_tail_bytes` win). Single-writer, like
        /// `appendCollected`.
        fn appendStderrTail(slot: *Slot, bytes: []const u8) void {
            for (bytes) |byte| {
                slot.stderr_ring[slot.stderr_total % max_effect_stderr_tail_bytes] = byte;
                slot.stderr_total += 1;
            }
        }

        /// Stamp a collect spawn's terminal payload onto its exit entry:
        /// the output length/flag (bytes stay in the slot buffer until
        /// the drain takes them) and the linearized stderr tail (oldest
        /// kept byte first) into the entry's line buffer.
        fn stampCollectExit(slot: *const Slot, entry: *Entry) void {
            entry.collect = true;
            entry.collect_len = @intCast(slot.collect_len);
            entry.collect_truncated = slot.collect_truncated;
            const tail_len = @min(slot.stderr_total, max_effect_stderr_tail_bytes);
            entry.stderr_truncated = slot.stderr_total > max_effect_stderr_tail_bytes;
            const start = if (slot.stderr_total > max_effect_stderr_tail_bytes)
                slot.stderr_total % max_effect_stderr_tail_bytes
            else
                0;
            var index: usize = 0;
            while (index < tail_len) : (index += 1) {
                entry.line_bytes[index] = slot.stderr_ring[(start + index) % max_effect_stderr_tail_bytes];
            }
            entry.line_len = @intCast(tail_len);
        }

        /// Producer-side line delivery with drop accounting, bounded by
        /// the slot's `line_limit`. Lines beyond the inline entry buffer
        /// (a raised `max_line_bytes`) ride a per-line heap allocation
        /// the drain retires; if that allocation fails the line degrades
        /// to the inline bound, truncated and flagged — never silent.
        fn produceLine(self: *Self, slot: *Slot, slot_index: u16, generation: u32, bytes: []const u8, truncated: bool) void {
            var len = @min(bytes.len, slot.line_limit);
            var entry: Entry = .{
                .kind = .line,
                .slot_index = slot_index,
                .generation = generation,
                .key = slot.key,
                .truncated = truncated or bytes.len > slot.line_limit,
                .dropped_before = slot.dropped_pending,
                .line_fn = slot.on_line,
            };
            if (len <= max_effect_line_bytes) {
                @memcpy(entry.line_bytes[0..len], bytes[0..len]);
            } else if (self.allocator.alloc(u8, len)) |heap| {
                @memcpy(heap, bytes[0..len]);
                entry.heap_line = heap;
            } else |_| {
                len = max_effect_line_bytes;
                entry.truncated = true;
                @memcpy(entry.line_bytes[0..len], bytes[0..len]);
            }
            entry.line_len = @intCast(len);
            if (self.enqueue(&entry)) {
                slot.dropped_pending = 0;
            } else {
                if (entry.heap_line) |heap| self.allocator.free(heap);
                slot.dropped_pending +|= 1;
                slot.dropped_total +|= 1;
            }
            self.wakeHost();
        }

        /// `produceLine` for a real spawn's blocking task: entry
        /// parameters and drop accounting come from the worker context,
        /// and every channel touch (the caller-owned allocator for an
        /// oversized line, the queue, the wake) happens under the
        /// context's abandon fence — teardown may ABANDON this worker
        /// at any pre-commit moment, and whoever takes `ctx.mutex`
        /// first decides: an abandoned task drops the line and walks
        /// away (the channel may already be freed), while a delivery in
        /// flight under the lock finishes before teardown can mark the
        /// abandon. Streaming deliveries therefore keep their live
        /// arrival order and byte identity on every healthy path.
        fn produceSpawnLine(self: *Self, ctx: *SpawnWorkerContext, slot_index: u16, generation: u32, bytes: []const u8, truncated: bool) void {
            var len = @min(bytes.len, ctx.line_limit);
            var entry: Entry = .{
                .kind = .line,
                .slot_index = slot_index,
                .generation = generation,
                .key = ctx.key,
                .truncated = truncated or bytes.len > ctx.line_limit,
                .dropped_before = ctx.dropped_pending,
                .line_fn = ctx.on_line,
            };
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            if (ctx.abandoned) return;
            if (len <= max_effect_line_bytes) {
                @memcpy(entry.line_bytes[0..len], bytes[0..len]);
            } else if (self.allocator.alloc(u8, len)) |heap| {
                @memcpy(heap, bytes[0..len]);
                entry.heap_line = heap;
            } else |_| {
                len = max_effect_line_bytes;
                entry.truncated = true;
                @memcpy(entry.line_bytes[0..len], bytes[0..len]);
            }
            entry.line_len = @intCast(len);
            if (self.enqueue(&entry)) {
                ctx.dropped_pending = 0;
            } else {
                if (entry.heap_line) |heap| self.allocator.free(heap);
                ctx.dropped_pending +|= 1;
                ctx.dropped_total +|= 1;
            }
            self.wakeHost();
        }

        /// Request a kill of a real spawn's child through its worker
        /// context: record the request (so a kill that races the
        /// child's publish still lands — the task re-checks after
        /// publishing) and signal the published id. Loop-thread only
        /// (cancel, teardown), while the channel is alive; the
        /// handshake itself lives in the process-lived context so the
        /// blocking task can take it channel-blind.
        fn killPublishedChild(self: *Self, slot: *Slot) void {
            _ = self;
            const ctx = slot.spawn_ctx orelse return;
            ctx.kill_requested.store(true, .release);
            killPublishedChildCtx(ctx);
        }

        /// Send a kill to the published child id, but only while the
        /// task has not begun reaping (guarded by the context mutex),
        /// so the pid/handle is guaranteed to still name this process.
        fn killPublishedChildCtx(ctx: *SpawnWorkerContext) void {
            ctx.child_mutex.lock();
            defer ctx.child_mutex.unlock();
            if (ctx.reaping) return;
            const id = ctx.child_id orelse return;
            if (builtin.os.tag == .windows) {
                // Windows has no process groups in this sense: the
                // direct-handle terminate cannot reach descendants, so
                // an escaped grandchild holding the stdout pipe is
                // converged by the teardown interruption (the threaded
                // io cancels the blocked read) or, past the deadline,
                // by the abandon net. Job objects would kill the whole
                // tree properly — the future strengthening; not built
                // here.
                _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
            } else {
                // The child owns its process group (see the spawn in
                // `runChild`), so the negative-pid form signals every
                // descendant still in it — the grandchildren of a
                // shell-wrapped command included, which is what lets
                // the worker's stdout read reach EOF promptly. The
                // direct-pid fallback covers a group already gone. A
                // descendant that LEFT the group (`setsid`, `set -m`)
                // is out of reach by construction; the teardown
                // interruption and abandon net bound the worker
                // instead.
                std.posix.kill(-id, .KILL) catch {
                    std.posix.kill(id, .KILL) catch {};
                };
            }
        }

        // ------------------------------------------------------------ worker

        /// Supervises one real spawn, mirroring `fileWorkerMain`: the
        /// blocking phase (child spawn, stream reads, wait/reap) runs
        /// as a cancelable `Io` task that touches only its out-of-line
        /// `SpawnWorkerContext` — plus the queue, under the context's
        /// abandon fence, for streaming line deliveries (see
        /// `produceSpawnLine`). Convergence at teardown is normally
        /// the group-kill's doing (EOF within milliseconds); when a
        /// descendant escaped the group and keeps the pipe open,
        /// teardown sets `ctx.interrupt` at half its spawn deadline
        /// and the supervisor cancels the task (the threaded io
        /// interrupts the blocked read), and past the full deadline
        /// the worker is abandoned. After the task ends the supervisor
        /// COMMITS under the context's mutex — from that point it may
        /// touch the slot and queue (publishing collect payloads into
        /// the slot's delivery buffer, posting the exit), and teardown
        /// will join it — or finds itself abandoned and returns
        /// without touching the channel again.
        fn spawnWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io, ctx: *SpawnWorkerContext) void {
            supervise: {
                var future = std.Io.concurrent(io, spawnTask, .{ self, ctx, @as(u16, @intCast(slot_index)), generation, io }) catch {
                    // No concurrent capacity: run the blocking phase
                    // inline. Teardown cannot interrupt it, but the
                    // group-kill converges the common case and the
                    // deadline still bounds deinit via the abandon
                    // net. (Deliberately unlike fetch, which REJECTS
                    // when its exchange cannot start cancellably:
                    // fetch joins are unconditional and unbounded,
                    // while a stuck spawn worker — like a file one —
                    // has the abandon safety net.)
                    spawnTask(self, ctx, @intCast(slot_index), generation, io);
                    break :supervise;
                };
                superviseWorkerTask(io, &future, &ctx.done, &ctx.interrupt);
            }
            ctx.mutex.lock();
            if (ctx.abandoned) {
                // Teardown gave up on this worker: the channel may
                // already be freed. The context (and everything the
                // task touched through it) is intentionally leaked and
                // stays valid forever — touch nothing else.
                ctx.mutex.unlock();
                return;
            }
            ctx.committed = true;
            ctx.mutex.unlock();
            // Committed: the channel is alive, and a concurrent
            // teardown now JOINS this thread instead of abandoning it.
            // The epilogue below touches the slot and queue freely and
            // converges within milliseconds (the terminal post gives
            // up on shutdown).
            const slot = &self.slots[slot_index];
            var exit = ctx.exit;
            exit.dropped_lines = ctx.dropped_total;
            slot.dropped_total = ctx.dropped_total;
            if (ctx.output_mode == .collect) {
                // Publish the collected payloads into the slot's
                // channel-owned delivery storage (what the drain hands
                // to `update`): the blocking phase filled only the
                // context's process-lived private copies.
                if (slot.collect_buffer) |delivery| {
                    const publish_len = @min(ctx.collect_len, delivery.len);
                    @memcpy(delivery[0..publish_len], ctx.collect_buffer.?[0..publish_len]);
                    slot.collect_len = publish_len;
                } else {
                    slot.collect_len = 0;
                }
                slot.collect_truncated = ctx.collect_truncated;
                slot.stderr_ring = ctx.stderr_ring;
                slot.stderr_total = ctx.stderr_total;
            }
            // Mark-then-post: the `.lines` undelivered-exit marker must
            // be published BEFORE the exit is consumable. `postExit`'s
            // enqueue releases the queue mutex the drain's dequeue
            // acquires, so this write is ordered before any consume —
            // the drain-side clear always follows this set. Posting
            // first would let a drain riding another wake consume the
            // exit (clearing a still-false marker) before the mark
            // landed, leaving a set marker no terminal can ever clear:
            // `reclaimSlots` would hold the slot out of `.idle` forever
            // and the key would never readmit.
            if (ctx.output_mode != .collect) slot.exit_undelivered = true;
            self.postExit(slot, @intCast(slot_index), generation, io, exit);
            // Park in `.draining` until the drain delivers the exit: a
            // collect slot still owns its stdout buffer (fetch-style),
            // and a `.lines` slot holds the marker set above — either
            // way the key stays occupied through the window between the
            // post and the drain, which is exactly the span session
            // replay keeps the parked fake occupying
            // (`findUndeliveredTerminalSlot`). This store must stay
            // AFTER the post: `reclaimSlots` joins any `.draining`
            // worker, and `postExit` can park in a full-queue retry
            // only the loop thread can relieve — staying `.running`
            // keeps this thread unjoinable until the post lands. It is
            // also the release the loop's acquire loads pair with, and
            // the worker's last slot access.
            slot.state.store(.draining, .release);
            self.wakeHost();
        }

        /// The blocking spawn phase as a cancelable task on the
        /// executor io. Always records a terminal `ctx.exit` before
        /// `done`. Touches only the leaked-on-abandon context, the io,
        /// and — under the context's abandon fence — the completion
        /// queue for streaming lines (see `SpawnWorkerContext`).
        fn spawnTask(self: *Self, ctx: *SpawnWorkerContext, slot_index: u16, generation: u32, io: std.Io) void {
            defer ctx.done.store(true, .release);
            self.runChild(ctx, slot_index, generation, io);
        }

        fn runChild(self: *Self, ctx: *SpawnWorkerContext, slot_index: u16, generation: u32, io: std.Io) void {
            var child = std.process.spawn(io, .{
                .argv = ctx.argv(),
                .stdin = if (ctx.stdin_len > 0) .pipe else .ignore,
                .stdout = .pipe,
                .stderr = if (ctx.output_mode == .collect) .pipe else .ignore,
                // POSIX: land the child in its OWN process group (id ==
                // its pid, set before exec) so `killPublishedChild` can
                // signal the whole descendant tree. Killing only the
                // direct child leaves a shell-wrapped command's
                // grandchildren (`sh -c "a; b"` forks `b`) holding the
                // stdout pipe open — the worker would then block at
                // read until the orphan exits on its own, stalling
                // cancel's `.cancelled` terminal and any teardown
                // joining the worker. Windows has no process groups in
                // this sense; the direct-handle terminate stands alone
                // there, as before (see `killPublishedChildCtx` for
                // the descendant story on both platforms).
                .pgid = if (builtin.os.tag == .windows) null else 0,
            }) catch return;

            ctx.child_mutex.lock();
            ctx.child_id = child.id;
            ctx.child_mutex.unlock();
            // A cancel that raced the spawn still lands.
            if (ctx.kill_requested.load(.acquire)) killPublishedChildCtx(ctx);

            // Collect mode drains stderr concurrently so a chatty child
            // can never deadlock against a full stderr pipe while we read
            // stdout. The reader ends at stderr EOF (the child exiting),
            // and the join below runs before the exit is assembled, so
            // the tail ring is complete and single-threaded again by the
            // time it is read. The reader touches only the context (and
            // the child's pipe), so it is as abandon-safe as the task.
            var stderr_thread: ?std.Thread = null;
            defer if (stderr_thread) |thread| thread.join();
            if (child.stderr) |stderr_file| {
                stderr_thread = std.Thread.spawn(.{}, stderrTailMain, .{ ctx, io, stderr_file }) catch null;
            }

            if (child.stdin) |stdin_file| {
                stdin_file.writeStreamingAll(io, ctx.stdinBytes()) catch {};
                stdin_file.close(io);
                child.stdin = null;
            }

            if (child.stdout) |stdout_file| {
                if (ctx.output_mode == .collect) {
                    collectStdout(ctx, io, stdout_file);
                } else {
                    self.streamLines(ctx, slot_index, generation, io, stdout_file);
                }
            }

            // Thread-spawn failure fallback: drain stderr inline after
            // stdout closed (before reaping, so a child blocked on a full
            // stderr pipe still finishes).
            if (stderr_thread == null) {
                if (child.stderr) |stderr_file| collectStderrTail(ctx, io, stderr_file);
            }

            // Join the stderr reader BEFORE reaping: `child.wait` closes
            // the child's pipe files unconditionally, and a reader still
            // in flight races that close and loses the tail (it reads a
            // dead — or worse, recycled — descriptor). The join is safe
            // here: stdout already hit EOF, and stderr EOF arrives when
            // the child dies whether or not it has been reaped.
            if (stderr_thread) |thread| {
                thread.join();
                stderr_thread = null;
            }

            ctx.child_mutex.lock();
            ctx.reaping = true;
            ctx.child_mutex.unlock();
            const term = child.wait(io) catch {
                ctx.exit = .{ .key = ctx.key, .code = effect_error_exit_code, .reason = .signaled };
                if (ctx.kill_requested.load(.acquire)) ctx.exit.reason = .cancelled;
                return;
            };
            ctx.exit = switch (term) {
                .exited => |code| .{ .key = ctx.key, .code = code, .reason = .exited },
                else => .{ .key = ctx.key, .code = effect_error_exit_code, .reason = .signaled },
            };
            if (ctx.kill_requested.load(.acquire)) {
                ctx.exit.reason = .cancelled;
                ctx.exit.code = effect_error_exit_code;
            }
        }

        fn streamLines(self: *Self, ctx: *SpawnWorkerContext, slot_index: u16, generation: u32, io: std.Io, stdout_file: std.Io.File) void {
            var read_buffer: [1024]u8 = undefined;
            // Spawns with a raised `max_line_bytes` frame into their
            // context's heap buffer; everyone else uses the stack.
            var stack_buffer: [max_effect_line_bytes]u8 = undefined;
            const line_buffer: []u8 = ctx.line_buffer orelse &stack_buffer;
            const limit = @min(ctx.line_limit, line_buffer.len);
            var line_len: usize = 0;
            var truncated = false;
            while (true) {
                const read_slices: [1][]u8 = .{&read_buffer};
                const count = stdout_file.readStreaming(io, &read_slices) catch break;
                for (read_buffer[0..count]) |byte| {
                    if (byte == '\n') {
                        self.produceSpawnLine(ctx, slot_index, generation, line_buffer[0..line_len], truncated);
                        line_len = 0;
                        truncated = false;
                    } else if (line_len < limit) {
                        line_buffer[line_len] = byte;
                        line_len += 1;
                    } else {
                        truncated = true;
                    }
                }
            }
            if (line_len > 0 or truncated) {
                self.produceSpawnLine(ctx, slot_index, generation, line_buffer[0..line_len], truncated);
            }
        }

        /// Collect-mode stdout: raw bytes into the context's private
        /// buffer, no line framing, bounded by
        /// `max_effect_collect_bytes`. The committed epilogue publishes
        /// them into the slot's delivery buffer.
        fn collectStdout(ctx: *SpawnWorkerContext, io: std.Io, stdout_file: std.Io.File) void {
            var read_buffer: [4096]u8 = undefined;
            while (true) {
                const read_slices: [1][]u8 = .{&read_buffer};
                const count = stdout_file.readStreaming(io, &read_slices) catch break;
                if (count == 0) break;
                appendCollectedCtx(ctx, read_buffer[0..count]);
            }
        }

        fn stderrTailMain(ctx: *SpawnWorkerContext, io: std.Io, stderr_file: std.Io.File) void {
            collectStderrTail(ctx, io, stderr_file);
        }

        /// Collect-mode stderr: keep the last
        /// `max_effect_stderr_tail_bytes` bytes in the context's tail
        /// ring.
        fn collectStderrTail(ctx: *SpawnWorkerContext, io: std.Io, stderr_file: std.Io.File) void {
            var read_buffer: [1024]u8 = undefined;
            while (true) {
                const read_slices: [1][]u8 = .{&read_buffer};
                const count = stderr_file.readStreaming(io, &read_slices) catch break;
                if (count == 0) break;
                appendStderrTailCtx(ctx, read_buffer[0..count]);
            }
        }

        /// `appendCollected` against the worker context's private
        /// buffer (single-writer: the blocking task).
        fn appendCollectedCtx(ctx: *SpawnWorkerContext, bytes: []const u8) void {
            const buffer = ctx.collect_buffer orelse return;
            const remaining = buffer.len - ctx.collect_len;
            const take = @min(bytes.len, remaining);
            @memcpy(buffer[ctx.collect_len..][0..take], bytes[0..take]);
            ctx.collect_len += take;
            if (take < bytes.len) ctx.collect_truncated = true;
        }

        /// `appendStderrTail` against the worker context's private ring
        /// (single-writer: the stderr reader).
        fn appendStderrTailCtx(ctx: *SpawnWorkerContext, bytes: []const u8) void {
            for (bytes) |byte| {
                ctx.stderr_ring[ctx.stderr_total % max_effect_stderr_tail_bytes] = byte;
                ctx.stderr_total += 1;
            }
        }

        // ------------------------------------------------------ fetch worker

        /// Supervises one fetch: runs the blocking HTTP exchange as a
        /// cancelable `Io` task and polls for completion, cancel, and
        /// the timeout deadline. An exchange that cannot start as a
        /// cancelable task is REJECTED, never run inline (see
        /// `startFetchExchange`). Ends by posting exactly one
        /// `.response` entry and parking the slot in `.draining` (the
        /// drain retires it after taking the body buffer).
        fn fetchWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io) void {
            const slot = &self.slots[slot_index];
            supervise: {
                var future = self.startFetchExchange(slot, slot_index, generation, io) catch {
                    // The executor cannot start the exchange as a
                    // cancelable task. Running it inline instead would
                    // observe neither `cancel` nor the timeout — and
                    // teardown joins fetch workers UNCONDITIONALLY on
                    // the guarantee that they poll `shutdown` and
                    // cancel their exchange, so an inline stall would
                    // hang `deinit` forever. REFUSE the exchange: the
                    // honest terminal is `.rejected` (the fetch never
                    // started), journaled at drain like every transport
                    // failure, so replay reproduces the rejection
                    // byte-identically.
                    slot.fetch_status = 0;
                    slot.body_len = 0;
                    slot.fetch_truncated = false;
                    slot.fetch_outcome = .rejected;
                    if (self.fetch_start_rejections.fetchAdd(1, .monotonic) == 0) {
                        std.debug.print(
                            "effects fetch: the executor could not start a cancelable exchange for '{s}'; rejecting the fetch (an inline exchange would evade cancel, the timeout, and teardown)\n",
                            .{slot.fetchUrl()},
                        );
                    }
                    break :supervise;
                };
                const poll_ms: u64 = 5;
                var waited_ms: u64 = 0;
                var timed_out = false;
                while (true) {
                    if (slot.fetch_done.load(.acquire)) break;
                    if (self.shutdown.load(.acquire) or slot.cancel_requested.load(.acquire)) {
                        future.cancel(io);
                        break;
                    }
                    if (waited_ms >= slot.timeout_ms) {
                        timed_out = true;
                        future.cancel(io);
                        break;
                    }
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_ms), .awake) catch {};
                    waited_ms += poll_ms;
                }
                future.await(io);
                if (!slot.fetch_done.load(.acquire)) {
                    // Interrupted before the task recorded a terminal
                    // state (never expected — the task always records).
                    slot.fetch_status = 0;
                    slot.body_len = 0;
                    slot.fetch_truncated = false;
                    slot.fetch_outcome = if (timed_out) .timed_out else .cancelled;
                } else if (timed_out and slot.fetch_outcome != .ok) {
                    // The interruption was the deadline, not the app.
                    // The interrupted exchange may have surfaced as any
                    // I/O error (a cancelled blocking read reports
                    // ReadFailed, not Canceled), so every non-ok
                    // outcome here is the timeout's doing. A response
                    // that completed before the deadline fired stays a
                    // delivered `.ok`.
                    slot.fetch_outcome = .timed_out;
                    slot.fetch_status = 0;
                    slot.body_len = 0;
                    slot.fetch_truncated = false;
                }
            }
            self.postResponse(slot, @intCast(slot_index), generation, io);
            slot.state.store(.draining, .release);
            self.wakeHost();
        }

        /// Start the blocking exchange as a cancelable task on the
        /// executor io — the ONLY way a real exchange may run: an
        /// exchange the supervisor cannot cancel would break the fetch
        /// contract (timeout, `cancel`, teardown's unconditional join),
        /// so a start failure is surfaced to `fetchWorkerMain`, which
        /// rejects the fetch instead of running it inline. Injectable
        /// through `fetch_concurrent_start` so tests pin the rejection
        /// path deterministically.
        fn startFetchExchange(self: *Self, slot: *Slot, slot_index: usize, generation: u32, io: std.Io) std.Io.ConcurrentError!std.Io.Future(void) {
            if (!self.fetch_concurrent_start) return error.ConcurrencyUnavailable;
            return std.Io.concurrent(io, fetchTask, .{ self, slot, @as(u16, @intCast(slot_index)), generation, io });
        }

        /// The blocking exchange, run as a cancelable task. Always
        /// records a terminal state in the slot before `fetch_done`.
        fn fetchTask(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io) void {
            defer slot.fetch_done.store(true, .release);
            self.runFetch(slot, slot_index, generation, io) catch |err| {
                slot.fetch_status = 0;
                slot.body_len = 0;
                slot.fetch_truncated = false;
                slot.fetch_outcome = classifyFetchError(err);
            };
        }

        fn runFetch(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io) !void {
            const uri = try std.Uri.parse(slot.fetchUrl());
            var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
            defer client.deinit();
            var request = client.request(slot.method, uri, .{
                .keep_alive = false,
                .extra_headers = slot.fetchHeaders(),
                // Mirrors `std.http.Client.fetch`: payloads cannot be
                // replayed across redirects.
                .redirect_behavior = if (slot.payload_len > 0) .unhandled else @enumFromInt(3),
            }) catch |err| {
                // Establishing the connection is what `request` does, so
                // an UNTYPED failure here is a connect failure. (The
                // Windows net layer surfaces refused/unreachable connects
                // as NTSTATUS codes it does not translate into typed
                // errors; without this, those reported `.protocol_failed`
                // even though no protocol exchange ever began.)
                if (err == error.Unexpected) return error.ConnectPhaseFailed;
                return err;
            };
            defer request.deinit();
            if (slot.payload_len > 0) {
                request.transfer_encoding = .{ .content_length = slot.payload_len };
                var body = try request.sendBodyUnflushed(&.{});
                try body.writer.writeAll(slot.fetchPayload());
                try body.end();
                try request.connection.?.flush();
            } else {
                try request.sendBodiless();
            }
            var redirect_buffer: [8 * 1024]u8 = undefined;
            var response = try request.receiveHead(&redirect_buffer);
            slot.fetch_status = @intFromEnum(response.head.status);

            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
                .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
                .compress => return error.UnsupportedCompressionMethod,
            };
            defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);
            var transfer_buffer: [4096]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

            if (slot.fetch_response_mode == .stream) {
                // Frame the body into on_line entries as bytes arrive —
                // the spawn `.lines` contract over HTTP. A broken stream
                // surfaces through the terminal outcome; lines delivered
                // before the break stand.
                try self.streamFetchLines(slot, slot_index, generation, reader, &response);
                slot.body_len = 0;
                slot.fetch_truncated = false;
                slot.fetch_outcome = .ok;
                return;
            }

            const buffer = slot.fetch_buffer.?;
            var body_writer = std.Io.Writer.fixed(buffer[slot.payload_len..]);
            _ = reader.streamRemaining(&body_writer) catch |err| switch (err) {
                // The bounded body space filled: deliver the first
                // `max_effect_body_bytes` bytes with the flag set.
                error.WriteFailed => slot.fetch_truncated = true,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            };
            slot.body_len = body_writer.end;
            slot.fetch_outcome = .ok;
        }

        /// Line-frame a streaming fetch's body, mirroring `streamLines`:
        /// every '\n'-terminated line becomes one queued `on_line`
        /// entry, bounded by the slot's `line_limit` with truncation
        /// flagged; a trailing unterminated line is delivered at end of
        /// stream. Read failures propagate so the terminal outcome
        /// reports the break (cancel interruptions included — the drain
        /// rewrites those to `.cancelled` and filters queued lines).
        fn streamFetchLines(
            self: *Self,
            slot: *Slot,
            slot_index: u16,
            generation: u32,
            reader: *std.Io.Reader,
            response: *std.http.Client.Response,
        ) !void {
            var stack_buffer: [max_effect_line_bytes]u8 = undefined;
            const line_buffer: []u8 = slot.line_buffer orelse &stack_buffer;
            const limit = @min(slot.line_limit, line_buffer.len);
            var line_len: usize = 0;
            var truncated = false;
            while (true) {
                const byte = reader.takeByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
                };
                if (byte == '\n') {
                    self.produceLine(slot, slot_index, generation, line_buffer[0..line_len], truncated);
                    line_len = 0;
                    truncated = false;
                } else if (line_len < limit) {
                    line_buffer[line_len] = byte;
                    line_len += 1;
                } else {
                    truncated = true;
                }
            }
            if (line_len > 0 or truncated) {
                self.produceLine(slot, slot_index, generation, line_buffer[0..line_len], truncated);
            }
        }

        /// The terminal response must never be dropped: retry until the
        /// loop thread drains space, giving up only on shutdown.
        fn postResponse(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io) void {
            var entry: Entry = .{
                .kind = .response,
                .slot_index = slot_index,
                .generation = generation,
                .key = slot.key,
                .line_len = @intCast(slot.body_len),
                .truncated = slot.fetch_truncated,
                // Stream-mode lines dropped on a full queue that no
                // later line reported land on the terminal instead.
                .dropped_before = slot.dropped_pending,
                .status = slot.fetch_status,
                .outcome = slot.fetch_outcome,
                .response_fn = slot.on_response,
            };
            while (!self.enqueue(&entry)) {
                if (self.shutdown.load(.acquire)) return;
                self.wakeHost();
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }

        /// Exits must never be dropped: retry until the loop thread
        /// drains space, giving up only on shutdown.
        fn postExit(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io, exit: EffectExit) void {
            var entry: Entry = .{
                .kind = .exit,
                .slot_index = slot_index,
                .generation = generation,
                .key = exit.key,
                .code = exit.code,
                .reason = exit.reason,
                .dropped_lines = exit.dropped_lines,
                .exit_fn = slot.on_exit,
            };
            if (slot.output_mode == .collect) stampCollectExit(slot, &entry);
            while (!self.enqueue(&entry)) {
                if (self.shutdown.load(.acquire)) return;
                self.wakeHost();
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }

        // ------------------------------------------------------- file worker

        /// Supervises one file effect, mirroring `fetchWorkerMain`: the
        /// blocking read/write runs as a cancelable `Io` task that
        /// touches ONLY its out-of-line `FileWorkerContext`, never the
        /// channel. `cancel` does not interrupt the OS call: it marks
        /// the generation and the drain rewrites the terminal to
        /// `.cancelled` (the operation itself may still have completed
        /// on disk, as `EffectFileOutcome.cancelled` documents).
        /// Teardown is the one interrupter — past half its file
        /// deadline it sets `ctx.interrupt` and the supervisor cancels
        /// the task (the threaded io interrupts the blocked syscall
        /// where the platform allows it). After the task ends the
        /// supervisor COMMITS under the context's mutex — from that
        /// point it may touch the slot and queue, and teardown will
        /// join it — or finds itself abandoned and returns without
        /// touching the channel again, walking only the leaked
        /// context. On the healthy path exactly one `.file` terminal
        /// entry posts and the slot parks in `.draining` until the
        /// drain takes its buffer.
        fn fileWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io, ctx: *FileWorkerContext) void {
            supervise: {
                var future = std.Io.concurrent(io, fileTask, .{ ctx, io }) catch {
                    // No concurrent capacity: run the op inline.
                    // Teardown cannot interrupt it, only outwait or
                    // abandon it — the deadline still bounds deinit.
                    // (Deliberately unlike fetch, which REJECTS when
                    // its exchange cannot start cancellably: fetch
                    // joins are unconditional and unbounded, while a
                    // stuck file worker has the abandon safety net.)
                    fileTask(ctx, io);
                    break :supervise;
                };
                superviseWorkerTask(io, &future, &ctx.done, &ctx.interrupt);
            }
            ctx.mutex.lock();
            if (ctx.abandoned) {
                // Teardown gave up on this worker: the channel may
                // already be freed. The context (and the buffer the
                // task just used) is intentionally leaked and stays
                // valid forever — touch nothing else.
                ctx.mutex.unlock();
                return;
            }
            ctx.committed = true;
            ctx.mutex.unlock();
            // Committed: the channel is alive, and a concurrent
            // teardown now JOINS this thread instead of abandoning it.
            // The epilogue below touches the slot and queue freely and
            // converges within milliseconds (the terminal post gives
            // up on shutdown).
            const slot = &self.slots[slot_index];
            const outcome: EffectFileOutcome = if (ctx.done.load(.acquire)) ctx.outcome else .cancelled;
            // Publish a read's bytes into the slot's channel-owned
            // delivery buffer (what the drain hands to `update`): the
            // blocking phase filled only the context's process-lived
            // private buffer. Committed means teardown JOINS this
            // worker, so the slot buffer is safe to touch here.
            if (ctx.op == .read) {
                if (slot.fetch_buffer) |delivery| {
                    const publish_len = @min(ctx.read_len, delivery.len);
                    @memcpy(delivery[0..publish_len], ctx.buffer[0..publish_len]);
                }
            }
            slot.body_len = ctx.read_len;
            self.postFile(slot, @intCast(slot_index), generation, io, outcome, ctx.read_len);
            slot.state.store(.draining, .release);
            self.wakeHost();
        }

        /// Poll a worker's cancelable blocking task to completion:
        /// converge when the task records `done`, cancel it
        /// (best-effort syscall interruption through the threaded io)
        /// when teardown sets `interrupt`, and always await the future
        /// so the task's frame retires. Shared by the file and spawn
        /// supervisors; both flags live in the worker's process-lived
        /// context, so the poll itself is abandon-safe.
        fn superviseWorkerTask(io: std.Io, future: *std.Io.Future(void), done: *const std.atomic.Value(bool), interrupt: *const std.atomic.Value(bool)) void {
            const poll_ms: u64 = 5;
            while (true) {
                if (done.load(.acquire)) break;
                if (interrupt.load(.acquire)) {
                    future.cancel(io);
                    break;
                }
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_ms), .awake) catch {};
            }
            future.await(io);
        }

        /// The blocking file op as a cancelable task on the executor
        /// io. Touches only the leaked-on-abandon context and the io —
        /// never the slot, the queue, or the channel (see
        /// `FileWorkerContext`).
        fn fileTask(ctx: *FileWorkerContext, io: std.Io) void {
            ctx.outcome = runFileOp(ctx, io);
            ctx.done.store(true, .release);
        }

        fn runFileOp(ctx: *FileWorkerContext, io: std.Io) EffectFileOutcome {
            const cwd = std.Io.Dir.cwd();
            const file_path = ctx.path();
            switch (ctx.op) {
                .write => {
                    if (std.fs.path.dirname(file_path)) |parent| {
                        cwd.createDirPath(io, parent) catch |err| return fileOpFailure(err);
                    }
                    cwd.writeFile(io, .{
                        .sub_path = file_path,
                        .data = ctx.payload(),
                    }) catch |err| return fileOpFailure(err);
                    return .ok;
                },
                .read => {
                    var file = cwd.openFile(io, file_path, .{}) catch |err| {
                        return if (err == error.FileNotFound) .not_found else fileOpFailure(err);
                    };
                    defer file.close(io);
                    // The buffer has one byte past the delivery bound:
                    // filling it proves the file is over-bound.
                    const len = file.readPositionalAll(io, ctx.buffer, 0) catch |err| return fileOpFailure(err);
                    if (len > max_effect_file_bytes) {
                        ctx.read_len = max_effect_file_bytes;
                        return .truncated;
                    }
                    ctx.read_len = len;
                    return .ok;
                },
            }
        }

        /// An interrupted blocking op reports `.cancelled` (only
        /// teardown cancels the task); every other failure stays the
        /// blanket `.io_failed`.
        fn fileOpFailure(err: anyerror) EffectFileOutcome {
            return if (err == error.Canceled) .cancelled else .io_failed;
        }

        // ------------------------------------------------------ image worker

        /// Supervises one image load, mirroring `fetchWorkerMain`: the
        /// whole source cascade (local probe, cache read, network
        /// fetch, cache install) runs as ONE cancelable `Io` task,
        /// polled against `cancel`, `shutdown`, and the effect timeout.
        /// Unlike bare file effects — which have no deadline at all and
        /// need the abandon safety net — every blocking phase here is
        /// deadline-bounded: the timeout (or teardown) cancels the task
        /// the same way it cancels a fetch exchange, so teardown joins
        /// image workers unconditionally, exactly like fetch workers.
        fn imageWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io) void {
            const slot = &self.slots[slot_index];
            supervise: {
                var future = self.startImageExchange(slot, io) catch {
                    // Same refusal as fetch: an inline cascade would
                    // evade cancel, the timeout, and teardown's
                    // unconditional join.
                    slot.fetch_status = 0;
                    slot.body_len = 0;
                    slot.image_outcome = .rejected;
                    if (self.fetch_start_rejections.fetchAdd(1, .monotonic) == 0) {
                        std.debug.print(
                            "effects image: the executor could not start a cancelable load for image id {d}; rejecting the load (an inline cascade would evade cancel, the timeout, and teardown)\n",
                            .{slot.key},
                        );
                    }
                    break :supervise;
                };
                const poll_ms: u64 = 5;
                var waited_ms: u64 = 0;
                var timed_out = false;
                while (true) {
                    if (slot.fetch_done.load(.acquire)) break;
                    if (self.shutdown.load(.acquire) or slot.cancel_requested.load(.acquire)) {
                        future.cancel(io);
                        break;
                    }
                    if (waited_ms >= slot.timeout_ms) {
                        timed_out = true;
                        future.cancel(io);
                        break;
                    }
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(poll_ms), .awake) catch {};
                    waited_ms += poll_ms;
                }
                future.await(io);
                if (!slot.fetch_done.load(.acquire)) {
                    // Interrupted before the task recorded a terminal
                    // state (never expected — the task always records).
                    slot.fetch_status = 0;
                    slot.body_len = 0;
                    slot.image_outcome = if (timed_out) .timed_out else .cancelled;
                } else if (timed_out and slot.image_outcome != .loaded) {
                    // The interruption was the deadline, not the app:
                    // every non-staged outcome here is the timeout's
                    // doing. A cascade that staged its bytes before the
                    // deadline fired stays a delivered `.loaded`.
                    slot.image_outcome = .timed_out;
                    slot.fetch_status = 0;
                    slot.body_len = 0;
                }
            }
            self.postImage(slot, @intCast(slot_index), generation, io);
            slot.state.store(.draining, .release);
            self.wakeHost();
        }

        /// Start the blocking cascade as a cancelable task on the
        /// executor io — the only way it may run (see
        /// `startFetchExchange` for the contract). Shares the fetch
        /// injection switch so tests pin the rejection path.
        fn startImageExchange(self: *Self, slot: *Slot, io: std.Io) std.Io.ConcurrentError!std.Io.Future(void) {
            if (!self.fetch_concurrent_start) return error.ConcurrencyUnavailable;
            return std.Io.concurrent(io, imageTask, .{ self, slot, io });
        }

        /// The blocking cascade, run as a cancelable task. Always
        /// records a terminal source-stage state in the slot before
        /// `fetch_done`.
        fn imageTask(self: *Self, slot: *Slot, io: std.Io) void {
            defer slot.fetch_done.store(true, .release);
            self.runImageLoad(slot, io) catch |err| {
                slot.body_len = 0;
                slot.image_outcome = classifyImageFetchError(err);
            };
        }

        /// The source cascade, the `playAudio` resolution order made
        /// byte-producing: local file first (a MISSING file is the one
        /// local failure that falls through to the url — everything
        /// else is terminal, because retrying a different source would
        /// mask the real problem), then a verified cache entry, then
        /// the network with a cache install behind it. On success the
        /// encoded bytes sit in the slot buffer with
        /// `image_outcome == .loaded`; the drain decodes and registers
        /// them on the loop thread.
        fn runImageLoad(self: *Self, slot: *Slot, io: std.Io) !void {
            const buffer = slot.fetch_buffer.?;
            const cwd = std.Io.Dir.cwd();
            if (slot.image_path_len > 0) {
                if (cwd.openFile(io, slot.imagePath(), .{})) |file_value| {
                    var file = file_value;
                    defer file.close(io);
                    const len = file.readPositionalAll(io, buffer, 0) catch |err| {
                        slot.image_outcome = if (err == error.Canceled) .cancelled else .io_failed;
                        slot.body_len = 0;
                        return;
                    };
                    if (len > max_effect_image_bytes) {
                        slot.image_outcome = .too_large;
                        slot.body_len = 0;
                        return;
                    }
                    slot.body_len = len;
                    slot.image_outcome = .loaded;
                    return;
                } else |err| {
                    if (err == error.Canceled) {
                        slot.image_outcome = .cancelled;
                        slot.body_len = 0;
                        return;
                    }
                    if (err != error.FileNotFound or slot.url_len == 0) {
                        slot.image_outcome = if (err == error.FileNotFound) .not_found else .io_failed;
                        slot.body_len = 0;
                        return;
                    }
                    // Missing local file with a url: fall through.
                }
            }
            if (slot.image_cache_len > 0) {
                // The probe's only error is a spent cancel: terminate
                // `.cancelled` like the local-probe arm above — never
                // fall through to a network fetch the cancel can no
                // longer reach.
                const cached = self.readImageCache(slot, io, buffer) catch {
                    slot.image_outcome = .cancelled;
                    slot.body_len = 0;
                    return;
                };
                if (cached) return;
            }
            try self.fetchImageBytes(slot, io, buffer);
            if (slot.image_outcome == .loaded and slot.image_cache_len > 0) {
                self.installImageCache(slot, io, buffer[0..slot.body_len]);
            }
        }

        /// Probe the cache entry for a url source: it qualifies only
        /// when readable, within the source bound, and — when the
        /// caller declared `expected_bytes` — exactly that size (the
        /// integrity gate). Anything else falls through to the network,
        /// which refreshes the entry — except a cancel interruption,
        /// which propagates: cancel delivery is ONE-SHOT (the Canceled
        /// error return IS the delivery), so treating it as a cache
        /// miss would consume it and send a cancelled load into the
        /// network fetch with nothing left to interrupt it.
        fn readImageCache(self: *Self, slot: *Slot, io: std.Io, buffer: []u8) error{Canceled}!bool {
            _ = self;
            const cwd = std.Io.Dir.cwd();
            var file = cwd.openFile(io, slot.imageCache(), .{}) catch |err|
                return if (err == error.Canceled) error.Canceled else false;
            defer file.close(io);
            const len = file.readPositionalAll(io, buffer, 0) catch |err|
                return if (err == error.Canceled) error.Canceled else false;
            if (len == 0 or len > max_effect_image_bytes) return false;
            if (slot.image_expected_bytes != 0 and len != slot.image_expected_bytes) return false;
            slot.body_len = len;
            // `fetch_status` stays 0 on a cache hit: no HTTP exchange
            // occurred, and 0 says so honestly (the documented
            // `EffectImageResult.status` contract) — fabricating the
            // origin's 200 would claim an exchange that never happened.
            slot.image_outcome = .loaded;
            return true;
        }

        /// GET the url whole into the slot buffer, mirroring
        /// `runFetch`'s exchange discipline. Non-2xx statuses terminate
        /// as `.http_status` with the body discarded — an error page is
        /// not an image — and bodies over the source bound terminate
        /// `.too_large` whole (a cut image can never decode, so there
        /// is no truncated delivery).
        fn fetchImageBytes(self: *Self, slot: *Slot, io: std.Io, buffer: []u8) !void {
            const uri = try std.Uri.parse(slot.fetchUrl());
            var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
            defer client.deinit();
            var request = client.request(.GET, uri, .{
                .keep_alive = false,
                .redirect_behavior = @enumFromInt(3),
            }) catch |err| {
                // See `runFetch`: an untyped failure here is a connect
                // failure.
                if (err == error.Unexpected) return error.ConnectPhaseFailed;
                return err;
            };
            defer request.deinit();
            try request.sendBodiless();
            var redirect_buffer: [8 * 1024]u8 = undefined;
            var response = try request.receiveHead(&redirect_buffer);
            slot.fetch_status = @intFromEnum(response.head.status);
            if (response.head.status.class() != .success) {
                slot.image_outcome = .http_status;
                slot.body_len = 0;
                return;
            }
            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
                .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
                .compress => return error.UnsupportedCompressionMethod,
            };
            defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);
            var transfer_buffer: [4096]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
            var body_writer = std.Io.Writer.fixed(buffer);
            var over_bound = false;
            _ = reader.streamRemaining(&body_writer) catch |err| switch (err) {
                // The buffer's spare byte filled: the source is over
                // the bound, whole-failure by policy.
                error.WriteFailed => over_bound = true,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            };
            if (over_bound or body_writer.end > max_effect_image_bytes) {
                slot.image_outcome = .too_large;
                slot.body_len = 0;
                return;
            }
            slot.body_len = body_writer.end;
            slot.image_outcome = .loaded;
        }

        /// Best-effort cache install behind a successful fetch: write
        /// a writer-unique temp beside the cache path (see
        /// `imageCachePartialPath` — concurrent installs toward one
        /// cache path must never share a temp, across channels and
        /// processes included) and atomically rename into place, and
        /// only when `expected_bytes` (if declared) verifies — a
        /// partial or wrong-size download never occupies the cache
        /// name. Failures cost only the next load a re-fetch, and a
        /// failed install deletes its own temp so the cache directory
        /// never accumulates this process's debris; only a hard crash
        /// mid-install can leave one behind, in the OS-purgeable
        /// caches directory.
        fn installImageCache(self: *Self, slot: *Slot, io: std.Io, bytes: []const u8) void {
            _ = self;
            if (slot.image_expected_bytes != 0 and bytes.len != slot.image_expected_bytes) return;
            const cache_path = slot.imageCache();
            const cwd = std.Io.Dir.cwd();
            if (std.fs.path.dirname(cache_path)) |parent| {
                cwd.createDirPath(io, parent) catch return;
            }
            // The uniqueness token comes from the operation's own
            // executor io — the CSPRNG seam every worker already
            // carries — so the name is unique across channels and
            // processes, not merely within this channel's generation
            // counter. Freestanding builds never reach this function
            // (no executor io exists there to run a worker), so the
            // entropy source needs no target gate.
            var token_bytes: [8]u8 = undefined;
            io.random(&token_bytes);
            const token = std.mem.readInt(u64, &token_bytes, .little);
            var partial_buffer: [max_effect_image_path_bytes + 48]u8 = undefined;
            const partial_path = imageCachePartialPath(&partial_buffer, cache_path, slot.generation, token) catch return;
            cwd.writeFile(io, .{ .sub_path = partial_path, .data = bytes }) catch {
                cwd.deleteFile(io, partial_path) catch {};
                return;
            };
            cwd.rename(partial_path, cwd, cache_path, io) catch {
                cwd.deleteFile(io, partial_path) catch {};
            };
        }

        /// The terminal image entry must never be dropped: retry until
        /// the loop thread drains space, giving up only on shutdown.
        fn postImage(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io) void {
            var entry: Entry = .{
                .kind = .image,
                .slot_index = slot_index,
                .generation = generation,
                .key = slot.key,
                .line_len = @intCast(slot.body_len),
                .status = slot.fetch_status,
                .image_outcome = slot.image_outcome,
                .image_fn = slot.on_image,
            };
            while (!self.enqueue(&entry)) {
                if (self.shutdown.load(.acquire)) return;
                self.wakeHost();
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }

        /// The terminal file result must never be dropped: retry until
        /// the loop thread drains space, giving up only on shutdown.
        fn postFile(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io, outcome: EffectFileOutcome, read_len: usize) void {
            var entry: Entry = .{
                .kind = .file,
                .slot_index = slot_index,
                .generation = generation,
                .key = slot.key,
                .line_len = @intCast(read_len),
                .file_op = slot.file_op,
                .file_outcome = outcome,
                .file_fn = slot.on_file,
            };
            while (!self.enqueue(&entry)) {
                if (self.shutdown.load(.acquire)) return;
                self.wakeHost();
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }
    };
}

test "effect payload types have documented defaults" {
    const line: EffectLine = .{ .key = 7, .line = "hello" };
    try std.testing.expect(!line.truncated);
    try std.testing.expectEqual(@as(u32, 0), line.dropped_before);
    const exit: EffectExit = .{ .key = 7 };
    try std.testing.expectEqual(EffectExitReason.exited, exit.reason);
    try std.testing.expectEqual(@as(u32, 0), exit.dropped_lines);
    try std.testing.expectEqualStrings("", exit.output);
    try std.testing.expect(!exit.output_truncated);
    try std.testing.expectEqualStrings("", exit.stderr_tail);
    try std.testing.expect(!exit.stderr_truncated);
    const response: EffectResponse = .{ .key = 7 };
    try std.testing.expectEqual(EffectFetchOutcome.ok, response.outcome);
    try std.testing.expectEqual(@as(u16, 0), response.status);
    try std.testing.expectEqualStrings("", response.body);
    try std.testing.expect(!response.truncated);
    try std.testing.expectEqual(@as(u32, 0), response.dropped_before);
    const file_result: EffectFileResult = .{ .key = 7 };
    try std.testing.expectEqual(EffectFileOp.read, file_result.op);
    try std.testing.expectEqual(EffectFileOutcome.ok, file_result.outcome);
    try std.testing.expectEqualStrings("", file_result.bytes);
    try std.testing.expectEqual(@as(u32, 0), file_result.dropped_before);
    const timer: EffectTimer = .{ .key = 7 };
    try std.testing.expectEqual(@as(u64, 0), timer.timestamp_ns);
    try std.testing.expectEqual(EffectTimerOutcome.fired, timer.outcome);
}

test "fx timer platform ids stay inside the reserved range and clear of the markup watch id" {
    try std.testing.expect(effect_timer_platform_id_base >= platform.reserved_timer_id_base);
    try std.testing.expect(effect_timer_platform_id_base + max_effect_timers - 1 < 0xffff_ffff_2e70_a11c);
}

test "image cache probe propagates a cancel interruption and reads every other failure as a miss" {
    const TestMsg = union(enum) { result: EffectImageResult };
    const Channel = Effects(TestMsg);
    const Fakes = struct {
        fn openCanceled(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            _ = userdata;
            _ = dir;
            _ = sub_path;
            _ = options;
            return error.Canceled;
        }
        fn openOk(userdata: ?*anyopaque, dir: std.Io.Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            _ = userdata;
            _ = dir;
            _ = sub_path;
            _ = options;
            return .{ .handle = 0, .flags = .{ .nonblocking = false } };
        }
        fn readCanceled(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            _ = userdata;
            _ = file;
            _ = data;
            _ = offset;
            return error.Canceled;
        }
        fn closeNoop(userdata: ?*anyopaque, files: []const std.Io.File) void {
            _ = userdata;
            _ = files;
        }
    };

    var slot: Channel.Slot = .{};
    const cache_path = "caches/images/probe.png";
    @memcpy(slot.image_cache_storage[0..cache_path.len], cache_path);
    slot.image_cache_len = cache_path.len;
    var buffer: [32]u8 = undefined;

    // Cancel delivery is one-shot: a cancel that interrupts the probe's
    // open IS the delivery, so the probe must surface it — reading it
    // as a miss would send the cancelled load into the network fetch
    // with nothing left to interrupt.
    var open_cancel_vtable = std.Io.failing.vtable.*;
    open_cancel_vtable.dirOpenFile = Fakes.openCanceled;
    const open_cancel_io: std.Io = .{ .userdata = null, .vtable = &open_cancel_vtable };
    try std.testing.expectError(error.Canceled, Channel.readImageCache(undefined, &slot, open_cancel_io, &buffer));

    // A cancel landing in the positional read, same contract.
    var read_cancel_vtable = std.Io.failing.vtable.*;
    read_cancel_vtable.dirOpenFile = Fakes.openOk;
    read_cancel_vtable.fileReadPositional = Fakes.readCanceled;
    read_cancel_vtable.fileClose = Fakes.closeNoop;
    const read_cancel_io: std.Io = .{ .userdata = null, .vtable = &read_cancel_vtable };
    try std.testing.expectError(error.Canceled, Channel.readImageCache(undefined, &slot, read_cancel_io, &buffer));

    // Every other failure stays an honest miss that falls through to
    // the network (`std.Io.failing`'s empty filesystem opens report
    // FileNotFound).
    try std.testing.expectEqual(false, try Channel.readImageCache(undefined, &slot, std.Io.failing, &buffer));
}

test "fetch errors map onto the documented taxonomy" {
    try std.testing.expectEqual(EffectFetchOutcome.cancelled, classifyFetchError(error.Canceled));
    try std.testing.expectEqual(EffectFetchOutcome.connect_failed, classifyFetchError(error.ConnectionRefused));
    try std.testing.expectEqual(EffectFetchOutcome.connect_failed, classifyFetchError(error.UnknownHostName));
    try std.testing.expectEqual(EffectFetchOutcome.tls_failed, classifyFetchError(error.TlsInitializationFailed));
    try std.testing.expectEqual(EffectFetchOutcome.rejected, classifyFetchError(error.UnsupportedUriScheme));
    try std.testing.expectEqual(EffectFetchOutcome.protocol_failed, classifyFetchError(error.HttpHeadersInvalid));
}
