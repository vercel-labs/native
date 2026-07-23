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
const pty_transport = @import("pty.zig");

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

/// Teardown budget for one channel's in-flight host wake call (see
/// `Effects.channel_wake_join_deadline_ms` and `quiesceChannelWake`).
/// A CONFORMING `wake_fn` is a bounded enqueue that returns in
/// microseconds (the contract at `PlatformServices.wake_fn`), so this
/// deadline is violator containment, not a wait any supported hook
/// meets: a hook still inside the call after five seconds is stuck
/// behind something teardown cannot service (typically a synchronous
/// marshal against the stopping loop — a contract violation) and is
/// abandoned with a warning rather than hanging teardown forever.
pub const default_channel_wake_join_deadline_ms: u64 = 5_000;

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

/// Type-erased handle to the runtime's media-surface texture channels,
/// bound onto the effects channel (`bindMediaSurfaces`) so `loadVideo`
/// can claim the surface a `<video>` widget binds and hand its frame
/// sink to the platform decoder — without reaching for the runtime.
/// Constructed by `Runtime.mediaSurfaceBinding()`. `acquire_fn` is
/// loop-thread-only (it claims runtime-owned channel state) and answers
/// the copyable `platform.VideoFrameSink` the decoder pushes through;
/// LOOP-THREAD-ONLY, both halves: acquire touches the runtime's claim
/// tables, and release purges the runtime's adopted-texture entry (and
/// the host's copied side-channel texture) for the ended playback —
/// loop-thread runtime state throughout. That matches every caller:
/// the video channel acquires in `loadVideo` and releases in
/// stop/replace/failure/teardown, all `update`-dispatch paths.
/// Producer THREADS never touch the binding — they hold the copyable
/// `VideoFrameSink`, whose `push` is the any-thread half.
/// `release_fn` ends the claim named by a previously acquired sink
/// (idempotent — the sink carries its claim generation).
pub const MediaSurfaceBinding = struct {
    context: *anyopaque,
    acquire_fn: *const fn (context: *anyopaque, surface_id: u64) anyerror!platform.VideoFrameSink,
    release_fn: *const fn (context: *anyopaque, sink: platform.VideoFrameSink) void,
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

/// Longest video source string (path or url) `loadVideo` accepts,
/// mirroring the platform bound. Longer strings deliver exactly one
/// `.rejected` video event Msg.
pub const max_effect_video_path_bytes: usize = platform.max_video_path_bytes;

/// Upper bound (exclusive) for every video scalar the channel delivers
/// — position, duration, width, height: the exact-integer window every
/// delivery tier can carry (the TS tier rides these through f64, whose
/// exact integers end at 2^53). Platform video events clamp into the
/// window at the delivery boundary (`takeVideoMsg`), whatever a host or
/// embedder reports — the engine-side guarantee behind session replay's
/// damage gate: a recorded video scalar at or past this bound can only
/// be a damaged or hand-edited journal, never an honest readout.
pub const max_effect_video_scalar_exclusive: u64 = 1 << 53;

/// How a video event Msg came to be — the audio vocabulary plus the
/// stream's decoded dimensions on `loaded`. `loaded` acknowledges a
/// successful `loadVideo` with the platform player's duration readout
/// (an estimate, exactly like audio's) and the stream's pixel
/// dimensions; `position` ticks at the platform's coarse honest cadence
/// (~500ms) only while playing, carrying the stream's `buffering` flag;
/// `completed` fires exactly once when a NON-LOOPING video reaches its
/// natural end (a looping playback wraps and keeps ticking — it never
/// completes); `failed` reports a load/decode/device failure or a
/// platform without video playback — always a Msg, never a crash and
/// never silence; `rejected` reports a command the effects layer
/// refused before the platform was asked (an empty or oversized source,
/// a non-http(s) url, an invalid surface id). Pixels never ride these
/// events: decoded frames flow platform-side into the media-surface
/// texture channel the load named.
pub const EffectVideoEventKind = enum(u8) {
    loaded,
    position,
    completed,
    failed,
    rejected,
};

/// Payload for `on_event` Msg constructors of video effects. Positions
/// and durations are milliseconds; `playing`/`buffering` carry the
/// audio payload's exact semantics; `width`/`height` are the stream's
/// decoded pixel dimensions (delivered on `.loaded`, 0 elsewhere — the
/// channel mirrors keep them for the snapshot). All fields are plain
/// data — safe to store in the model.
pub const EffectVideo = struct {
    key: u64,
    kind: EffectVideoEventKind,
    position_ms: u64 = 0,
    duration_ms: u64 = 0,
    playing: bool = false,
    buffering: bool = false,
    width: u64 = 0,
    height: u64 = 0,
};

/// Where the active video playback's bytes come from — the resolved end
/// of the `loadVideo` source cascade (local file, then network stream).
/// Exposed in the snapshot and the fake executor's request so tests and
/// automation can pin the resolution order.
pub const EffectVideoSource = enum(u8) {
    local,
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

/// How many external-source channels (`openChannel`) may be open at
/// once. Channels are LONG-LIVED occupancies (open until close
/// delivers), so they live in their own fixed table beside the effect
/// slots — like timers and audio — while still sharing the keyed
/// families' one key space.
pub const max_effect_channels: usize = 8;

/// Largest single `ChannelHandle.post` payload. Channel posts are
/// small-message-shaped (sensor readings, socket frames, watcher
/// notifications) — the spawn line bound is the honest ceiling, and it
/// keeps a post inside one completion-queue entry and one inline
/// journal record. Oversized posts answer `.dropped_oversized` and
/// count as drops.
pub const max_effect_channel_bytes: usize = max_effect_line_bytes;

/// Staged posts one channel holds between drains. The staging FIFO is
/// NON-LOSSY: nothing already staged is ever evicted — a full stage
/// makes `post` answer `.dropped_full` and counts the drop, and the
/// next delivered event carries the counts (never silence, never a
/// stall of the posting thread).
pub const max_effect_channel_pending: usize = 32;

/// In-flight ptys (interactive terminal sessions) per Effects channel —
/// their own table beside the channel table: a pty is a long-lived keyed
/// occupancy like a channel, not a run-to-completion worker slot. One
/// live terminal surface plus a background job or two is the realistic
/// shape; a fifth spawn is refused loudly (reason `.rejected`).
pub const max_effect_ptys: usize = 4;
/// Longest one delivered pty output record: one Msg payload, one
/// journal blob. Output arriving between drains coalesces into batches
/// of at most this size — `cat largefile` journals per-drain batches,
/// never per-read records.
pub const max_effect_pty_chunk_bytes: usize = 64 * 1024;
/// The cross-thread output staging ring per pty. When it fills, the io
/// thread stops reading the parent end until the loop drains — kernel
/// back-pressure to the child, a terminal's native flow control. Bytes
/// are NEVER dropped: a fast producer is slowed, not lied to.
pub const max_effect_pty_staging_bytes: usize = 256 * 1024;
/// Largest one `ptyWrite` accepts: keystrokes and pastes, not bulk
/// transfers (the spawn stdin bound, same teaching). Over-bound writes
/// are refused whole and counted — a cut keystroke sequence would
/// corrupt the child's input stream.
pub const max_effect_pty_write_bytes: usize = 4096;
/// Outbound (child stdin) staging between the loop thread and the io
/// thread. A child that stops reading fills it; further writes are
/// refused and counted into `EffectPtyEvent.dropped_writes` on the
/// exit event — never silence.
pub const max_effect_pty_outbound_bytes: usize = 64 * 1024;
/// Distinct un-fully-sent `ptyWrite` payloads the outbound FIFO holds
/// (see `PtyShared.out_write_lens`) — an admission bound alongside the
/// byte budget, so every accepted write owns an exact length record and
/// `dropped_writes` counts payloads precisely. A write past it is
/// refused and counted, exactly like a full byte buffer; realistic
/// input is a handful of small writes in flight, so only a child that
/// stopped reading entirely reaches it.
pub const max_effect_pty_write_records: usize = 256;
/// Longest TERM value `ptySpawn` accepts.
pub const max_effect_pty_term_bytes: usize = 32;
/// Bytes of `ptyWrite` input a FAKE pty retains for test assertions
/// (`ptyWrittenBytes`) — the scriptable pty's inspection window, not a
/// delivery bound: writes beyond it drop oldest-first, exactly what a
/// test inspecting "what did the app type" wants.
pub const max_effect_pty_write_capture_bytes: usize = 4096;

/// What one pty event Msg reports. `.output` carries a coalesced batch
/// of child output bytes; `.exit` is the exactly-one terminal every
/// accepted (and every refused) `ptySpawn` produces.
pub const EffectPtyEventKind = enum(u8) {
    output,
    exit,
    /// Journal-only: one `ptyWrite` admission verdict (accepted rides the
    /// record's `code`, 1/0). The verdict is EXECUTOR TRUTH — whether the
    /// outbound FIFO and record ring had room depends on how fast the
    /// child was reading — so replay must feed the recorded verdicts
    /// rather than recompute them against a fake with no child. Never
    /// delivered as an event: no `EffectPtyEvent` ever carries this kind.
    write,
};

/// Payload for `on_event` Msg constructors of pty effects. `bytes` is
/// drain scratch, valid only during the `update` call that receives it
/// — copy what the model keeps (feed it to the terminal emulator and
/// move on). The exit taxonomy reuses the spawn vocabulary: `.exited`
/// with the child's code, `.signaled` with the signal, `.cancelled`
/// after `ptyKill`, `.rejected` for requests refused before a child
/// existed, `.spawn_failed` when the pty or exec could not start.
pub const EffectPtyEvent = struct {
    key: u64,
    kind: EffectPtyEventKind = .output,
    bytes: []const u8 = "",
    /// `.exit`: the child's exit code for a normal `.exited` end; -1 for
    /// every non-`.exited` reason. One documented exception carries -1
    /// WITH `.exited`: the child exited on its own but was reaped OUTSIDE
    /// the toolkit before `waitpid` could read its status — only
    /// reachable when an embedder installs `SA_NOCLDWAIT`, ignores
    /// `SIGCHLD`, or runs its own reaper for the toolkit's children (the
    /// toolkit forks the pty child and is its sole reaper, and never
    /// touches SIGCHLD disposition). In that already-broken case the
    /// real code is genuinely unrecoverable, so -1 is the honest
    /// "unknown"; a session the toolkit actually reaps always carries
    /// the real code.
    code: i32 = effect_error_exit_code,
    /// `.exit`: how the pty ended.
    reason: EffectExitReason = .exited,
    /// `.exit` after a fatal signal: the signal number, else 0.
    signal: i32 = 0,
    /// `.exit`: `ptyWrite` payloads refused over the pty's lifetime
    /// (outbound staging full, or a single write over
    /// `max_effect_pty_write_bytes`). Zero means every write reached
    /// the child.
    dropped_writes: u32 = 0,
};

/// What one channel event Msg reports. `.data` is one delivered post;
/// `.closed` is the exactly-one terminal `closeChannel` produces (final
/// drop totals aboard); `.rejected` is the exactly-one terminal a
/// refused `openChannel` produces (duplicate occupied key, full channel
/// table, or an executor that could not stage the channel).
pub const EffectChannelEventKind = enum(u8) {
    data,
    closed,
    rejected,
};

/// Payload for `on_event` Msg constructors of external-source channels.
/// `bytes` is drain scratch, valid only during the `update` call that
/// receives it — copy what the model keeps. `dropped_pending` counts
/// posts refused since the previous delivered event on this channel;
/// `dropped_total` is the occupancy's cumulative count — back-pressure
/// is part of the contract, reported honestly, never silent.
pub const EffectChannelEvent = struct {
    key: u64,
    kind: EffectChannelEventKind = .data,
    bytes: []const u8 = "",
    dropped_pending: u32 = 0,
    dropped_total: u32 = 0,
};

/// One channel's cross-thread staging FIFO: fixed entries, never
/// evicted (see `max_effect_channel_pending`). Allocated from
/// `process_allocator` per open occupancy and freed when the `.closed`
/// terminal delivers (or at teardown) — the loop thread frees it only
/// after `open` was cleared under the mutex, so no post can still be
/// copying into it.
const ChannelStaging = struct {
    head: usize = 0,
    len: usize = 0,
    lens: [max_effect_channel_pending]u32 = @splat(0),
    seqs: [max_effect_channel_pending]u64 = @splat(0),
    data: [max_effect_channel_pending][max_effect_channel_bytes]u8 = undefined,
};

/// The owner-side references a post may touch WHILE THE CHANNEL IS
/// OPEN: the shared post-order stamp and the pending mirror behind
/// `hasPending`. The validity argument is the mutex: every close path
/// (closeChannel, teardown) clears `open` under `ChannelShared.mutex`
/// before the owner can be freed, and a post reads these only after
/// observing `open` under that same mutex — so a post that may touch
/// the owner holds the lock the close must first acquire. The host
/// wake lives in `ChannelWake`, never here: nothing behind the staging
/// mutex may call into the host.
const ChannelOwnerRefs = struct {
    seq: *std.atomic.Value(u64),
    pending: *std.atomic.Value(usize),
};

/// The producer-to-loop wake binding, one per channel header, guarded
/// by its OWN spin mutex — never `ChannelShared.mutex`, whose guarded
/// sections must stay bounded memcpys: the wake path calls into the
/// platform host, and holding the staging mutex across that call would
/// stall every drain, close, and teardown behind a slow (or blocking)
/// host wake hook. This is the media-surface producer's data/wake
/// split (`MediaSurfaceWake` in media_surface.zig).
///
/// One deliberate DEPARTURE from the media-surface pattern: the host
/// call itself runs with `mutex` FREE. Media-surface could hold its
/// wake mutex through the call because its frame-request
/// implementations are enqueue-only BY CONTRACT; this seam calls the
/// EMBEDDER-supplied `wake_fn`, where the same contract exists (see
/// `PlatformServices.wake_fn`: bounded, non-blocking, enqueue-only)
/// but cannot be enforced — so the lock discipline assumes a
/// violator. An embedder wake that synchronously marshals to the loop
/// thread would wait for a loop that is itself waiting on this mutex
/// (`drainBoundary` takes it at every pass boundary): deadlock. So a
/// post marks itself in flight under the mutex, RELEASES, invokes the
/// host, then re-acquires to clear — `mutex` is only ever held for
/// bounded field access, and no lock the loop thread takes is ever
/// held across `wake_fn`. A violating wake therefore hangs only its
/// own posting thread; it can never entangle the runtime's lock
/// graph.
///
/// Ownership story (the abandon-fence doctrine, ditto): `services`
/// points at the owning Effects' late-bound services field, and the
/// teardown fence is `in_flight`. Every close path (closeChannel,
/// terminal retire, teardown) REVOKES the binding under `mutex` AFTER
/// clearing `open` under the staging mutex — a later post fails the
/// generation gate before it could increment `in_flight`, so no new
/// host call can start. Only TEARDOWN additionally waits (bounded)
/// for `in_flight` to reach zero, because only teardown outlives the
/// host: mid-life closes leave an in-flight `wake_fn` to finish on
/// its own time against services that stay alive (see
/// `revokeChannelWake` vs `quiesceChannelWake` for the split and the
/// marshal deadlock it prevents). Either way a stale handle's post
/// can never wake a dead host.
const ChannelWake = struct {
    mutex: SpinMutex = .{},
    /// The occupancy this binding serves (the header's generation): a
    /// post wakes only when its handle's generation matches, so a
    /// stale producer of a closed — or reopened — channel can never
    /// wake the loop spuriously.
    generation: u64 = 0,
    /// The owning Effects' ATOMIC services mirror (`wake_services` — a
    /// pointer to the mirror, so a channel opened before
    /// `bindServices` still wakes once the binding publishes), or null
    /// while disarmed. Posting threads load through it with seq_cst —
    /// the load side of the bind/post store-buffer handshake (see
    /// `Effects.bindServices` for why release/acquire cannot carry
    /// it); the plain `services` field stays loop-thread-only. This
    /// pointer reaches into Effects (Runtime-owned) memory, but only
    /// under `mutex`, and that is the validity argument: every close
    /// path revokes it under the same mutex before the Effects can be
    /// freed, so a reader either holds the lock the revoke must first
    /// acquire or observes null. What the load PRODUCES — the
    /// `PlatformServices` the poster dereferences with the mutex
    /// free — is the published services snapshot, never Runtime
    /// memory: freed only after a clean teardown proves no poster can
    /// hold it, and kept process-lived past an abandon (see
    /// `Effects.wake_snapshot`).
    services: ?*const std.atomic.Value(?*const platform.PlatformServices) = null,
    /// A latched wake has not yet reached a drain pass: the wake
    /// coalescer (`MediaSurfaceWake.pending`, channel-shaped). Set by
    /// the first accepted post, suppressing further host wakes until
    /// `drainBoundary` clears it BEFORE snapshotting the post order —
    /// so a burst of accepted posts costs at most one host wake, and a
    /// post racing the drain always lands either inside the pass's
    /// snapshot or a fresh wake of its own. Per-channel, like
    /// MediaSurfaceWake's per-slot flag: the coalescer rides the
    /// binding it guards (same generation fence, same revoke sweep),
    /// and the drain structure supports it because every pass sweeps
    /// all channel slots at its boundary. Atomic so posts can check it
    /// WITHOUT the wake mutex (see `requestHostWake` for why that
    /// lock-free fast path matters); mutations happen under the mutex.
    pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Posts currently INSIDE the embedder's `wake_fn` — the teardown
    /// fence (see the header doc: the host call runs with `mutex`
    /// free). Incremented under `mutex` before the call, decremented
    /// under `mutex` after it returns; `quiesceChannelWake` clears the
    /// binding under `mutex` and then waits (bounded) for zero, so a
    /// quiesce that returns true means "no producer is inside the
    /// host call". Mid-life closes never wait on this counter
    /// (`revokeChannelWake`). A counter, not a flag: the pass-boundary
    /// coalescer clear can let a second post latch and call while a
    /// slow first call is still in flight.
    in_flight: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// The thread-shared half of one channel table slot — the block a
/// `ChannelHandle` resolves through. Allocated from `process_allocator`
/// the first time its slot opens and DELIBERATELY NEVER FREED (the
/// abandoned-worker invariant): the app's posting threads are the
/// app's, nothing here can join them, so a handle may call `post` at
/// any later time — including after `closeChannel` and after the whole
/// runtime tore down — and everything that call can reach must stay
/// allocated forever. The leak is bounded (one ~200-byte header per
/// channel slot per Effects instance; the multi-KiB staging FIFO is
/// separate and freed on close) and the post-after-death answer is a
/// plain `.closed` through the header's `open`/`generation` gate, never
/// a use-after-free.
pub const ChannelShared = struct {
    /// The staging mutex. LOCK-ORDER INVARIANT: this mutex is NEVER
    /// held across a host callback. The host wake lives in `wake`,
    /// behind its own mutex, taken only AFTER this one is released —
    /// the two never nest, in either order. Drain, close, and teardown
    /// all contend here, so a wake hook that is slow, blocks, or
    /// synchronizes against the loop thread must never be able to
    /// stall (or deadlock) them; every guarded section below is a
    /// bounded copy of at most one staged post. The media-surface
    /// producer's data/wake split (`MediaSurfaceWake`), matched
    /// exactly.
    mutex: SpinMutex = .{},
    /// Posts are accepted only while set. Cleared under the mutex by
    /// every close path before anything a post could reach is freed.
    open: bool = false,
    /// The occupancy this block currently serves; a handle stamped
    /// with an older generation posts into nothing (answers `.closed`).
    /// u64, channel-owned and monotonic (see `ChannelHandle.generation`).
    generation: u64 = 0,
    /// The occupancy's effective staging bound (1..max_effect_channel_pending).
    max_pending: u32 = max_effect_channel_pending,
    /// Posts refused since the last delivered event / over the whole
    /// occupancy. Producer- and consumer-shared, guarded by `mutex`.
    dropped_pending: u32 = 0,
    dropped_total: u32 = 0,
    staging: ?*ChannelStaging = null,
    /// Valid only while `open` (see `ChannelOwnerRefs`).
    owner: ?ChannelOwnerRefs = null,
    /// The host-wake binding (its own mutex; see `ChannelWake` for the
    /// ownership story and the lock-order invariant on `mutex`).
    wake: ChannelWake = .{},
};

/// The THREAD-SAFE posting handle `openChannel` returns: the one
/// sanctioned way an app-owned thread (socket reader, file watcher,
/// worker) wakes the UI loop and produces a Msg. Plain copyable value —
/// hand it to the source thread and post away. Lifetime by
/// construction, not discipline: the handle resolves through a
/// generation-stamped process-lifetime header (`ChannelShared`), never
/// a raw pointer into a table slot, so a post after `closeChannel`,
/// after the slot was reused by a later `openChannel`, or after the
/// runtime itself tore down answers `.closed` safely instead of
/// touching freed memory.
pub const ChannelHandle = struct {
    shared: ?*ChannelShared = null,
    /// The occupancy this handle serves. u64 from the channel-owned
    /// monotonic counter, NEVER the shared u32 effect counter: the
    /// permanent-`.closed` guarantee is absolute, and a u32 that wraps
    /// after 2^32 occupancies would let a long-lived stale handle
    /// match a reused slot and post into some other producer's channel
    /// — the media-surface producer handle draws the same line with
    /// the same width (`MediaSurfaceProducer.generation`).
    generation: u64 = 0,

    /// What one `post` answered — the producer's whole contract in one
    /// value, because "try again later" and "stop forever" demand
    /// different responses and a producer must never have to guess.
    /// The two drop answers are distinct members for the same teaching
    /// reason `.rejected` is distinct from `.closed`: they name
    /// different producer mistakes with different remedies — a full
    /// stage is transient back-pressure (skip this message and keep
    /// producing; the consumer's next drain relieves it), an oversized
    /// payload is a programming error no retry will fix (bound your
    /// bytes at `max_effect_channel_bytes`). Both count into the drop
    /// counters the next delivered event carries, exactly as before.
    pub const PostResult = enum {
        /// Staged: exactly one `.data` event Msg delivers on the next
        /// drain.
        accepted,
        /// The staging FIFO is full (`max_pending`). Transient: nothing
        /// staged, the drop counted — skip this message and keep going.
        dropped_full,
        /// `bytes` exceeds `max_effect_channel_bytes`. Permanent for
        /// this payload: nothing staged, the drop counted — a retry of
        /// the same bytes can never land.
        dropped_oversized,
        /// The occupancy is over — `closeChannel` ran, the slot was
        /// reused by a later open, the open itself was refused, the
        /// runtime tore down, or the session is a replay (the handle is
        /// inert there; the journaled events are the whole stream).
        /// Nothing staged, nothing counted: a well-behaved producer
        /// thread exits its loop on this answer.
        closed,
    };

    /// Whether this handle can CURRENTLY accept posts: the channel is
    /// open and the occupancy is this handle's. False for a refused
    /// open's dead handle, a closed (or reused) occupancy, a torn-down
    /// runtime — and for every handle `openChannel` returns under
    /// SESSION REPLAY, where the open parks and the journaled events
    /// are the whole stream. That last answer is the method's reason
    /// to exist: it is the producer-launch check. A replayed session
    /// re-executes the update that opened the channel, so a producer
    /// launched unconditionally really starts — socket connects and
    /// blocking setup before its first post DO happen — and is only
    /// stopped when that first post answers `.closed`. A producer that
    /// consults `live()` before launching skips all of it and keeps
    /// replay fully offline.
    ///
    /// ADVISORY for that launch decision, never a gate on posting:
    /// the channel can close between this answer and the next post,
    /// so the post's own `PostResult` remains the authoritative answer
    /// and a producer loop still exits on `.closed`.
    /// Callable from any thread.
    pub fn live(handle: ChannelHandle) bool {
        const shared = handle.shared orelse return false;
        shared.mutex.lock();
        defer shared.mutex.unlock();
        return shared.open and shared.generation == handle.generation;
    }

    /// Stage `bytes` for delivery as one `.data` event Msg on the next
    /// drain, and — for an ACCEPTED post only — wake the host loop.
    /// Wakes COALESCE: the first accepted post latches one host wake
    /// and a burst rides it (the drain unlatches before it snapshots),
    /// so a fast producer costs the host loop's queue at most one
    /// entry per drain, never a backlog of redundant wakes.
    /// Callable from ANY thread. Never silently drops a delivered
    /// event, and never blocks GIVEN a conforming host wake: the
    /// guarantee is two-sided — `post`'s own work is bounded lock-held
    /// copies, and the one call that leaves the runtime, the host
    /// `wake_fn`, is contractually a bounded, non-blocking, enqueue-only
    /// nudge (see `PlatformServices.wake_fn`; every first-party
    /// implementation conforms). The runtime holds no channel lock
    /// across that call (`ChannelWake.in_flight` is the teardown fence,
    /// not lock tenure), so a violating embedder wake hangs in its own
    /// stack on the posting thread WITHOUT entangling the runtime's
    /// lock graph: a post can never hold a lock the loop thread is
    /// waiting on, and even a wake that synchronizes with the loop
    /// cannot deadlock a drain, close, or teardown against this
    /// call. The answer says exactly what happened (see
    /// `PostResult`) — `.dropped_full` and `.dropped_oversized` count
    /// into the drop counters the next delivered event carries;
    /// `.closed` counts nothing and ends the producer's occupancy for
    /// good. Refused and closed posts never wake: a wake is issued
    /// only when a post makes new work drainable, so a producer loop
    /// that keeps going through drops (the documented pattern) cannot
    /// flood the host loop's queue.
    pub fn post(handle: ChannelHandle, bytes: []const u8) PostResult {
        const shared = handle.shared orelse return .closed;
        {
            shared.mutex.lock();
            defer shared.mutex.unlock();
            if (!shared.open or shared.generation != handle.generation) return .closed;
            // Open implies the owner references are alive (see
            // `ChannelOwnerRefs`) and staging is installed.
            const owner = shared.owner.?;
            const staging = shared.staging.?;
            if (bytes.len > max_effect_channel_bytes or staging.len >= shared.max_pending) {
                shared.dropped_pending +|= 1;
                shared.dropped_total +|= 1;
                // NO wake for a refusal — the invariant of this whole post
                // site is that a wake is issued only when a post makes new
                // work drainable. A full stage proves staged entries exist
                // whose accepted posts already latched the wake, and the drop
                // counters ride the next delivered event with no extra
                // nudge; an oversized post stages nothing, so there is
                // nothing to drain. Waking here would let a producer that
                // keeps posting after `.dropped_full` — the documented
                // producer contract — grow the host loop's queue without
                // bound, defeating the bounded stage's back-pressure.
                // (`.closed` answers above are pure no-ops for the same
                // reason: nothing staged, nothing to drain.)
                return if (bytes.len > max_effect_channel_bytes) .dropped_oversized else .dropped_full;
            }
            // seq_cst: the coalescer's correctness argument orders this
            // stamp against the drain's clear-then-snapshot (see
            // `requestHostWake` and `drainBoundary`).
            const seq = owner.seq.fetchAdd(1, .seq_cst);
            const index = (staging.head + staging.len) % max_effect_channel_pending;
            staging.lens[index] = @intCast(bytes.len);
            staging.seqs[index] = seq;
            @memcpy(staging.data[index][0..bytes.len], bytes);
            staging.len += 1;
            // seq_cst: the poster's STORE side of the bind/post
            // store-buffer handshake — this increment must precede the
            // `wake_services` load below it in the seq_cst total order,
            // or a concurrent `bindServices` can miss the post in its
            // sweep while this post misses the binding (see
            // `Effects.bindServices` for the four-operation argument).
            _ = owner.pending.fetchAdd(1, .seq_cst);
        }
        // New work is staged: wake the host loop OUTSIDE the staging
        // mutex (the lock-order invariant at `ChannelShared.mutex`) and
        // gated on the generation again under the wake half's own lock,
        // so a close racing this gap wakes nobody spuriously.
        requestHostWake(&shared.wake, handle.generation);
        return .accepted;
    }

    /// Wake the owning loop for one accepted post. Any-thread; touches
    /// only the process-lifetime header's wake half. The host call runs
    /// with the wake mutex FREE — the embedder's `wake_fn` is
    /// contractually enqueue-only (`PlatformServices.wake_fn`) but the
    /// contract cannot be enforced, and the loop thread takes this
    /// mutex at every pass boundary (`drainBoundary`), so holding it
    /// across the call would let a violating wake that synchronizes
    /// with the loop deadlock the runtime's own lock graph (see
    /// `ChannelWake`). The teardown fence is `in_flight` instead: it
    /// increments under the mutex before the call and decrements under
    /// the mutex after, so a teardown quiesce can still wait out every
    /// call into the host, and once the binding is revoked no new call
    /// can start.
    fn requestHostWake(wake: *ChannelWake, generation: u64) void {
        // Coalesce, LOCK-FREE: a latched flag means a host wake is in
        // flight whose drain pass clears the flag before snapshotting
        // the post order — the entry staged above is inside that
        // snapshot (both sides are seq_cst: this load observing true
        // orders our seq stamp before the drain's clear, and the clear
        // before its snapshot, so the snapshot covers our stamp; see
        // `drainBoundary`). Checking without the mutex is also what
        // keeps a wake hook that posts back into the SAME channel safe:
        // the flag latches below BEFORE the host call, so a reentrant
        // post coalesces here instead of deadlocking on the wake mutex.
        if (wake.pending.load(.seq_cst)) return;
        const services = arm: {
            wake.mutex.lock();
            defer wake.mutex.unlock();
            // Stale occupancy (closed, reopened, or torn down): no wake.
            if (wake.generation != generation) return;
            // Lost the race to another poster: its latched wake covers us.
            if (wake.pending.load(.seq_cst)) return;
            // Disarmed, or no host services bound yet: nothing to call and
            // nothing latched — `bindServices` sweeps staged work with one
            // catch-up wake when it lands, and any later post retries too.
            // seq_cst, not acquire: the poster's LOAD side of the bind/post
            // store-buffer handshake. The pending increment in `post` is a
            // seq_cst store before this load, and the bind's seq_cst store
            // precedes its `hasPending` sweep — the total order over the
            // two stores guarantees whichever side ran second observes the
            // other, so an accepted post always gets a wake from one of
            // them (see `Effects.bindServices` for the full argument).
            const services_ref = wake.services orelse return;
            const found = services_ref.load(.seq_cst) orelse return;
            // Latch BEFORE the call — MediaSurfaceWake latches after,
            // but its hosts never re-enter the producer; this seam is
            // test-injectable, and the pre-latch is what makes a
            // reentrant post coalesce (above) instead of relocking. A
            // refused wake unlatches so the next post retries instead
            // of parking a wake that never comes.
            wake.pending.store(true, .seq_cst);
            // Mark in flight under the mutex, then RELEASE for the
            // call: the teardown fence (`ChannelWake.in_flight`).
            _ = wake.in_flight.fetchAdd(1, .seq_cst);
            break :arm found;
        };
        const failed = if (services.wake()) |_| false else |_| true;
        // Re-acquire to clear: the decrement is what a waiting
        // teardown quiesce observes, and the failure unlatch stays
        // generation-gated — a revoke (which zeroed the generation) or
        // a reopen (which replaced it) that won the race already reset
        // `pending` for its own occupancy, and this stale call must
        // not clear a latch it no longer owns. The decrement itself is
        // unconditional and safe against any interleaving: it lands in
        // the process-lifetime header, which outlives every close.
        wake.mutex.lock();
        defer wake.mutex.unlock();
        if (failed and wake.generation == generation) wake.pending.store(false, .seq_cst);
        _ = wake.in_flight.fetchSub(1, .seq_cst);
    }
};

/// REVOKE one channel header's wake binding, non-blocking: clear the
/// binding under the wake mutex and return. Any post locking after
/// this fails the generation gate before it could mark itself in
/// flight, so no NEW host call can start — but a call already inside
/// the embedder's `wake_fn` is left to finish on its own time. That is
/// safe for every mid-life close (closeChannel, terminal retire)
/// because everything the stale call still touches outlives it: the
/// host services stay bound and alive past any single channel's close,
/// its post-call decrement lands in the process-lifetime header, and
/// the failure unlatch it may attempt is generation-gated
/// (`requestHostWake` compares against the call's OWN generation,
/// which this revoke zeroed — and a reopen replaced — so a stale call
/// can never clear a later occupancy's latched wake). The stale wake
/// itself is a harmless nudge: the loop drains, finds nothing, moves
/// on.
///
/// Deliberately NOT a wait (`quiesceChannelWake` is): a wake that
/// synchronously marshals to the loop thread VIOLATES the wake
/// contract (`PlatformServices.wake_fn` is enqueue-only), but the
/// close path must contain the violator rather than join its
/// deadlock — when the marshaled dispatch delivers a channel message
/// whose handler calls `closeChannel`, a close that waited for
/// `in_flight == 0` would spin on the loop thread while the producer
/// inside `wake_fn` waited for that same loop to service its marshal:
/// a lock cycle of the runtime's own making. The non-blocking revoke
/// keeps the runtime's half deadlock-free no matter what the hook
/// does.
///
/// Called by every close path AFTER `open` cleared under the staging
/// mutex; the two locks are taken strictly one after the other, never
/// nested.
fn revokeChannelWake(wake: *ChannelWake) void {
    wake.mutex.lock();
    wake.generation = 0;
    wake.services = null;
    wake.pending.store(false, .seq_cst);
    wake.mutex.unlock();
}

/// QUIESCE one channel header's wake binding: revoke, then wait —
/// OUTSIDE the mutex, which the finishing post re-acquires to
/// decrement — for every already-in-flight host call to return, up to
/// `deadline_ms`. Reserved for TEARDOWN (`deinit`'s channel sweep),
/// the one caller that must not leave a call inside the host: deinit
/// ends by severing the services binding, and the platform behind it
/// may be destroyed the moment deinit returns, so an in-flight
/// `wake_fn` abandoned silently could execute into a freed platform.
/// Mid-life closes must never wait here (see `revokeChannelWake` for
/// the marshal deadlock this split exists for).
///
/// The wait is BOUNDED because teardown cannot guarantee the loop
/// thread is not a pending marshal target: deinit runs on the loop
/// thread as the loop stops pumping dispatches, so a synchronous
/// marshal already inside `wake_fn` may be waiting for a dispatch this
/// loop will never service — an unbounded wait would hang teardown
/// forever behind it. A CONFORMING `wake_fn` (bounded, enqueue-only —
/// the contract at `PlatformServices.wake_fn`) returns in
/// microseconds and never meets the deadline, so the bound is
/// violator containment only, never a wait supported usage races.
/// False means the call is ABANDONED, the abandoned-worker idiom, and
/// the abandon is safe END TO END because EVERYTHING the stale call
/// can still dereference now outlives it: the framework's own pieces —
/// the wake mutex, the in-flight decrement, the generation gate — live
/// in the process-lifetime header; the `PlatformServices` value it
/// reads inside `services.wake()` is the services snapshot its bind
/// generation published, never the Runtime-owned original — and the
/// abandon is exactly what makes that snapshot immortal: the ownership
/// rule at `Effects.wake_snapshot` frees it only on a clean teardown,
/// and this teardown was not one; and the platform the call executes into
/// is told to outlive it too (the caller reports the abandon through
/// `PlatformServices.noteChannelWakeAbandoned`, and the platform's
/// destruction path skips destruction and leaks BOTH the native host
/// and the wrapper the wake context points at, process-lived — the
/// runners heap-allocate the wrapper for exactly this gate; see
/// `MacPlatform.destroy` and its siblings). The caller still warns
/// loudly naming the stuck hook — the leak is deliberate, never
/// silent.
fn quiesceChannelWake(wake: *ChannelWake, deadline_ms: u64) bool {
    revokeChannelWake(wake);
    const start_ns = runtime_clock.monotonicNanoseconds();
    while (wake.in_flight.load(.seq_cst) != 0) {
        const elapsed_ms = (runtime_clock.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;
        if (elapsed_ms >= deadline_ms) return false;
        std.atomic.spinLoopHint();
    }
    return true;
}

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

/// One pty's cross-thread OUTPUT staging: a contiguous byte FIFO,
/// deliberately unlike the channel staging's discrete posts — terminal
/// output is one byte stream, and coalescing is the point (every byte
/// arriving between drains delivers as one bounded batch). Allocated
/// from process-lifetime storage per occupancy, freed when the exit
/// terminal delivers (or at teardown), exactly the channel staging's
/// lifetime.
const PtyStaging = struct {
    head: usize = 0,
    len: usize = 0,
    data: [max_effect_pty_staging_bytes]u8 = undefined,
};

/// The outbound (child stdin) buffers of one open pty: the byte ring the
/// loop thread stages `ptyWrite` payloads into and the io thread drains,
/// plus the per-payload length ring `dropped_writes` accounts from. Held
/// in a SEPARATE heap block — allocated at the slot's spawn, freed at its
/// retire — rather than inline in the process-lifetime `PtyShared`
/// header, so the ~64 KiB never joins the permanent leak: only the small
/// header does (the `ChannelShared` invariant). Freeing at retire is
/// safe for the same reason the staging ring's free is: the io thread's
/// exit is its last touch of this block (it drains outbound only inside
/// its read loop, gated by `open`), and `ptyWrite` runs on the loop
/// thread that owns retire — so at retire nothing reaches it. A teardown
/// that ABANDONS a stuck io thread leaks this block with the thread,
/// exactly as it leaks the staging ring.
const PtyOutbound = struct {
    data: [max_effect_pty_outbound_bytes]u8 = undefined,
    write_lens: [max_effect_pty_write_records]u32 = @splat(0),
};

/// The owner-side counters a pty io thread may touch while the pty is
/// open — the `ChannelOwnerRefs` shape: the shared post-order stamp and
/// the pending mirror behind `hasPending`. Same validity argument: every
/// close path clears `open` under `PtyShared.mutex` before the owner can
/// be freed, and the io thread reads these only after observing `open`
/// under that same mutex.
const PtyOwnerRefs = struct {
    seq: *std.atomic.Value(u64),
    pending: *std.atomic.Value(usize),
};

/// The thread-shared half of one pty table slot: everything the pty io
/// thread and the loop thread exchange. Allocated from
/// `process_allocator` at the slot's first open and DELIBERATELY NEVER
/// FREED — the abandoned-worker invariant, channel-shaped: teardown may
/// abandon an io thread stuck past its join deadline, and everything
/// that thread can still reach must stay allocated forever. The
/// permanently-leaked part is just this small header, per pty slot per
/// Effects instance; the two large per-session buffers (the staging ring
/// and the outbound block, ~256 KiB and ~64 KiB) live in their own heap
/// allocations freed at retire, so they never join the permanent leak —
/// only a teardown that ABANDONS a stuck io thread leaks them, with the
/// thread that can still reach them.
///
/// Lock discipline is `ChannelShared`'s, verbatim: `mutex` guards only
/// bounded copies; the host wake lives in `wake` behind its OWN mutex,
/// taken only after this one is released — the two never nest.
const PtyShared = struct {
    mutex: SpinMutex = .{},
    /// Output and exits are accepted only while set. Cleared under the
    /// mutex by every close path before anything the io thread could
    /// reach is freed.
    open: bool = false,
    /// The occupancy this block currently serves (u64, monotonic —
    /// the channel generation's width argument).
    generation: u64 = 0,
    staging: ?*PtyStaging = null,
    /// Post-order stamp of the staged output backlog: assigned when the
    /// ring transitions empty -> nonempty, held (with its pending count)
    /// until the loop drains the ring EMPTY. Bytes appended to an
    /// already-stamped backlog ride the batch — a byte stream has one
    /// producer and inherent order, so per-byte stamps would buy
    /// nothing but overhead.
    data_seq: u64 = 0,
    data_seq_valid: bool = false,
    /// The io thread's staged exit — delivered only after the output
    /// ring drains empty (data-before-exit, per pty, by construction).
    exit_staged: bool = false,
    exit_seq: u64 = 0,
    exit_code: i32 = effect_error_exit_code,
    exit_signal: i32 = 0,
    exit_reason: EffectExitReason = .exited,
    /// Set by the io thread when it stops reading because the staging
    /// ring is full; the loop nudges the io thread's wake pipe after
    /// draining so reading resumes (the back-pressure handshake).
    reader_parked: bool = false,
    /// Outbound (child stdin) FIFO, loop thread -> io thread. The byte
    /// ring and per-payload length ring live in `outbound` (a heap block
    /// freed at retire, so the ~64 KiB stays OUT of the permanent leak);
    /// the cursors below index into it and stay inline in the header.
    /// Valid (non-null) exactly while `open`. Refusals count into
    /// `dropped_writes`, reported on the exit event.
    outbound: ?*PtyOutbound = null,
    out_head: usize = 0,
    out_len: usize = 0,
    /// Per-payload accounting for `dropped_writes`, so a discard counts
    /// the writes NOT yet fully sent — never the ones already delivered.
    /// `outbound.write_lens` is a ring of the byte length of each staged-
    /// but-not-fully-sent `ptyWrite`; `out_front_sent` is how many bytes
    /// of the head payload have already left. As bytes flush, fully-sent
    /// payloads pop; on a discard, the surviving `out_write_count` is
    /// what was truly lost. A pathological backlog past the record cap
    /// merges into the tail entry (a bounded undercount, never a wrong
    /// overcount of delivered writes).
    out_write_head: usize = 0,
    out_write_count: usize = 0,
    out_front_sent: usize = 0,
    dropped_writes: u32 = 0,
    /// Set by the io thread under the mutex BEFORE it calls `waitpid`,
    /// so a `ptyKill` or teardown that observes it never signals the
    /// pid: `waitpid` may reap and free the pid for OS reuse the instant
    /// after it returns, and setting the flag before the call means the
    /// child is still alive (unwaited) for the whole window a signal
    /// could be sent. This closes the pid-reuse race that a
    /// post-`waitpid` `exit_staged` check alone leaves open.
    reaping: bool = false,
    /// `ptyKill` ran (the exit reports `.cancelled`, the spawn cancel
    /// convention: after the verb, the exit always says so).
    kill_requested: bool = false,
    /// Teardown/kill asked the io thread to wind down.
    shutdown: bool = false,
    /// The io thread has returned (its last shared touch) — the
    /// bounded-join flag teardown polls.
    io_done: bool = false,
    /// Valid only while `open` (see `PtyOwnerRefs`).
    owner: ?PtyOwnerRefs = null,
    /// The host-wake binding — the channel wake struct, reused whole:
    /// same generation fence, same coalescer, same teardown quiesce.
    wake: ChannelWake = .{},
};

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
    /// One external-source channel event (`EffectChannelEvent`) —
    /// journal format v8. The post bytes ride the record's `payload`
    /// INLINE, never the blob store: a post is bounded at
    /// `max_effect_channel_bytes` (small-message-shaped by contract),
    /// so the record stays far under budget and replay needs no side
    /// store to resolve it. `dropped_pending` rides the shared
    /// `dropped` field; the cumulative total gets its own field.
    channel = 12,
    /// One video playback event (`EffectVideo`), journaled verbatim at
    /// the delivery boundary exactly like `.audio` — the Msg source
    /// under replay, while the platform's own `.video` events stay
    /// inert. Kind codes are append-only and never repack; the code
    /// value rides the journal, so a change here moves the format
    /// fingerprint.
    video = 13,
    /// One `loadVideo` cascade resolution (`EffectVideoSource`),
    /// journaled at the load itself — Msg-less engine truth like
    /// `.clock` and `.env` records, handler or no handler. The
    /// recording host's filesystem decides whether a local path plays
    /// or falls through to the url, and the replay-side fake executor
    /// cannot re-run that probe (replay routinely runs on a machine
    /// without the assets), so the record is what steers the replayed
    /// `source` and initial `buffering` mirrors
    /// (`applyReplayVideoSource`). Kind codes are append-only and
    /// never repack; the code value rides the journal, so a change
    /// here moves the format fingerprint.
    video_load = 14,
    /// One pty event (`EffectPtyEvent`). Output records carry their
    /// batch bytes in `payload` as they leave the drain, and the
    /// session recorder moves them into the content-addressed blob
    /// store (`pty_blob_hash`/`pty_blob_len`), the dynamic-image
    /// pipeline — output is stream-shaped and dedup-friendly, the
    /// opposite of the channel records' inline argument. Exit records
    /// ride `code`/`exit_reason` plus the pty fields.
    pty = 15,
};

/// Journaled wall-clock reads buffered for replay (`Effects.wallMs`).
/// Bounded like everything else: more reads per drain window than this
/// is a runaway loop, not a session shape.
pub const max_effect_replay_clock_entries: usize = 64;
/// Inline capacity of the replay `ptyWrite` verdict queue. One dispatch
/// can legitimately issue ANY number of writes (a large paste drained in
/// per-write-bound chunks, refused chunks retried within the same
/// update), and every verdict for a dispatch feeds before the dispatch
/// replays — so the queue must hold a whole dispatch's worth and spills
/// to the heap past this inline window (the pending-stage growth story:
/// a fixed bound would reject a valid recording).
pub const max_effect_replay_pty_write_inline: usize = 64;

/// One journaled `ptyWrite` admission verdict awaiting its replayed
/// write: the pty KEY it was recorded against and the accepted bit.
/// Keyed on purpose — a replayed run that wrote to a DIFFERENT pty with
/// the same call count and results is still divergent input, and only
/// the key comparison can see it.
pub const ReplayPtyWriteVerdict = struct {
    key: u64,
    accepted: bool,
};

/// Inline capacity of the replayed video cascade-resolution queue
/// (`Effects.pushReplayVideoSource`). Records precede the event whose
/// dispatch consumes them, so the queue holds at most one dispatch's
/// loads — and loads per dispatch are unbounded by contract (the
/// rejection-burst rule), so a burst past this spills to the heap
/// instead of refusing: each record is one recorded resolution owed to
/// exactly one replayed load.
pub const max_effect_replay_video_source_entries: usize = 64;

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
    /// `.channel` records: the delivered event kind (post bytes ride
    /// `payload` inline, `dropped_pending` rides `dropped`) and the
    /// occupancy's cumulative drop total.
    channel_kind: EffectChannelEventKind = .data,
    channel_dropped_total: u32 = 0,
    /// `.video` records: the delivered video event, verbatim — the
    /// audio record fields' twin, plus the stream dimensions the
    /// `.loaded` acknowledgment carries.
    video_kind: EffectVideoEventKind = .position,
    video_position_ms: u64 = 0,
    video_duration_ms: u64 = 0,
    video_playing: bool = false,
    video_buffering: bool = false,
    video_width: u64 = 0,
    video_height: u64 = 0,
    /// `.video` records: the identity of the LOAD that produced the
    /// event (`VideoChannel.token`). The public key alone cannot name
    /// a playback — replace semantics reuse app keys — and replay
    /// re-mints the same deterministic token sequence, so this is how
    /// `feedVideoRecord` routes each journaled delivery to the load
    /// that owned it live, never to a same-key replacement. Zero on
    /// `.rejected` records: a refused load never minted a token (and
    /// those records regenerate under replay anyway).
    video_token: u64 = 0,
    /// `.video_load` records: the source the recording host's cascade
    /// resolved (see the kind's doc).
    video_source: EffectVideoSource = .local,
    /// `.video` records: whether the delivery dispatched a Msg (a
    /// handler was bound). Replay validates the replayed handler
    /// presence against it at feed time — a record whose Msg the
    /// replayed timeline could not dispatch (or would dispatch where
    /// none was) is divergence, not a silent consume.
    video_handled: bool = false,
    /// `.pty` records: the delivered event kind. Output batches ride
    /// `payload` out of the drain and the blob fields after the
    /// recorder moves them out of line; exits ride `code` and
    /// `exit_reason` plus the signal and refused-write count here.
    pty_kind: EffectPtyEventKind = .output,
    pty_signal: i32 = 0,
    pty_dropped_writes: u32 = 0,
    /// `.pty` output records: the content address of the journaled
    /// batch bytes in the session blob store, filled by the recorder
    /// when it moves `payload` out of line (the image convention).
    pty_blob_hash: [effect_image_blob_hash_len]u8 = @splat(0),
    pty_blob_len: u64 = 0,
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

/// Flatten the bound environ into the pty transport's env list — the
/// spawn effect's inherit-the-host policy, made explicit because execve
/// takes a flat envp. TERM is injected by the transport whether or not
/// the host carried one. Returns null when the environ exceeds the
/// transport's bounds: the child MUST see the whole environment the API
/// promised, so an over-bound environ fails the spawn loudly rather
/// than handing the child a silently truncated one (a required variable
/// past the cutoff would otherwise vanish).
fn flattenPtyEnviron(environ: std.process.Environ, buffer: []pty_transport.EnvVar) ?[]const pty_transport.EnvVar {
    if (comptime std.process.Environ.Block != std.process.Environ.PosixBlock) return buffer[0..0];
    var count: usize = 0;
    var total_bytes: usize = 0;
    for (environ.block.slice) |entry_opt| {
        const entry = entry_opt orelse continue;
        const text = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        // The transport injects its own TERM; a host TERM would race it.
        if (std.mem.eql(u8, text[0..eq], "TERM")) continue;
        if (count == buffer.len) return null;
        if (total_bytes + text.len > pty_transport.max_env_bytes) return null;
        buffer[count] = .{ .name = text[0..eq], .value = text[eq + 1 ..] };
        count += 1;
        total_bytes += text.len;
    }
    return buffer[0..count];
}

/// The pty io thread: one poll loop owning all blocking parent-end I/O.
/// Reads coalesce into the shared staging ring (parking, not dropping,
/// when it fills — the loop's drain nudges resumption); outbound bytes
/// flush when the parent end accepts them; EOF reaps the child and stages
/// the exit as the thread's last shared touch. Touches ONLY the
/// process-lifetime shared block, the transport fds, and the nudge
/// pipe's read end — never the slot — so a teardown that abandons this
/// thread past its deadline leaks bounded fds, never memory safety.
fn ptyIoLoop(shared: *PtyShared, transport: pty_transport.Pty, nudge_fd: c_int, generation: u64) void {
    if (comptime !pty_transport.supported) return;
    var local: [16 * 1024]u8 = undefined;
    read_loop: while (true) {
        shared.mutex.lock();
        const shutdown = shared.shutdown;
        const killed = shared.kill_requested;
        const staged = if (shared.staging) |staging| staging.len else max_effect_pty_staging_bytes;
        const room = max_effect_pty_staging_bytes - staged;
        const want_read = room > 0;
        if (!want_read) shared.reader_parked = true;
        const want_write = shared.out_len > 0;
        shared.mutex.unlock();

        // Teardown or a kill asked the thread to wind down: stop reading
        // and go reap. Checked here so a reader PARKED on a full staging
        // ring — which polls only the nudge pipe, never the parent end,
        // so it can never observe a hangup — still exits promptly on the
        // nudge. The kill case is load-bearing beyond teardown: the
        // SIGKILL fells the direct child, but a new-session descendant
        // that kept the child end open leaves the parent end with no EOF,
        // so waiting for the pty to close would strand the exit forever.
        // The direct child is dead, so `reapBlocking` below returns at
        // once; the escaped descendant runs on detached, the spawn
        // family's documented limit.
        if (shutdown or killed) break :read_loop;

        const ready = pty_transport.wait(transport.parent, nudge_fd, want_read, want_write);
        if (ready.nudged) pty_transport.drainNudges(nudge_fd);
        if (ready.writable) ptyFlushOutbound(shared, transport, generation);
        if (ready.readable and want_read) {
            const take = @min(local.len, room);
            const n = transport.read(local[0..take]) catch |err| switch (err) {
                // Nothing ready on the non-blocking parent end (a spurious
                // readable): not EOF — re-poll.
                error.WouldBlock => continue :read_loop,
                // A real read error (or normalized EOF) ends the stream.
                error.ReadFailed => break :read_loop,
            };
            if (n == 0) break :read_loop;
            ptyStageOutput(shared, generation, local[0..n]);
            continue :read_loop;
        }
        // Hangup with nothing readable is the EOF signal: the child
        // side closed. (A parked reader ignores it until the drain
        // frees room — the remaining bytes are still in the kernel
        // buffer and readable.)
        if (ready.hangup and want_read) break :read_loop;
    }
    // The stream is over: reap the child and stage the exit. Publish
    // `reaping` BEFORE any waitpid so a racing ptyKill/teardown never
    // signals a pid that reaping is about to free for reuse — until the
    // reap returns the child is still alive, so declining to signal
    // loses nothing. `reapEnding` never blocks forever: the normal case
    // (child already exited) returns at once with no signal; a child
    // that closed its terminal but kept running is hung up and escalated
    // to SIGKILL within a bounded window; and a child the kernel holds
    // in uninterruptible I/O past a further bounded window has its kill
    // reported as the ending (the surrendered reap's documented zombie)
    // — the exit always arrives. This is the thread's LAST shared touch
    // before the wake.
    shared.mutex.lock();
    shared.reaping = true;
    shared.mutex.unlock();
    const exit = transport.reapEnding();
    // A spawn whose exec probe timed out unresolved carries its status
    // pipe here: the failure byte (written before the child's _exit) is
    // readable exactly now, so a late exec failure still reports
    // `spawn_failed` instead of masquerading as a normal end.
    const late_exec_failure = transport.lateExecFailure();
    shared.mutex.lock();
    if (shared.open and shared.generation == generation) {
        // Outbound bytes still staged at exit never reached the child:
        // count each lost payload so `dropped_writes == 0` keeps its
        // promise (distinct writes, not one lumped event).
        if (shared.out_len > 0) {
            shared.dropped_writes +|= @intCast(shared.out_write_count);
            shared.out_len = 0;
            shared.out_write_count = 0;
            shared.out_front_sent = 0;
        }
        const cancelled = shared.kill_requested;
        shared.exit_reason = if (cancelled)
            .cancelled
        else if (late_exec_failure)
            .spawn_failed
        else if (exit.signal != 0)
            .signaled
        else
            .exited;
        // `signal` is meaningful ONLY for `.signaled` (a fatal signal
        // the child was not sent by cancel). A cancelled end reports
        // signal 0 even though the toolkit's own SIGKILL is what felled
        // it — the API contract is "signal != 0 iff reason == signaled".
        shared.exit_signal = if (shared.exit_reason == .signaled) exit.signal else 0;
        // Only a natural exit carries a meaningful child code; every
        // other reason reports the doc's -1 sentinel.
        shared.exit_code = if (shared.exit_reason == .exited) exit.code else effect_error_exit_code;
        shared.exit_staged = true;
        if (shared.owner) |owner| {
            shared.exit_seq = owner.seq.fetchAdd(1, .seq_cst);
            _ = owner.pending.fetchAdd(1, .seq_cst);
        }
    }
    shared.io_done = true;
    shared.mutex.unlock();
    ChannelHandle.requestHostWake(&shared.wake, generation);
}

/// Append read bytes into the staging ring (bounded by the room the
/// caller observed) and stamp/wake exactly like a channel post: the
/// first batch after an empty ring stamps the backlog and requests one
/// coalesced host wake.
fn ptyStageOutput(shared: *PtyShared, generation: u64, bytes: []const u8) void {
    var stamped = false;
    shared.mutex.lock();
    if (shared.open and shared.generation == generation) {
        if (shared.staging) |staging| {
            const room = max_effect_pty_staging_bytes - staging.len;
            const take = @min(room, bytes.len);
            var index: usize = 0;
            while (index < take) : (index += 1) {
                staging.data[(staging.head + staging.len + index) % max_effect_pty_staging_bytes] = bytes[index];
            }
            staging.len += take;
            if (take > 0 and !shared.data_seq_valid) {
                if (shared.owner) |owner| {
                    shared.data_seq = owner.seq.fetchAdd(1, .seq_cst);
                    shared.data_seq_valid = true;
                    _ = owner.pending.fetchAdd(1, .seq_cst);
                    stamped = true;
                }
            } else if (take > 0) {
                stamped = true;
            }
        }
    }
    shared.mutex.unlock();
    if (stamped) ChannelHandle.requestHostWake(&shared.wake, generation);
}

/// Flush staged outbound bytes toward the child while the parent end
/// accepts them. Bounded copies under the mutex, the write itself
/// outside it.
fn ptyFlushOutbound(shared: *PtyShared, transport: pty_transport.Pty, generation: u64) void {
    var chunk: [4096]u8 = undefined;
    while (true) {
        shared.mutex.lock();
        if (!shared.open or shared.generation != generation or shared.out_len == 0) {
            shared.mutex.unlock();
            return;
        }
        const take = @min(chunk.len, shared.out_len);
        const outbound = shared.outbound.?;
        var index: usize = 0;
        while (index < take) : (index += 1) {
            chunk[index] = outbound.data[(shared.out_head + index) % max_effect_pty_outbound_bytes];
        }
        shared.mutex.unlock();
        const wrote = transport.write(chunk[0..take]) catch |err| switch (err) {
            // The child's input buffer is full (it is not reading): the
            // bytes STAY staged and retry on the next writable poll.
            // Returning here — rather than looping — is what keeps a
            // non-reading child from blocking the io thread and
            // stalling stdout: one bounded write attempt per POLLOUT.
            error.WouldBlock => return,
            // A real write error (the child closed its read end): the
            // staged bytes can never reach it. Drop and count each lost
            // payload so `dropped_writes == 0` keeps meaning "every
            // write landed".
            error.WriteFailed => {
                shared.mutex.lock();
                if (shared.out_len > 0) {
                    shared.dropped_writes +|= @intCast(shared.out_write_count);
                    shared.out_len = 0;
                    shared.out_write_count = 0;
                    shared.out_front_sent = 0;
                }
                shared.mutex.unlock();
                return;
            },
        };
        if (wrote == 0) return;
        shared.mutex.lock();
        shared.out_head = (shared.out_head + wrote) % max_effect_pty_outbound_bytes;
        shared.out_len -= @min(wrote, shared.out_len);
        // Pop every payload these bytes fully sent, so a later discard
        // counts only the writes that never reached the child.
        var sent = wrote;
        const write_lens = &shared.outbound.?.write_lens;
        while (sent > 0 and shared.out_write_count > 0) {
            const front = write_lens[shared.out_write_head] - shared.out_front_sent;
            if (sent >= front) {
                sent -= front;
                shared.out_front_sent = 0;
                shared.out_write_head = (shared.out_write_head + 1) % max_effect_pty_write_records;
                shared.out_write_count -= 1;
            } else {
                shared.out_front_sent += sent;
                sent = 0;
            }
        }
        const drained = shared.out_len == 0;
        shared.mutex.unlock();
        if (drained or wrote < take) return;
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
        pub const VideoMsgFn = *const fn (event: EffectVideo) Msg;
        pub const HostMsgFn = *const fn (result: EffectHostResult) Msg;
        pub const ImageMsgFn = *const fn (result: EffectImageResult) Msg;
        pub const ChannelMsgFn = *const fn (event: EffectChannelEvent) Msg;
        pub const PtyMsgFn = *const fn (event: EffectPtyEvent) Msg;

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

        /// Comptime Msg constructor for `on_event` of video playback:
        /// `videoMsg(.video_event)` builds
        /// `Msg{ .video_event = event }` — the variant's payload type
        /// must be `native_sdk.EffectVideo`.
        pub fn videoMsg(comptime tag: std.meta.Tag(Msg)) VideoMsgFn {
            return struct {
                fn make(event: EffectVideo) Msg {
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

        /// Comptime Msg constructor for `on_event` of external-source
        /// channels: `channelMsg(.tick)` builds `Msg{ .tick = event }` —
        /// the variant's payload type must be
        /// `native_sdk.EffectChannelEvent`.
        pub fn channelMsg(comptime tag: std.meta.Tag(Msg)) ChannelMsgFn {
            return struct {
                fn make(event: EffectChannelEvent) Msg {
                    return @unionInit(Msg, @tagName(tag), event);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_event` of pty effects:
        /// `ptyMsg(.shell)` builds `Msg{ .shell = event }` — the
        /// variant's payload type must be `native_sdk.EffectPtyEvent`.
        pub fn ptyMsg(comptime tag: std.meta.Tag(Msg)) PtyMsgFn {
            return struct {
                fn make(event: EffectPtyEvent) Msg {
                    return @unionInit(Msg, @tagName(tag), event);
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

        pub const OpenChannelOptions = struct {
            /// Caller-chosen identity, stored in the model. Shares the
            /// keyed families' one key space: occupied from open until
            /// the `.closed` terminal delivers, blocking (and blocked
            /// by) a same-key spawn/fetch/file/clipboard/host/image.
            key: u64,
            /// Every channel event — each delivered post, the
            /// `.closed` terminal, a refused open's `.rejected` —
            /// arrives through this constructor. Required: a channel
            /// with nothing to tell is not a channel.
            on_event: ChannelMsgFn,
            /// Back-pressure bound: staged posts held between drains,
            /// clamped to 1..`max_effect_channel_pending`. Posts past
            /// it answer `.dropped_full` and count as drops —
            /// deterministic arithmetic on the wire value, so replay
            /// clamps identically.
            max_pending: u32 = max_effect_channel_pending,
        };

        pub const PtySpawnOptions = struct {
            /// Caller-chosen identity, stored in the model. Shares the
            /// keyed families' one key space, occupied from spawn until
            /// the `.exit` terminal delivers.
            key: u64,
            /// The command and its arguments (shares the spawn effect's
            /// argv budgets). argv[0] resolves against the child
            /// environment's PATH.
            argv: []const []const u8,
            /// Initial grid size the child observes via TIOCGWINSZ.
            cols: u16 = 80,
            rows: u16 = 24,
            /// The TERM the child starts with. The rest of the child's
            /// environment is the spawn policy verbatim: the bound host
            /// environ (`bindEnviron`), nothing else — a pty is a spawn
            /// with a different transport, one env story.
            term: []const u8 = pty_transport.default_term,
            /// Every pty event — each coalesced output batch and the
            /// exactly-one `.exit` terminal — arrives through this
            /// constructor. Required: a terminal nobody watches is not
            /// a terminal.
            on_event: PtyMsgFn,
        };

        /// A recorded fake-pty spawn request, exposed for test
        /// assertions (`pendingPtyAt`). Strings borrow the slot's
        /// storage — valid until the slot retires.
        pub const PtyRequest = struct {
            key: u64,
            argv: []const []const u8,
            cols: u16,
            rows: u16,
            term: []const u8,
        };

        /// How one pty table slot advances: `.running` from the
        /// accepted spawn until its `.exit` terminal DELIVERS — the
        /// exit retires the slot to `.idle` before the Msg reaches
        /// update, the families' shared instant. There is no `.closing`
        /// phase: the io thread stages the exit into the shared block
        /// and the drain's delivery is the retire.
        const PtySlotState = enum(u8) { idle, running };

        const PtySlot = struct {
            state: PtySlotState = .idle,
            key: u64 = 0,
            /// u64 from the channel-owned monotonic counter (shared
            /// with channel occupancies; same width argument).
            generation: u64 = 0,
            on_event: ?PtyMsgFn = null,
            fake: bool = false,
            /// The slot's process-lifetime shared block — created at
            /// the slot's first REAL open, reused across occupancies,
            /// never freed (see `PtyShared`). Fake and parked
            /// occupancies never touch it.
            shared: ?*PtyShared = null,
            /// The live transport (real executor on a posix target).
            transport: if (pty_transport.supported) ?pty_transport.Pty else void =
                if (pty_transport.supported) null else {},
            io_thread: ?WorkerThread = null,
            /// The io thread's nudge pipe: [read, write]. Written by
            /// the loop (outbound bytes staged, drain freed staging
            /// room, shutdown); poll()'d by the io thread.
            wake_pipe: [2]c_int = .{ -1, -1 },
            /// Grid mirrors (the automation/test truth of the last
            /// accepted spawn/resize).
            cols: u16 = 0,
            rows: u16 = 0,
            /// Fake mirror of `ptyKill` for test assertions.
            kill_requested: bool = false,
            /// Fake capture of `ptyWrite` payloads (`ptyWrittenBytes`),
            /// oldest dropped past the window.
            write_capture: [max_effect_pty_write_capture_bytes]u8 = undefined,
            write_capture_len: usize = 0,
            /// Fake mirror of refused writes (over-bound payloads).
            dropped_writes: u32 = 0,
            /// Request storage for the fake/test seam.
            argv_storage: [max_effect_argv_bytes]u8 = undefined,
            argv_slices: [max_effect_argv][]const u8 = undefined,
            argv_count: usize = 0,
            term_storage: [max_effect_pty_term_bytes]u8 = undefined,
            term_len: usize = 0,
            /// Session replay only: the pending-order reservation this
            /// parked spawn holds (see `ParkOrderState` — the channel
            /// park dance, pty-shaped: a fed start-failure terminal
            /// reclaims the stamp and delivers through the pending
            /// stage at the spawn's dispatch position; a fed output or
            /// real exit proves the spawn started live and vacates it).
            park_seq: u64 = 0,
            park_state: ParkOrderState = .none,

            fn requestArgv(slot: *const PtySlot) []const []const u8 {
                return slot.argv_slices[0..slot.argv_count];
            }

            fn requestTerm(slot: *const PtySlot) []const u8 {
                return slot.term_storage[0..slot.term_len];
            }
        };

        /// How one channel table slot advances: `.open` accepts posts
        /// and delivers `.data` events; `.closing` (closeChannel ran)
        /// flushes the staged backlog, delivers the one `.closed`
        /// terminal, and retires to `.idle`. The KEY stays occupied
        /// through `.closing` — delivery of the terminal is what frees
        /// it, the families' shared discipline.
        const ChannelSlotState = enum(u8) { idle, open, closing };

        /// The pending-order reservation a replay-parked open holds —
        /// mixed-provenance rejection order. Live, an open REFUSED as
        /// executor truth stages its `.rejected` in the pending stage
        /// AT DISPATCH, so it delivers before every pending entry
        /// staged after it (a younger regenerating refusal, an image
        /// rejection — the stages share one `pending_seq`). Under
        /// replay the same open parks instead and its journaled
        /// terminal arrives through the feed; fed through the
        /// completion queue it would deliver AFTER every pending entry
        /// of the pass — younger regenerating refusals included — and
        /// invert the recorded order. Every park therefore consumes
        /// one `pending_seq` stamp at dispatch (the exact position a
        /// live refusal would have staged at), and the feed resolves
        /// what the stamp meant:
        ///
        /// - A fed park-retiring `.rejected` proves the open was
        ///   REFUSED live: the terminal delivers through the pending
        ///   stage at the park's stamp, restoring the live order. The
        ///   feed always lands in time — results journal BEFORE the
        ///   event whose dispatch delivered them (the recorder stages
        ///   the event and commits on exit), so the replay pump feeds
        ///   the refusal before it dispatches the event whose drain
        ///   pass serves it alongside the younger entries.
        /// - Any other fed kind proves the open was ACCEPTED live: an
        ///   accepted open delivered nothing at its dispatch — no
        ///   pending entry existed — so the stamp is vacated unused
        ///   and the event rides the completion queue like every fed
        ///   result. Which case a park is only becomes knowable at the
        ///   first feed, which is why the stamp is unconditional; an
        ///   unused stamp costs one skipped seq value, and only
        ///   relative order ever matters.
        const ParkOrderState = enum(u8) {
            /// Not a replay park (live slots, retired slots).
            none,
            /// Stamped at the parked open's dispatch; no feed has
            /// resolved it yet.
            reserved,
            /// Resolved as ACCEPTED LIVE: the first fed event was a
            /// `.data`, so the stamp went unused and the recorded
            /// stream is still flowing — more `.data` and the one
            /// `.closed` terminal may follow.
            vacated,
            /// The open's TERMINAL fed (the refusal reclaimed the
            /// stamp, or a `.closed` rode the queue): nothing may
            /// target this occupancy again. The slot itself retires
            /// when the terminal DELIVERS; until then this state is
            /// what refuses a damaged journal's post-terminal records
            /// (`feedChannelEvent` -> `error.ReplayDamagedRecord`)
            /// instead of letting them enqueue and be silently
            /// discarded by the delivery generation gate after the
            /// retire.
            terminated,
        };

        const ChannelSlot = struct {
            state: ChannelSlotState = .idle,
            key: u64 = 0,
            /// The occupancy's generation — u64 from the channel-owned
            /// monotonic counter (`channel_generation`), never the
            /// shared u32 effect counter (see `ChannelHandle.generation`
            /// for why the width is load-bearing).
            generation: u64 = 0,
            on_event: ?ChannelMsgFn = null,
            /// The slot's process-lifetime posting header — created at
            /// the slot's first open, reused across occupancies, never
            /// freed (see `ChannelShared`).
            shared: ?*ChannelShared = null,
            /// `.closing` only: the close marker's post-order stamp.
            /// The `.closed` terminal delivers once every staged post
            /// older than it has drained (all of them — nothing stages
            /// after close), keeping data-before-closed order by the
            /// same stamp the posts carry.
            closed_seq: u64 = 0,
            /// `.closing` only: whether `closed_seq` is armed. Never
            /// set under session replay — there the journaled `.closed`
            /// record is the one delivery (`feedChannelEvent`).
            closed_staged: bool = false,
            /// Session replay only: the pending-order stamp this parked
            /// open reserved at dispatch (see `ParkOrderState`).
            park_seq: u64 = 0,
            /// Session replay only: whether `park_seq` still reserves
            /// its pending-order slot.
            park_state: ParkOrderState = .none,
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

        pub const LoadVideoOptions = struct {
            /// Caller-chosen identity, stored in the model and echoed in
            /// every event for this playback. Video keys are their own
            /// namespace (like audio and timer keys); a new `loadVideo`
            /// replaces the previous playback outright — one player is
            /// the whole surface.
            key: u64,
            /// The media-surface texture channel decoded frames feed:
            /// the SAME model-owned u64 a `<video>` (or
            /// `<media-surface>`) widget binds. 0 and ids in the
            /// reserved texture namespace
            /// (`canvas.media_surface_image_id_bit`) are refused with
            /// one `.rejected` event, mirroring
            /// `acquireMediaSurfaceProducer`.
            surface: u64,
            /// Local file path, tried FIRST — the audio cascade's rule:
            /// a present-but-missing file falls through to `url` when
            /// one is given; every other local failure is terminal.
            /// Bounded by `max_effect_video_path_bytes`.
            path: []const u8 = "",
            /// http(s) source, tried when the local path is absent or
            /// missing: progressive streaming, playable before the
            /// download finishes. Empty means local-only. Non-http(s)
            /// schemes are rejected before the platform is asked — the
            /// image loader's scheme check.
            url: []const u8 = "",
            /// Start playing as soon as the load lands. False loads
            /// paused at position zero — `playVideo` starts it (the
            /// poster-frame shape: the first decoded frame reaches the
            /// surface either way).
            autoplay: bool = true,
            /// Wrap from the natural end back to zero and keep playing.
            /// A looping playback never delivers `.completed`.
            loop: bool = false,
            /// Start with the audio track muted (a reversible switch,
            /// independent of the remembered volume).
            muted: bool = false,
            /// Msg constructor every playback event flows through (see
            /// `videoMsg`). Without one, playback still runs — frames
            /// reach the surface; the app just hears nothing back.
            on_event: ?VideoMsgFn = null,
        };

        /// The single video playback channel — one player is the whole
        /// platform surface, mirroring `AudioChannel` exactly: a
        /// platform service arm, no `max_effects` slots, keys in their
        /// own namespace, mirrors tracking what the app has been told
        /// (commands optimistically, platform events authoritatively).
        /// The channel additionally owns the media-surface claim for
        /// the playback's surface: `sink` is the frame conduit handed
        /// to the platform decoder, released on stop/replace/failure so
        /// the surface becomes claimable again (the runtime keeps the
        /// last adopted frame either way).
        const VideoChannel = struct {
            active: bool = false,
            fake: bool = false,
            key: u64 = 0,
            /// This load's identity on the platform seam: minted from
            /// `video_token_seq` at load, passed to the platform, and
            /// echoed in every `.video` event it emits — how
            /// `takeVideoMsg` swallows a replaced playback's queued
            /// stragglers instead of applying them to the replacement.
            /// Deterministic under replay (one increment per replayed
            /// load dispatch).
            token: u64 = 0,
            surface_id: u64 = 0,
            on_event: ?VideoMsgFn = null,
            playing: bool = false,
            /// Latched by a non-looping `.completed` apply: real hosts
            /// retire the platform player at the natural end
            /// (retire-before-emit), so any later transport meets an
            /// absent player. The fake executor has no player to be
            /// absent — this flag is how it models the same refusals
            /// (a post-completion seek keeps the terminal position,
            /// live and replayed alike). A fresh load resets it with
            /// the rest of the channel.
            completed: bool = false,
            source: EffectVideoSource = .local,
            buffering: bool = false,
            looping: bool = false,
            muted: bool = false,
            position_ms: u64 = 0,
            duration_ms: u64 = 0,
            width: u64 = 0,
            height: u64 = 0,
            volume: f32 = 1.0,
            /// The live media-surface claim (real executor only): a
            /// zeroed sink means no claim is held. Fake channels never
            /// claim — replay stays producer-free by construction.
            sink: platform.VideoFrameSink = .{},
            path_buffer: [max_effect_video_path_bytes]u8 = undefined,
            path_len: usize = 0,
            url_buffer: [max_effect_video_path_bytes]u8 = undefined,
            url_len: usize = 0,

            fn path(channel: *const VideoChannel) []const u8 {
                return channel.path_buffer[0..channel.path_len];
            }

            fn url(channel: *const VideoChannel) []const u8 {
                return channel.url_buffer[0..channel.url_len];
            }
        };

        /// Video playback state the automation snapshot exposes: honest
        /// — it reports what the platform has told us.
        pub const VideoSnapshot = struct {
            active: bool = false,
            key: u64 = 0,
            surface: u64 = 0,
            playing: bool = false,
            buffering: bool = false,
            /// A non-looping natural end was reached and the platform
            /// player retired (`VideoChannel.completed`): play and
            /// seek refuse from here — the resume path is
            /// `restartVideo` (or a fresh load).
            completed: bool = false,
            looping: bool = false,
            muted: bool = false,
            source: EffectVideoSource = .local,
            position_ms: u64 = 0,
            duration_ms: u64 = 0,
            width: u64 = 0,
            height: u64 = 0,
            volume: f32 = 1.0,
        };

        /// A recorded video playback request, exposed by the fake
        /// executor for test assertions. The strings borrow the
        /// channel's storage — valid until the next `loadVideo`.
        pub const VideoRequest = struct {
            key: u64,
            surface: u64,
            path: []const u8,
            url: []const u8,
            playing: bool,
            looping: bool,
            muted: bool,
            position_ms: u64,
            volume: f32,
        };

        /// `draining`: the worker is done and the terminal entry is
        /// queued, but the slot still owns a heap buffer (a fetch's body
        /// or a collect spawn's stdout) until the drain delivers (and
        /// thereby retires) it.
        const SlotState = enum(u8) { idle, running, done, draining };

        const SlotKind = enum(u8) { spawn, fetch, file, clipboard, host, image };

        const EntryKind = enum(u8) { line, exit, response, file, clipboard, host, image, channel, pty };

        const Entry = struct {
            kind: EntryKind = .line,
            slot_index: u16 = 0,
            generation: u32 = 0,
            /// `.channel` entries only: the parked occupancy's u64
            /// channel generation (`slot_index` names a CHANNEL table
            /// slot there, and the shared `generation` above is the
            /// slot families' u32 — see `ChannelSlot.generation`).
            channel_generation: u64 = 0,
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
            /// `.channel` entries (session replay's fed channel events;
            /// live events ride the per-channel staging instead): the
            /// recorded event kind. `slot_index`/`generation` name a
            /// CHANNEL table slot here, not an effect slot; the bytes
            /// ride `line_bytes` (`max_effect_channel_bytes` fits by
            /// construction), `dropped_before` carries dropped_pending
            /// and `dropped_lines` the cumulative total.
            channel_kind: EffectChannelEventKind = .data,
            /// `.pty` entries (session replay's fed pty events; live
            /// events ride the per-pty staging instead): the recorded
            /// event kind. `slot_index` names a PTY table slot and
            /// `channel_generation` its u64 occupancy generation;
            /// output bytes ride `line_bytes` up to the inline bound
            /// and `heap_line` past it; exits ride `code`/`reason`
            /// plus the fields here.
            pty_kind: EffectPtyEventKind = .output,
            pty_signal: i32 = 0,
            pty_dropped_writes: u32 = 0,
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
            pty: struct {
                event: EffectPtyEvent,
                pty_fn: ?PtyMsgFn,
                regenerates: bool,
                retire_slot: ?usize = null,
                retire_generation: u64 = 0,
            },
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
            /// The audio entry's shape for the video channel, staged
            /// in the non-lossy `pending_videos` (see `PendingVideo`)
            /// and taking this union shape only at drain time.
            /// `resolve` marks fed events (fake executor / replay)
            /// that update the live channel's mirrors at delivery; the
            /// handler is captured at stage time either way (the
            /// `PendingVideo` doc has the replay ordering argument).
            video: struct { event: EffectVideo, video_fn: ?VideoMsgFn, resolve: bool, token: u64 = 0 },
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
            /// Loop-thread channel `.rejected` terminals (refused
            /// opens). Exactly the image discipline: never in the
            /// lossy ring — they stage in the non-lossy
            /// `pending_channels` (see `PendingChannel`) and take this
            /// union shape only at drain time, in `takePendingMsg`.
            /// `regenerates` follows the image classification:
            /// validation refusals (occupied key, full channel table)
            /// re-derive under replay and are skipped; an executor
            /// that could not stage the channel is executor truth and
            /// feeds.
            /// `retire_slot`/`retire_generation`: a fed park-retiring
            /// `.rejected` names the parked channel-table slot it
            /// retires at delivery (see `PendingChannel`).
            channel: struct { event: EffectChannelEvent, channel_fn: ?ChannelMsgFn, regenerates: bool, retire_slot: ?usize = null, retire_generation: u64 = 0 },
            /// A fully formed Msg staged on the loop thread by a
            /// caller-side validator (`stageLoopMsg` — the TS bridge's
            /// synchronous refusals). Always regenerating by contract:
            /// never journaled, re-staged identically by the caller's
            /// replayed dispatch. Never in the lossy ring — staged in
            /// the non-lossy `pending_staged` (see `PendingStaged`)
            /// and takes this union shape only at drain time.
            staged: Msg,

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
                    // Video events never enter the ring (they stage in
                    // the non-lossy `pending_videos`): a loop-side
                    // `.rejected`/`.failed` is its load's only
                    // terminal and a fed event is one recorded
                    // delivery — eviction would silently break both.
                    .video => unreachable,
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
                    // Pty terminals stage in the non-lossy
                    // `pending_ptys` for the same reason — exactly
                    // one `.exit` per spawn.
                    .pty => unreachable,
                    // Channel terminals stage in the non-lossy
                    // `pending_channels` for the same reason —
                    // exactly one `.rejected` per refused open.
                    .channel => unreachable,
                    // Staged Msgs live in the non-lossy
                    // `pending_staged` — one per caller-side refusal,
                    // and no counter to fold a loss into.
                    .staged => unreachable,
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
                    .pty => 0,
                    .host => 0,
                    // Never in the ring; see `addDropped`.
                    .video => unreachable,
                    .image => unreachable,
                    .channel => unreachable,
                    .staged => unreachable,
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

        /// One loop-side video event awaiting drain — non-lossy like
        /// `PendingImage` and `PendingChannel`, and for the same
        /// contract: a loop-side `.rejected` or `.failed` is its
        /// `loadVideo` call's ONLY terminal, refusals are unbounded
        /// per dispatch, and `EffectVideo` carries no drop counter
        /// that could make an eviction visible (the ring's audio
        /// eviction rationale — "the next position tick supersedes a
        /// lost one" — never covers a terminal). Fed events (fake
        /// executor / session replay) stage here too: each fed record
        /// is one recorded delivery, owed exactly once. `video_fn` is
        /// captured at STAGE time for fed events as well as loop-side
        /// terminals: any fed record corresponds to a delivery that
        /// really ran at record time, and under replay the journaled
        /// platform `.video` event that follows the record in the
        /// file may apply a channel-resetting terminal before this
        /// delivery runs — delivery-time capture would find the
        /// handler already cleared and drop a Msg the recording
        /// delivered.
        const PendingVideo = struct {
            seq: u64,
            event: EffectVideo,
            video_fn: ?VideoMsgFn,
            resolve: bool,
            /// The load token of the playback this entry belongs to,
            /// captured at stage time (`VideoChannel.token`): resolve
            /// applies mirrors only while the LIVE channel still IS
            /// that load — the public key alone cannot tell two loads
            /// under the same app key apart, and a stale entry
            /// resolving against a same-key replacement would reset
            /// it.
            token: u64 = 0,
        };

        /// Replay-side identity of a video load the replayed timeline
        /// has already replaced or stopped: enough to deliver its still
        /// outstanding journaled terminal (a synchronous `.failed` the
        /// recording host refused inside the very dispatch that then
        /// replaced or stopped the playback drains AFTER that dispatch,
        /// so its record feeds when the channel has moved on). Parked
        /// by `loadVideo`/`stopVideo` under replay only, consumed by
        /// `feedVideoRecord` on token match, and swept at the next
        /// drain-pass boundary (`drainBoundary`) once its window has
        /// provably closed — so a long replayed playlist parks and
        /// releases one entry per clip instead of accumulating them
        /// for the whole session.
        const RetiredVideo = struct {
            key: u64,
            token: u64,
            video_fn: ?VideoMsgFn,
            /// `drain_pass_seq` at park time — the sweep's age stamp
            /// (see `drainBoundary` for why one pass boundary is
            /// enough).
            parked_pass: u64 = 0,
        };

        /// One journaled `.video_load` cascade resolution awaiting the
        /// replayed load that will consume it (see
        /// `pushReplayVideoSource`). The key rides along as the
        /// cross-check: the reminted token sequence pairs records with
        /// loads by POSITION, and the journaled key proves the load at
        /// that position is the same load the recording issued.
        const ReplayVideoSource = struct {
            key: u64,
            token: u64,
            source: EffectVideoSource,
            /// The recording's load refused synchronously — its live
            /// channel reset before `loadVideo` returned, and the
            /// replayed fake load must reset at the same instant.
            failed: bool,
        };

        /// One loop-side channel `.rejected` terminal awaiting drain —
        /// the channel twin of `PendingImage`, non-lossy for the same
        /// contract (exactly one terminal per refused open, no drop
        /// counter that could make an eviction visible, unbounded per
        /// dispatch). Shares the `pending_seq` stamp so the drain
        /// merges all the loop-side stages in enqueue order.
        const PendingChannel = struct {
            seq: u64,
            event: EffectChannelEvent,
            channel_fn: ?ChannelMsgFn,
            regenerates: bool,
            /// Set for a fed park-retiring `.rejected` (session replay):
            /// the channel-table slot whose parked occupancy this staged
            /// terminal retires at delivery — the live instant the pop
            /// releases the staged refusal's reservation. `seq` is then
            /// the park's dispatch-time stamp, which can be OLDER than
            /// already-staged entries, so `stagePendingChannel` inserts
            /// in seq order. The parked slot itself holds the key and
            /// the table capacity through the staged window, so retire
            /// entries are skipped by `stagedChannelOccupiesKey` and
            /// `stagedChannelReservationCount` (counting both would
            /// double-book against live).
            retire_slot: ?usize = null,
            /// Generation gate for `retire_slot`, the fed-terminal
            /// discipline.
            retire_generation: u64 = 0,
        };

        /// One loop-side pty `.exit` terminal awaiting drain — the pty
        /// twin of `PendingChannel`, non-lossy for the same contract
        /// (exactly one terminal per refused spawn). Shares the
        /// `pending_seq` stamp so the drain merges every loop-side
        /// stage in enqueue order; fed park-retiring start failures
        /// carry their park's older stamp and insert in seq order,
        /// the channel discipline verbatim.
        const PendingPty = struct {
            seq: u64,
            event: EffectPtyEvent,
            pty_fn: ?PtyMsgFn,
            regenerates: bool,
            retire_slot: ?usize = null,
            retire_generation: u64 = 0,
        };

        /// One caller-staged loop-side Msg awaiting drain (see
        /// `stageLoopMsg`) — non-lossy like `PendingImage` and
        /// `PendingChannel`, and for the same contract: each staged
        /// entry is some refused dispatch's ONLY answer, unbounded per
        /// dispatch (a `Cmd.batch` of N refused records stages N), and
        /// there is no drop counter that could make an eviction
        /// visible. Shares the `pending_seq` stamp so the drain merges
        /// all the loop-side stages in enqueue order — staging at
        /// refusal time is what puts a caller-side refusal at its
        /// command-stream position among the engine's own refusals.
        const PendingStaged = struct {
            seq: u64,
            msg: Msg,
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
        /// The allocator behind each channel occupancy's
        /// process-lifetime storage (the `ChannelShared` posting header,
        /// the staging FIFO, and the services snapshot at
        /// `wake_snapshot`). Defaults to `process_allocator`, and
        /// any replacement MUST delegate every allocation it does not
        /// refuse to `process_allocator`'s backing: CHANNEL retire and
        /// teardown free the header/FIFO storage through
        /// `process_allocator` directly (the snapshot is created AND
        /// destroyed through this seam, which is what lets the snapshot
        /// lifetime tests count it). Pty session buffers (staging ring,
        /// outbound block) allocate AND free through this seam, so a
        /// tracking or arena replacement sees its own frees. Swap seam
        /// for the channel start-failure and snapshot-lifetime tests —
        /// `loadImage` stages its source buffer from the app allocator,
        /// so its failure tests inject there; channel storage is
        /// process-lifetime and needs this explicit seam.
        channel_storage_allocator: std.mem.Allocator = process_allocator,
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
        /// Journaled `ptyWrite` admission verdicts queued for replay-mode
        /// writes (keyed FIFO; fed from `.pty`/`.write` records before
        /// the consuming event dispatches — the `replay_clock` shape,
        /// with the pending-stage inline+spill growth so a dispatch that
        /// wrote any number of times replays whole). The verdict is
        /// executor truth: live it depends on how fast the child drained
        /// the outbound FIFO, so a replayed write must take the RECORDED
        /// path — retaining or removing the app's pending bytes exactly
        /// as the live run did — never an optimistic recomputation
        /// against a fake with no child.
        replay_pty_write_verdicts: [max_effect_replay_pty_write_inline]ReplayPtyWriteVerdict = undefined,
        replay_pty_write_spill: []ReplayPtyWriteVerdict = &.{},
        replay_pty_write_head: usize = 0,
        replay_pty_write_len: usize = 0,
        /// Replay writes that diverged from the journaled verdict stream:
        /// a write past the recorded count, or a write against a
        /// DIFFERENT pty key than the verdict at the queue's head (same
        /// count and results against another session is still divergent
        /// input). Reported loudly once; the end-of-journal settle turns
        /// any nonzero count into a replay failure.
        replay_pty_write_divergences: u64 = 0,
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
        /// thread-safe PlatformServices entry). Loop-thread reads only
        /// — cross-thread readers (channel posts in `requestHostWake`)
        /// go through `wake_services`, the atomically published
        /// mirror, never this plain field.
        services: ?*const platform.PlatformServices = null,
        /// The cross-thread mirror of `services` — pointing at the
        /// SNAPSHOT the bind generation copies into process-lifetime
        /// storage, never at the caller's (Runtime-owned) value: a wake
        /// call teardown abandons may dereference this pointer after
        /// the Runtime is destroyed, so the pointee must outlive every
        /// possible reader — the ownership rule at `wake_snapshot`:
        /// freed only on a clean teardown that proved no reader
        /// remains, leaked process-lived past an abandon. Written by
        /// the snapshot publication (`materializeWakeSnapshot`, at
        /// `bindServices` or the first live `openChannel`, whichever
        /// runs later) with seq_cst (and cleared by `deinit` with
        /// `.release` — teardown needs only the publication half; the
        /// snapshot's own disposal follows `wake_snapshot`) and read by
        /// posting threads with seq_cst (see `requestHostWake`).
        /// Open-before-bind is supported, so a posting thread can race
        /// the loop thread's bind: the wake mutex alone cannot order
        /// that pair (the bind path never takes it), and an
        /// unsynchronized read of the plain field would be a data
        /// race. Publication safety alone would take release/acquire —
        /// every loop-thread write that initialized the snapshot
        /// happens-before any producer that observes the non-null
        /// pointer — but the bind/post HANDSHAKE needs more: bind
        /// stores here then loads the pending mirror, a post stores
        /// the pending mirror then loads here, and release/acquire
        /// never orders a store before the same thread's subsequent
        /// load of a different location. The seq_cst total order over
        /// the two stores is what guarantees at least one side
        /// observes the other (see `bindServices`).
        wake_services: std.atomic.Value(?*const platform.PlatformServices) = std.atomic.Value(?*const platform.PlatformServices).init(null),
        /// The snapshot `wake_services` currently publishes, tracked
        /// for disposal — the OWNERSHIP RULE: a snapshot is alive from
        /// the publication that materialized it (the first live channel
        /// wake arm of its bind generation; see
        /// `materializeWakeSnapshot` — no channel ever opens, no
        /// snapshot ever allocates) until the clean teardown of the
        /// Effects lifetime that allocated it, and process-lived —
        /// deliberately leaked — only past an ABANDON (`deinit`'s
        /// quiesce missing its deadline), where a stale wake call
        /// captured the pointer before the revoke and may dereference
        /// it at any later time. One field tracks every snapshot this
        /// Effects ever allocated because they cannot accumulate: at
        /// most one snapshot exists per bind generation (`bindServices`
        /// is first-bind-sticks and publication is once), and every
        /// `deinit` disposes the current generation's snapshot — freed
        /// on a clean teardown, leaked immortal past an abandon —
        /// before a rebind (the one supported shape: a second bind
        /// after `deinit`) can allocate the next. Loop-thread only.
        wake_snapshot: ?*platform.PlatformServices = null,
        /// The runtime's canvas image registry, bound by `UiApp`
        /// alongside the services so `update` can register fetched
        /// pixels synchronously (loop-thread only, not an effect).
        images: ?ImageRegistryBinding = null,
        /// The runtime's media-surface texture channels, bound by
        /// `UiApp` alongside the services so `loadVideo` can claim the
        /// surface a video widget binds and hand its frame sink to the
        /// platform decoder (loop-thread only). Null means no texture
        /// channel host: real video loads fail loudly with one
        /// `.failed` event.
        media_surfaces: ?MediaSurfaceBinding = null,
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
        /// Teardown budget (milliseconds, per channel) for a host wake
        /// call still inside the embedder's `wake_fn` when the channel
        /// sweep quiesces it — see `quiesceChannelWake` for why the
        /// wait must be bounded (a synchronous marshal against the
        /// stopping loop may never return). A healthy hook is a
        /// bounded enqueue that never meets this. Injectable so tests
        /// pin the abandon path with a tiny bound.
        channel_wake_join_deadline_ms: u64 = default_channel_wake_join_deadline_ms,
        /// How many in-flight channel wake calls teardown has
        /// abandoned (each one warned, and each one reported to the
        /// platform so its destruction is skipped and the host leaks,
        /// process-lived — the header the stale call still touches is
        /// process-lived too; see `quiesceChannelWake`). The seam
        /// tests assert against: zero on every healthy teardown.
        abandoned_channel_wakes: u32 = 0,
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
        /// The channel family's OWN generation counter — u64 and
        /// monotonic for the process's lifetime, never the shared u32
        /// `next_generation` above: channel handles live on app-owned
        /// threads with no lifetime bound, so their permanent-`.closed`
        /// guarantee must survive any number of occupancies, and a
        /// wrapped u32 would let a stale handle match a reused slot
        /// after 2^32 turnovers (the media-surface producer handle
        /// draws the same line — `MediaSurfaceSlot.generation`). The
        /// slot families keep the u32 counter: their generations gate
        /// loop-internal queue entries and worker joins, not
        /// process-lifetime posting handles. Seedable in tests to pin
        /// the non-wrapping guarantee without 2^32 opens.
        channel_generation: u64 = 0,
        slots: [max_effects]Slot = [_]Slot{.{}} ** max_effects,
        /// Fixed fx timer table (see `max_effect_timers`): timers live
        /// beside the effect slots, never in them. Loop-thread only.
        timer_slots: [max_effect_timers]TimerSlot = [_]TimerSlot{.{}} ** max_effect_timers,
        /// The single audio playback channel (see `AudioChannel`).
        /// Loop-thread only, like the timer table.
        audio: AudioChannel = .{},
        /// The single video playback channel (see `VideoChannel`).
        video: VideoChannel = .{},
        /// Monotonic per-load video token mint (see
        /// `VideoChannel.token`). Loop-thread only.
        video_token_seq: u64 = 0,
        /// Fixed external-source channel table (see
        /// `max_effect_channels`): long-lived keyed occupancies beside
        /// the effect slots. Loop-thread only — the thread-shared half
        /// of each slot lives behind its `ChannelSlot.shared` header.
        channel_slots: [max_effect_channels]ChannelSlot = [_]ChannelSlot{.{}} ** max_effect_channels,
        /// Monotonic post-order stamp shared by every channel's staging
        /// FIFO and the close markers: the cross-channel delivery order
        /// and the drain boundary's causality cut (posts stamped at or
        /// past a pass's snapshot wait for the next wake, exactly like
        /// the worker queue's budget).
        channel_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Undelivered channel events (staged posts + armed close
        /// markers), mirrored atomically so `hasPending` can answer
        /// without taking any channel mutex.
        channel_pending_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// Scratch a delivered post is copied into so the event's byte
        /// slice stays valid while `update` runs (recycled per
        /// delivered channel Msg, the `drain_scratch` discipline).
        channel_drain_scratch: [max_effect_channel_bytes]u8 = undefined,
        /// Fixed pty table (see `max_effect_ptys`): long-lived keyed
        /// occupancies beside the channel table. Loop-thread only —
        /// the thread-shared half of each slot lives behind its
        /// `PtySlot.shared` header.
        pty_slots: [max_effect_ptys]PtySlot = [_]PtySlot{.{}} ** max_effect_ptys,
        /// Monotonic stamp shared by every pty's staged output backlog
        /// and exit marker — the channels' `channel_seq`, pty-shaped:
        /// cross-pty delivery order and the drain boundary's causality
        /// cut.
        pty_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Undelivered pty completions (stamped output backlogs + staged
        /// exits), mirrored atomically for `hasPending`.
        pty_pending_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// Scratch a delivered output batch is copied into so the
        /// event's byte slice stays valid while `update` runs.
        pty_drain_scratch: [max_effect_pty_chunk_bytes]u8 = undefined,
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
        /// Loop-thread-only channel-terminal stage (see
        /// `PendingChannel` for the non-lossy contract) — the image
        /// stage's storage discipline exactly: inline until a burst
        /// outgrows it, geometric spill after, freed when it drains
        /// empty and at `deinit`.
        pending_channels: [max_effect_pending_images_inline]PendingChannel = undefined,
        pending_channel_spill: []PendingChannel = &.{},
        pending_channel_head: usize = 0,
        pending_channel_len: usize = 0,
        /// Loop-thread-only video-event stage (see `PendingVideo` for
        /// the non-lossy contract) — the image stage's storage
        /// discipline exactly: inline until a burst outgrows it,
        /// geometric spill after, freed when it drains empty and at
        /// `deinit`.
        pending_videos: [max_effect_pending_images_inline]PendingVideo = undefined,
        pending_video_spill: []PendingVideo = &.{},
        pending_video_head: usize = 0,
        pending_video_len: usize = 0,
        /// Replay-only retired-load identities (see `RetiredVideo`) —
        /// the image stage's storage discipline: inline until a session
        /// outgrows it, geometric spill after, freed at `deinit`.
        retired_videos: [max_effect_pending_images_inline]RetiredVideo = undefined,
        retired_video_spill: []RetiredVideo = &.{},
        retired_video_len: usize = 0,
        /// Journaled `.video_load` cascade resolutions awaiting their
        /// replayed loads (see `pushReplayVideoSource`). Loop-thread
        /// only; inline until a burst outgrows it, geometric spill
        /// after (freed when the queue empties, and at `deinit`) — the
        /// pending stages' storage discipline.
        replay_video_sources: [max_effect_replay_video_source_entries]ReplayVideoSource = undefined,
        replay_video_source_spill: []ReplayVideoSource = &.{},
        replay_video_source_len: usize = 0,
        /// A journaled cascade resolution paired against a different
        /// key than it named (see `takeReplayVideoSource`) — latched
        /// for `finishReplay`, which turns it into the divergence
        /// refusal the void-returning `loadVideo` cannot raise itself.
        replay_video_diverged: bool = false,
        /// Drain-pass counter (incremented in `drainBoundary`): the
        /// retired-video sweep's clock. Loop-thread only.
        drain_pass_seq: u64 = 0,
        /// Loop-thread-only pty-terminal stage (see `PendingPty` for
        /// the non-lossy contract) — the channel stage's storage
        /// discipline exactly.
        pending_ptys: [max_effect_pending_images_inline]PendingPty = undefined,
        pending_pty_spill: []PendingPty = &.{},
        pending_pty_head: usize = 0,
        pending_pty_len: usize = 0,
        /// Loop-thread-only caller-staged Msg stage (see
        /// `PendingStaged` for the non-lossy contract) — the image
        /// stage's storage discipline exactly: inline until a burst
        /// outgrows it, geometric spill after, freed when it drains
        /// empty and at `deinit`.
        pending_staged: [max_effect_pending_images_inline]PendingStaged = undefined,
        pending_staged_spill: []PendingStaged = &.{},
        pending_staged_head: usize = 0,
        pending_staged_len: usize = 0,
        /// INTERNED backing for the KEY bytes a staged Msg carries (a TS
        /// bridge spawn-rejection names the app's requested key). A
        /// staged Msg outlives the caller's frame arena, the caller has
        /// no durable home for the key (a rejected spawn has no live
        /// table slot), and the delivered Msg's consumer may COMMIT the
        /// slice into its model — so these buffers are instance-lived,
        /// freed only at deinit (each a stable heap allocation; the
        /// pointer array may grow and move, the buffers never do).
        /// Interning bounds the storage by the app's distinct key
        /// vocabulary, not its rejection count.
        staged_keys: [][]u8 = &.{},
        staged_keys_len: usize = 0,
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
            // Per-teardown abandon accounting for the services-snapshot
            // disposal below: only an abandon during THIS teardown's
            // quiesce sweep leaves a stale call holding THIS
            // generation's snapshot (an abandoned call from an earlier
            // lifetime captured the earlier generation's snapshot,
            // already leaked at its own deinit, and never re-loads the
            // mirror — see `requestHostWake`'s epilogue).
            const abandoned_channel_wakes_before = self.abandoned_channel_wakes;
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
            // Stop the platform video player (best effort), release the
            // media-surface claim, and clear the channel.
            if (self.video.active and !self.video.fake) {
                if (self.services) |services| services.videoStop() catch {};
            }
            self.releaseVideoSink();
            self.video = .{};
            // Wind down every live pty BEFORE the channel sweep: the
            // group kill forces the parent end to EOF, the io thread reaps
            // and stages the exit as its last shared touch, and a
            // bounded join collects it. Staged events are discarded, no
            // Msg is delivered — the families' teardown discipline. An
            // io thread still stuck at the deadline is abandoned with a
            // teaching warning: everything it can still reach (the
            // shared header, its staging ring, the transport fds) is
            // process-lived or deliberately leaked with it.
            for (&self.pty_slots) |*pty_slot| {
                // Wind down a running REAL pty: kill and wait (bounded)
                // for the io thread to stage its exit, then retire or
                // abandon it. A fake or unsupported occupancy just
                // clears. Idle slots fall straight to the wake quiesce
                // below — their retained header may still carry an
                // in-flight wake from a session that retired earlier
                // this teardown (retirement only REVOKES, never waits).
                if (comptime pty_transport.supported) {
                    if (pty_slot.state == .running and !pty_slot.fake) {
                        if (pty_slot.shared) |shared| {
                            // Signal under the mutex, the ptyKill
                            // discipline: check and kill are atomic
                            // against the io thread's `reaping` publish,
                            // so a reaped pid's reuse is never signalled.
                            shared.mutex.lock();
                            shared.shutdown = true;
                            shared.kill_requested = true;
                            if (!(shared.reaping or shared.exit_staged or shared.io_done)) {
                                if (pty_slot.transport) |transport| transport.kill(false);
                            }
                            shared.mutex.unlock();
                        } else if (pty_slot.transport) |transport| {
                            transport.kill(false);
                        }
                        pty_transport.nudge(pty_slot.wake_pipe[1]);
                        var io_done = pty_slot.shared == null;
                        if (pty_slot.shared) |shared| {
                            const start_ns = runtime_clock.monotonicNanoseconds();
                            while (true) {
                                shared.mutex.lock();
                                io_done = shared.io_done;
                                shared.mutex.unlock();
                                if (io_done) break;
                                const elapsed_ms = (runtime_clock.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;
                                if (elapsed_ms >= self.spawn_join_deadline_ms) break;
                                std.atomic.spinLoopHint();
                            }
                        }
                        if (io_done) {
                            self.retirePtySlot(pty_slot);
                        } else {
                            // Abandon: detach the io thread and leak what
                            // it can still touch (its staging ring and
                            // outbound block stay installed, the parent-
                            // side fd stays open).
                            if (comptime builtin.os.tag != .freestanding) {
                                std.debug.print(
                                    "effects teardown: a pty io thread is still running after {d}ms (a descendant may be holding the terminal open past the group kill); abandoning the thread and leaking its fds and staging so teardown can return safely\n",
                                    .{self.spawn_join_deadline_ms},
                                );
                            }
                            if (pty_slot.io_thread) |thread| {
                                thread.detach();
                                pty_slot.io_thread = null;
                            }
                            if (pty_slot.shared) |shared| {
                                shared.mutex.lock();
                                shared.open = false;
                                shared.owner = null;
                                shared.mutex.unlock();
                            }
                            pty_slot.state = .idle;
                            pty_slot.on_event = null;
                        }
                    } else if (pty_slot.state != .idle) {
                        pty_slot.state = .idle;
                        pty_slot.on_event = null;
                    }
                    // Quiesce the wake header — for EVERY slot with one,
                    // idle included: the header is process-lifetime and
                    // reused, so a retired session's slow `wake_fn` may
                    // still be in flight, and the services snapshot and
                    // platform it dereferences are about to be freed. A
                    // still-executing call at the deadline is abandoned,
                    // counted, and the platform signalled to outlive it.
                    //
                    // The header itself is DELIBERATELY NEVER FREED — the
                    // `ChannelShared` permanent-leak invariant, verbatim.
                    // Quiescing proves only `in_flight == 0`, not that
                    // the io thread has RETURNED: the thread publishes
                    // its exit and then calls `requestHostWake`, and a
                    // thread descheduled in that pre-wake window (or a
                    // mid-life-retired, detached thread whose violating
                    // wake still runs) will lock this header's wake mutex
                    // later, so freeing it here would be a use-after-
                    // free. The leak is bounded (at most `max_effect_ptys`
                    // small headers per Effects instance — the ~64 KiB
                    // outbound block and the staging ring freed at retire)
                    // and never grows during a runtime's life (headers are
                    // reused across sessions), matching every channel
                    // header.
                    if (pty_slot.shared) |shared| {
                        if (!quiesceChannelWake(&shared.wake, self.channel_wake_join_deadline_ms)) {
                            self.abandoned_channel_wakes += 1;
                            if (self.services) |services| services.noteChannelWakeAbandoned();
                        }
                    }
                } else if (pty_slot.state != .idle) {
                    pty_slot.state = .idle;
                    pty_slot.on_event = null;
                }
            }
            self.pty_pending_count.store(0, .release);
            // Settle any surrendered reap whose child has since died —
            // teardown is the last cheap moment before the process
            // would otherwise carry the zombie.
            if (comptime pty_transport.supported) pty_transport.reapSurrendered();
            // Close every external-source channel FIRST among the
            // loop-side teardowns: clearing `open` under each shared
            // mutex fences the app's posting threads off this struct
            // (and off the services binding severed below) — after
            // this loop a post can only read the process-lifetime
            // header and answer false. Terminal discipline matches the
            // other families' teardown: staged events are discarded,
            // no Msg is delivered. The `ChannelShared` headers stay
            // allocated forever (see `ChannelShared` for the bounded
            // leak's invariant); only the staging FIFOs free here.
            for (&self.channel_slots) |*channel_slot| {
                if (channel_slot.shared) |shared| {
                    shared.mutex.lock();
                    shared.open = false;
                    const staging = shared.staging;
                    shared.staging = null;
                    shared.owner = null;
                    shared.mutex.unlock();
                    // The wake QUIESCE is the abandon fence — teardown
                    // is the one caller that waits (every mid-life
                    // close only revokes; see `revokeChannelWake` for
                    // the marshal deadlock the split prevents): it
                    // clears the binding under the wake mutex and
                    // waits out the in-flight count, so once it
                    // returns true no posting thread is inside
                    // `wake_fn` and none can re-enter — this struct
                    // (and the services binding severed below) may die
                    // safely. The wait is BOUNDED because this loop
                    // thread has stopped servicing dispatches, so
                    // deinit cannot guarantee it is not the pending
                    // target of a synchronous marshal inside an
                    // in-flight `wake_fn` — an unbounded wait would
                    // hang teardown forever behind a marshal nobody
                    // will ever service. A conforming hook (bounded,
                    // enqueue-only — `PlatformServices.wake_fn`)
                    // returns in microseconds and never meets the
                    // deadline, so this bound is violator containment
                    // only. A hook still stuck at the deadline is
                    // abandoned, warned, counted — and made safe end
                    // to end: everything the framework hands the
                    // stale call (the wake mutex, the in-flight
                    // decrement, the generation gate) lives in the
                    // process-lifetime header and stays valid
                    // forever, and the platform the call entered
                    // through is signaled — synchronously, while it
                    // is still alive — to outlive the call too: its
                    // destruction path consults the latch, skips
                    // destruction, and deliberately leaks the host,
                    // process-lived (the abandoned-worker idiom,
                    // applied to the platform itself; see
                    // `PlatformServices.note_channel_wake_abandoned_fn`).
                    if (!quiesceChannelWake(&shared.wake, self.channel_wake_join_deadline_ms)) {
                        self.abandoned_channel_wakes += 1;
                        if (self.services) |services| services.noteChannelWakeAbandoned();
                        if (comptime builtin.os.tag != .freestanding) {
                            std.debug.print(
                                "effects teardown: a channel host wake hook is still executing after {d}ms (likely a synchronous marshal against this stopping loop, which violates the enqueue-only wake contract); abandoning the in-flight call — the channel header it can still touch is process-lived, and the platform it entered through has been signaled to skip its own destruction and stay leaked, process-lived, so the stale call can never execute into freed host state\n",
                                .{self.channel_wake_join_deadline_ms},
                            );
                        }
                    }
                    if (staging) |s| process_allocator.destroy(s);
                }
                channel_slot.* = .{};
            }
            self.channel_pending_count.store(0, .release);
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
            // Undrained staged channel terminals are plain data too.
            if (self.pending_channel_spill.len > 0) {
                self.allocator.free(self.pending_channel_spill);
                self.pending_channel_spill = &.{};
            }
            if (self.pending_pty_spill.len > 0) {
                self.allocator.free(self.pending_pty_spill);
                self.pending_pty_spill = &.{};
            }
            self.pending_pty_head = 0;
            self.pending_pty_len = 0;
            self.pending_channel_head = 0;
            self.pending_channel_len = 0;
            // And undrained staged video events.
            if (self.pending_video_spill.len > 0) {
                self.allocator.free(self.pending_video_spill);
                self.pending_video_spill = &.{};
            }
            self.pending_video_head = 0;
            self.pending_video_len = 0;
            // And the replay-side retired-load identities.
            if (self.retired_video_spill.len > 0) {
                self.allocator.free(self.retired_video_spill);
                self.retired_video_spill = &.{};
            }
            self.retired_video_len = 0;
            // And the queued replayed cascade resolutions.
            if (self.replay_video_source_spill.len > 0) {
                self.allocator.free(self.replay_video_source_spill);
                self.replay_video_source_spill = &.{};
            }
            self.replay_video_source_len = 0;
            // And undrained caller-staged Msgs.
            if (self.pending_staged_spill.len > 0) {
                self.allocator.free(self.pending_staged_spill);
                self.pending_staged_spill = &.{};
            }
            self.pending_staged_head = 0;
            self.pending_staged_len = 0;
            // The durable key buffers those staged Msgs referenced.
            self.releaseStagedKeys();
            if (self.staged_keys.len > 0) {
                self.allocator.free(self.staged_keys);
                self.staged_keys = &.{};
            }
            // And an undrained replay write-verdict spill.
            if (self.replay_pty_write_spill.len > 0) {
                self.allocator.free(self.replay_pty_write_spill);
                self.replay_pty_write_spill = &.{};
            }
            self.replay_pty_write_head = 0;
            self.replay_pty_write_len = 0;
            // Sever the services binding last: the platform this pointer
            // reaches into may be destroyed before the next call arrives
            // (main's deferred app deinit runs after the runner's platform
            // teardown), and a severed channel already answers every
            // transport command inert through its existing no-services
            // paths instead of dereferencing freed memory.
            self.services = null;
            self.wake_services.store(null, .release);
            // Dispose this bind generation's services snapshot (the
            // ownership rule at `wake_snapshot`). A CLEAN teardown —
            // the channel sweep above quiesced every wake header with
            // zero abandons — proves no poster can still reach it: a
            // poster captures the snapshot pointer only under the wake
            // mutex with `in_flight` already incremented, every
            // header's binding is revoked (generation zeroed,
            // `wake.services` nulled) with its `in_flight` observed at
            // zero, and the mirror above now publishes null — so no
            // captured pointer survives and no new capture can happen;
            // free it. Past an ABANDON the snapshot is deliberately
            // leaked, process-lived: the abandoned call captured the
            // pointer before the revoke and may dereference it at any
            // later time (see `quiesceChannelWake`).
            if (self.wake_snapshot) |snapshot| {
                self.wake_snapshot = null;
                if (self.abandoned_channel_wakes == abandoned_channel_wakes_before) {
                    self.channel_storage_allocator.destroy(snapshot);
                }
            }
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
        /// runtime and is stable for its lifetime). Publishes the
        /// binding to posting threads (`wake_services`) and sweeps:
        /// work staged BEFORE the binding could never reach the host —
        /// open-before-bind is supported, so a pre-bind post is
        /// `.accepted` with `requestHostWake` finding no services and
        /// latching nothing, and every loop-side stage's `wakeHost` was
        /// a no-op — so without one catch-up nudge here a one-shot
        /// producer that posted early strands forever. One host wake
        /// covers everything staged: the drain pass sweeps all stages.
        ///
        /// SEQ_CST, NOT RELEASE — the bind/post handshake is a
        /// store-buffer (Dekker) pairing across two locations. Binder:
        /// store `wake_services`, then load the pending mirror
        /// (`hasPending`). Poster: store the pending mirror
        /// (`channel_pending_count`), then load `wake_services`
        /// (`requestHostWake`). Acquire/release cannot repair this
        /// shape: release/acquire only orders a load AFTER the store it
        /// pairs with — it never orders a thread's own store before its
        /// own SUBSEQUENT load of a DIFFERENT location, so both sides
        /// may read the stale value (binder sees no work, poster sees
        /// no services) and an accepted post strands with no wake ever
        /// coming. The correctness argument is seq_cst's total order
        /// over the two stores: whichever store is later in that order,
        /// the storing thread's subsequent load is later still and sees
        /// the other side's store — so at least one side always acts
        /// (the poster wakes, or the binder sweeps). All four
        /// participating operations carry seq_cst: this store, the
        /// loads in `hasPending`, the pending increment in
        /// `ChannelHandle.post`, and the services load in
        /// `requestHostWake`.
        ///
        /// WHAT IS PUBLISHED IS A SNAPSHOT, never the caller's storage.
        /// The caller's `PlatformServices` value lives on the Runtime,
        /// and a wake call teardown ABANDONS (see `quiesceChannelWake`)
        /// outlives the Runtime: a poster suspended between capturing
        /// the published pointer and dereferencing it inside
        /// `services.wake()` would read freed Runtime memory. So the
        /// bind generation copies the value into process-lifetime
        /// storage and publishes the copy's address — LAZILY: the
        /// snapshot exists for producer-thread wakes alone, so it
        /// materializes at whichever comes LAST of this bind and the
        /// first live `openChannel` (see `materializeWakeSnapshot`),
        /// and an app that never opens a channel never allocates one.
        /// Immutable-per-bind is the tear-freedom argument: a snapshot,
        /// once published, is never written again, so there is no
        /// rebind race to reason about beyond the atomic pointer swap
        /// itself — a rebind (a second bind after `deinit` cleared the
        /// first; mid-life binds are first-bind-sticks no-ops)
        /// allocates a FRESH snapshot and swaps the pointer, and a
        /// stale call that captured the old pointer keeps reading
        /// intact, fully-initialized memory for as long as it can
        /// exist. Publication safety rides the existing handshake
        /// unchanged: the copy is fully written before the seq_cst
        /// store, and every reader loads the pointer with seq_cst
        /// before dereferencing. Disposal follows the ownership rule at
        /// `wake_snapshot`: alive from the first channel wake arm until
        /// clean teardown frees it; process-lived only past an abandon.
        pub fn bindServices(self: *Self, services: *const platform.PlatformServices) void {
            if (self.services != null) return;
            self.services = services;
            // Open-before-bind: a channel wake header is already armed
            // and its producer may already be posting, so this bind IS
            // the publication site. Bind-before-open publishes at the
            // first live `openChannel` instead (the lazy rule), and
            // replay never publishes at all — parked handles are inert.
            if (self.liveChannelWakeArmed() and !self.materializeWakeSnapshot()) {
                // The publication failed with channels LIVE — the one
                // shape `openChannel`'s refusing pre-flight cannot
                // reach (these opens were committed before any
                // services existed). Left open, they would keep
                // accepting posts that can never wake the host — and
                // with no unrelated loop event, never deliver — so
                // CLOSE them instead: the accepted backlog flushes,
                // each `.closed` terminal (drop totals aboard)
                // delivers through the loop-side wake the close and
                // the sweep below nudge, and the producer's next post
                // answers `.closed`, its exit signal. Loud, like every
                // containment on this seam.
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "effects bindServices: closing the open channels - without the snapshot their accepted posts could never wake the host; each flushes its backlog and delivers its .closed terminal\n",
                        .{},
                    );
                }
                for (&self.channel_slots) |*slot| {
                    if (slot.state == .open and slot.shared != null) self.closeChannel(slot.key);
                }
                // Running ptys arm the same producer-wake seam and hit
                // the same dead end: their io thread could never wake
                // the host. Wind each down — kill the child and wait
                // (bounded) for the io thread to stage its exit — so the
                // exit is pending for the catch-up sweep below to
                // deliver, instead of stranding forever. (Reachable only
                // when a pty was spawned before `bindServices`, which
                // the standard startup order never does; contained here
                // regardless.)
                if (comptime pty_transport.supported) {
                    for (&self.pty_slots) |*pty_slot| {
                        if (!(pty_slot.state == .running and !pty_slot.fake)) continue;
                        const shared = pty_slot.shared orelse continue;
                        shared.mutex.lock();
                        shared.shutdown = true;
                        shared.kill_requested = true;
                        if (!(shared.reaping or shared.exit_staged or shared.io_done)) {
                            if (pty_slot.transport) |transport| transport.kill(false);
                        }
                        shared.mutex.unlock();
                        pty_transport.nudge(pty_slot.wake_pipe[1]);
                        const start_ns = runtime_clock.monotonicNanoseconds();
                        while (true) {
                            shared.mutex.lock();
                            const done = shared.io_done;
                            shared.mutex.unlock();
                            if (done) break;
                            const elapsed_ms = (runtime_clock.monotonicNanoseconds() - start_ns) / std.time.ns_per_ms;
                            if (elapsed_ms >= self.spawn_join_deadline_ms) break;
                            std.atomic.spinLoopHint();
                        }
                    }
                }
            }
            // Sweep unconditionally, snapshot or no snapshot: work
            // staged BEFORE this bind could never reach the host
            // (`wakeHost` was a no-op with `services` null), so exactly
            // one catch-up nudge here covers every stage — the
            // publisher's load half of the Dekker handshake at
            // `materializeWakeSnapshot`.
            if (self.hasPending()) self.wakeHost();
        }

        /// Whether any channel occupancy currently has an armed wake
        /// header — a producer that could consume the published
        /// services snapshot. Replay parks never arm one (their
        /// handles are inert by construction), and a closed occupancy
        /// revoked its binding (stale posts fail the open/generation
        /// gates before reaching the wake, so no snapshot is needed on
        /// their account). Loop-thread only.
        fn liveChannelWakeArmed(self: *Self) bool {
            if (self.replay) return false;
            for (&self.channel_slots) |*slot| {
                if (slot.state == .open and slot.shared != null) return true;
            }
            // Ptys arm the same producer-wake seam: a running REAL
            // occupancy's io thread wakes through its shared header.
            for (&self.pty_slots) |*slot| {
                if (slot.state == .running and !slot.fake and slot.shared != null) return true;
            }
            return false;
        }

        /// Allocate and publish the services snapshot producer threads
        /// dereference inside `services.wake()` — once per bind
        /// generation, at whichever comes last of `bindServices` and
        /// the first live `openChannel` (the lazy rule at
        /// `bindServices`). Storage comes from
        /// `channel_storage_allocator` (process-lifetime by default;
        /// the seam the snapshot lifetime tests count through) and is
        /// disposed by `deinit` under the ownership rule at
        /// `wake_snapshot`.
        ///
        /// THE DEKKER ARGUMENT MOVES WITH THE PUBLICATION, intact: the
        /// bind/post store-buffer handshake (the four-operation
        /// argument at `bindServices`) constrains the pair
        /// publish-then-sweep, not where the pair runs. The store half
        /// is here (the seq_cst `wake_services` store) and EVERY
        /// caller supplies the load half — a seq_cst `hasPending`
        /// sweep after a `true` return — so whichever of {this store,
        /// a poster's pending increment} is later in the seq_cst total
        /// order, that thread's subsequent load observes the other
        /// side's store, and an accepted post always gets a wake from
        /// one of them. At the `openChannel` site the sweep looks
        /// redundant (the channel being opened has no handle yet, so
        /// no producer of its generation can have posted) but is
        /// load-bearing for the retry story: a publication attempt
        /// that failed allocation leaves producer wakes disarmed,
        /// posts accepted in that window latch nothing, and the next
        /// successful publication's sweep is what un-strands them.
        ///
        /// FAILURE CONTAINMENT differs by site, and together the two
        /// sites keep one invariant: NO live channel ever runs with
        /// producer wakes disarmed while services are bound.
        /// `openChannel` REFUSES the open outright (no channel exists
        /// whose accepted posts could strand wakeless); `bindServices`
        /// CLOSES the channels that were already open (committed
        /// before any services existed — the one shape the refusing
        /// pre-flight cannot reach), flushing their backlogs and
        /// delivering their terminals through the bind's own loop-side
        /// wake. Returns whether THIS call published.
        fn materializeWakeSnapshot(self: *Self) bool {
            if (self.wake_services.load(.seq_cst) != null) return false;
            const services = self.services orelse return false;
            const snapshot = self.channel_storage_allocator.create(platform.PlatformServices) catch {
                // No storage for the snapshot: leave the producer-side
                // mirror disarmed rather than publish a pointer whose
                // owner can die before an abandoned call dereferences
                // it; each call site contains the consequence (see the
                // doc above).
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print("effects: cannot allocate the process-lived services snapshot; producer-thread host wakes stay disarmed until a later open retries\n", .{});
                }
                return false;
            };
            snapshot.* = services.*;
            self.wake_snapshot = snapshot;
            self.wake_services.store(snapshot, .seq_cst);
            return true;
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
        /// Bind the runtime's media-surface texture channels
        /// (`Runtime.mediaSurfaceBinding()`), so `loadVideo` can claim
        /// the surface a video widget binds. Loop-thread only.
        pub fn bindMediaSurfaces(self: *Self, binding: MediaSurfaceBinding) void {
            self.media_surfaces = binding;
        }

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

        /// End-of-journal consistency check (the `.finish` replay
        /// control): every journaled video cascade resolution must have
        /// been consumed by the load it named, and none may have paired
        /// against a different key. A leftover or mismatched record
        /// means the replayed updates issued different loads than the
        /// recording — divergence, not success.
        pub fn finishReplay(self: *Self) error{ReplayVideoDivergence}!void {
            if (self.replay_video_diverged) return error.ReplayVideoDivergence;
            if (self.replay_video_source_len > 0) {
                std.debug.print(
                    "session replay: {d} journaled video load resolution(s) were never consumed by a replayed load - the replayed updates issued different loads than the recording (nondeterminism outside the effect boundary?)\n",
                    .{self.replay_video_source_len},
                );
                return error.ReplayVideoDivergence;
            }
            // Every FED record is one recorded delivery, and the event
            // during whose dispatch it delivered live sits AFTER it in
            // the journal — so a fed entry still staged when the
            // journal ends was never consumed by the stream that
            // recorded it: the file is truncated or hand-edited (or
            // the replayed updates issued different effects).
            // Regenerated loop-side answers (resolve = false) may
            // honestly outlive the last drain — a recording can end
            // before the wake that would have delivered them, on both
            // timelines symmetrically.
            var offset: usize = 0;
            const storage = self.pendingVideoStorage();
            while (offset < self.pending_video_len) : (offset += 1) {
                const entry = storage[(self.pending_video_head + offset) % storage.len];
                if (!entry.resolve) continue;
                std.debug.print(
                    "session replay: a journaled video result for key {d} was never delivered - the recording's own delivering event follows every record, so the journal is truncated or hand-edited (or the replayed updates issued different effects)\n",
                    .{entry.event.key},
                );
                return error.ReplayVideoDivergence;
            }
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

        /// The verdict queue's current backing storage —
        /// `pendingStagedStorage`'s twin.
        fn replayPtyWriteStorage(self: *Self) []ReplayPtyWriteVerdict {
            if (self.replay_pty_write_spill.len > 0) return self.replay_pty_write_spill;
            return &self.replay_pty_write_verdicts;
        }

        /// Queue one journaled `ptyWrite` admission verdict for a
        /// replay-mode write (the `.pty`/`.write` record feed — the
        /// clock queue's shape, growable past the inline window because
        /// every verdict a dispatch recorded feeds BEFORE that dispatch
        /// replays: a fixed bound would reject a valid recording whose
        /// one update wrote more times than the bound).
        pub fn pushReplayPtyWriteVerdict(self: *Self, key: u64, accepted: bool) error{EffectNotFound}!void {
            const storage = self.replayPtyWriteStorage();
            if (self.replay_pty_write_len == storage.len) {
                const new_cap = storage.len * 2;
                const grown = self.allocator.alloc(ReplayPtyWriteVerdict, new_cap) catch return error.EffectNotFound;
                for (grown[0..self.replay_pty_write_len], 0..) |*slot, index| {
                    slot.* = storage[(self.replay_pty_write_head + index) % storage.len];
                }
                if (self.replay_pty_write_spill.len > 0) self.allocator.free(self.replay_pty_write_spill);
                self.replay_pty_write_spill = grown;
                self.replay_pty_write_head = 0;
            }
            const active = self.replayPtyWriteStorage();
            active[(self.replay_pty_write_head + self.replay_pty_write_len) % active.len] = .{
                .key = key,
                .accepted = accepted,
            };
            self.replay_pty_write_len += 1;
        }

        /// Verify every journaled replay feed was consumed exactly:
        /// called at the journal's end (the `.finish` replay
        /// control). A leftover write verdict means the replayed updates
        /// wrote FEWER times than the recording; a recorded underflow
        /// means they wrote MORE. Neither necessarily moves a
        /// fingerprint checkpoint (a fire-and-forget caller ignores the
        /// optimistic answer and changes no state), so the settle check
        /// is what makes write-count divergence loud.
        pub fn settleReplayFeeds(self: *Self) error{ReplayDivergence}!void {
            // The clock feed settles by the same rule as the write
            // verdicts: a `wallMs` read past the journaled values, or a
            // journaled value never consumed, is divergence a checkpoint
            // may not see (the optimistic 0 answer, or the skipped read,
            // need not move any rendered state).
            if (self.replay_clock_underflows > 0) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay diverged: {d} wallMs read(s) ran past the journaled clock values - the replayed updates read the clock more often than the recording did (nondeterminism outside the effect boundary?)\n",
                        .{self.replay_clock_underflows},
                    );
                }
                return error.ReplayDivergence;
            }
            if (self.replay_clock_len > 0) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay diverged: {d} journaled clock value(s) were never consumed - the replayed updates read the clock fewer times than the recording did (nondeterminism outside the effect boundary?)\n",
                        .{self.replay_clock_len},
                    );
                }
                return error.ReplayDivergence;
            }
            if (self.replay_pty_write_divergences > 0) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay diverged: {d} ptyWrite call(s) ran past the journaled verdicts or wrote to a different pty than the recording did (nondeterminism outside the effect boundary?)\n",
                        .{self.replay_pty_write_divergences},
                    );
                }
                return error.ReplayDivergence;
            }
            if (self.replay_pty_write_len > 0) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay diverged: {d} journaled ptyWrite verdict(s) were never consumed - the replayed updates wrote fewer times than the recording did (nondeterminism outside the effect boundary?)\n",
                        .{self.replay_pty_write_len},
                    );
                }
                return error.ReplayDivergence;
            }
            // Fed pty results still awaiting delivery: the recorder
            // journals every result at its live DELIVERY — inside a
            // dispatched event that follows it in the stream — so a
            // journal that ends with a fed result still queued was
            // truncated past its consuming event. Succeeding here would
            // silently omit a recorded delivery. Regenerating staged
            // rejections are exempt: the live run could also end with
            // one staged (it journals nothing until delivery), and the
            // replayed dispatch restaged it identically.
            var undelivered_pty: usize = 0;
            {
                self.queue_mutex.lock();
                defer self.queue_mutex.unlock();
                var index: usize = 0;
                while (index < self.queue_len) : (index += 1) {
                    const entry = &self.queue[(self.queue_head + index) % max_effect_queue_entries];
                    if (entry.kind == .pty) undelivered_pty += 1;
                }
            }
            {
                const storage = self.pendingPtyStorage();
                var index: usize = 0;
                while (index < self.pending_pty_len) : (index += 1) {
                    const entry = &storage[(self.pending_pty_head + index) % storage.len];
                    if (!entry.regenerates) undelivered_pty += 1;
                }
            }
            if (undelivered_pty > 0) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay diverged: {d} fed pty result(s) were never delivered - the journal ends before the event that consumed them live (truncated or hand-edited?)\n",
                        .{undelivered_pty},
                    );
                }
                return error.ReplayDivergence;
            }
        }

        /// Pop the next journaled write verdict for a replay-mode
        /// `ptyWrite` against `key`. An empty queue, or a head verdict
        /// recorded against a DIFFERENT pty, is a divergence signal (the
        /// replayed update wrote more, or wrote elsewhere, than the
        /// recording did); reported once and answered optimistically so
        /// the dispatch can finish — the end-of-journal settle check
        /// (`settleReplayFeeds`) turns the count into a loud replay
        /// failure either way (a key mismatch also strands its verdict,
        /// so the leftover check backstops it too).
        fn takeReplayPtyWriteVerdict(self: *Self, key: u64) bool {
            if (self.replay_pty_write_len == 0) {
                self.replay_pty_write_divergences += 1;
                if (self.replay_pty_write_divergences == 1 and comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "session replay: a ptyWrite found no journaled verdict - the replayed update writes more often than the recording did (nondeterministic control flow); answering accepted\n",
                        .{},
                    );
                }
                return true;
            }
            const storage = self.replayPtyWriteStorage();
            const head = storage[self.replay_pty_write_head];
            if (head.key != key) {
                self.replay_pty_write_divergences += 1;
                if (self.replay_pty_write_divergences == 1 and comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "session replay: a ptyWrite against key {d} found a verdict recorded against key {d} - the replayed update writes to a different pty than the recording did (nondeterministic control flow); answering accepted\n",
                        .{ key, head.key },
                    );
                }
                return true;
            }
            self.replay_pty_write_head = (self.replay_pty_write_head + 1) % storage.len;
            self.replay_pty_write_len -= 1;
            if (self.replay_pty_write_len == 0) {
                self.replay_pty_write_head = 0;
                if (self.replay_pty_write_spill.len > 0) {
                    self.allocator.free(self.replay_pty_write_spill);
                    self.replay_pty_write_spill = &.{};
                }
            }
            return head.accepted;
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

        /// Open an external-source channel: the public seam for
        /// app-owned long-lived sources (sockets, file watchers, worker
        /// threads) to wake the UI loop and produce Msgs WITHOUT timer
        /// polling — the same completion-queue-plus-wake ride every
        /// runtime-owned source already takes, made first-class. The
        /// returned `ChannelHandle` is thread-safe: hand it to the
        /// source thread and `post(bytes)` away; each accepted post
        /// delivers exactly one `.data` event Msg through `on_event` on
        /// the next drain (bytes in drain scratch — copy what the model
        /// keeps). A channel is LONG-LIVED: it occupies its key from
        /// open until `closeChannel`'s `.closed` terminal delivers, and
        /// the key space is the keyed families' shared one — a same-key
        /// fetch rejects while a channel holds the key, and vice versa.
        /// Never fails from the caller's view: a duplicate occupied
        /// key, a full channel table, or an executor that could not
        /// stage the channel delivers exactly one `.rejected` event on
        /// the next drain (and the returned handle is dead — posts
        /// answer `.closed`). Channel events are journaled as executor
        /// truth at the drain boundary; under session replay the
        /// recorded events feed verbatim and the source is never
        /// NEEDED: the replayed open PARKS the occupancy (the key
        /// registers exactly as live, so duplicate opens reject
        /// symmetrically) and returns an INERT handle whose every post
        /// answers `.closed`. Honesty about what re-runs: the update
        /// that calls this openChannel re-executes under replay — app
        /// code is app code — so a producer launched unconditionally
        /// really starts, and any connect or blocking setup before its
        /// first post really happens; the inert handle only stops it
        /// AT that first post. Consult `ChannelHandle.live()` before
        /// launching (the channel-monitor example's pattern) and the
        /// producer never starts at all, keeping replay fully offline
        /// — the Msg stream is identical either way, because the
        /// journaled events are the whole stream on both paths.
        pub fn openChannel(self: *Self, options: OpenChannelOptions) ChannelHandle {
            self.reclaimSlots();
            const dead: ChannelHandle = .{};
            // Occupancy is the keyed families' shared admission gate —
            // validation-class, so the refusal regenerates under
            // replay (the same windows re-derive there).
            if (self.keyOccupiedUntilDelivery(options.key)) {
                self.rejectChannel(options.key, options.on_event, true);
                return dead;
            }
            const slot_index = self.findIdleChannelSlot() orelse {
                self.rejectChannel(options.key, options.on_event, true);
                return dead;
            };
            // TABLE CAPACITY obeys the replay-hold invariant: any
            // resource replay holds until a terminal feeds, live must
            // hold until that terminal drains. An alloc-failed open
            // (below) stages an executor-truth `.rejected` and claims
            // no slot — but its replay twin PARKS a REAL slot until
            // that journaled terminal feeds, so live must keep the
            // open counted against the table through the same window
            // or live accepts an open whose replay answer is a
            // regenerating table-full reject, leaving the accepted
            // open's journaled terminals with no parked request to
            // feed (`ReplayEffectDivergence`).
            // `stagedChannelOccupiesKey` holds the KEY through this
            // window; the reservation count holds the CAPACITY. The
            // asymmetry with the refusal one line up is deliberate and
            // is the same regenerating/non-regenerating line the key
            // window draws: a table-full (or occupied-key) reject is
            // REGENERATING — replay re-derives it against the parked
            // table and stages its own, no slot held on either side —
            // so it must NOT reserve; only executor-truth rejections
            // reserve.
            if (self.idleChannelSlotCount() <= self.stagedChannelReservationCount()) {
                self.rejectChannel(options.key, options.on_event, true);
                return dead;
            }
            const slot = &self.channel_slots[slot_index];
            // Session replay: PARK the occupancy instead of arming a
            // live channel — the fake-slot discipline, channel-shaped.
            // The slot registers exactly as a live open (duplicate
            // opens reject symmetrically above, the shared key space
            // holds), but no staging is allocated, nothing can be
            // journaled, and the returned handle is INERT: every post
            // answers `.closed` immediately (nothing staged, no drop
            // counted), so a re-run source thread exits on its first
            // post. The journaled `.data` events are the whole stream,
            // and the fed `.closed`/`.rejected` terminal retires the
            // parked slot at its recorded position (`feedChannelEvent`
            // -> the drain's terminal retire), the same causal instant
            // live delivery frees the key.
            if (self.replay) {
                const parked_generation = self.nextChannelGeneration();
                slot.state = .open;
                slot.key = options.key;
                slot.generation = parked_generation;
                slot.on_event = options.on_event;
                slot.closed_seq = 0;
                slot.closed_staged = false;
                // Reserve the pending-order slot a live executor-truth
                // refusal of THIS open would have staged at — stamped
                // unconditionally, because refusal-vs-accepted is only
                // knowable when the journaled feed arrives (see
                // `ParkOrderState` for the full resolution story).
                slot.park_seq = self.nextPendingSeq();
                slot.park_state = .reserved;
                return dead;
            }
            // Materialize the services snapshot BEFORE committing the
            // occupancy (the lazy half of the ownership rule at
            // `wake_snapshot`; a no-op once published or while no
            // services are bound — `bindServices` publishes then). A
            // channel whose snapshot cannot allocate can never wake the
            // host from a producer thread — its accepted posts would
            // strand until unrelated traffic — so the open REFUSES
            // instead of handing out a handle that cannot fulfill the
            // posting contract: the same executor-truth rejection class
            // as the header/staging allocation failures below. A
            // publication is followed by its Dekker sweep (see
            // `materializeWakeSnapshot`) — publish-then-sweep is the
            // invariant every publication site keeps, cheap insurance
            // here where the failure containments leave no post to
            // strand.
            if (self.services != null and self.wake_services.load(.seq_cst) == null) {
                if (!self.materializeWakeSnapshot()) {
                    self.rejectChannel(options.key, options.on_event, false);
                    return dead;
                }
                if (self.hasPending()) self.wakeHost();
            }
            // The posting header is process-lifetime storage: created
            // at the slot's first open, reused forever (see
            // `ChannelShared`). Failing to stage the channel is NOT
            // regenerable validation — the replayed open stages its
            // own and parks the slot, so this terminal journals as
            // executor truth and feeds (mirroring `loadImage`'s
            // allocation-failure classification), and the staged
            // rejection holds the key until it drains.
            const shared = slot.shared orelse blk: {
                const created = self.channel_storage_allocator.create(ChannelShared) catch {
                    self.rejectChannel(options.key, options.on_event, false);
                    return dead;
                };
                created.* = .{};
                slot.shared = created;
                break :blk created;
            };
            const staging = self.channel_storage_allocator.create(ChannelStaging) catch {
                self.rejectChannel(options.key, options.on_event, false);
                return dead;
            };
            staging.* = .{};
            const generation = self.nextChannelGeneration();
            slot.state = .open;
            slot.key = options.key;
            slot.generation = generation;
            slot.on_event = options.on_event;
            slot.closed_seq = 0;
            slot.closed_staged = false;
            slot.park_seq = 0;
            slot.park_state = .none;
            shared.mutex.lock();
            shared.open = true;
            shared.generation = generation;
            shared.max_pending = std.math.clamp(options.max_pending, 1, @as(u32, max_effect_channel_pending));
            shared.dropped_pending = 0;
            shared.dropped_total = 0;
            shared.staging = staging;
            shared.owner = .{
                .seq = &self.channel_seq,
                .pending = &self.channel_pending_count,
            };
            shared.mutex.unlock();
            // Arm the wake binding for this occupancy (after the
            // staging mutex dropped — the locks never nest). No handle
            // of THIS generation exists before we return, so nothing
            // races the arm; a stale generation taking the wake mutex
            // fails its generation gate.
            shared.wake.mutex.lock();
            shared.wake.generation = generation;
            shared.wake.services = &self.wake_services;
            shared.wake.pending.store(false, .seq_cst);
            shared.wake.mutex.unlock();
            return .{ .shared = shared, .generation = generation };
        }

        /// The thread-safe posting handle of the OPEN channel with
        /// `key`, for callers that did not keep `openChannel`'s return
        /// (an embedder resolving a channel a transpiled core opened).
        /// Null while no open channel holds the key — including the
        /// `.closing` window, where posts could no longer land anyway.
        pub fn channelHandle(self: *Self, key: u64) ?ChannelHandle {
            for (&self.channel_slots) |*slot| {
                if (slot.state == .open and slot.key == key) {
                    return .{ .shared = slot.shared, .generation = slot.generation };
                }
            }
            return null;
        }

        /// Close the open channel with `key`: posts stop landing
        /// immediately (the handle answers `.closed`), the staged
        /// backlog flushes in post order, and exactly one terminal
        /// `.closed` event (final drop totals aboard) delivers and
        /// retires the key. Unknown keys — and a key already `.closing`
        /// — are a no-op, `cancelTimer`'s idle rule; and `cancel(key)`
        /// is NOT a channel's close (channels end the way audio does:
        /// through their own verb).
        pub fn closeChannel(self: *Self, key: u64) void {
            const slot = self.findChannelSlot(key) orelse return;
            if (slot.state != .open) return;
            slot.state = .closing;
            // A replay-parked occupancy never armed the posting header
            // (its handle was inert from the open), so there may be
            // nothing to sever here.
            if (slot.shared) |shared| {
                shared.mutex.lock();
                shared.open = false;
                shared.mutex.unlock();
                // Revoke AFTER `open` cleared: no NEW host call can
                // start past this line (the generation gate), and an
                // in-flight one finishes against the process-lifetime
                // header on its own time. Never a quiescing wait here —
                // this close may BE the dispatch a synchronous-marshal
                // `wake_fn` is waiting on (see `revokeChannelWake`).
                revokeChannelWake(&shared.wake);
            }
            // Replay mode: the recorded session already journaled this
            // channel's `.closed` terminal, and feeding that record is
            // the one delivery — the slot parks `.closing` until then
            // (the `cancel` discipline), with no live flush (the fed
            // events carry whatever the recording delivered).
            if (self.replay) return;
            slot.closed_seq = self.channel_seq.fetchAdd(1, .monotonic);
            slot.closed_staged = true;
            _ = self.channel_pending_count.fetchAdd(1, .monotonic);
            self.wakeHost();
        }

        /// Feed a RECORDED channel event — the session-replay feed
        /// (and the failure-class test seam): the journaled kind,
        /// bytes, and drop counts deliver verbatim through the OPEN (or
        /// `.closing`) channel's `on_event` at the next drain, in queue
        /// order with every other fed result. `.closed` and `.rejected`
        /// retire the channel slot at delivery, the same causal instant
        /// live delivery frees the key. Bytes are clamped to
        /// `max_effect_channel_bytes` for memory safety only — the
        /// replay damage gate refuses over-bound records before they
        /// reach here, and no recorder-produced journal carries one.
        ///
        /// Terminals feed only into PARKED (or already-retired-header)
        /// occupancies — the shapes replay constructs, where the
        /// posting handle is inert by construction and no accepted
        /// post can exist. Feeding a terminal into a LIVE occupancy
        /// (an open posting header, a staged backlog, or an armed
        /// close marker) answers `error.ChannelLiveFeed` instead of
        /// racing the producer: the fed terminal's delivery retires
        /// the slot and destroys the staging FIFO, so a post accepted
        /// after the drain snapshot but before the terminal processes
        /// would be silently destroyed with its `hasPending` count
        /// stranded — a permanent busy signal. Live occupancies end
        /// through `closeChannel`, never through the feed seam.
        ///
        /// One terminal per open, nothing past it: a replay-parked
        /// occupancy's pending-order reservation (`ParkOrderState`)
        /// resolves at the FIRST fed terminal and never again — a
        /// `.rejected` record targeting a park already resolved, or
        /// ANY record targeting an open whose terminal already fed, is
        /// journal damage (`error.ReplayDamagedRecord`), refused
        /// before it could append a duplicate terminal to the pending
        /// ring or enqueue an event the terminal's retire would
        /// silently discard.
        pub fn feedChannelEvent(self: *Self, key: u64, kind: EffectChannelEventKind, bytes: []const u8, dropped_pending: u32, dropped_total: u32) error{ EffectNotFound, EffectQueueFull, ChannelLiveFeed, ReplayDamagedRecord }!void {
            const slot_index = blk: {
                for (&self.channel_slots, 0..) |*slot, index| {
                    if (slot.state != .idle and slot.key == key) break :blk index;
                }
                return error.EffectNotFound;
            };
            const slot = &self.channel_slots[slot_index];
            if (kind != .data and channelSlotLive(slot)) return error.ChannelLiveFeed;
            // A replay-parked open resolves its pending-order
            // reservation from the feed's evidence (`ParkOrderState`):
            // the journaled REFUSAL reclaims the stamp — it delivers
            // through the pending stage at the park's dispatch-time
            // seq, exactly where live staged it, never through the
            // completion queue the drain serves later — and any other
            // kind proves the open was accepted live (an accepted open
            // staged nothing at dispatch), so the reservation vacates
            // and the event rides the queue like every fed result.
            if (slot.park_state != .none) {
                // Nothing feeds after the open's terminal: between a
                // terminal's feed and its delivery the slot is still
                // occupied, so a damaged journal's extra records would
                // otherwise enqueue here and then be silently discarded
                // by the delivery generation gate once the terminal
                // retires the slot — an invalid stream that unverified
                // replay would pass. One terminal per open, nothing
                // past it.
                if (slot.park_state == .terminated) {
                    if (comptime builtin.os.tag != .freestanding) {
                        std.debug.print(
                            "replay refused: channel record for key {d} feeds a .{s} event after the open's terminal already fed - a channel delivers nothing past its terminal (one terminal per open), so the journal is damaged or hand-edited; re-record the session\n",
                            .{ key, @tagName(kind) },
                        );
                    }
                    return error.ReplayDamagedRecord;
                }
                if (kind == .rejected) {
                    // Resolve ONLY while `.reserved`: one open reserves
                    // exactly one pending-order stamp, and the first
                    // fed terminal spends it. A `.rejected` record
                    // targeting a park the stream already proved
                    // ACCEPTED live (`.vacated` — a `.data` fed first)
                    // is a terminal the recorded open can never have
                    // produced (a refused open delivers nothing before
                    // its refusal); reusing the stamp would append
                    // duplicate entries to the one-entry-per-open
                    // pending ring until its capacity panic. Refuse the
                    // record as journal damage instead.
                    if (slot.park_state != .reserved) {
                        if (comptime builtin.os.tag != .freestanding) {
                            std.debug.print(
                                "replay refused: channel record for key {d} feeds a .rejected terminal into a park already resolved - a recorded open delivers exactly one terminal (one terminal per open), so the journal is damaged or hand-edited; re-record the session\n",
                                .{key},
                            );
                        }
                        return error.ReplayDamagedRecord;
                    }
                    const park_seq = slot.park_seq;
                    slot.park_state = .terminated;
                    self.stagePendingChannel(.{
                        .seq = park_seq,
                        .event = .{
                            .key = key,
                            .kind = .rejected,
                            .dropped_pending = dropped_pending,
                            .dropped_total = dropped_total,
                        },
                        .channel_fn = slot.on_event,
                        .regenerates = false,
                        .retire_slot = slot_index,
                        .retire_generation = slot.generation,
                    });
                    return;
                }
                // `.data` and `.closed` resolve the park too — but the
                // transition applies only AFTER the enqueue below
                // succeeds: a full queue answers `EffectQueueFull` and
                // the replay pump drains and feeds the SAME record
                // again, so a state written before a refused enqueue
                // would turn that legal retry into a damage refusal of
                // a valid journal.
            }
            const staged_len = @min(bytes.len, max_effect_channel_bytes);
            var entry: Entry = .{
                .kind = .channel,
                .slot_index = @intCast(slot_index),
                .channel_generation = slot.generation,
                .key = key,
                .line_len = @intCast(staged_len),
                .dropped_before = dropped_pending,
                .dropped_lines = dropped_total,
                .channel_kind = kind,
            };
            @memcpy(entry.line_bytes[0..staged_len], bytes[0..staged_len]);
            // Everything goes THROUGH the queue (the fed-image
            // discipline): a full queue back-pressures with
            // `error.EffectQueueFull` and the replay pump drains and
            // feeds again, so recorded delivery order survives drain
            // passes larger than the queue.
            if (!self.enqueue(&entry)) return error.EffectQueueFull;
            // The event is committed: NOW resolve the park. `.data`
            // proves the open was accepted live and keeps the recorded
            // stream flowing; `.closed` is that stream's one terminal.
            if (slot.park_state != .none) {
                slot.park_state = if (kind == .closed) .terminated else .vacated;
            }
            self.wakeHost();
        }

        /// Feed a RECORDED pty output batch — the session-replay feed
        /// and the scriptable fake pty's output seam: the bytes deliver
        /// verbatim through the occupied slot's `on_event` at the next
        /// drain, in queue order with every other fed result. Batches
        /// past the inline entry bound ride a heap payload (the raised
        /// line-bound discipline). Live REAL occupancies refuse the
        /// feed — fed events are for parked fakes and replay, never a
        /// second producer beside a live io thread.
        pub fn feedPtyOutput(self: *Self, key: u64, bytes: []const u8) error{ EffectNotFound, EffectQueueFull, PtyLiveFeed, PtyChunkTooLarge, ReplayDamagedRecord }!void {
            const slot_index = blk: {
                for (&self.pty_slots, 0..) |*slot, index| {
                    if (slot.state != .idle and slot.key == key) break :blk index;
                }
                return error.EffectNotFound;
            };
            const slot = &self.pty_slots[slot_index];
            if (!slot.fake) return error.PtyLiveFeed;
            if (slot.park_state == .terminated) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay refused: pty record for key {d} feeds output after the spawn's terminal already fed - a pty delivers nothing past its exit (one terminal per spawn), so the journal is damaged or hand-edited; re-record the session\n",
                        .{key},
                    );
                }
                return error.ReplayDamagedRecord;
            }
            // One batch never exceeds the chunk bound (the live ring
            // splits at it, and the replay damage gate refuses a bigger
            // record) — reject an over-bound feed rather than deliver a
            // silently truncated prefix.
            if (bytes.len > max_effect_pty_chunk_bytes) return error.PtyChunkTooLarge;
            // Empty output is a no-op: the live drain only ever delivers
            // a non-empty batch, so journaling an empty one would write
            // a zero-length blob record that replay refuses as damage.
            // A fake feed of "" simply delivers nothing.
            if (bytes.len == 0) return;
            const staged_len = bytes.len;
            var entry: Entry = .{
                .kind = .pty,
                .slot_index = @intCast(slot_index),
                .channel_generation = slot.generation,
                .key = key,
                .line_len = @intCast(staged_len),
                .pty_kind = .output,
                // A non-exit event carries the -1 code sentinel, matching
                // the live drain's `EffectPtyEvent` default (whose `code`
                // is `effect_error_exit_code`). Without this the Entry's
                // own `code` default of 0 would make a replayed output
                // batch deliver code 0 where the live run delivered -1 —
                // a deterministic-state divergence for an app that folds
                // the code into its model.
                .code = effect_error_exit_code,
            };
            if (staged_len > entry.line_bytes.len) {
                const heap = self.allocator.alloc(u8, staged_len) catch return error.EffectQueueFull;
                @memcpy(heap[0..staged_len], bytes[0..staged_len]);
                entry.heap_line = heap;
            } else {
                @memcpy(entry.line_bytes[0..staged_len], bytes[0..staged_len]);
            }
            if (!self.enqueue(&entry)) {
                if (entry.heap_line) |heap| self.allocator.free(heap);
                return error.EffectQueueFull;
            }
            // The first fed event proves the spawn started live: the
            // park's pending-order reservation vacates unused.
            if (slot.park_state == .reserved) slot.park_state = .vacated;
            self.wakeHost();
        }

        /// Feed a RECORDED pty exit — the terminal half of the replay
        /// feed and the fake pty's scripted ending. Start failures
        /// (`.rejected`, `.spawn_failed`) resolve a replay park's
        /// pending-order reservation and deliver at the spawn's
        /// dispatch position (the channel park dance); real endings
        /// ride the completion queue and retire the slot at delivery.
        pub fn feedPtyExit(self: *Self, key: u64, code: i32, signal: i32, reason: EffectExitReason, dropped_writes: u32) error{ EffectNotFound, EffectQueueFull, PtyLiveFeed, ReplayDamagedRecord }!void {
            const slot_index = blk: {
                for (&self.pty_slots, 0..) |*slot, index| {
                    if (slot.state != .idle and slot.key == key) break :blk index;
                }
                return error.EffectNotFound;
            };
            const slot = &self.pty_slots[slot_index];
            if (!slot.fake) return error.PtyLiveFeed;
            // Normalize the tuple to the EffectPtyEvent contract the live
            // io loop guarantees, so a fake (test or replay) can never
            // stage an event the recorder journals but replay's damage
            // gate then refuses: a signal is meaningful only after a
            // `.signaled` end, and a code only after an `.exited` one —
            // every other reason carries the -1 sentinel. This clamps at
            // the feed boundary rather than trusting the caller.
            const norm_signal: i32 = if (reason == .signaled) signal else 0;
            const norm_code: i32 = if (reason == .exited) code else effect_error_exit_code;
            // The contract is a BICONDITIONAL: `.signaled` also REQUIRES a
            // nonzero signal (replay's gate treats `signaled != (signal !=
            // 0)` as damage). The live io loop never sets `.signaled`
            // without a real signal, so a signaled feed carrying zero is
            // malformed and cannot map to any recordable exit — refuse it
            // loudly rather than journal a record replay would reject.
            if (reason == .signaled and norm_signal == 0) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay refused: pty record for key {d} feeds a .signaled exit with signal 0 - a signaled end names its fatal signal (the live transport never reports zero), so the journal is damaged or hand-edited; re-record the session\n",
                        .{key},
                    );
                }
                return error.ReplayDamagedRecord;
            }
            if (slot.park_state == .terminated) {
                if (comptime builtin.os.tag != .freestanding) {
                    std.debug.print(
                        "replay refused: pty record for key {d} feeds a second terminal - a pty delivers exactly one exit per spawn, so the journal is damaged or hand-edited; re-record the session\n",
                        .{key},
                    );
                }
                return error.ReplayDamagedRecord;
            }
            // The delivered drop count is the fed (transport-reported)
            // count PLUS the refusals the fake itself counted onto the
            // slot (an oversized write, or a write after this exit was
            // staged — both mirror the live admission path). The fold
            // happens AT DELIVERY, the live staged-exit drain's rule, so
            // a refusal between this feed and the drain still lands in
            // the delivered tally; the entry carries only the fed count.
            // Under session replay the slot count is always zero
            // (replay-mode writes never reach the fake admission path),
            // so a replayed exit delivers exactly the journaled count.
            const start_failure = reason == .rejected or reason == .spawn_failed;
            if (start_failure) {
                // A start failure the recorded spawn produced at
                // dispatch: reclaim the park's stamp (one per spawn)
                // and deliver through the pending stage, retiring the
                // parked slot at delivery. Outside replay (a plain
                // fake), there is no reservation — stamp now.
                if (slot.park_state == .vacated) {
                    if (comptime builtin.os.tag != .freestanding) {
                        std.debug.print(
                            "replay refused: pty record for key {d} feeds a start-failure terminal into a spawn the stream already proved started, so the journal is damaged or hand-edited; re-record the session\n",
                            .{key},
                        );
                    }
                    return error.ReplayDamagedRecord;
                }
                const seq = if (slot.park_state == .reserved) slot.park_seq else self.nextPendingSeq();
                slot.park_state = .terminated;
                self.stagePendingPty(.{
                    .seq = seq,
                    .event = .{
                        .key = key,
                        .kind = .exit,
                        .code = norm_code,
                        .reason = reason,
                        .signal = norm_signal,
                        .dropped_writes = dropped_writes,
                    },
                    .pty_fn = slot.on_event,
                    .regenerates = false,
                    .retire_slot = slot_index,
                    .retire_generation = slot.generation,
                });
                return;
            }
            var entry: Entry = .{
                .kind = .pty,
                .slot_index = @intCast(slot_index),
                .channel_generation = slot.generation,
                .key = key,
                .pty_kind = .exit,
                .code = norm_code,
                .reason = reason,
                .pty_signal = norm_signal,
                .pty_dropped_writes = dropped_writes,
            };
            if (!self.enqueue(&entry)) return error.EffectQueueFull;
            // One terminal per spawn, on every fake — not just replay
            // parks: mark terminated so a second output or exit fed
            // before this one drains is refused loudly instead of
            // enqueued and then silently dropped by the delivery
            // generation gate once the exit retires the slot.
            slot.park_state = .terminated;
            self.wakeHost();
        }

        /// Number of recorded (still-active) fake pty spawns.
        pub fn pendingPtyCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.pty_slots) |*slot| {
                if (slot.fake and slot.state == .running) count += 1;
            }
            return count;
        }

        /// The `index`th active fake pty spawn request (insertion
        /// order over the fixed table). Slices borrow slot storage —
        /// valid until the occupancy retires.
        pub fn pendingPtyAt(self: *Self, index: usize) ?PtyRequest {
            var seen: usize = 0;
            for (&self.pty_slots) |*slot| {
                if (!(slot.fake and slot.state == .running)) continue;
                if (seen == index) {
                    return .{
                        .key = slot.key,
                        .argv = slot.requestArgv(),
                        .cols = slot.cols,
                        .rows = slot.rows,
                        .term = slot.requestTerm(),
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Everything the app wrote toward a fake pty (the newest
        /// `max_effect_pty_write_capture_bytes` of it) — the test seam
        /// proving "the app typed ls\n".
        pub fn ptyWrittenBytes(self: *Self, key: u64) []const u8 {
            const slot = self.findPtySlot(key) orelse return "";
            return slot.write_capture[0..slot.write_capture_len];
        }

        /// The grid the pty currently declares (spawn size, updated by
        /// `ptyResize`).
        pub fn ptySize(self: *Self, key: u64) ?struct { cols: u16, rows: u16 } {
            const slot = self.findPtySlot(key) orelse return null;
            return .{ .cols = slot.cols, .rows = slot.rows };
        }

        /// Whether `ptyKill` ran against the occupancy (the fake pty's
        /// kill mirror; the test answers it by feeding the exit).
        pub fn ptyKillRequested(self: *Self, key: u64) bool {
            const slot = self.findPtySlot(key) orelse return false;
            return slot.kill_requested;
        }

        /// Spawn a command onto a fresh pseudo-terminal and stream its
        /// output back as coalesced `on_event` Msgs — a spawn with a
        /// different transport: same argv budgets, same key space, the
        /// same environment policy (`bindEnviron`), and the same
        /// permission/manifest kind (`command`). Never fails from the
        /// caller's view: requests that cannot run deliver exactly one
        /// `.exit` event with reason `.rejected` on the next drain, and
        /// a transport that cannot start (no pty, missing binary)
        /// delivers `.spawn_failed`. Output pacing is the whole point:
        /// bytes arriving between drains coalesce into batches of at
        /// most `max_effect_pty_chunk_bytes`, so a fast producer costs
        /// per-drain Msgs (and journal records), never per-read ones.
        /// Under session replay nothing spawns — the journaled batches
        /// and exit ARE the session (`feedPtyOutput`/`feedPtyExit`).
        pub fn ptySpawn(self: *Self, options: PtySpawnOptions) void {
            self.reclaimSlots();
            if (options.argv.len == 0 or options.argv.len > max_effect_argv) {
                return self.rejectPty(options.key, options.on_event, true);
            }
            var total_bytes: usize = 0;
            for (options.argv) |arg| {
                total_bytes += arg.len;
                // An embedded NUL would be silently truncated at the C
                // boundary — reject the spawn rather than hand the child
                // a cut argument (validated here so the fake executor
                // and replay refuse identically, before the real
                // transport's own guard).
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return self.rejectPty(options.key, options.on_event, true);
            }
            if (total_bytes > max_effect_argv_bytes) return self.rejectPty(options.key, options.on_event, true);
            if (options.cols == 0 or options.rows == 0) return self.rejectPty(options.key, options.on_event, true);
            if (options.term.len == 0 or options.term.len > max_effect_pty_term_bytes) {
                return self.rejectPty(options.key, options.on_event, true);
            }
            // TERM rides the child environment; an embedded NUL would
            // truncate it at the C boundary, so a spawn that "succeeded"
            // would hand the child a different TERM than requested.
            if (std.mem.indexOfScalar(u8, options.term, 0) != null) return self.rejectPty(options.key, options.on_event, true);
            if (self.keyOccupiedUntilDelivery(options.key)) return self.rejectPty(options.key, options.on_event, true);
            const slot_index = self.findIdlePtySlot() orelse return self.rejectPty(options.key, options.on_event, true);
            // Table capacity obeys the replay-hold invariant, the
            // channel argument verbatim: executor-truth start failures
            // park a real slot under replay until the journaled
            // terminal feeds, so live holds the open counted through
            // the staged window too.
            if (self.idlePtySlotCount() <= self.stagedPtyReservationCount()) {
                return self.rejectPty(options.key, options.on_event, true);
            }
            // A build without a pty transport (Windows until ConPTY
            // lands; a libc-free Linux build) refuses up front. Unlike
            // the argv/dims/key bounds above, this is EXECUTOR TRUTH,
            // not regenerating validation: whether a spawn can start is
            // a property of the recording host, so the rejection is
            // journaled (`regenerates = false`) and FED under replay —
            // a session recorded where ptys are unsupported replays its
            // rejection verbatim on a host where they are supported (and
            // the replay executor is always the fake, which parks every
            // spawn), instead of the replayed spawn parking with no
            // journaled terminal to retire it.
            if (comptime !pty_transport.supported) {
                if (self.executor != .fake) return self.rejectPty(options.key, options.on_event, false);
            }

            const slot = &self.pty_slots[slot_index];
            const generation = self.nextChannelGeneration();
            slot.* = .{
                .state = .running,
                .key = options.key,
                .generation = generation,
                .on_event = options.on_event,
                .fake = self.executor == .fake,
                .shared = slot.shared,
                .cols = options.cols,
                .rows = options.rows,
            };
            slot.argv_count = options.argv.len;
            var offset: usize = 0;
            for (options.argv, 0..) |arg, index| {
                @memcpy(slot.argv_storage[offset .. offset + arg.len], arg);
                slot.argv_slices[index] = slot.argv_storage[offset .. offset + arg.len];
                offset += arg.len;
            }
            @memcpy(slot.term_storage[0..options.term.len], options.term);
            slot.term_len = options.term.len;

            if (slot.fake) {
                // Session replay: PARK — the fake-slot discipline. The
                // stamp reserves the pending-order position a live
                // executor-truth start failure would have staged at
                // (see `ParkOrderState`); the fed terminal resolves
                // which case this spawn was.
                if (self.replay) {
                    slot.park_seq = self.nextPendingSeq();
                    slot.park_state = .reserved;
                }
                return;
            }
            self.startRealPty(slot, options);
        }

        /// Write bytes toward the pty child's stdin, all-or-nothing.
        /// RETURNS whether the whole payload was accepted: false means it
        /// was refused (an unknown/exited key, a payload over
        /// `max_effect_pty_write_bytes`, or a full outbound buffer/record
        /// ring against a child that stopped reading) and, being
        /// all-or-nothing, no prefix was queued. A fire-and-forget caller
        /// (a keystroke) may ignore the result — a refusal still counts
        /// into the exit event's `dropped_writes`, never silence — while a
        /// caller that must not lose bytes (a large paste) retains the
        /// payload on false and retries as the child reads and the FIFO
        /// drains. The truth is a single admission decision, so the caller
        /// never has to model the byte and record limits itself.
        ///
        /// The verdict is EXECUTOR TRUTH — live it depends on how fast
        /// the child drained the FIFO — so while a session records, every
        /// verdict journals (a `.pty`/`.write` record), and under session
        /// replay the write is inert but RETURNS THE RECORDED VERDICT
        /// (fed like every other executor truth, never recomputed): an
        /// app that retains refused bytes takes the identical
        /// retain/remove path in both runs. The journal/feed boundary is
        /// exact: a verdict is journaled (and consumed) iff the key names
        /// a live occupancy and the payload is non-empty — both
        /// deterministic across the replayed dispatch stream.
        pub fn ptyWrite(self: *Self, key: u64, bytes: []const u8) bool {
            const slot = self.findPtySlot(key) orelse {
                // A spawn whose transport failed SYNCHRONOUSLY released
                // its slot, but its staged executor-truth terminal keeps
                // the key occupied until delivery — and REPLAY keeps that
                // same window occupied as a parked slot, where a write
                // consumes a verdict. Journal the refusal AND count it
                // into the staged terminal's tally (this terminal has no
                // slot left to carry drops to delivery), so the verdict
                // streams stay aligned and the delivered exit reports the
                // refusal — never silence. A key with no spawn at all
                // refuses with no verdict on both sides (no slot, no
                // park).
                if (bytes.len > 0 and !self.replay and self.countRefusalOnStagedPtyTerminal(key)) {
                    self.journalNote(.{
                        .kind = .pty,
                        .key = key,
                        .pty_kind = .write,
                        .code = 0,
                    });
                }
                return false;
            };
            if (bytes.len == 0) return true;
            if (self.replay) return self.takeReplayPtyWriteVerdict(key);
            const accepted = ptyWriteAdmit(slot, bytes);
            self.journalNote(.{
                .kind = .pty,
                .key = key,
                .pty_kind = .write,
                .code = if (accepted) 1 else 0,
            });
            return accepted;
        }

        /// The admission decision behind `ptyWrite` — the live half the
        /// journaled verdict records.
        fn ptyWriteAdmit(slot: *PtySlot, bytes: []const u8) bool {
            if (slot.fake) {
                // The fed exit is staged (one terminal per spawn, marked
                // `.terminated`): the session is already over, so a late
                // write refuses and counts — the LIVE admission path's
                // staged-exit rule, mirrored so scripted sessions report
                // the same dropped tally a real transport would.
                if (slot.park_state == .terminated) {
                    slot.dropped_writes +|= 1;
                    return false;
                }
                if (bytes.len > max_effect_pty_write_bytes) {
                    slot.dropped_writes +|= 1;
                    return false;
                }
                // Capture for `ptyWrittenBytes`, oldest dropped past
                // the window (an inspection seam, not a delivery).
                if (bytes.len >= slot.write_capture.len) {
                    @memcpy(slot.write_capture[0..slot.write_capture.len], bytes[bytes.len - slot.write_capture.len ..]);
                    slot.write_capture_len = slot.write_capture.len;
                } else {
                    if (slot.write_capture_len + bytes.len > slot.write_capture.len) {
                        const keep = slot.write_capture.len - bytes.len;
                        const shift = slot.write_capture_len - keep;
                        std.mem.copyForwards(u8, slot.write_capture[0..keep], slot.write_capture[shift..slot.write_capture_len]);
                        slot.write_capture_len = keep;
                    }
                    @memcpy(slot.write_capture[slot.write_capture_len .. slot.write_capture_len + bytes.len], bytes);
                    slot.write_capture_len += bytes.len;
                }
                return true;
            }
            if (comptime !pty_transport.supported) return false;
            const shared = slot.shared orelse return false;
            shared.mutex.lock();
            const accepted = accepted: {
                if (!shared.open or shared.generation != slot.generation) break :accepted false;
                // The reaper has finished (exit staged): there is no io
                // thread left to send bytes, so a late write must not
                // queue bytes nobody will flush. It still COUNTS — the
                // no-silent-refusal contract: the exit event reads
                // `dropped_writes` under this mutex at drain delivery,
                // which has not happened yet (the loop thread is here),
                // so the refusal lands in the delivered count. Only a
                // write after the exit DELIVERS misses it, and that one
                // finds no slot at all (the documented cancel race).
                if (shared.exit_staged or shared.io_done) {
                    shared.dropped_writes +|= 1;
                    break :accepted false;
                }
                if (bytes.len > max_effect_pty_write_bytes or
                    shared.out_len + bytes.len > max_effect_pty_outbound_bytes or
                    shared.out_write_count == max_effect_pty_write_records)
                {
                    // Refused: over-bound, the byte FIFO is full, or the
                    // per-payload record ring is full (a child that
                    // stopped reading). Counted as one dropped write, so
                    // the count stays EXACT — admission is bounded by
                    // both the byte buffer and the record ring, so an
                    // accepted write always has an exact record and the
                    // fold that would undercount never happens.
                    shared.dropped_writes +|= 1;
                    break :accepted false;
                }
                const outbound = shared.outbound.?;
                var index: usize = 0;
                while (index < bytes.len) : (index += 1) {
                    outbound.data[(shared.out_head + shared.out_len + index) % max_effect_pty_outbound_bytes] = bytes[index];
                }
                shared.out_len += bytes.len;
                outbound.write_lens[(shared.out_write_head + shared.out_write_count) % max_effect_pty_write_records] = @intCast(bytes.len);
                shared.out_write_count += 1;
                break :accepted true;
            };
            shared.mutex.unlock();
            if (accepted) pty_transport.nudge(slot.wake_pipe[1]);
            return accepted;
        }

        /// Push a new grid size to the pty so the child receives
        /// SIGWINCH. Fire-and-forget like `ptyWrite`; zero dimensions
        /// are clamped to 1 by the transport. The size mirrors update
        /// either way so tests and the fake pty read the declared grid.
        pub fn ptyResize(self: *Self, key: u64, cols: u16, rows: u16) void {
            const slot = self.findPtySlot(key) orelse return;
            slot.cols = if (cols == 0) 1 else cols;
            slot.rows = if (rows == 0) 1 else rows;
            if (slot.fake) return;
            if (comptime !pty_transport.supported) return;
            if (slot.transport) |transport| transport.resize(slot.cols, slot.rows);
        }

        /// Terminate the pty child: SIGKILL to its process group (the
        /// child owns its session, so the signal reaches the whole
        /// foreground job — a descendant that re-grouped itself escapes,
        /// the spawn family's documented limit; POSIX has no
        /// kill-whole-session primitive), after which the io thread
        /// reaps and the exit delivers with reason `.cancelled` — after
        /// this verb the exit always reports `.cancelled`, the spawn
        /// cancel convention. Unknown keys are a no-op; on a fake pty
        /// the kill is recorded (`ptyKillRequested`) and the test feeds
        /// the exit.
        pub fn ptyKill(self: *Self, key: u64) void {
            const slot = self.findPtySlot(key) orelse return;
            slot.kill_requested = true;
            if (slot.fake) return;
            if (comptime !pty_transport.supported) return;
            const shared = slot.shared orelse return;
            shared.mutex.lock();
            shared.kill_requested = true;
            // A kill racing the reap still keeps the contract: an exit
            // already staged but not yet delivered rewrites to
            // `.cancelled` with the -1 sentinel code — after this verb
            // the exit always says cancelled, never a stale child code.
            // Signal ONLY while the io thread has not begun reaping,
            // and do it UNDER THE MUTEX so the check and the signal are
            // atomic against the io thread: the io thread sets `reaping`
            // under this same mutex before its first waitpid, so either
            // we acquire first (reaping false → the child is unwaited
            // and alive → the signal is safe) or it acquires first
            // (reaping true → we skip). Once `reaping` is set the pid
            // may be freed for reuse the instant a reap returns, so
            // signalling then could hit an unrelated process. kill() is
            // a bounded, non-blocking syscall, so holding the spin mutex
            // across it is fine. The nudge (outside the lock) still
            // wakes a read parked short of EOF through the
            // kill_requested break.
            //
            // `reaping == false` proves pid ownership ONLY under the
            // toolkit's reaping contract (documented on
            // `EffectPtyEvent.code`): the toolkit forks the pty child,
            // is its SOLE reaper, and never touches SIGCHLD disposition
            // — an embedder must not either. An embedder that ignores
            // SIGCHLD (kernel auto-reap), installs `SA_NOCLDWAIT`, or
            // wait()s on children it did not spawn frees the pid outside
            // this fence, and no portable POSIX primitive can close that:
            // kill-by-pid is inherently check-then-act against a reaper
            // you do not control (a race-free handle needs Linux-only
            // pidfd_send_signal). The contract is the boundary; inside
            // it this fence is exact.
            if (shared.exit_staged) {
                shared.exit_reason = .cancelled;
                shared.exit_code = effect_error_exit_code;
                shared.exit_signal = 0;
            }
            if (!(shared.reaping or shared.exit_staged or shared.io_done)) {
                if (slot.transport) |transport| transport.kill(false);
            }
            shared.mutex.unlock();
            pty_transport.nudge(slot.wake_pipe[1]);
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
            // Channel occupancies hold the shared key space the same
            // way: from open (or a staged executor-truth rejection)
            // until the terminal delivers, live and replayed alike.
            if (self.channelOccupiesKey(options.key) or self.stagedChannelOccupiesKey(options.key)) {
                return self.rejectHost(options.key, options.on_result);
            }
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

        /// Load a video source into the app's single video player,
        /// claim the media-surface texture channel its frames feed, and
        /// (with `autoplay`) start playing — replacing whatever played
        /// before, the audio channel's replace semantics extended to
        /// the surface claim: the previous playback's platform player
        /// stops and its claim is released before the new one lands.
        /// Sources resolve in the audio cascade's fixed, honest order:
        /// the LOCAL `path` first; when it is absent (or the file is
        /// missing) the http(s) `url`, streaming progressively. TEA all
        /// the way down for TRANSPORT: every report — the load
        /// acknowledgment with real dimensions and duration, coarse
        /// position ticks (carrying the stream's honest `buffering`
        /// flag), the one completion at a non-looping natural end,
        /// failures — arrives as an `on_event` Msg (payload
        /// `EffectVideo`) through the ordinary update path. PIXELS
        /// never enter this channel: decoded frames flow platform-side
        /// through the claimed surface's frame sink into the
        /// compositor, presentation-only by construction. Never fails
        /// from the caller's view: an invalid request (no source,
        /// oversized strings, a non-http(s) url, an invalid surface id)
        /// delivers one `.rejected` event; a platform without video
        /// playback, an unclaimable surface, an unreadable file with no
        /// url fallback, or a network failure delivers one `.failed`
        /// event — never a crash, never silence. The video key is its
        /// own namespace (like audio keys) and identifies the playback
        /// in every event; it consumes no `max_effects` slots.
        /// The deterministic loop-side validation `loadVideo` refuses
        /// with — pure and public so a caller-side validator (the TS
        /// bridge) can refuse the SAME shapes before committing its own
        /// routing state, staging its own rejection Msg instead of the
        /// engine's (`stageLoopMsg`, the channel-admission precedent).
        /// One source of truth: `loadVideo` consults exactly this.
        pub fn videoLoadRejected(options: LoadVideoOptions) bool {
            // The same surface ids `acquireMediaSurfaceProducer`
            // refuses, refused before any claim: 0 is the no-surface
            // sentinel, the high bit is the derived-texture namespace.
            const surface_invalid = options.surface == 0 or
                (options.surface & canvas.media_surface_image_id_bit) != 0;
            if (surface_invalid or
                (options.path.len == 0 and options.url.len == 0) or
                options.path.len > max_effect_video_path_bytes or
                options.url.len > max_effect_video_path_bytes) return true;
            if (options.url.len > 0) {
                // The image loader's scheme check: http(s) only, before
                // the platform is asked.
                if (std.Uri.parse(options.url)) |uri| {
                    const scheme_ok = std.ascii.eqlIgnoreCase(uri.scheme, "http") or
                        std.ascii.eqlIgnoreCase(uri.scheme, "https");
                    if (!scheme_ok) return true;
                } else |_| {
                    return true;
                }
            }
            return false;
        }

        pub fn loadVideo(self: *Self, options: LoadVideoOptions) void {
            if (videoLoadRejected(options)) {
                self.deliverLoopVideo(.{ .key = options.key, .kind = .rejected }, options.on_event, 0);
                return;
            }
            // Replace semantics: end the previous playback whole —
            // platform player stopped, surface claim released — before
            // the new channel state lands.
            if (self.video.active and !self.video.fake) {
                if (self.services) |services| services.videoStop() catch {};
            }
            // Under replay the outgoing load may still be owed one
            // journaled terminal (see `RetiredVideo`), so its identity
            // is parked before the replacement overwrites it.
            self.parkRetiredVideo();
            self.releaseVideoSink();
            const volume = self.video.volume;
            self.video_token_seq += 1;
            self.video = .{
                .active = true,
                .fake = self.executor == .fake,
                .key = options.key,
                .token = self.video_token_seq,
                .surface_id = options.surface,
                .on_event = options.on_event,
                // Optimistic command mirror; the platform's events are
                // the authority from the `.loaded` acknowledgment on.
                .playing = options.autoplay,
                // The fake executor cannot resolve the cascade, so it
                // records the requested shape: URL-only requests read
                // as streams, anything with a local path as local.
                .source = if (options.path.len == 0) .stream else .local,
                .looping = options.loop,
                .muted = options.muted,
                .volume = volume,
            };
            @memcpy(self.video.path_buffer[0..options.path.len], options.path);
            self.video.path_len = options.path.len;
            @memcpy(self.video.url_buffer[0..options.url.len], options.url);
            self.video.url_len = options.url.len;
            if (self.video.fake) {
                // Under replay the recorded cascade resolution stands
                // in for the local-file probe this fake cannot run.
                if (self.replay) self.takeReplayVideoSource();
                return;
            }
            const services = self.services orelse return self.failVideoLoad();
            // Claim the texture channel first: a surface another
            // producer holds (or a host with no channels left) fails
            // loudly before the platform decodes anything toward it.
            const binding = self.media_surfaces orelse return self.failVideoLoad();
            const sink = binding.acquire_fn(binding.context, options.surface) catch
                return self.failVideoLoad();
            self.video.sink = sink;
            // The source cascade, the audio rule verbatim: a missing
            // local file is the ONE local failure that falls through to
            // the url — everything else is terminal, because retrying a
            // different source would mask the real problem.
            resolve: {
                if (options.path.len > 0) {
                    if (services.videoLoad(options.path, self.video.token, sink)) |_| {
                        self.video.source = .local;
                        break :resolve;
                    } else |err| {
                        if (err != error.VideoSourceNotFound or options.url.len == 0) {
                            return self.failVideoLoad();
                        }
                    }
                }
                services.videoLoadUrl(options.url, self.video.token, sink) catch return self.failVideoLoad();
                self.video.source = .stream;
                // A fresh stream has no bytes yet: when the load will
                // PLAY, buffering starts true optimistically and the
                // platform's events are the authority from there. A
                // paused load (`autoplay = false`) is paused, not
                // buffering — the flag means an un-paused stream
                // waiting for bytes, and the wait only starts with
                // play. `playing` holds the autoplay intent here.
                self.video.buffering = self.video.playing;
            }
            // Options that shape the fresh player (a load resets the
            // platform side, so defaults need no call). Best effort,
            // like the remembered audio volume.
            if (options.loop) services.videoSetLoop(true) catch {};
            if (options.muted) services.videoSetMuted(true) catch {};
            if (volume != 1.0) services.videoSetVolume(volume) catch {};
            if (options.autoplay) services.videoPlay() catch return self.failVideoLoad();
            // Journal the cascade's resolution for replay — Msg-less
            // engine truth, journaled handler or no handler (the
            // `.video_load` kind's doc has the full story). EVERY exit
            // of the real path journals exactly one such record
            // (`failVideoLoad` covers the refusals), so the replayed
            // loads and the journaled records form a bijection replay
            // can verify: extras and absences are both divergence.
            self.journalNote(.{
                .kind = .video_load,
                .key = options.key,
                .video_kind = .loaded,
                .video_token = self.video.token,
                .video_source = self.video.source,
            });
        }

        /// Start or resume the loaded playback (the poster-frame
        /// counterpart of `autoplay = false`, and un-pause). Idle
        /// channels no-op; a player the platform can no longer start
        /// delivers one `.failed` event instead of silence.
        pub fn playVideo(self: *Self) void {
            if (!self.video.active) return;
            if (self.video.fake and self.video.completed) {
                // The live hosts retire the player at a non-looping
                // natural end, so play meets an absent player there:
                // one `.failed` terminal and the channel resets before
                // playVideo returns (`failVideoChannel`). The fake
                // models the same refusal — a snapshot an update reads
                // right after its own play must answer the same on
                // every executor. Under replay the journaled terminal
                // delivers itself, so the reset just parks the
                // identity it routes by.
                if (self.replay) {
                    self.parkRetiredVideo();
                    self.video = .{ .volume = self.video.volume };
                } else {
                    self.failVideoChannel();
                }
                return;
            }
            self.video.playing = true;
            if (self.video.fake) return;
            const services = self.services orelse return self.failVideoChannel();
            services.videoPlay() catch return self.failVideoChannel();
        }

        /// Restart the current playback from the start: a fresh load
        /// of the channel's own remembered source with autoplay,
        /// keeping the key, surface claim, handler, and the loop and
        /// mute flags. THE resume path after a non-looping natural
        /// end — the platform player was retired there, so play and
        /// seek refuse — and the house transport's Play goes through
        /// here when the completion latch is set. Idle channels no-op
        /// (nothing to restart). An ordinary load in every other
        /// respect: it journals its cascade resolution, replaces the
        /// player whole, and delivers a fresh `.loaded`
        /// acknowledgment.
        pub fn restartVideo(self: *Self) void {
            if (!self.video.active) return;
            // Copies, not slices: loadVideo writes the channel's own
            // source buffers, and the options must not alias them.
            var path_buffer: [max_effect_video_path_bytes]u8 = undefined;
            var url_buffer: [max_effect_video_path_bytes]u8 = undefined;
            const path_len = self.video.path_len;
            const url_len = self.video.url_len;
            @memcpy(path_buffer[0..path_len], self.video.path());
            @memcpy(url_buffer[0..url_len], self.video.url());
            self.loadVideo(.{
                .key = self.video.key,
                .surface = self.video.surface_id,
                .path = path_buffer[0..path_len],
                .url = url_buffer[0..url_len],
                .autoplay = true,
                .loop = self.video.looping,
                .muted = self.video.muted,
                .on_event = self.video.on_event,
            });
        }

        /// Pause the current playback in place; the surface keeps its
        /// last adopted frame. Idle channels no-op; no event echoes —
        /// the caller commanded it, so the caller knows.
        pub fn pauseVideo(self: *Self) void {
            if (!self.video.active) return;
            self.video.playing = false;
            // Buffering is an un-paused stream's wait for bytes; the
            // pause ends the wait by definition. The command mirror
            // clears it here because a conforming host emits no pause
            // acknowledgment that could (pause's no-event contract).
            self.video.buffering = false;
            if (self.video.fake) return;
            const services = self.services orelse return;
            services.videoPause() catch {};
        }

        /// `stopVideo` plus the stream CANCEL the TS wire promises:
        /// the stopped stream's staged-but-undrained answers — a
        /// synchronous terminal from the very batch that stops it —
        /// are removed, so no event for the stream ever reaches the
        /// app after this call (`Cmd.videoStop`: "no events for the
        /// key after this"). The stream is identified by its TOKEN
        /// (`videoMintedToken` at the adapter's own load), not the
        /// public key: the key is caller-controlled and shared by
        /// every load routed through one event arm, and a REPLACED
        /// predecessor under the same key still speaks its owed
        /// terminal — only stop cancels. The PLAYER stops only while
        /// the channel still plays that stream: a playback some other
        /// caller loaded since (a declarative element) must survive a
        /// stale stream's stop untouched. The Zig-native `stopVideo`
        /// keeps every staged answer instead (one terminal per load,
        /// never silence); an adapter whose public stop is the
        /// stream's cancel goes through here. A cancelled answer never
        /// journals, so replay regenerates and cancels the same
        /// entries and the timelines stay identical.
        pub fn stopVideoCancel(self: *Self, token: u64) void {
            self.cancelPendingVideo(token);
            if (self.video.active and self.video.token == token) self.stopVideo();
        }

        /// Remove every staged entry belonging to load `token` — the
        /// cancel behind `stopVideoCancel`. Surviving entries keep
        /// their relative (seq) order. Loop-side rejections carry
        /// token 0 (a refused load never minted one) and are never
        /// cancelled — they answer commands, not streams.
        fn cancelPendingVideo(self: *Self, token: u64) void {
            if (token == 0) return;
            const storage = self.pendingVideoStorage();
            var kept: usize = 0;
            var offset: usize = 0;
            while (offset < self.pending_video_len) : (offset += 1) {
                const from = (self.pending_video_head + offset) % storage.len;
                const entry = storage[from];
                if (entry.token == token) continue;
                const to = (self.pending_video_head + kept) % storage.len;
                storage[to] = entry;
                kept += 1;
            }
            self.pending_video_len = kept;
            if (kept == 0) {
                self.pending_video_head = 0;
                if (self.pending_video_spill.len > 0) {
                    self.allocator.free(self.pending_video_spill);
                    self.pending_video_spill = &.{};
                }
            }
        }

        /// Stop playback, release the player AND the surface claim. No
        /// event echoes; the channel goes idle, later platform
        /// stragglers are swallowed, and the surface returns to its
        /// placeholder (the release purges the adopted frame - a
        /// stopped player must not freeze-frame under "no playback"
        /// chrome).
        pub fn stopVideo(self: *Self) void {
            if (!self.video.active) return;
            const fake = self.video.fake;
            // Under replay the stopped load may still be owed one
            // journaled terminal (see `RetiredVideo`).
            self.parkRetiredVideo();
            self.releaseVideoSink();
            const volume = self.video.volume;
            self.video = .{ .volume = volume };
            if (fake) return;
            const services = self.services orelse return;
            services.videoStop() catch {};
        }

        /// Jump the current playback to `position_ms` (the platform
        /// clamps to the duration; a paused seek still pushes the
        /// sought frame, so scrubbing is visible). Idle channels no-op;
        /// no event echoes — the next position tick reports from the
        /// new position.
        pub fn seekVideo(self: *Self, position_ms: u64) void {
            if (!self.video.active) return;
            const clamped = if (self.video.duration_ms > 0)
                @min(position_ms, self.video.duration_ms)
            else
                position_ms;
            // The mirror's gate is the DETERMINISTIC completion latch,
            // identical on every executor: a completed non-looping
            // playback's player is retired, its seek refuses, and the
            // mirror must keep the terminal position — live, fake, and
            // replayed alike. A residual platform verdict beyond that
            // (no shipping host refuses a seek on a live player) is
            // fire-and-forget: journaling per-seek outcomes would buy
            // nothing, and gating the mirror on it would let an exotic
            // host's answer diverge replay's mirrors from the
            // recording's.
            if (self.video.completed) return;
            self.video.position_ms = clamped;
            if (self.video.fake) return;
            const services = self.services orelse return;
            services.videoSeek(position_ms) catch {};
        }

        /// Set playback volume, clamped to 0.0—1.0 and remembered
        /// across loads — the audio volume contract. Independent of
        /// mute.
        pub fn setVideoVolume(self: *Self, volume: f32) void {
            const clamped = std.math.clamp(volume, 0.0, 1.0);
            self.video.volume = clamped;
            if (!self.video.active or self.video.fake) return;
            const services = self.services orelse return;
            services.videoSetVolume(clamped) catch {};
        }

        /// Mute or unmute the playback's audio track without touching
        /// the remembered volume. Idle channels no-op (a fresh load's
        /// `muted` option is the way to start muted).
        pub fn setVideoMuted(self: *Self, muted: bool) void {
            if (!self.video.active) return;
            self.video.muted = muted;
            if (self.video.fake) return;
            const services = self.services orelse return;
            services.videoSetMuted(muted) catch {};
        }

        /// Enable or disable looping on the current playback. Idle
        /// channels no-op (a fresh load's `loop` option covers the
        /// start-looping case). A looping playback never delivers
        /// `.completed`.
        pub fn setVideoLoop(self: *Self, loop: bool) void {
            if (!self.video.active) return;
            self.video.looping = loop;
            if (self.video.fake) return;
            const services = self.services orelse return;
            services.videoSetLoop(loop) catch {};
        }

        /// Route a platform video event back into an `on_event` Msg for
        /// the active channel, updating the playback mirrors on the
        /// way. Null when the channel is idle (a straggler after
        /// `stopVideo`) or has no handler. Loop-thread only; called by
        /// `UiApp.handleEvent` for `.video` platform events.
        pub fn takeVideoMsg(self: *Self, platform_event: platform.VideoEvent) ?Msg {
            // Identity gate, before anything else: an event whose token
            // is not the CURRENT load's belongs to a playback this
            // channel already replaced or stopped — a terminal queued
            // by the old player must neither reset the replacement nor
            // route through its handler (`VideoChannel.token`). Under
            // replay the same gate keeps the mirrors honest: the re-run
            // loads mint the same deterministic token sequence, so
            // stale recorded events are swallowed exactly as they were
            // live.
            if (!self.video.active or platform_event.token != self.video.token) return null;
            // Scalars clamp into the exact-integer delivery window here
            // (`max_effect_video_scalar_exclusive`), once, for the live
            // Msg, the mirrors, the journaled record, AND the replayed
            // steering below — so live and replay derive identical
            // state from the same platform event, and no journaled
            // record can carry a value replay's damage gate refuses.
            // The macOS host clamps CMTimes host-side already; this
            // makes the bound true for every host.
            const position_ms = clampVideoScalar(platform_event.position_ms);
            const duration_ms = clampVideoScalar(platform_event.duration_ms);
            const width = clampVideoScalar(platform_event.width);
            const height = clampVideoScalar(platform_event.height);
            const kind: EffectVideoEventKind = switch (platform_event.kind) {
                .loaded => .loaded,
                .position => .position,
                .completed => .completed,
                .failed => .failed,
            };
            // Under replay the journaled effect records are the Msg
            // source (fed through `feedVideoEvent`); the replayed
            // platform `.video` events must not double-deliver. They DO
            // still steer the channel mirrors — unlike audio, a video
            // playback routinely runs with NO Msg handler (the house
            // chrome renders straight from these mirrors, and a
            // handler-less delivery journals no effect record).
            // TIMING: at record time this event's Msg dispatched
            // SYNCHRONOUSLY inside this very event's dispatch, and the
            // journal's contiguity invariant puts its effect record
            // immediately before this event — so if the head of the
            // video stage is a fed entry, it IS this event's recorded
            // delivery and must dispatch NOW, not at the next drain: an
            // update that loads the next clip from a `completed`
            // handler has to run before the next recorded event (the
            // new clip's `.loaded`) replays, or that event would be
            // swallowed against the old token.
            if (self.replay) {
                // Captured BEFORE the apply: a terminal event resets
                // the channel, and the missing-record check below needs
                // the handler that was bound when this event dispatched.
                const event_handler = self.video.on_event;
                const resolved = self.applyVideoEvent(.{
                    .key = 0,
                    .kind = kind,
                    .position_ms = position_ms,
                    .duration_ms = duration_ms,
                    .playing = platform_event.playing,
                    .buffering = platform_event.buffering,
                    .width = width,
                    .height = height,
                });
                // Only a FED entry (a recorded delivery) pairs with a
                // platform event — and only THIS load's (the token
                // gate, against the event's token: a terminal apply
                // above may have reset the channel). The entry pairs
                // from ANY stage position: live, the event's Msg
                // dispatched synchronously, jumping the loop-side
                // stage entirely, so a regenerating rejection staged
                // earlier in the same dispatch (which keeps its own
                // drain-time order) must not block it — head-only
                // pairing would reverse the recorded Msg order.
                if (self.takePendingVideoMatching(platform_event.token)) |entry| {
                    // The record was journaled FROM this very event at
                    // record time, so its payload must equal what the
                    // event resolves to now — a record whose scalars
                    // or kind were altered around an intact identity
                    // is a hand-edited journal, and delivering it
                    // would hand the app a Msg the mirrors (steered by
                    // the event) contradict.
                    if (resolved == null or !std.meta.eql(entry.event, resolved.?)) {
                        std.debug.print(
                            "session replay: the journaled video result for key {d} does not match the platform event that delivered it live - the recorder journals every delivery verbatim, so the journal is damaged or hand-edited\n",
                            .{entry.event.key},
                        );
                        self.replay_video_diverged = true;
                        return null;
                    }
                    const event_fn = entry.video_fn orelse return null;
                    return event_fn(entry.event);
                }
                if (event_handler != null) {
                    // A handler was bound when this recorded event
                    // dispatched, so the recording delivered a Msg and
                    // journaled its record immediately before this
                    // event — a missing record is a truncated or
                    // hand-edited journal, and returning silently
                    // would drop a Msg the recording dispatched.
                    std.debug.print(
                        "session replay: a recorded video event arrived with no journaled result before it - the recorder journals every handled delivery, so the journal is truncated or hand-edited\n",
                        .{},
                    );
                    self.replay_video_diverged = true;
                }
                return null;
            }
            const video_fn = self.video.on_event;
            const event = self.applyVideoEvent(.{
                .key = 0,
                .kind = kind,
                .position_ms = position_ms,
                .duration_ms = duration_ms,
                .playing = platform_event.playing,
                .buffering = platform_event.buffering,
                .width = width,
                .height = height,
            }) orelse return null;
            const event_fn = video_fn orelse return null;
            // The token rides the platform event, not the channel: a
            // terminal apply above resets the channel, and the record
            // must still name the load that produced the delivery
            // (`EffectResultRecord.video_token`).
            self.journalNote(.{
                .kind = .video,
                .key = event.key,
                .video_kind = event.kind,
                .video_position_ms = event.position_ms,
                .video_duration_ms = event.duration_ms,
                .video_playing = event.playing,
                .video_buffering = event.buffering,
                .video_width = event.width,
                .video_height = event.height,
                .video_token = platform_event.token,
                // Past the handler gate above by construction.
                .video_handled = true,
            });
            return event_fn(event);
        }

        /// The CURRENT playback's load identity (`VideoChannel.token`;
        /// 0 when idle) — how the declarative reconciler proves the
        /// playback it is about to stop or mutate is the one IT
        /// started: the public key alone is caller-controlled, and a
        /// manual load could collide with the reconciler's derived
        /// key.
        pub fn videoOwnerToken(self: *const Self) u64 {
            return if (self.video.active) self.video.token else 0;
        }

        /// The most recently MINTED load identity — valid right after
        /// `loadVideo` returns even when a synchronous refusal already
        /// reset the channel (where `videoOwnerToken` reads 0). How an
        /// adapter remembers which stream its own load opened, so its
        /// later verbs can prove the playback on the channel is still
        /// that stream (rejected loads never mint, and adapters
        /// pre-validate rejections before committing routing state).
        pub fn videoMintedToken(self: *const Self) u64 {
            return self.video_token_seq;
        }

        /// The video playback state mirrors, for the automation
        /// snapshot.
        pub fn videoSnapshot(self: *const Self) VideoSnapshot {
            return .{
                .active = self.video.active,
                .key = self.video.key,
                .surface = self.video.surface_id,
                .playing = self.video.playing,
                .buffering = self.video.buffering,
                .completed = self.video.completed,
                .looping = self.video.looping,
                .muted = self.video.muted,
                .source = self.video.source,
                .position_ms = self.video.position_ms,
                .duration_ms = self.video.duration_ms,
                .width = self.video.width,
                .height = self.video.height,
                .volume = self.video.volume,
            };
        }

        /// Fake executor: the recorded playback request on the single
        /// video channel, or null when nothing was asked to play.
        pub fn pendingVideo(self: *const Self) ?VideoRequest {
            if (!self.video.active) return null;
            return .{
                .key = self.video.key,
                .surface = self.video.surface_id,
                .path = self.video.path(),
                .url = self.video.url(),
                .playing = self.video.playing,
                .looping = self.video.looping,
                .muted = self.video.muted,
                .position_ms = self.video.position_ms,
                .volume = self.video.volume,
            };
        }

        /// Fake executor convenience: feed one video event to the
        /// CURRENT playback as the platform would deliver it — the
        /// whole journal shape in one signature (dimensions ride only
        /// `.loaded` from real hosts; other kinds pass 0). Fails when
        /// no playback is active to receive it. Session replay never
        /// calls this: a journaled record names the load that produced
        /// it, and `feedVideoRecord` routes by that identity.
        pub fn feedVideoEvent(self: *Self, kind: EffectVideoEventKind, position_ms: u64, duration_ms: u64, playing: bool, buffering: bool, width: u64, height: u64) !void {
            if (!self.video.active) return error.EffectNotFound;
            return self.feedVideoRecord(self.video.key, self.video.token, self.video.on_event != null, kind, position_ms, duration_ms, playing, buffering, width, height);
        }

        /// Session replay: feed one journaled video record, routed by
        /// the JOURNALED identity exactly as live delivery routed it —
        /// the record's token names the load that produced the event
        /// (`EffectResultRecord.video_token`; app keys are reused by
        /// replace semantics and cannot tell two loads apart), and the
        /// replayed dispatches re-mint the same deterministic token
        /// sequence. A token naming the CURRENT playback resolves
        /// against the live channel at drain time (mirrors updated,
        /// handler from the channel), mirroring `takeVideoMsg`. A token
        /// naming a load the replayed timeline already replaced or
        /// stopped — a synchronous terminal the recording host refused
        /// inside the very dispatch that then moved on — delivers the
        /// journaled shape verbatim through the handler that load
        /// registered (`RetiredVideo`), leaving the live channel alone:
        /// binding it to the current playback would misattribute the
        /// Msg and reset a replacement the recording kept playing.
        /// Fails when the token matches neither (the replayed updates
        /// issued different loads than the recording).
        pub fn feedVideoRecord(self: *Self, key: u64, token: u64, handled: bool, kind: EffectVideoEventKind, position_ms: u64, duration_ms: u64, playing: bool, buffering: bool, width: u64, height: u64) !void {
            // Handler captured NOW, not at delivery: a fed event is one
            // recorded delivery, and under replay the platform `.video`
            // event that follows this record in the journal can apply a
            // channel-resetting terminal before the drain delivers this
            // entry (see `PendingVideo`).
            var video_fn: ?VideoMsgFn = undefined;
            if (self.video.active and self.video.token == token) {
                // The reminted token pairs by position; the journaled
                // key proves the load at that position is the load the
                // recording issued. A mismatch is divergence, not a
                // delivery.
                if (self.video.key != key) return error.EffectNotFound;
                video_fn = self.video.on_event;
            } else if (self.takeRetiredVideo(token)) |retired| {
                if (retired.key != key) return error.EffectNotFound;
                video_fn = retired.video_fn;
            } else {
                return error.EffectNotFound;
            }
            // The record says whether the delivery dispatched a Msg
            // live; the replayed load's handler presence must agree —
            // a consumed record whose Msg silently vanished (or a Msg
            // live never dispatched) is divergence, not a delivery.
            if (handled != (video_fn != null)) return error.EffectNotFound;
            self.stagePendingVideo(.{
                .seq = self.nextPendingSeq(),
                .event = .{
                    .key = key,
                    .kind = kind,
                    .position_ms = position_ms,
                    .duration_ms = duration_ms,
                    .playing = playing,
                    .buffering = buffering,
                    .width = width,
                    .height = height,
                },
                .video_fn = video_fn,
                .resolve = true,
                .token = token,
            });
        }

        /// Session replay: queue a journaled `.video_load` cascade
        /// resolution — the source the RECORDING host's filesystem
        /// decided (a missing local file falls through to the url),
        /// which the replay-side fake load cannot probe. The record
        /// precedes the event whose dispatch issued the load (the
        /// journal's ordering invariant), so it queues here and the
        /// replayed `loadVideo` consumes it by token — the minted
        /// sequence is deterministic, so each entry pairs with exactly
        /// the load that journaled it, and a load whose cascade failed
        /// live (no record) simply finds no entry.
        pub fn pushReplayVideoSource(self: *Self, key: u64, token: u64, source: EffectVideoSource, failed: bool) void {
            const storage = self.replayVideoSourceStorage();
            if (self.replay_video_source_len == storage.len) {
                // Loads per dispatch are unbounded by contract, so the
                // queue grows rather than refusing — the pending
                // stages' discipline, loud on allocation failure for
                // the same stranded-consumer reason.
                const grown = self.allocator.alloc(ReplayVideoSource, storage.len * 2) catch
                    @panic("effects: out of memory queueing a replayed video cascade resolution - each record is one recorded load's resolution and must never be dropped");
                @memcpy(grown[0..self.replay_video_source_len], storage[0..self.replay_video_source_len]);
                if (self.replay_video_source_spill.len > 0) self.allocator.free(self.replay_video_source_spill);
                self.replay_video_source_spill = grown;
            }
            const active = self.replayVideoSourceStorage();
            active[self.replay_video_source_len] = .{ .key = key, .token = token, .source = source, .failed = failed };
            self.replay_video_source_len += 1;
        }

        /// The cascade-resolution queue's current backing storage.
        fn replayVideoSourceStorage(self: *Self) []ReplayVideoSource {
            if (self.replay_video_source_spill.len > 0) return self.replay_video_source_spill;
            return &self.replay_video_sources;
        }

        /// Consume the queued cascade resolution for the load just
        /// minted, if the recording journaled one — the replayed fake
        /// load's stand-in for the local-file probe. Entries for
        /// already-minted tokens can never match again (tokens are
        /// unique and monotone), so the scan drops them on the way —
        /// the queue self-cleans.
        fn takeReplayVideoSource(self: *Self) void {
            const storage = self.replayVideoSourceStorage();
            var index: usize = 0;
            var matched = false;
            while (index < self.replay_video_source_len) {
                const entry = storage[index];
                if (entry.token < self.video.token) {
                    // A record whose load position has already passed:
                    // the replayed timeline never issued the load that
                    // journaled it. Divergence, consumed (it can never
                    // pair) and latched for `finishReplay`.
                    std.debug.print(
                        "session replay: the journaled video load for key {d} (position {d}) was never issued by the replayed updates - the replayed updates issued different loads than the recording (nondeterminism outside the effect boundary?)\n",
                        .{ entry.key, entry.token },
                    );
                    self.replay_video_diverged = true;
                    self.replay_video_source_len -= 1;
                    storage[index] = storage[self.replay_video_source_len];
                    continue;
                }
                if (entry.token == self.video.token) {
                    // The resolution must be one this load's request
                    // could have produced: `.local` needs a local path
                    // and `.stream` needs a url — a journaled source
                    // the cascade could never have selected is a
                    // hand-edited journal, and applying it would
                    // expose an impossible snapshot state.
                    const source_possible = switch (entry.source) {
                        .local => self.video.path_len > 0,
                        .stream => self.video.url_len > 0,
                    };
                    if (!source_possible) {
                        std.debug.print(
                            "session replay: the journaled video load for key {d} resolved to .{s}, which its request shape cannot select - the journal is damaged or hand-edited\n",
                            .{ entry.key, @tagName(entry.source) },
                        );
                        self.replay_video_diverged = true;
                        self.replay_video_source_len -= 1;
                        storage[index] = storage[self.replay_video_source_len];
                        matched = true;
                        break;
                    }
                    if (entry.key != self.video.key) {
                        // The load at this position is not the load the
                        // recording issued: the replayed updates
                        // diverged. Latched for `finishReplay` (this is
                        // the live `loadVideo` API — no error channel)
                        // and consumed; it can never pair honestly.
                        std.debug.print(
                            "session replay: the journaled video load at this position carries key {d} but the replayed dispatch loaded key {d} - the replayed updates issued different loads than the recording (nondeterminism outside the effect boundary?)\n",
                            .{ entry.key, self.video.key },
                        );
                        self.replay_video_diverged = true;
                        self.replay_video_source_len -= 1;
                        storage[index] = storage[self.replay_video_source_len];
                        matched = true;
                        break;
                    }
                    self.video.source = entry.source;
                    // The live cascade starts an autoplaying fresh
                    // stream buffering optimistically (`loadVideo`);
                    // the fake load could not know it resolved to a
                    // stream. `playing` holds the autoplay intent, as
                    // it does live at this point.
                    if (entry.source == .stream and self.video.playing) self.video.buffering = true;
                    self.replay_video_source_len -= 1;
                    storage[index] = storage[self.replay_video_source_len];
                    matched = true;
                    if (entry.failed) {
                        // The recording's load refused synchronously:
                        // its channel reset before `loadVideo`
                        // returned, so the fake resets NOW — the
                        // snapshot an update reads inside this very
                        // dispatch must match the recording's. The
                        // identity parks for the journaled `.failed`
                        // terminal, which delivers at its recorded
                        // drain.
                        self.parkRetiredVideo();
                        self.video = .{ .volume = self.video.volume };
                    }
                    break;
                }
                index += 1;
            }
            if (!matched and !self.replay_video_diverged) {
                // Every non-rejected recorded load journaled a record
                // that feeds before its dispatch, so a replayed load
                // with no record at its position is a load the
                // recording never issued. Divergence, latched for
                // `finishReplay` (this is the live `loadVideo` API —
                // no error channel).
                std.debug.print(
                    "session replay: the replayed dispatch loaded video key {d} (position {d}) but the recording journaled no load there - the replayed updates issued different loads than the recording (nondeterminism outside the effect boundary?)\n",
                    .{ self.video.key, self.video.token },
                );
                self.replay_video_diverged = true;
            }
            if (self.replay_video_source_len == 0 and self.replay_video_source_spill.len > 0) {
                self.allocator.free(self.replay_video_source_spill);
                self.replay_video_source_spill = &.{};
            }
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
        /// The atomic loads are seq_cst: this is the binder's load side
        /// of the bind/post store-buffer handshake (see `bindServices`
        /// for the full four-operation argument) — an acquire load here
        /// could read a pre-post zero even though the poster's own load
        /// missed the just-published services, stranding the post.
        pub fn hasPending(self: *const Self) bool {
            return self.pending_exit_len > 0 or
                self.pending_image_len > 0 or
                self.pending_channel_len > 0 or
                self.pending_video_len > 0 or
                self.pending_pty_len > 0 or
                self.pending_staged_len > 0 or
                self.channel_pending_count.load(.seq_cst) > 0 or
                self.pty_pending_count.load(.seq_cst) > 0 or
                self.queue_count.load(.seq_cst) > 0;
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
            /// below this deliver (the loop-side pending structures
            /// share the monotonic `pending_seq` stamp).
            pending_before: u64,
            /// Worker-queue entries enqueued before the pass. The queue
            /// is FIFO, so consuming exactly this many dequeues consumes
            /// exactly the pre-existing entries.
            queue_budget: usize,
            /// Channel posts (and close markers) stamped before the
            /// pass: `channel_seq` stamps below this deliver. A post
            /// landing mid-pass waits for the fresh wake it latched —
            /// the coalescer cleared at the pass boundary guarantees
            /// one — the same causality cut the other two fields make.
            channel_before: u64,
            /// Pty output backlogs and exits stamped before the pass:
            /// `pty_seq` stamps below this deliver. One deliberate
            /// nuance of the byte-stream shape: bytes appended to an
            /// ALREADY-STAMPED backlog ride its batch even mid-pass —
            /// a single producer's byte stream has inherent order and
            /// the journal records exactly what delivered, so the
            /// causality cut only needs the stamp, not the bytes.
            pty_before: u64,
        };

        /// Snapshot the completion backlog at the start of one drain
        /// pass. Loop-thread only, like the drain itself.
        pub fn drainBoundary(self: *Self) DrainBoundary {
            // Advance the pass clock and release replay-side retired
            // video identities whose window closed (`sweepRetiredVideos`
            // has the full argument). Cheap and empty outside replay.
            self.drain_pass_seq += 1;
            self.sweepRetiredVideos();
            // Drain the channel wake coalescers BEFORE snapshotting the
            // post order — `adoptMediaSurfaceFrames`' clear-before-
            // sample placement, matched exactly (it clears each slot's
            // `MediaSurfaceWake.pending` before sampling the staged
            // flag): a post whose latched-flag check observed true
            // stamped its entry before this clear, so the seq_cst
            // snapshot below covers it and this pass delivers it; a
            // post racing the drain and landing after the clear
            // observes the flag clear and latches a fresh wake for the
            // pass that will. Either interleaving, nothing staged is
            // ever left wakeless.
            for (&self.channel_slots) |*slot| {
                const shared = slot.shared orelse continue;
                shared.wake.mutex.lock();
                shared.wake.pending.store(false, .seq_cst);
                shared.wake.mutex.unlock();
            }
            for (&self.pty_slots) |*slot| {
                const shared = slot.shared orelse continue;
                shared.wake.mutex.lock();
                shared.wake.pending.store(false, .seq_cst);
                shared.wake.mutex.unlock();
            }
            return .{
                .pending_before = self.pending_seq,
                .queue_budget = self.queue_count.load(.acquire),
                // seq_cst, paired with the post's seq_cst stamp and
                // flag check (see `requestHostWake`): a post ordered
                // before the clear above is inside this snapshot.
                .channel_before = self.channel_seq.load(.seq_cst),
                .pty_before = self.pty_seq.load(.seq_cst),
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
                .channel_before = std.math.maxInt(u64),
                .pty_before = std.math.maxInt(u64),
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
                        .video => |entry| {
                            var event = entry.event;
                            const video_fn = entry.video_fn;
                            if (entry.resolve) {
                                // Fed events move the live channel's
                                // mirrors at delivery exactly like a
                                // platform event — but only while the
                                // live channel is still THE playback
                                // the feed captured. A stale fed event
                                // (its playback was replaced before
                                // the drain, or a replayed platform
                                // `.failed` already applied this
                                // terminal and reset the channel)
                                // delivers its staged values verbatim
                                // — they ARE the resolved event from
                                // stage time — through the handler
                                // captured at feed time
                                // (`PendingVideo`), and leaves the
                                // live channel alone: applying a
                                // replaced stream's terminal would
                                // reset the replacement.
                                if (self.video.active and self.video.token == entry.token) {
                                    if (self.applyVideoEvent(event)) |resolved| event = resolved;
                                }
                            } else {
                                // Loop-side terminals journal BEFORE
                                // the handler gate — the image arm's
                                // rule: a handler-less declarative
                                // playback's synchronous `.failed` is
                                // executor truth, and its record is
                                // what replays the channel reset. Only
                                // the Msg depends on the handler.
                                self.journalNote(.{
                                    .kind = .video,
                                    .key = event.key,
                                    .video_kind = event.kind,
                                    .video_position_ms = event.position_ms,
                                    .video_duration_ms = event.duration_ms,
                                    .video_playing = event.playing,
                                    .video_buffering = event.buffering,
                                    .video_width = event.width,
                                    .video_height = event.height,
                                    .video_token = entry.token,
                                    .video_handled = entry.video_fn != null,
                                });
                            }
                            const event_fn = video_fn orelse continue;
                            if (entry.resolve) self.journalNote(.{
                                .kind = .video,
                                .key = event.key,
                                .video_kind = event.kind,
                                .video_position_ms = event.position_ms,
                                .video_duration_ms = event.duration_ms,
                                .video_playing = event.playing,
                                .video_buffering = event.buffering,
                                .video_width = event.width,
                                .video_height = event.height,
                                .video_token = entry.token,
                                .video_handled = true,
                            });
                            return event_fn(event);
                        },
                        .image => |entry| {
                            // Journal BEFORE the handler gate: a staged
                            // executor-truth terminal with no handler
                            // (a fire-and-forget load's start failure)
                            // still journals, because its record is
                            // what retires the parked replay-side fake
                            // (see `deliverLoopImage`). Only the Msg
                            // depends on the handler.
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
                            const image_fn = entry.image_fn orelse continue;
                            return image_fn(entry.result);
                        },
                        .channel => |entry| {
                            // A fed park-retiring rejection frees its
                            // parked slot BEFORE the Msg reaches update
                            // — the same causal instant the live pop
                            // released the staged refusal's key and
                            // table reservation, so a handler that
                            // opens a channel sees the same table on
                            // both sides.
                            if (entry.retire_slot) |slot_index| {
                                const parked = &self.channel_slots[slot_index];
                                if (parked.state != .idle and parked.generation == entry.retire_generation) {
                                    retireChannelSlot(parked);
                                }
                            }
                            // The image arm's journal encoding, reused:
                            // only regenerating admission refusals mark
                            // themselves with the exit reason — replay
                            // skips those records (the re-run open
                            // stages its own); an executor-truth
                            // rejection keeps `.exited` and feeds.
                            self.journalNote(.{
                                .kind = .channel,
                                .key = entry.event.key,
                                .channel_kind = entry.event.kind,
                                .dropped = entry.event.dropped_pending,
                                .channel_dropped_total = entry.event.dropped_total,
                                .exit_reason = if (entry.regenerates) .rejected else .exited,
                            });
                            const channel_fn = entry.channel_fn orelse continue;
                            return channel_fn(entry.event);
                        },
                        .pty => |entry| {
                            // A fed park-retiring start failure frees
                            // its parked slot before the Msg reaches
                            // update — the channel discipline. The drop
                            // count folds in the slot's own tally AT
                            // DELIVERY (the live staged-exit drain's
                            // rule): a write refused after the feed
                            // still lands in the delivered count.
                            var event = entry.event;
                            if (entry.retire_slot) |slot_index| {
                                const parked = &self.pty_slots[slot_index];
                                if (parked.state != .idle and parked.generation == entry.retire_generation) {
                                    event.dropped_writes +|= parked.dropped_writes;
                                    self.retirePtySlot(parked);
                                }
                            }
                            // Provenance rides `truncated` (unused for
                            // pty records): a pty exit's `reason` is
                            // meaningful data, so unlike channels it
                            // cannot double as the regenerating marker.
                            // Only deterministic admission refusals
                            // regenerate under replay and are skipped;
                            // executor-truth terminals (start failures,
                            // and the platform-unsupported rejection)
                            // keep `truncated = false` and feed.
                            self.journalNote(.{
                                .kind = .pty,
                                .key = event.key,
                                .pty_kind = event.kind,
                                .code = event.code,
                                .exit_reason = event.reason,
                                .pty_signal = event.signal,
                                .pty_dropped_writes = event.dropped_writes,
                                .truncated = entry.regenerates,
                            });
                            const pty_fn = entry.pty_fn orelse continue;
                            return pty_fn(event);
                        },
                        .staged => |msg| {
                            // Deliberately NO journal record: a
                            // caller-staged Msg is regenerating by
                            // contract (`stageLoopMsg`) — the replayed
                            // dispatch that staged it re-runs and
                            // stages the identical Msg at the
                            // identical pending position, so a
                            // journaled record would double-deliver.
                            return msg;
                        },
                    }
                }
                if (self.takeChannelStagedMsg(boundary.channel_before)) |msg| return msg;
                if (self.takePtyStagedMsg(boundary.pty_before)) |msg| return msg;
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
                        // key parks as a fresh effect. Retire the slot
                        // in the same stroke (see the `.image` arm's
                        // race note): the real worker stores `.draining`
                        // only AFTER posting this exit, so a drain can
                        // consume it while the slot still reads
                        // `.running` — and the handler's respawn would
                        // reject as a duplicate active key. The
                        // happens-before chain is complete here: the
                        // worker's mark-then-post publishes the marker
                        // (and every other slot write) before the entry
                        // is consumable — the enqueue releases the queue
                        // mutex this dequeue acquired — so with the
                        // generations matching, clearing the marker and
                        // storing `.draining` before the handler leaves
                        // the key free by the time any update code runs.
                        // The worker's own store keeps its role (it must
                        // stay after the post — a `.draining` slot is
                        // joinable, and the post can park in a
                        // full-queue retry only the loop can relieve);
                        // re-storing `.draining` is idempotent.
                        if (entry.generation == slot.generation) {
                            slot.exit_undelivered = false;
                            slot.state.store(.draining, .release);
                        }
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
                        // Retire the slot BEFORE the terminal reaches
                        // any handler (the `.image` arm's race note):
                        // the real worker stores `.draining` only after
                        // posting this entry, so a same-key fetch from
                        // the response handler must not find the slot
                        // still `.running`. Idempotent re-store.
                        slot.state.store(.draining, .release);
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
                        // Retire the slot BEFORE the terminal reaches
                        // any handler (the `.image` arm's race note):
                        // the real worker stores `.draining` only after
                        // posting this entry, so a same-key file effect
                        // from the result handler must not find the
                        // slot still `.running`. Idempotent re-store.
                        slot.state.store(.draining, .release);
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
                        // occupant was already retired. No consumer-side
                        // `.draining` store is needed here (unlike the
                        // worker-fed arms): clipboard terminals are
                        // staged on the loop thread with the store
                        // sequenced before the enqueue, so this drain
                        // can never observe the entry ahead of it.
                        if (entry.generation != slot.generation) continue;
                        // Take buffer ownership so the slot can be
                        // reused while `update` still reads the text.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        const payload_len = slot.payload_len;
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
                        // Journal BEFORE the handler gate: a clipboard
                        // terminal is executor truth (the pasteboard
                        // ran), so a fire-and-forget write's `.ok` or
                        // `.failed` must still journal — under session
                        // replay the request is a parked fake that only
                        // this record's feed retires. Only the Msg
                        // depends on the handler.
                        self.journalNote(.{
                            .kind = .clipboard,
                            .key = result.key,
                            .payload = result.text,
                            .dropped = result.dropped_before,
                            .clipboard_op = result.op,
                            .clipboard_outcome = result.outcome,
                        });
                        const clipboard_fn = entry.clipboard_fn orelse continue;
                        return clipboard_fn(result);
                    },
                    .host => {
                        // One terminal per host occupancy, mirroring
                        // `.response`: a mismatched generation means the
                        // occupant was already retired (replaced or
                        // cancelled — its result drops silently, per the
                        // request contract). No consumer-side
                        // `.draining` store is needed here (unlike the
                        // worker-fed arms): host answers are fed on the
                        // loop thread with the store sequenced before
                        // the enqueue — and a same-key host request
                        // REPLACES an in-flight one rather than
                        // rejecting, so no handler retry hinges on the
                        // state either way.
                        if (entry.generation != slot.generation) continue;
                        // Take buffer ownership so the slot can be
                        // reused while `update` still reads the bytes.
                        if (self.drain_fetch_body) |old| self.allocator.free(old);
                        self.drain_fetch_body = slot.fetch_buffer;
                        slot.fetch_buffer = null;
                        const payload_len = slot.payload_len;
                        // A cancel that raced the feed (the entry was
                        // already queued) still drops silently — on
                        // both sides: live never journals it, and the
                        // replayed cancel drops the parked fake, so
                        // neither side has a record to feed.
                        if (cancelled) continue;
                        const bytes: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[payload_len .. payload_len + entry.line_len]
                        else
                            "";
                        const result: EffectHostResult = .{
                            .key = entry.key,
                            .ok = entry.host_ok,
                            .bytes = bytes,
                        };
                        // Journal BEFORE the handler gate: a host
                        // answer is executor truth, so it must journal
                        // even when no `on_result` route exists — under
                        // session replay the request is a parked fake
                        // that only this record's feed retires. Only
                        // the Msg depends on the handler.
                        self.journalNote(.{
                            .kind = .host,
                            .key = result.key,
                            .payload = result.bytes,
                            // `.host` journal encoding: route in `code`.
                            .code = @intFromBool(!result.ok),
                        });
                        const host_fn = entry.host_fn orelse continue;
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
                    .channel => {
                        // A fed (session-replay / test) channel event:
                        // `slot_index` names a CHANNEL table slot, so
                        // the shared `slot`/`cancelled` prelude above
                        // is meaningless here and unused. The recorded
                        // kind, bytes, and drop counts deliver
                        // verbatim; the handler resolves from the live
                        // slot at delivery (the audio resolve rule).
                        const channel_slot = &self.channel_slots[entry.slot_index];
                        if (channel_slot.state == .idle or entry.channel_generation != channel_slot.generation) continue;
                        const on_event = channel_slot.on_event;
                        // Terminals retire the slot BEFORE the Msg
                        // reaches update — the drain-wide discipline:
                        // the key frees at the same causal instant on
                        // both sides, so a handler that reopens its
                        // own key is accepted.
                        if (entry.channel_kind != .data) retireChannelSlot(channel_slot);
                        const event: EffectChannelEvent = .{
                            .key = entry.key,
                            .kind = entry.channel_kind,
                            .bytes = entry.line_bytes[0..entry.line_len],
                            .dropped_pending = entry.dropped_before,
                            .dropped_total = entry.dropped_lines,
                        };
                        self.journalNote(.{
                            .kind = .channel,
                            .key = event.key,
                            .payload = event.bytes,
                            .channel_kind = event.kind,
                            .dropped = event.dropped_pending,
                            .channel_dropped_total = event.dropped_total,
                        });
                        const deliver_fn = on_event orelse continue;
                        return deliver_fn(event);
                    },
                    .pty => {
                        // A fed (session-replay / test) pty event:
                        // `slot_index` names a PTY table slot; the
                        // shared `slot`/`cancelled` prelude above is
                        // unused here. Bytes may ride the heap payload
                        // (an output batch past the inline bound) —
                        // take it before any early-out so skipped
                        // entries still free, the `.line` discipline.
                        if (self.drain_heap_line) |old_heap| {
                            self.allocator.free(old_heap);
                            self.drain_heap_line = null;
                        }
                        if (entry.heap_line) |heap| {
                            self.drain_heap_line = heap;
                            entry.heap_line = null;
                        }
                        const pty_slot = &self.pty_slots[entry.slot_index];
                        if (pty_slot.state == .idle or entry.channel_generation != pty_slot.generation) continue;
                        const on_event = pty_slot.on_event;
                        // The delivered drop count reads AT DELIVERY, the
                        // live staged-exit drain's rule: a write refused
                        // AFTER the exit was fed (and counted onto the
                        // slot) still lands in the delivered tally.
                        // Captured before retire resets the slot. Under
                        // replay the slot count is always zero, so the
                        // journaled count delivers verbatim.
                        const slot_dropped = pty_slot.dropped_writes;
                        if (entry.pty_kind == .exit) self.retirePtySlot(pty_slot);
                        const bytes: []const u8 = if (self.drain_heap_line) |heap|
                            heap[0..entry.line_len]
                        else
                            entry.line_bytes[0..entry.line_len];
                        const event: EffectPtyEvent = .{
                            .key = entry.key,
                            .kind = entry.pty_kind,
                            .bytes = bytes,
                            .code = entry.code,
                            .reason = entry.reason,
                            .signal = entry.pty_signal,
                            .dropped_writes = if (entry.pty_kind == .exit)
                                entry.pty_dropped_writes +| slot_dropped
                            else
                                entry.pty_dropped_writes,
                        };
                        self.journalNote(.{
                            .kind = .pty,
                            .key = event.key,
                            .payload = event.bytes,
                            .pty_kind = event.kind,
                            .code = event.code,
                            .exit_reason = event.reason,
                            .pty_signal = event.signal,
                            .pty_dropped_writes = event.dropped_writes,
                        });
                        const deliver_fn = on_event orelse continue;
                        return deliver_fn(event);
                    },
                }
            }
        }

        /// Deliver the oldest boundary-eligible LIVE channel event: the
        /// smallest post-order stamp across every channel's staging
        /// FIFO, or a `.closing` channel's armed close marker once its
        /// backlog drained (every staged post is older than the marker
        /// by construction, so data-before-closed holds per channel and
        /// cross-channel delivery follows post order). Stamps at or
        /// past `before` wait for the next wake — the posting thread
        /// already nudged it (`DrainBoundary` causality). Loop-thread
        /// only; each pop is a bounded copy under the channel's spin
        /// mutex into `channel_drain_scratch`, so the delivered slice
        /// stays valid while `update` runs.
        fn takeChannelStagedMsg(self: *Self, before: u64) ?Msg {
            var best_index: ?usize = null;
            var best_seq: u64 = std.math.maxInt(u64);
            var best_closed = false;
            for (&self.channel_slots, 0..) |*slot, index| {
                if (slot.state == .idle) continue;
                const shared = slot.shared orelse continue;
                shared.mutex.lock();
                var seq: ?u64 = null;
                var is_closed = false;
                if (shared.staging) |staging| {
                    if (staging.len > 0) seq = staging.seqs[staging.head];
                }
                shared.mutex.unlock();
                // A staged queue observed EMPTY while the coalescer is
                // still latched: release the latch HERE, not only at
                // the pass boundary. `takeMsg` is a public drain entry
                // with no `drainBoundary` around it, so a bare-takeMsg
                // caller that drains a wake's entries to empty would
                // otherwise leave the latch set — and the next
                // accepted post, seeing the stale latch, would never
                // wake: a stranded event. Clear-then-recheck, the
                // boundary clear's ordering (both sides seq_cst): a
                // post whose latched-flag check observed true stamped
                // its entry before this clear, so the RE-CHECK below
                // observes that entry and this sweep delivers it; a
                // post landing after the clear observes the flag clear
                // and latches a fresh wake of its own. Either
                // interleaving, nothing staged is ever left wakeless —
                // at worst the recheck delivers an entry whose fresh
                // wake then finds nothing, and one redundant host wake
                // is the acceptable price (a stranded event is not).
                // The empty observation is also what keeps this clear
                // from racing the BOUNDED boundary path into a lost
                // wake: inside a `drainBoundary` pass the latch is
                // only re-set by a post stamped AFTER the boundary
                // snapshot, and such an entry cannot deliver inside
                // the pass (`candidate >= before` below), so the queue
                // this sweep observes stays non-empty and the clear
                // never fires — the post-boundary latch survives for
                // the pass that will deliver it.
                if (seq == null and shared.wake.pending.load(.seq_cst)) {
                    shared.wake.mutex.lock();
                    shared.wake.pending.store(false, .seq_cst);
                    shared.wake.mutex.unlock();
                    shared.mutex.lock();
                    if (shared.staging) |staging| {
                        if (staging.len > 0) seq = staging.seqs[staging.head];
                    }
                    shared.mutex.unlock();
                }
                if (seq == null and slot.state == .closing and slot.closed_staged) {
                    seq = slot.closed_seq;
                    is_closed = true;
                }
                const candidate = seq orelse continue;
                if (candidate >= before) continue;
                if (candidate < best_seq) {
                    best_seq = candidate;
                    best_index = index;
                    best_closed = is_closed;
                }
            }
            const index = best_index orelse return null;
            const slot = &self.channel_slots[index];
            const shared = slot.shared.?;
            const on_event = slot.on_event;
            var event: EffectChannelEvent = .{ .key = slot.key, .kind = .data };
            if (best_closed) {
                slot.closed_staged = false;
                shared.mutex.lock();
                event.kind = .closed;
                event.dropped_pending = shared.dropped_pending;
                event.dropped_total = shared.dropped_total;
                shared.dropped_pending = 0;
                shared.mutex.unlock();
                // Retire BEFORE the Msg reaches update (the key frees
                // at delivery, the families' shared instant).
                retireChannelSlot(slot);
            } else {
                shared.mutex.lock();
                const staging = shared.staging.?;
                const len = staging.lens[staging.head];
                @memcpy(self.channel_drain_scratch[0..len], staging.data[staging.head][0..len]);
                staging.head = (staging.head + 1) % max_effect_channel_pending;
                staging.len -= 1;
                event.bytes = self.channel_drain_scratch[0..len];
                event.dropped_pending = shared.dropped_pending;
                event.dropped_total = shared.dropped_total;
                shared.dropped_pending = 0;
                shared.mutex.unlock();
            }
            _ = self.channel_pending_count.fetchSub(1, .monotonic);
            self.journalNote(.{
                .kind = .channel,
                .key = event.key,
                .payload = event.bytes,
                .channel_kind = event.kind,
                .dropped = event.dropped_pending,
                .channel_dropped_total = event.dropped_total,
            });
            const deliver_fn = on_event orelse return null;
            return deliver_fn(event);
        }

        /// Deliver the oldest boundary-eligible LIVE pty completion:
        /// the smallest stamp across every pty's staged output backlog
        /// and staged exit. An output pop takes at most one chunk
        /// (`max_effect_pty_chunk_bytes`) per call — the drain loop
        /// keeps calling until the backlog empties, so one pass
        /// delivers the whole coalesced backlog as a handful of
        /// bounded records; the exit (stamped after every byte by
        /// construction) delivers only once its ring is empty:
        /// data-before-exit per pty. Popping also resumes a parked
        /// reader — the back-pressure handshake's loop half.
        fn takePtyStagedMsg(self: *Self, before: u64) ?Msg {
            var best_index: ?usize = null;
            var best_seq: u64 = std.math.maxInt(u64);
            var best_exit = false;
            for (&self.pty_slots, 0..) |*slot, index| {
                if (slot.state == .idle) continue;
                const shared = slot.shared orelse continue;
                shared.mutex.lock();
                var seq: ?u64 = null;
                var is_exit = false;
                if (shared.staging) |staging| {
                    if (staging.len > 0 and shared.data_seq_valid) {
                        seq = shared.data_seq;
                    } else if (shared.exit_staged) {
                        seq = shared.exit_seq;
                        is_exit = true;
                    }
                } else if (shared.exit_staged) {
                    seq = shared.exit_seq;
                    is_exit = true;
                }
                shared.mutex.unlock();
                // Empty-but-latched: release the coalescer here, the
                // channel sweep's bare-takeMsg argument verbatim.
                if (seq == null and shared.wake.pending.load(.seq_cst)) {
                    shared.wake.mutex.lock();
                    shared.wake.pending.store(false, .seq_cst);
                    shared.wake.mutex.unlock();
                    shared.mutex.lock();
                    if (shared.staging) |staging| {
                        if (staging.len > 0 and shared.data_seq_valid) {
                            seq = shared.data_seq;
                        } else if (shared.exit_staged) {
                            seq = shared.exit_seq;
                            is_exit = true;
                        }
                    } else if (shared.exit_staged) {
                        seq = shared.exit_seq;
                        is_exit = true;
                    }
                    shared.mutex.unlock();
                }
                const candidate = seq orelse continue;
                if (candidate >= before) continue;
                if (candidate < best_seq) {
                    best_seq = candidate;
                    best_index = index;
                    best_exit = is_exit;
                }
            }
            const index = best_index orelse return null;
            const slot = &self.pty_slots[index];
            const shared = slot.shared.?;
            const on_event = slot.on_event;
            var event: EffectPtyEvent = .{ .key = slot.key };
            if (best_exit) {
                shared.mutex.lock();
                event.kind = .exit;
                event.code = shared.exit_code;
                event.signal = shared.exit_signal;
                event.reason = shared.exit_reason;
                event.dropped_writes = shared.dropped_writes;
                shared.exit_staged = false;
                shared.mutex.unlock();
                _ = self.pty_pending_count.fetchSub(1, .seq_cst);
                // Retire BEFORE the Msg reaches update (the key frees
                // at delivery, the families' shared instant).
                self.retirePtySlot(slot);
                self.journalNote(.{
                    .kind = .pty,
                    .key = event.key,
                    .pty_kind = .exit,
                    .code = event.code,
                    .exit_reason = event.reason,
                    .pty_signal = event.signal,
                    .pty_dropped_writes = event.dropped_writes,
                });
            } else {
                var resume_reader = false;
                shared.mutex.lock();
                const staging = shared.staging.?;
                const take = @min(staging.len, max_effect_pty_chunk_bytes);
                var i: usize = 0;
                while (i < take) : (i += 1) {
                    self.pty_drain_scratch[i] = staging.data[(staging.head + i) % max_effect_pty_staging_bytes];
                }
                staging.head = (staging.head + take) % max_effect_pty_staging_bytes;
                staging.len -= take;
                const emptied = staging.len == 0;
                var rewake = false;
                if (emptied) {
                    shared.data_seq_valid = false;
                } else if (shared.owner) |owner| {
                    // ONE output batch per pty per drain pass: re-stamp
                    // the remaining backlog with a fresh seq (> this
                    // pass's boundary snapshot, so `candidate >= before`
                    // skips it here) and wake for the next pass. Without
                    // this, a continuously writing child (`yes`) whose
                    // io thread keeps appending to the same pre-boundary
                    // stamp would let one pass deliver without bound and
                    // starve every other platform event.
                    shared.data_seq = owner.seq.fetchAdd(1, .seq_cst);
                    rewake = true;
                }
                if (shared.reader_parked) {
                    shared.reader_parked = false;
                    resume_reader = true;
                }
                shared.mutex.unlock();
                if (emptied) _ = self.pty_pending_count.fetchSub(1, .seq_cst);
                if (rewake) ChannelHandle.requestHostWake(&shared.wake, slot.generation);
                if (resume_reader and comptime pty_transport.supported) {
                    pty_transport.nudge(slot.wake_pipe[1]);
                }
                event.bytes = self.pty_drain_scratch[0..take];
                self.journalNote(.{
                    .kind = .pty,
                    .key = event.key,
                    .payload = event.bytes,
                    .pty_kind = .output,
                    // Canonical output-record shape: the -1 code sentinel
                    // every delivered non-exit event carries (and the fed
                    // drain journals), zero signal/drops. The replay
                    // damage gate holds records to exactly this.
                    .code = effect_error_exit_code,
                });
            }
            const deliver_fn = on_event orelse return null;
            return deliver_fn(event);
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
        ///
        /// Only the Msg is gated on the handler. An executor-truth
        /// terminal (`regenerates = false`) stages even without one:
        /// it occupies its id through the staged window
        /// (`stagedImageOccupiesKey`) and journals at drain, because
        /// under session replay the request it answers is a parked
        /// fake that ONLY the journaled record's feed retires —
        /// skipping the stage for a fire-and-forget load would leave
        /// the id and a slot occupied replay-side forever. A
        /// handlerless REGENERATING refusal stages nothing: replay
        /// re-runs the same loop-side validation at the same dispatch
        /// and refuses identically, so both sides stay symmetric with
        /// no record, no occupancy, and no Msg.
        fn deliverLoopImage(self: *Self, result: EffectImageResult, image_fn: ?ImageMsgFn, regenerates: bool) void {
            if (image_fn == null and regenerates) return;
            self.stagePendingImage(.{
                .seq = self.nextPendingSeq(),
                .result = result,
                .image_fn = image_fn,
                .regenerates = regenerates,
            });
        }

        /// Stage a refused open's one `.rejected` terminal —
        /// `rejectImage`'s channel twin, same `regenerates` provenance:
        /// true for the deterministic admission refusals replay
        /// re-derives (occupied key, full channel table), false when
        /// the executor could not stage an otherwise valid channel
        /// (process-allocator failure the replayed open never
        /// reproduces — journals as executor truth and feeds, and the
        /// staged terminal holds the key until it drains).
        fn rejectChannel(self: *Self, key: u64, channel_fn: ChannelMsgFn, regenerates: bool) void {
            self.stagePendingChannel(.{
                .seq = self.nextPendingSeq(),
                .event = .{ .key = key, .kind = .rejected },
                .channel_fn = channel_fn,
                .regenerates = regenerates,
            });
        }

        /// The next channel occupancy generation — channel-owned,
        /// u64, monotonic (see `channel_generation`). The zero skip
        /// mirrors the shared counter's: 0 is the never-opened /
        /// disarmed sentinel, unreachable to a live handle. Wrapping
        /// arithmetic is kept for form; at one open per nanosecond the
        /// wrap is five centuries away.
        fn nextChannelGeneration(self: *Self) u64 {
            self.channel_generation +%= 1;
            if (self.channel_generation == 0) self.channel_generation = 1;
            return self.channel_generation;
        }

        fn findChannelSlot(self: *Self, key: u64) ?*ChannelSlot {
            for (&self.channel_slots) |*slot| {
                if (slot.state != .idle and slot.key == key) return slot;
            }
            return null;
        }

        fn findIdleChannelSlot(self: *Self) ?usize {
            for (&self.channel_slots, 0..) |*slot, index| {
                if (slot.state == .idle) return index;
            }
            return null;
        }

        fn idleChannelSlotCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.channel_slots) |*slot| {
                if (slot.state == .idle) count += 1;
            }
            return count;
        }

        /// Staged EXECUTOR-TRUTH channel rejections (`regenerates =
        /// false`) — each one an open that could not stage its channel
        /// storage. Each reserves one slot of live table capacity
        /// until it drains (see `openChannel`'s admission gate): the
        /// same open PARKS a real slot under replay until the
        /// journaled terminal feeds, and the drain's pop
        /// (`takePendingChannel`, before the Msg reaches update) is
        /// the live instant matching the fed terminal's
        /// `retireChannelSlot`. Regenerating refusals never appear in
        /// this count — replay stages its own with no slot held on
        /// either side.
        fn stagedChannelReservationCount(self: *Self) usize {
            const storage = self.pendingChannelStorage();
            var count: usize = 0;
            var index: usize = 0;
            while (index < self.pending_channel_len) : (index += 1) {
                const entry = &storage[(self.pending_channel_head + index) % storage.len];
                // A fed park-retiring rejection reserves nothing: its
                // parked slot still counts against the table until the
                // entry delivers and retires it (see `PendingChannel`).
                if (!entry.regenerates and entry.retire_slot == null) count += 1;
            }
            return count;
        }

        /// A channel occupies its key from open through the `.closing`
        /// flush until the `.closed` terminal delivers — the keyed
        /// families' posted-but-undelivered window, held by the table
        /// state instead of a slot marker.
        fn channelOccupiesKey(self: *Self, key: u64) bool {
            return self.findChannelSlot(key) != null;
        }

        /// A staged executor-truth channel rejection occupies its key
        /// until the drain delivers it — `stagedImageOccupiesKey`'s
        /// channel twin, with the identical replay-window reasoning
        /// (see there). Regenerating admission refusals deliberately
        /// do NOT occupy: both sides refuse and stage identically.
        fn stagedChannelOccupiesKey(self: *Self, key: u64) bool {
            const storage = self.pendingChannelStorage();
            var index: usize = 0;
            while (index < self.pending_channel_len) : (index += 1) {
                const entry = &storage[(self.pending_channel_head + index) % storage.len];
                // A fed park-retiring rejection holds no key of its
                // own: the parked slot occupies the key until the
                // entry delivers and retires it (see `PendingChannel`).
                if (!entry.regenerates and entry.retire_slot == null and entry.event.key == key) return true;
            }
            return false;
        }

        /// Whether a channel slot is a LIVE occupancy from the feed
        /// seam's view (`feedChannelEvent`'s terminal gate): an open
        /// posting header (posts may still land), a staging FIFO still
        /// installed (accepted posts may be waiting to drain), or an
        /// armed close marker (`closeChannel`'s counted terminal).
        /// Replay-parked occupancies — which never install staging and
        /// whose handles are inert — answer false, as does a header
        /// left over from an earlier occupancy that already retired.
        /// Loop-thread only.
        fn channelSlotLive(slot: *ChannelSlot) bool {
            if (slot.closed_staged) return true;
            const shared = slot.shared orelse return false;
            shared.mutex.lock();
            defer shared.mutex.unlock();
            return shared.open or shared.staging != null;
        }

        /// Retire a channel occupancy at terminal delivery: free the
        /// staging FIFO (posts stopped touching it the moment `open`
        /// cleared under the mutex — see `ChannelStaging`) and return
        /// the slot to `.idle`. The `ChannelShared` header stays,
        /// generation-dead, for the slot's next occupancy. Loop-thread
        /// only.
        fn retireChannelSlot(slot: *ChannelSlot) void {
            if (slot.shared) |shared| {
                shared.mutex.lock();
                shared.open = false;
                const staging = shared.staging;
                shared.staging = null;
                shared.owner = null;
                shared.mutex.unlock();
                // Usually a no-op (closeChannel already revoked), but
                // fed terminals can retire a channel that never closed
                // through the verb — revoke uniformly (idempotent).
                // Non-blocking like the close path, and for the same
                // reason: retire runs at delivery, inside the very
                // dispatch a synchronous-marshal `wake_fn` may be
                // waiting on (see `revokeChannelWake`).
                revokeChannelWake(&shared.wake);
                if (staging) |s| process_allocator.destroy(s);
            }
            slot.state = .idle;
            slot.on_event = null;
            slot.closed_staged = false;
            slot.park_seq = 0;
            slot.park_state = .none;
        }

        fn rejectPty(self: *Self, key: u64, pty_fn: ?PtyMsgFn, regenerates: bool) void {
            self.stagePendingPty(.{
                .seq = self.nextPendingSeq(),
                .event = .{ .key = key, .kind = .exit, .reason = .rejected },
                .pty_fn = pty_fn,
                .regenerates = regenerates,
            });
        }

        fn findPtySlot(self: *Self, key: u64) ?*PtySlot {
            for (&self.pty_slots) |*slot| {
                if (slot.state != .idle and slot.key == key) return slot;
            }
            return null;
        }

        fn findIdlePtySlot(self: *Self) ?usize {
            for (&self.pty_slots, 0..) |*slot, index| {
                if (slot.state == .idle) return index;
            }
            return null;
        }

        fn idlePtySlotCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.pty_slots) |*slot| {
                if (slot.state == .idle) count += 1;
            }
            return count;
        }

        /// Staged EXECUTOR-TRUTH pty start failures reserve table
        /// capacity until they deliver — `stagedChannelReservationCount`
        /// with the identical replay-hold reasoning.
        fn stagedPtyReservationCount(self: *Self) usize {
            const storage = self.pendingPtyStorage();
            var count: usize = 0;
            var index: usize = 0;
            while (index < self.pending_pty_len) : (index += 1) {
                const entry = &storage[(self.pending_pty_head + index) % storage.len];
                if (!entry.regenerates and entry.retire_slot == null) count += 1;
            }
            return count;
        }

        /// A pty occupies its key from the accepted spawn until its
        /// `.exit` terminal delivers.
        fn ptyOccupiesKey(self: *Self, key: u64) bool {
            return self.findPtySlot(key) != null;
        }

        /// A staged executor-truth pty terminal occupies its key until
        /// the drain delivers it — `stagedChannelOccupiesKey`'s pty
        /// twin, same regenerating/non-regenerating line.
        fn stagedPtyOccupiesKey(self: *Self, key: u64) bool {
            const storage = self.pendingPtyStorage();
            var index: usize = 0;
            while (index < self.pending_pty_len) : (index += 1) {
                const entry = &storage[(self.pending_pty_head + index) % storage.len];
                if (!entry.regenerates and entry.retire_slot == null and entry.event.key == key) return true;
            }
            return false;
        }

        /// Count one refused write into the staged executor-truth
        /// terminal occupying `key` — the synchronous start-failure
        /// window, whose slot was already released so no slot tally can
        /// carry the drop to delivery. Returns whether such a terminal
        /// was found (the `stagedPtyOccupiesKey` predicate, with the
        /// count folded into the same walk).
        fn countRefusalOnStagedPtyTerminal(self: *Self, key: u64) bool {
            const storage = self.pendingPtyStorage();
            var index: usize = 0;
            while (index < self.pending_pty_len) : (index += 1) {
                const entry = &storage[(self.pending_pty_head + index) % storage.len];
                if (!entry.regenerates and entry.retire_slot == null and entry.event.key == key) {
                    entry.event.dropped_writes +|= 1;
                    return true;
                }
            }
            return false;
        }

        /// Retire a pty occupancy at terminal delivery: sever the
        /// shared block, free the staging ring, close the transport,
        /// and collect the io thread (which staged the exit as its
        /// last shared touch, so the join is an epilogue wait, never a
        /// wait on child I/O). The `PtyShared` header stays allocated
        /// forever, the channel headers' bounded-leak invariant.
        fn retirePtySlot(self: *Self, slot: *PtySlot) void {
            if (slot.shared) |shared| {
                shared.mutex.lock();
                shared.open = false;
                const staging = shared.staging;
                shared.staging = null;
                const outbound = shared.outbound;
                shared.outbound = null;
                shared.owner = null;
                shared.mutex.unlock();
                revokeChannelWake(&shared.wake);
                // Both heap blocks free here: the io thread staged its
                // exit as its last touch of either (it reads outbound and
                // writes staging only inside its read loop, gated by
                // `open`), and `ptyWrite` runs on this same loop thread —
                // so at retire nothing reaches them. Only the small
                // `PtyShared` header stays, the channel bounded-leak rule.
                // Freed through the SAME seam that allocated them
                // (`channel_storage_allocator`): a swapped-in tracking or
                // arena allocator must see its own frees, never a
                // mismatched destroy against the default backing.
                if (staging) |st| self.channel_storage_allocator.destroy(st);
                if (outbound) |ob| self.channel_storage_allocator.destroy(ob);
            }
            if (comptime pty_transport.supported) {
                if (slot.io_thread) |thread| {
                    // DETACH, never join. Retirement runs at exit
                    // delivery — inside the very dispatch a
                    // synchronous-marshal `wake_fn` may be waiting on —
                    // and the io thread's LAST act is that host wake, so
                    // joining here would deadlock a violating hook
                    // exactly the way `ChannelWake` forbids (revoke
                    // mid-life, quiesce only at teardown). By retirement
                    // the thread has published `io_done` and is past all
                    // transport, staging, and pipe access (it only
                    // touches the process-lifetime wake header from here
                    // on), so detaching and reclaiming its fds is safe:
                    // a conforming enqueue-only wake means the thread has
                    // already exited, and a violating one lingers
                    // harmlessly against the process-lived header.
                    thread.detach();
                    slot.io_thread = null;
                }
                if (slot.transport) |transport| {
                    transport.close();
                    slot.transport = null;
                }
                pty_transport.closeFd(slot.wake_pipe[0]);
                pty_transport.closeFd(slot.wake_pipe[1]);
                slot.wake_pipe = .{ -1, -1 };
            }
            slot.state = .idle;
            slot.on_event = null;
            slot.kill_requested = false;
            slot.write_capture_len = 0;
            slot.dropped_writes = 0;
            slot.park_seq = 0;
            slot.park_state = .none;
        }

        /// Start the real transport for an accepted `ptySpawn`: flatten
        /// the bound environ (the spawn env policy, verbatim), open the
        /// pty pair, fork the child onto it, and hand the parent end to a
        /// dedicated io thread. Failures release the slot and stage an
        /// executor-truth `.spawn_failed` terminal — journaled with its
        /// real reason and FED under replay, where the re-run spawn
        /// parks a slot this terminal retires (the channel
        /// classification, applied to transports).
        ///
        /// Runs SYNCHRONOUSLY on the loop thread by design: the
        /// spawn-position start verdict is part of the record/replay
        /// contract (a start failure delivers at the spawn's dispatch
        /// position, retiring the replay park). The cost is bounded —
        /// a handful of syscalls plus the half-second exec probe, whose
        /// unresolved case carries to the reap instead of waiting — with
        /// one residual: the PATH walk's `access()` probes have no
        /// timeout, so an executable searched through a stalled
        /// NFS/autofs PATH entry stalls the loop like any synchronous
        /// filesystem touch of that mount would.
        fn startRealPty(self: *Self, slot: *PtySlot, options: PtySpawnOptions) void {
            if (comptime !pty_transport.supported) {
                // ptySpawn already refused unsupported builds.
                unreachable;
            }
            const shared = slot.shared orelse blk: {
                const created = self.channel_storage_allocator.create(PtyShared) catch {
                    return self.failPtyStart(slot, options);
                };
                created.* = .{};
                slot.shared = created;
                break :blk created;
            };
            const staging = self.channel_storage_allocator.create(PtyStaging) catch {
                return self.failPtyStart(slot, options);
            };
            staging.* = .{};
            const outbound = self.channel_storage_allocator.create(PtyOutbound) catch {
                self.channel_storage_allocator.destroy(staging);
                return self.failPtyStart(slot, options);
            };
            outbound.* = .{};
            const pipe = pty_transport.pipePair() catch {
                self.channel_storage_allocator.destroy(outbound);
                self.channel_storage_allocator.destroy(staging);
                return self.failPtyStart(slot, options);
            };
            var env_buffer: [pty_transport.max_env_entries]pty_transport.EnvVar = undefined;
            const env = flattenPtyEnviron(self.environ orelse fallbackEnviron(), &env_buffer) orelse {
                self.channel_storage_allocator.destroy(outbound);
                self.channel_storage_allocator.destroy(staging);
                pty_transport.closeFd(pipe[0]);
                pty_transport.closeFd(pipe[1]);
                return self.failPtyStart(slot, options);
            };
            const transport = pty_transport.spawn(self.allocator, .{
                .argv = slot.requestArgv(),
                .env = env,
                .term = slot.requestTerm(),
                .cols = slot.cols,
                .rows = slot.rows,
            }) catch {
                self.channel_storage_allocator.destroy(outbound);
                self.channel_storage_allocator.destroy(staging);
                pty_transport.closeFd(pipe[0]);
                pty_transport.closeFd(pipe[1]);
                return self.failPtyStart(slot, options);
            };
            const generation = slot.generation;
            shared.mutex.lock();
            shared.open = true;
            shared.generation = generation;
            shared.staging = staging;
            shared.outbound = outbound;
            shared.data_seq_valid = false;
            shared.exit_staged = false;
            shared.exit_code = effect_error_exit_code;
            shared.exit_signal = 0;
            shared.exit_reason = .exited;
            shared.reader_parked = false;
            shared.out_head = 0;
            shared.out_len = 0;
            shared.out_write_head = 0;
            shared.out_write_count = 0;
            shared.out_front_sent = 0;
            shared.dropped_writes = 0;
            shared.kill_requested = false;
            // Every prior-session flag on the reused header must reset,
            // or a stale value steers the new session: a leftover
            // `reaping` would make ptyKill skip its immediate SIGKILL
            // and fall through to the reaper's slower SIGHUP-first
            // escalation.
            shared.reaping = false;
            shared.shutdown = false;
            shared.io_done = false;
            shared.owner = .{
                .seq = &self.pty_seq,
                .pending = &self.pty_pending_count,
            };
            shared.mutex.unlock();
            shared.wake.mutex.lock();
            shared.wake.generation = generation;
            shared.wake.services = &self.wake_services;
            shared.wake.pending.store(false, .seq_cst);
            shared.wake.mutex.unlock();
            // Publish the services snapshot if channels have not
            // already (the openChannel dance, same refusal class): a
            // pty whose snapshot cannot allocate could stage output no
            // producer wake would ever deliver, so the spawn fails
            // loudly instead. Publish-then-sweep, the invariant every
            // publication site keeps.
            if (self.services != null and self.wake_services.load(.seq_cst) == null) {
                if (!self.materializeWakeSnapshot()) {
                    shared.mutex.lock();
                    shared.open = false;
                    shared.staging = null;
                    shared.outbound = null;
                    shared.owner = null;
                    shared.mutex.unlock();
                    revokeChannelWake(&shared.wake);
                    self.channel_storage_allocator.destroy(staging);
                    self.channel_storage_allocator.destroy(outbound);
                    pty_transport.closeFd(pipe[0]);
                    pty_transport.closeFd(pipe[1]);
                    transport.kill(false);
                    // Bounded (the escalate-then-surrender reap): see
                    // the thread-start failure path below.
                    _ = transport.reapEnding();
                    transport.close();
                    return self.failPtyStart(slot, options);
                }
                if (self.hasPending()) self.wakeHost();
            }
            const thread = std.Thread.spawn(.{}, ptyIoLoop, .{ shared, transport, pipe[0], generation }) catch {
                shared.mutex.lock();
                shared.open = false;
                shared.staging = null;
                shared.outbound = null;
                shared.owner = null;
                shared.mutex.unlock();
                revokeChannelWake(&shared.wake);
                self.channel_storage_allocator.destroy(staging);
                self.channel_storage_allocator.destroy(outbound);
                pty_transport.closeFd(pipe[0]);
                pty_transport.closeFd(pipe[1]);
                transport.kill(false);
                // Bounded (the escalate-then-surrender reap): the child
                // may be wedged inside an exec on a stalled mount, and
                // an unbounded waitpid here would freeze the UI loop
                // instead of delivering spawn_failed.
                _ = transport.reapEnding();
                transport.close();
                return self.failPtyStart(slot, options);
            };
            slot.transport = transport;
            slot.io_thread = thread;
            slot.wake_pipe = pipe;
        }

        /// Release a claimed pty slot and stage the executor-truth
        /// start-failure terminal.
        fn failPtyStart(self: *Self, slot: *PtySlot, options: PtySpawnOptions) void {
            slot.state = .idle;
            slot.on_event = null;
            self.stagePendingPty(.{
                .seq = self.nextPendingSeq(),
                .event = .{ .key = options.key, .kind = .exit, .reason = .spawn_failed },
                .pty_fn = options.on_event,
                .regenerates = false,
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

        /// Update the video channel mirrors from one event and stamp
        /// the channel's key into it — `applyAudioEvent` for the video
        /// channel, plus the dimension mirrors the `.loaded`
        /// acknowledgment carries. Null when the channel is idle (a
        /// platform straggler after `stopVideo` is swallowed rather
        /// than misattributed). `.completed` pins position to the
        /// duration; `.failed`/`.rejected` release the surface claim
        /// and reset the channel (nothing is left to resume).
        /// One video scalar into the exact-integer delivery window
        /// (see `max_effect_video_scalar_exclusive`).
        fn clampVideoScalar(value: u64) u64 {
            return @min(value, max_effect_video_scalar_exclusive - 1);
        }

        fn applyVideoEvent(self: *Self, event: EffectVideo) ?EffectVideo {
            if (!self.video.active) return null;
            var resolved = event;
            resolved.key = self.video.key;
            switch (resolved.kind) {
                .loaded, .position => {
                    self.video.position_ms = resolved.position_ms;
                    if (resolved.duration_ms > 0) self.video.duration_ms = resolved.duration_ms;
                    if (resolved.width > 0) self.video.width = resolved.width;
                    if (resolved.height > 0) self.video.height = resolved.height;
                    self.video.playing = resolved.playing;
                    self.video.buffering = resolved.buffering;
                },
                .completed => {
                    if (resolved.duration_ms > 0) self.video.duration_ms = resolved.duration_ms;
                    resolved.position_ms = self.video.duration_ms;
                    resolved.playing = false;
                    resolved.buffering = false;
                    self.video.position_ms = self.video.duration_ms;
                    self.video.playing = false;
                    self.video.buffering = false;
                    // The natural end retired the platform player
                    // (retire-before-emit); the fake transport refuses
                    // from here like the live one (`VideoChannel.completed`).
                    self.video.completed = true;
                },
                .failed, .rejected => {
                    resolved.playing = false;
                    resolved.buffering = false;
                    self.releaseVideoSink();
                    self.video = .{ .volume = self.video.volume };
                },
            }
            return resolved;
        }

        /// A synchronous refusal (the claim, load, or play errored, or
        /// no services/binding are bound): silence whatever the
        /// platform may have installed (best effort — a load that
        /// succeeded before a later step refused would otherwise keep
        /// its player decoding while this channel forgets it, and the
        /// inactive channel would skip it at teardown too), release
        /// whatever was claimed, reset the channel, and deliver one
        /// `.failed` event on the next drain — the honest degrade for
        /// hosts without video playback.
        /// A synchronous `loadVideo` refusal: journal this load's
        /// `.video_load` record FIRST — every non-rejected load
        /// journals exactly one, resolved or refused, which is what
        /// lets replay pair every replayed load with a record and
        /// refuse extras — then degrade through `failVideoChannel`.
        /// The record's `video_kind` carries the outcome (`.failed`
        /// here): the live channel resets before `loadVideo` returns,
        /// so the replayed fake load must reset at the same instant
        /// (`takeReplayVideoSource`) — a snapshot an update reads
        /// inside the very dispatch must match the recording's. The
        /// `.failed` terminal Msg still journals separately, at its
        /// drain.
        fn failVideoLoad(self: *Self) void {
            self.journalNote(.{
                .kind = .video_load,
                .key = self.video.key,
                .video_kind = .failed,
                .video_token = self.video.token,
                .video_source = self.video.source,
            });
            self.failVideoChannel();
        }

        fn failVideoChannel(self: *Self) void {
            const key = self.video.key;
            const token = self.video.token;
            const on_event = self.video.on_event;
            if (!self.video.fake) {
                if (self.services) |services| services.videoStop() catch {};
            }
            self.releaseVideoSink();
            self.video = .{ .volume = self.video.volume };
            self.deliverLoopVideo(.{ .key = key, .kind = .failed }, on_event, token);
        }

        /// Stage a video event Msg produced on the loop thread
        /// (rejections and synchronous failures) for the next drain —
        /// through the non-lossy video stage, never the ring: each is
        /// its load call's only terminal (`PendingVideo`). Handler-less
        /// terminals stage too (the image arm's rule): a declarative
        /// playback binds no Msg, but its synchronous `.failed` must
        /// still journal — the record is what replays the channel
        /// reset — and the staged delivery's wake is what re-renders
        /// the house chrome from the reset mirrors.
        /// `token` is the failing load's identity for the journal
        /// (`EffectResultRecord.video_token`) — passed explicitly
        /// because `failVideoChannel` resets the channel before staging
        /// (reading `self.video.token` here would read 0); a rejected
        /// load passes 0 honestly, it never minted one.
        fn deliverLoopVideo(self: *Self, event: EffectVideo, video_fn: ?VideoMsgFn, token: u64) void {
            self.stagePendingVideo(.{
                .seq = self.nextPendingSeq(),
                .event = event,
                .video_fn = video_fn,
                .resolve = false,
                .token = token,
            });
        }

        /// Release the channel's media-surface claim, if one is held.
        /// Idempotent. The runtime purges the claim's adopted frame on
        /// this video-channel release (states that release — stop,
        /// replace, failure — tell the UI "no playback", and a rebuild
        /// there drops the surface's contain stamp, so a retained frame
        /// would composite distorted); paused and naturally-completed
        /// playbacks keep their claim and their freeze-frame.
        fn releaseVideoSink(self: *Self) void {
            if (self.video.sink.push_fn == null) return;
            const sink = self.video.sink;
            self.video.sink = .{};
            const binding = self.media_surfaces orelse return;
            binding.release_fn(binding.context, sink);
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

        /// The video-event stage's current backing storage —
        /// `pendingImageStorage`'s twin.
        fn pendingVideoStorage(self: *Self) []PendingVideo {
            if (self.pending_video_spill.len > 0) return self.pending_video_spill;
            return &self.pending_videos;
        }

        /// Stage one loop-side video event for the next drain — never
        /// dropping one (`stagePendingImage`'s discipline and growth
        /// story: each staged terminal is one load call's only answer
        /// and each fed event one recorded delivery, loud refusal on
        /// allocation failure for the same stranded-issuer reason).
        /// Stamps are monotonic here (no fed entry ever carries an
        /// older stamp — video has no park to inherit one from), so
        /// staging appends.
        fn stagePendingVideo(self: *Self, entry: PendingVideo) void {
            const storage = self.pendingVideoStorage();
            if (self.pending_video_len == storage.len) {
                const grown = self.allocator.alloc(PendingVideo, storage.len * 2) catch
                    @panic("effects: out of memory staging a video event - each staged terminal is one loadVideo call's only answer and must never be dropped");
                for (grown[0..self.pending_video_len], 0..) |*slot, index| {
                    slot.* = storage[(self.pending_video_head + index) % storage.len];
                }
                if (self.pending_video_spill.len > 0) self.allocator.free(self.pending_video_spill);
                self.pending_video_spill = grown;
                self.pending_video_head = 0;
            }
            const active = self.pendingVideoStorage();
            active[(self.pending_video_head + self.pending_video_len) % active.len] = entry;
            self.pending_video_len += 1;
            self.wakeHost();
        }

        /// Park the CURRENT playback's identity for replay routing
        /// (see `RetiredVideo`) — called by `loadVideo` and `stopVideo`
        /// with the outgoing channel still in `self.video`, before the
        /// replacement (or the reset) overwrites it. Replay-only: live
        /// and plain-fake sessions never feed by retired identity, so
        /// they park nothing. Growth is the image stage's discipline —
        /// never dropping an entry (a lost identity would strand a
        /// journaled delivery), loud refusal on allocation failure.
        fn parkRetiredVideo(self: *Self) void {
            if (!self.replay or !self.video.active) return;
            const storage = self.retiredVideoStorage();
            if (self.retired_video_len == storage.len) {
                const grown = self.allocator.alloc(RetiredVideo, storage.len * 2) catch
                    @panic("effects: out of memory parking a replayed video load's identity - a journaled delivery routed by it would be stranded");
                @memcpy(grown[0..self.retired_video_len], storage[0..self.retired_video_len]);
                if (self.retired_video_spill.len > 0) self.allocator.free(self.retired_video_spill);
                self.retired_video_spill = grown;
            }
            const active = self.retiredVideoStorage();
            active[self.retired_video_len] = .{
                .key = self.video.key,
                .token = self.video.token,
                .video_fn = self.video.on_event,
                .parked_pass = self.drain_pass_seq,
            };
            self.retired_video_len += 1;
        }

        /// The retired-load list's current backing storage.
        fn retiredVideoStorage(self: *Self) []RetiredVideo {
            if (self.retired_video_spill.len > 0) return self.retired_video_spill;
            return &self.retired_videos;
        }

        /// Consume the retired-load entry with this token, if one is
        /// parked. Tokens are unique per load, so removal order does
        /// not matter (swap-remove); the spill releases when the list
        /// empties, like the pending stages.
        fn takeRetiredVideo(self: *Self, token: u64) ?RetiredVideo {
            const storage = self.retiredVideoStorage();
            for (storage[0..self.retired_video_len], 0..) |entry, index| {
                if (entry.token != token) continue;
                self.retired_video_len -= 1;
                storage[index] = storage[self.retired_video_len];
                if (self.retired_video_len == 0 and self.retired_video_spill.len > 0) {
                    self.allocator.free(self.retired_video_spill);
                    self.retired_video_spill = &.{};
                }
                return entry;
            }
            return null;
        }

        /// Release retired-load entries whose delivery window has
        /// closed — called from `drainBoundary` after the pass counter
        /// advances. WHY one boundary suffices: a retired load's only
        /// post-retirement delivery is the ≤1 loop-staged terminal
        /// pending when it was retired, and live that terminal drains
        /// at the FIRST pass after staging, so the journal places its
        /// record before that pass's event. Drain passes run only
        /// during wake and frame dispatches — the same journaled
        /// events replay re-dispatches — and no such event exists
        /// between the retirement and that first pass. Replay feeds
        /// records in file order between dispatches, so by the time
        /// any pass counted PAST the parking one begins, the entry's
        /// record (if the recording produced one) has already fed and
        /// consumed it; whatever remains at an older stamp can never
        /// be referenced again.
        fn sweepRetiredVideos(self: *Self) void {
            const storage = self.retiredVideoStorage();
            var index: usize = 0;
            while (index < self.retired_video_len) {
                if (storage[index].parked_pass < self.drain_pass_seq) {
                    self.retired_video_len -= 1;
                    storage[index] = storage[self.retired_video_len];
                    continue;
                }
                index += 1;
            }
            if (self.retired_video_len == 0 and self.retired_video_spill.len > 0) {
                self.allocator.free(self.retired_video_spill);
                self.retired_video_spill = &.{};
            }
        }

        /// Remove and return the earliest FED entry belonging to
        /// `token`, wherever it sits in the stage (see the replay
        /// pairing in `takeVideoMsg`). Later entries shift down one
        /// slot; their relative order — the drain's seq order — is
        /// untouched. Null when no fed entry names the token.
        fn takePendingVideoMatching(self: *Self, token: u64) ?PendingVideo {
            const storage = self.pendingVideoStorage();
            var offset: usize = 0;
            while (offset < self.pending_video_len) : (offset += 1) {
                const index = (self.pending_video_head + offset) % storage.len;
                const entry = storage[index];
                if (!entry.resolve or entry.token != token) continue;
                var hole = offset;
                while (hole + 1 < self.pending_video_len) : (hole += 1) {
                    const to = (self.pending_video_head + hole) % storage.len;
                    const from = (self.pending_video_head + hole + 1) % storage.len;
                    storage[to] = storage[from];
                }
                self.pending_video_len -= 1;
                if (self.pending_video_len == 0) {
                    self.pending_video_head = 0;
                    if (self.pending_video_spill.len > 0) {
                        self.allocator.free(self.pending_video_spill);
                        self.pending_video_spill = &.{};
                    }
                }
                return entry;
            }
            return null;
        }

        /// Pop the video stage's head — `takePendingImage`'s twin,
        /// spill released when the stage drains empty.
        fn takePendingVideo(self: *Self) PendingVideo {
            const storage = self.pendingVideoStorage();
            const entry = storage[self.pending_video_head];
            self.pending_video_head = (self.pending_video_head + 1) % storage.len;
            self.pending_video_len -= 1;
            if (self.pending_video_len == 0) {
                self.pending_video_head = 0;
                if (self.pending_video_spill.len > 0) {
                    self.allocator.free(self.pending_video_spill);
                    self.pending_video_spill = &.{};
                }
            }
            return entry;
        }

        /// The channel-terminal stage's current backing storage —
        /// `pendingImageStorage`'s twin.
        fn pendingChannelStorage(self: *Self) []PendingChannel {
            if (self.pending_channel_spill.len > 0) return self.pending_channel_spill;
            return &self.pending_channels;
        }

        /// Stage one loop-side channel terminal for the next drain —
        /// never dropping one (`stagePendingImage`'s discipline and
        /// growth story, one refused open per staged entry, loud
        /// refusal on allocation failure for the same
        /// stranded-issuer reason).
        fn stagePendingChannel(self: *Self, entry: PendingChannel) void {
            const storage = self.pendingChannelStorage();
            if (self.pending_channel_len == storage.len) {
                const grown = self.allocator.alloc(PendingChannel, storage.len * 2) catch
                    @panic("effects: out of memory staging a channel terminal - each staged entry is one openChannel call's only terminal and must never be dropped");
                for (grown[0..self.pending_channel_len], 0..) |*slot, index| {
                    slot.* = storage[(self.pending_channel_head + index) % storage.len];
                }
                if (self.pending_channel_spill.len > 0) self.allocator.free(self.pending_channel_spill);
                self.pending_channel_spill = grown;
                self.pending_channel_head = 0;
            }
            const active = self.pendingChannelStorage();
            // Insert in seq order: dispatch-time staging appends (the
            // stamps are monotonic, so the scan breaks immediately),
            // but a fed park-retiring rejection carries its park's
            // OLDER stamp and belongs ahead of entries staged after
            // the parked dispatch — the merge in `takePendingMsg`
            // requires every stage to be FIFO over the shared stamp.
            var index = self.pending_channel_len;
            while (index > 0) : (index -= 1) {
                const prev = active[(self.pending_channel_head + index - 1) % active.len];
                if (prev.seq <= entry.seq) break;
                active[(self.pending_channel_head + index) % active.len] = prev;
            }
            active[(self.pending_channel_head + index) % active.len] = entry;
            self.pending_channel_len += 1;
            self.wakeHost();
        }

        /// Stage a fully formed Msg for the next drain, at THIS
        /// moment's position in the loop-side pending order — the seam
        /// a caller-side validator (the TS bridge) uses so its own
        /// synchronous refusals deliver in one stream with the
        /// engine's: both are stamped from the shared `pending_seq` at
        /// refusal time, so a `Cmd.batch`'s rejections dispatch in
        /// command order no matter which layer refused each record.
        /// Loop-thread only, and two contracts ride on the caller:
        /// the Msg must be SELF-CONTAINED (no drain-scratch or
        /// frame-arena references — it is held until the next drain),
        /// and it must be DETERMINISTICALLY RE-DERIVED by the caller's
        /// replayed dispatch (the regenerating class: nothing is
        /// journaled here, so under session replay the re-run update
        /// must stage the identical Msg at the identical position —
        /// exactly what a validation refusal against caller-side
        /// tables does).
        pub fn stageLoopMsg(self: *Self, msg: Msg) void {
            self.stagePendingStaged(.{
                .seq = self.nextPendingSeq(),
                .msg = msg,
            });
        }

        /// INTERN a staged Msg's KEY bytes and return the interned slice,
        /// for a caller (the TS bridge) whose staged rejection must name
        /// a key it has no live table slot to hold (a duplicate or
        /// table-full spawn). The slice is INSTANCE-LIVED, freed only at
        /// deinit: the delivered Msg's consumer may commit the slice
        /// into its model (the TS commit walker shares pointers that
        /// live outside the frame arena rather than copying them), so
        /// reclaiming mid-run would dangle a committed model. Interning
        /// bounds the storage by the app's DISTINCT key vocabulary —
        /// keys are app-authored names, so repeat rejections of the same
        /// key cost nothing — not by the rejection count. Call BEFORE
        /// `stageLoopMsg` and pass the returned slice into the built
        /// Msg. Loop-thread only; the same deterministic-replay contract
        /// as `stageLoopMsg` rides on the caller.
        pub fn stageLoopKey(self: *Self, key: []const u8) []const u8 {
            if (key.len == 0) return "";
            for (self.staged_keys[0..self.staged_keys_len]) |existing| {
                if (std.mem.eql(u8, existing, key)) return existing;
            }
            if (self.staged_keys_len == self.staged_keys.len) {
                const new_cap = if (self.staged_keys.len == 0) 8 else self.staged_keys.len * 2;
                const grown = self.allocator.alloc([]u8, new_cap) catch
                    @panic("effects: out of memory staging a loop-side Msg key - each staged rejection is one refused spawn's only answer and must never be dropped");
                @memcpy(grown[0..self.staged_keys_len], self.staged_keys[0..self.staged_keys_len]);
                if (self.staged_keys.len > 0) self.allocator.free(self.staged_keys);
                self.staged_keys = grown;
            }
            const buf = self.allocator.alloc(u8, key.len) catch
                @panic("effects: out of memory staging a loop-side Msg key - each staged rejection is one refused spawn's only answer and must never be dropped");
            @memcpy(buf, key);
            self.staged_keys[self.staged_keys_len] = buf;
            self.staged_keys_len += 1;
            return buf;
        }

        /// Free every interned staged-Msg key buffer. Deinit only: a
        /// committed model may reference these slices for as long as the
        /// app lives.
        fn releaseStagedKeys(self: *Self) void {
            for (self.staged_keys[0..self.staged_keys_len]) |buf| self.allocator.free(buf);
            self.staged_keys_len = 0;
        }

        /// The caller-staged Msg stage's current backing storage —
        /// `pendingImageStorage`'s twin.
        fn pendingStagedStorage(self: *Self) []PendingStaged {
            if (self.pending_staged_spill.len > 0) return self.pending_staged_spill;
            return &self.pending_staged;
        }

        /// Stage one caller-built Msg for the next drain — never
        /// dropping one (`stagePendingImage`'s discipline and growth
        /// story: each staged entry is one refused dispatch's only
        /// answer, loud refusal on allocation failure for the same
        /// stranded-issuer reason).
        fn stagePendingStaged(self: *Self, entry: PendingStaged) void {
            const storage = self.pendingStagedStorage();
            if (self.pending_staged_len == storage.len) {
                const grown = self.allocator.alloc(PendingStaged, storage.len * 2) catch
                    @panic("effects: out of memory staging a loop-side Msg - each staged entry is one refused dispatch's only answer and must never be dropped");
                for (grown[0..self.pending_staged_len], 0..) |*slot, index| {
                    slot.* = storage[(self.pending_staged_head + index) % storage.len];
                }
                if (self.pending_staged_spill.len > 0) self.allocator.free(self.pending_staged_spill);
                self.pending_staged_spill = grown;
                self.pending_staged_head = 0;
            }
            const active = self.pendingStagedStorage();
            active[(self.pending_staged_head + self.pending_staged_len) % active.len] = entry;
            self.pending_staged_len += 1;
            self.wakeHost();
        }

        /// Pop the staged-Msg stage's head — `takePendingImage`'s
        /// twin, including the drained-empty spill release.
        fn takePendingStaged(self: *Self) PendingStaged {
            const storage = self.pendingStagedStorage();
            const entry = storage[self.pending_staged_head];
            self.pending_staged_head = (self.pending_staged_head + 1) % storage.len;
            self.pending_staged_len -= 1;
            if (self.pending_staged_len == 0) {
                self.pending_staged_head = 0;
                if (self.pending_staged_spill.len > 0) {
                    self.allocator.free(self.pending_staged_spill);
                    self.pending_staged_spill = &.{};
                }
            }
            return entry;
        }

        /// Pop the channel stage's head — `takePendingImage`'s twin,
        /// including the drained-empty spill release.
        fn takePendingChannel(self: *Self) PendingChannel {
            const storage = self.pendingChannelStorage();
            const entry = storage[self.pending_channel_head];
            self.pending_channel_head = (self.pending_channel_head + 1) % storage.len;
            self.pending_channel_len -= 1;
            if (self.pending_channel_len == 0) {
                self.pending_channel_head = 0;
                if (self.pending_channel_spill.len > 0) {
                    self.allocator.free(self.pending_channel_spill);
                    self.pending_channel_spill = &.{};
                }
            }
            return entry;
        }

        /// The pty-terminal stage's current backing storage —
        /// `pendingImageStorage`'s twin.
        fn pendingPtyStorage(self: *Self) []PendingPty {
            if (self.pending_pty_spill.len > 0) return self.pending_pty_spill;
            return &self.pending_ptys;
        }

        /// Stage one loop-side pty terminal for the next drain —
        /// never dropping one (`stagePendingChannel`'s discipline,
        /// including the seq-ordered insert a fed park-retiring
        /// terminal's older stamp requires).
        fn stagePendingPty(self: *Self, entry: PendingPty) void {
            const storage = self.pendingPtyStorage();
            if (self.pending_pty_len == storage.len) {
                const grown = self.allocator.alloc(PendingPty, storage.len * 2) catch
                    @panic("effects: out of memory staging a pty terminal - each staged entry is one ptySpawn call's only terminal and must never be dropped");
                for (grown[0..self.pending_pty_len], 0..) |*slot, index| {
                    slot.* = storage[(self.pending_pty_head + index) % storage.len];
                }
                if (self.pending_pty_spill.len > 0) self.allocator.free(self.pending_pty_spill);
                self.pending_pty_spill = grown;
                self.pending_pty_head = 0;
            }
            const active = self.pendingPtyStorage();
            var index = self.pending_pty_len;
            while (index > 0) : (index -= 1) {
                const prev = active[(self.pending_pty_head + index - 1) % active.len];
                if (prev.seq <= entry.seq) break;
                active[(self.pending_pty_head + index) % active.len] = prev;
            }
            active[(self.pending_pty_head + index) % active.len] = entry;
            self.pending_pty_len += 1;
            self.wakeHost();
        }

        /// Pop the pty stage's head — `takePendingImage`'s twin,
        /// including the drained-empty spill release.
        fn takePendingPty(self: *Self) PendingPty {
            const storage = self.pendingPtyStorage();
            const entry = storage[self.pending_pty_head];
            self.pending_pty_head = (self.pending_pty_head + 1) % storage.len;
            self.pending_pty_len -= 1;
            if (self.pending_pty_len == 0) {
                self.pending_pty_head = 0;
                if (self.pending_pty_spill.len > 0) {
                    self.allocator.free(self.pending_pty_spill);
                    self.pending_pty_spill = &.{};
                }
            }
            return entry;
        }

        /// Take the next loop-side pending terminal in enqueue order,
        /// merging the ring, the image stage, the channel stage, and
        /// the caller-staged Msg stage by their shared stamp so
        /// splitting the storage never reordered delivery. Entries
        /// stamped at or past `before` stay staged: they were produced
        /// during the current drain pass and belong to the next one
        /// (the `DrainBoundary` causality contract). All four
        /// structures are FIFO over the monotonic stamp, so refusing
        /// the merged head refuses everything younger too.
        fn takePendingMsg(self: *Self, before: u64) ?PendingMsg {
            const no_seq = std.math.maxInt(u64);
            const ring_seq: u64 = if (self.pending_exit_len > 0)
                self.pending_exit_seqs[self.pending_exit_head]
            else
                no_seq;
            const image_seq: u64 = if (self.pending_image_len > 0)
                self.pendingImageStorage()[self.pending_image_head].seq
            else
                no_seq;
            const channel_seq_head: u64 = if (self.pending_channel_len > 0)
                self.pendingChannelStorage()[self.pending_channel_head].seq
            else
                no_seq;
            const video_seq: u64 = if (self.pending_video_len > 0)
                self.pendingVideoStorage()[self.pending_video_head].seq
            else
                no_seq;
            const staged_seq: u64 = if (self.pending_staged_len > 0)
                self.pendingStagedStorage()[self.pending_staged_head].seq
            else
                no_seq;
            const pty_seq_head: u64 = if (self.pending_pty_len > 0)
                self.pendingPtyStorage()[self.pending_pty_head].seq
            else
                no_seq;
            const min_seq = @min(@min(@min(ring_seq, staged_seq), video_seq), @min(@min(image_seq, channel_seq_head), pty_seq_head));
            if (min_seq == no_seq or min_seq >= before) return null;
            if (min_seq == staged_seq) {
                return .{ .staged = self.takePendingStaged().msg };
            }
            if (min_seq == video_seq) {
                const staged = self.takePendingVideo();
                return .{ .video = .{
                    .event = staged.event,
                    .video_fn = staged.video_fn,
                    .resolve = staged.resolve,
                    .token = staged.token,
                } };
            }
            if (min_seq == image_seq) {
                const staged = self.takePendingImage();
                return .{ .image = .{
                    .result = staged.result,
                    .image_fn = staged.image_fn,
                    .regenerates = staged.regenerates,
                } };
            }
            if (min_seq == channel_seq_head) {
                const staged = self.takePendingChannel();
                return .{ .channel = .{
                    .event = staged.event,
                    .channel_fn = staged.channel_fn,
                    .regenerates = staged.regenerates,
                    .retire_slot = staged.retire_slot,
                    .retire_generation = staged.retire_generation,
                } };
            }
            if (min_seq == pty_seq_head) {
                const staged = self.takePendingPty();
                return .{ .pty = .{
                    .event = staged.event,
                    .pty_fn = staged.pty_fn,
                    .regenerates = staged.regenerates,
                    .retire_slot = staged.retire_slot,
                    .retire_generation = staged.retire_generation,
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
            // External-source channels share the key space: open until
            // the `.closed` terminal delivers, plus the staged
            // executor-truth rejection window (see the channel twins
            // of the image predicates).
            if (self.channelOccupiesKey(key)) return true;
            if (self.stagedChannelOccupiesKey(key)) return true;
            // Ptys share it too: occupied from spawn until the `.exit`
            // terminal delivers, plus the staged executor-truth
            // start-failure window.
            if (self.ptyOccupiesKey(key)) return true;
            if (self.stagedPtyOccupiesKey(key)) return true;
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
            // NOT under the pty spawn-window lock, deliberately: the
            // std process start waits on its own exec-status pipe, and
            // an `execve` stalled on a wedged mount would hold the lock
            // unbounded — freezing the UI loop the moment a pty spawn
            // needs it. A job fork landing inside a pty flag gap is the
            // bounded residual instead (shared with embedder forks): the
            // inherited copies die at the job child's exec, and a job
            // whose exec stalls merely delays the pty's exec-pipe EOF —
            // which the carried reap-time verdict resolves correctly, so
            // no misclassification and no unbounded harm either way.
            const spawn_result = std.process.spawn(io, .{
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
            });
            var child = spawn_result catch return;

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
