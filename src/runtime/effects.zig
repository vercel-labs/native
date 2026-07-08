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

/// Maximum clipboard-effect payload: what one `writeClipboard` writes
/// and the most one `readClipboard` delivers — the platform clipboard
/// bound (`platform.max_clipboard_data_bytes`). Over-bound writes are
/// rejected outright, mirroring `writeFile` (a cut clipboard string
/// must never pass for the whole one).
pub const max_effect_clipboard_bytes: usize = platform.max_clipboard_data_bytes;

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
/// on chromeless windows. Label-addressed because labels are what apps
/// declare (`ShellWindow.label`, `WindowDescriptor.label`); the runtime
/// side resolves them to live window ids. Constructed by `UiApp`.
pub const WindowActionBinding = struct {
    context: *anyopaque,
    close_fn: *const fn (context: *anyopaque, window_label: []const u8) bool,
    minimize_fn: *const fn (context: *anyopaque, window_label: []const u8) bool,
};

/// Window-action label capacity (`Effects.closeWindow`/`minimizeWindow`):
/// the mirror copies the last requested label so tests can pin it.
pub const max_window_action_label = 64;

/// The window-action mirror: observable state for every close/minimize
/// request made through the channel, recorded before the runtime call
/// (and INSTEAD of it under the fake executor — hermetic tests pin the
/// counts, live runs also perform the verb).
pub const WindowActionState = struct {
    close_count: u32 = 0,
    minimize_count: u32 = 0,
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
    /// a malformed URL or non-http(s) scheme, or URL/headers/payload
    /// over capacity.
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
};

/// Journaled wall-clock reads buffered for replay (`Effects.wallMs`).
/// Bounded like everything else: more reads per drain window than this
/// is a runaway loop, not a session shape.
pub const max_effect_replay_clock_entries: usize = 64;

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

        const SlotKind = enum(u8) { spawn, fetch, file, clipboard };

        const EntryKind = enum(u8) { line, exit, response, file, clipboard };

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
            /// `.exit` entries of `.collect` spawns: the collected stdout
            /// stays in the slot's heap buffer (taken at drain, like a
            /// fetch body); the stderr tail rides in `line_bytes` with
            /// its length in `line_len`.
            collect: bool = false,
            collect_len: u32 = 0,
            collect_truncated: bool = false,
            stderr_truncated: bool = false,
            line_fn: ?LineMsgFn = null,
            exit_fn: ?ExitMsgFn = null,
            response_fn: ?ResponseMsgFn = null,
            file_fn: ?FileMsgFn = null,
            clipboard_fn: ?ClipboardMsgFn = null,
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
            /// `resolve`: a fed audio event (fake executor / replay)
            /// whose key and handler come from the live channel at
            /// delivery time — exactly how a platform event resolves in
            /// `takeAudioMsg`. Non-resolving entries (rejections and
            /// synchronous failures) are fully formed at enqueue.
            audio: struct { event: EffectAudio, audio_fn: ?AudioMsgFn, resolve: bool },

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
                };
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
            /// Set by `cancel` before any kill attempt; read by the
            /// worker so a cancel that lands before the process spawns
            /// still kills it.
            cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            /// Loop-thread bookkeeping: the generation whose queued
            /// lines the drain discards and whose exit reports
            /// `.cancelled`. Zero means none (generations start at 1).
            cancelled_generation: u32 = 0,
            /// Guards `child_id`/`reaping` between the worker and
            /// `cancel` on the loop thread: a kill is only sent while
            /// the worker has not started reaping, so the pid/handle is
            /// guaranteed un-reaped (alive or zombie) when signaled.
            child_mutex: SpinMutex = .{},
            child_id: ?std.process.Child.Id = null,
            reaping: bool = false,
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
        };

        allocator: std.mem.Allocator,
        executor: EffectExecutor = .real,
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
        pending_exit_head: usize = 0,
        pending_exit_len: usize = 0,
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
        /// (draining their final queue posts), and release the executor
        /// io. Bounded: gives up waiting after ~5s.
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
                    const io = threaded.io();
                    var waited_ms: usize = 0;
                    while (waited_ms < 5000) : (waited_ms += 1) {
                        var running = false;
                        for (&self.slots) |*slot| {
                            if (slot.state.load(.acquire) == .running and !slot.fake) running = true;
                        }
                        if (!running) break;
                        // Keep the queue drained so exit-post retries finish.
                        self.clearQueue();
                        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch break;
                    }
                }
                if (self.io_threaded) |threaded| {
                    threaded.deinit();
                    self.allocator.destroy(threaded);
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
            // Sever the services binding last: the platform this pointer
            // reaches into may be destroyed before the next call arrives
            // (main's deferred app deinit runs after the runner's platform
            // teardown), and a severed channel already answers every
            // transport command inert through its existing no-services
            // paths instead of dereferencing freed memory.
            self.services = null;
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

        // ------------------------------------------------------------- API

        /// Register (or replace) decoded straight-alpha RGBA8 pixels
        /// under the caller-chosen ImageId `id`, so image/icon/avatar
        /// widgets referencing it draw them. Synchronous (the pixels are
        /// copied before this returns), not an effect: no Msg follows.
        /// Errors are the registry's (`error.InvalidImageId`,
        /// `error.InvalidImageDimensions`, `error.ImageTooLarge`,
        /// `error.ImageRegistryFull`) plus `error.UnsupportedService`
        /// when no registry is bound.
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
            if (self.findActiveSlot(options.key) != null) return self.reject(options);
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
            slot.cancel_requested.store(false, .release);
            // `cancelled_generation` is deliberately NOT reset: entries
            // from a cancelled previous occupant may still sit in the
            // queue, and the sticky value keeps filtering them after the
            // slot is reused (the new generation never matches it).
            slot.child_id = null;
            slot.reaping = false;
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
                slot.collect_buffer = self.allocator.alloc(u8, max_effect_collect_bytes) catch {
                    return self.reject(options);
                };
            } else if (options.max_line_bytes > max_effect_line_bytes) {
                slot.line_buffer = self.allocator.alloc(u8, options.max_line_bytes) catch {
                    return self.reject(options);
                };
            }
            slot.fake = self.executor == .fake;
            slot.state.store(.running, .release);

            if (slot.fake) return;

            const io = self.ensureIo() catch {
                self.releaseSpawnSlot(slot);
                return self.reject(options);
            };
            const thread = std.Thread.spawn(.{}, workerMain, .{ self, slot_index, slot.generation, io }) catch {
                self.releaseSpawnSlot(slot);
                return self.reject(options);
            };
            thread.detach();
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
            if (self.findActiveSlot(options.key) != null) return self.rejectFetch(options);
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
            slot.child_id = null;
            slot.reaping = false;
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
            thread.detach();
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
            if (self.findActiveSlot(key) != null) return self.rejectFile(key, op, on_result);
            const slot_index = self.findIdleSlot() orelse return self.rejectFile(key, op, on_result);

            const slot = &self.slots[slot_index];
            // A write's buffer holds its payload copy; a read's holds
            // the content space plus one spare byte that detects
            // over-bound files without a stat round trip.
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
            slot.child_id = null;
            slot.reaping = false;
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
            const thread = std.Thread.spawn(.{}, fileWorkerMain, .{ self, slot_index, slot.generation, io }) catch {
                self.releaseFetchSlot(slot);
                return self.rejectFile(key, op, on_result);
            };
            thread.detach();
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
            if (self.findActiveSlot(key) != null) return self.rejectClipboard(key, op, on_result);
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
            slot.child_id = null;
            slot.reaping = false;
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

        /// Cancel a running effect by key. After this returns, no
        /// further `on_line` Msgs for that spawn are dispatched; one
        /// `on_exit` Msg with reason `.cancelled` follows once the
        /// process is reaped. A cancel that races the natural exit
        /// (worker finished, completions still queued) keeps the same
        /// promise: queued lines are discarded and the queued exit is
        /// reported as `.cancelled`. Unknown keys are a no-op.
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

        /// The window-action mirror, for tests: how many close/minimize
        /// requests rode the channel and the last label requested.
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
            return self.pending_exit_len > 0 or self.queue_count.load(.acquire) > 0;
        }

        /// Pop the next completion as a Msg. Loop-thread only. The
        /// returned Msg's line payload stays valid until the next call.
        pub fn takeMsg(self: *Self) ?Msg {
            self.reclaimSlots();
            while (true) {
                if (self.takePendingMsg()) |pending| {
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
                    }
                }
                if (!self.dequeueInto(&self.drain_scratch)) return null;
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
                }
            }
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
            slot.state.store(.idle, .release);
            if (!delivered) {
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
                    const threaded = try self.allocator.create(IoThreaded);
                    // `environ` defaults to `.empty` in `InitOptions`, which
                    // would hand every spawned child a blank environment (no
                    // HOME, no PATH) — always pass the host environment.
                    threaded.* = IoThreaded.init(self.allocator, .{
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
        /// loss in its drop counter — overflow stays visible.
        fn deliverPending(self: *Self, pending: PendingMsg) void {
            if (self.pending_exit_len == max_effect_pending_exits) {
                const oldest = &self.pending_exits[self.pending_exit_head];
                self.pending_exit_head = (self.pending_exit_head + 1) % max_effect_pending_exits;
                self.pending_exit_len -= 1;
                var replacement = pending;
                replacement.addDropped(oldest.droppedCount() +| 1);
                const tail = (self.pending_exit_head + self.pending_exit_len) % max_effect_pending_exits;
                self.pending_exits[tail] = replacement;
                self.pending_exit_len += 1;
            } else {
                const tail = (self.pending_exit_head + self.pending_exit_len) % max_effect_pending_exits;
                self.pending_exits[tail] = pending;
                self.pending_exit_len += 1;
            }
            self.wakeHost();
        }

        fn takePendingMsg(self: *Self) ?PendingMsg {
            if (self.pending_exit_len == 0) return null;
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

        fn reclaimSlots(self: *Self) void {
            for (&self.slots) |*slot| {
                switch (slot.state.load(.acquire)) {
                    .done => slot.state.store(.idle, .release),
                    // A draining slot is reusable once the drain took its
                    // heap buffer (fetch body or collected stdout — the
                    // terminal Msg was delivered).
                    .draining => if (slot.fetch_buffer == null and slot.collect_buffer == null) slot.state.store(.idle, .release),
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

        /// Send a kill to the published child id, but only while the
        /// worker has not begun reaping (guarded by the slot mutex), so
        /// the pid/handle is guaranteed to still name this process.
        fn killPublishedChild(self: *Self, slot: *Slot) void {
            _ = self;
            slot.child_mutex.lock();
            defer slot.child_mutex.unlock();
            if (slot.reaping) return;
            const id = slot.child_id orelse return;
            if (builtin.os.tag == .windows) {
                _ = std.os.windows.ntdll.NtTerminateProcess(id, @enumFromInt(1));
            } else {
                std.posix.kill(id, .KILL) catch {};
            }
        }

        // ------------------------------------------------------------ worker

        fn workerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io) void {
            const slot = &self.slots[slot_index];
            var exit: EffectExit = .{
                .key = slot.key,
                .code = effect_error_exit_code,
                .reason = .spawn_failed,
            };
            self.runChild(slot, @intCast(slot_index), generation, io, &exit);
            exit.dropped_lines = slot.dropped_total;
            self.postExit(slot, @intCast(slot_index), generation, io, exit);
            // A collect slot still owns its stdout buffer; park it in
            // `.draining` until the drain takes the buffer (fetch-style).
            slot.state.store(if (slot.output_mode == .collect) .draining else .done, .release);
            self.wakeHost();
        }

        fn runChild(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io, exit: *EffectExit) void {
            var child = std.process.spawn(io, .{
                .argv = slot.argv(),
                .stdin = if (slot.stdin_len > 0) .pipe else .ignore,
                .stdout = .pipe,
                .stderr = if (slot.output_mode == .collect) .pipe else .ignore,
            }) catch return;

            slot.child_mutex.lock();
            slot.child_id = child.id;
            slot.child_mutex.unlock();
            // A cancel that raced the spawn still lands.
            if (slot.cancel_requested.load(.acquire)) self.killPublishedChild(slot);

            // Collect mode drains stderr concurrently so a chatty child
            // can never deadlock against a full stderr pipe while we read
            // stdout. The reader ends at stderr EOF (the child exiting),
            // and the join below runs before the exit is assembled, so
            // the tail ring is complete and single-threaded again by the
            // time it is read.
            var stderr_thread: ?std.Thread = null;
            defer if (stderr_thread) |thread| thread.join();
            if (child.stderr) |stderr_file| {
                stderr_thread = std.Thread.spawn(.{}, stderrTailMain, .{ slot, io, stderr_file }) catch null;
            }

            if (child.stdin) |stdin_file| {
                stdin_file.writeStreamingAll(io, slot.stdinBytes()) catch {};
                stdin_file.close(io);
                child.stdin = null;
            }

            if (child.stdout) |stdout_file| {
                if (slot.output_mode == .collect) {
                    collectStdout(slot, io, stdout_file);
                } else {
                    self.streamLines(slot, slot_index, generation, io, stdout_file);
                }
            }

            // Thread-spawn failure fallback: drain stderr inline after
            // stdout closed (before reaping, so a child blocked on a full
            // stderr pipe still finishes).
            if (stderr_thread == null) {
                if (child.stderr) |stderr_file| collectStderrTail(slot, io, stderr_file);
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

            slot.child_mutex.lock();
            slot.reaping = true;
            slot.child_mutex.unlock();
            const term = child.wait(io) catch {
                exit.* = .{ .key = slot.key, .code = effect_error_exit_code, .reason = .signaled };
                return;
            };
            exit.* = switch (term) {
                .exited => |code| .{ .key = slot.key, .code = code, .reason = .exited },
                else => .{ .key = slot.key, .code = effect_error_exit_code, .reason = .signaled },
            };
            if (slot.cancel_requested.load(.acquire)) {
                exit.reason = .cancelled;
                exit.code = effect_error_exit_code;
            }
        }

        fn streamLines(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io, stdout_file: std.Io.File) void {
            var read_buffer: [1024]u8 = undefined;
            // Spawns with a raised `max_line_bytes` frame into their
            // slot's heap buffer; everyone else uses the stack.
            var stack_buffer: [max_effect_line_bytes]u8 = undefined;
            const line_buffer: []u8 = slot.line_buffer orelse &stack_buffer;
            const limit = @min(slot.line_limit, line_buffer.len);
            var line_len: usize = 0;
            var truncated = false;
            while (true) {
                const read_slices: [1][]u8 = .{&read_buffer};
                const count = stdout_file.readStreaming(io, &read_slices) catch break;
                for (read_buffer[0..count]) |byte| {
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
            }
            if (line_len > 0 or truncated) {
                self.produceLine(slot, slot_index, generation, line_buffer[0..line_len], truncated);
            }
        }

        /// Collect-mode stdout: raw bytes into the slot's heap buffer,
        /// no line framing, bounded by `max_effect_collect_bytes`.
        fn collectStdout(slot: *Slot, io: std.Io, stdout_file: std.Io.File) void {
            var read_buffer: [4096]u8 = undefined;
            while (true) {
                const read_slices: [1][]u8 = .{&read_buffer};
                const count = stdout_file.readStreaming(io, &read_slices) catch break;
                if (count == 0) break;
                appendCollected(slot, read_buffer[0..count]);
            }
        }

        fn stderrTailMain(slot: *Slot, io: std.Io, stderr_file: std.Io.File) void {
            collectStderrTail(slot, io, stderr_file);
        }

        /// Collect-mode stderr: keep the last
        /// `max_effect_stderr_tail_bytes` bytes in the slot's tail ring.
        fn collectStderrTail(slot: *Slot, io: std.Io, stderr_file: std.Io.File) void {
            var read_buffer: [1024]u8 = undefined;
            while (true) {
                const read_slices: [1][]u8 = .{&read_buffer};
                const count = stderr_file.readStreaming(io, &read_slices) catch break;
                if (count == 0) break;
                appendStderrTail(slot, read_buffer[0..count]);
            }
        }

        // ------------------------------------------------------ fetch worker

        /// Supervises one fetch: runs the blocking HTTP exchange as a
        /// cancelable `Io` task and polls for completion, cancel, and
        /// the timeout deadline. Ends by posting exactly one `.response`
        /// entry and parking the slot in `.draining` (the drain retires
        /// it after taking the body buffer).
        fn fetchWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io) void {
            const slot = &self.slots[slot_index];
            supervise: {
                var future = std.Io.concurrent(io, fetchTask, .{ self, slot, @as(u16, @intCast(slot_index)), generation, io }) catch {
                    // No concurrent capacity: run the exchange inline.
                    // Cancels can no longer interrupt mid-transfer and
                    // the timeout is not enforced, but the terminal Msg
                    // still lands (a raced cancel is rewritten at drain).
                    fetchTask(self, slot, @intCast(slot_index), generation, io);
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

        /// Runs one file effect: the blocking read/write happens right
        /// here on the worker thread (local file IO is quick — no
        /// timeout supervision), then exactly one `.file` terminal
        /// entry posts and the slot parks in `.draining` until the
        /// drain takes its buffer. `cancel` does not interrupt the OS
        /// call: it marks the generation and the drain rewrites the
        /// terminal to `.cancelled` (the operation itself may still
        /// have completed on disk, as `EffectFileOutcome.cancelled`
        /// documents).
        fn fileWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io) void {
            const slot = &self.slots[slot_index];
            var read_len: usize = 0;
            const outcome = runFileOp(slot, io, &read_len);
            slot.body_len = read_len;
            self.postFile(slot, @intCast(slot_index), generation, io, outcome, read_len);
            slot.state.store(.draining, .release);
            self.wakeHost();
        }

        fn runFileOp(slot: *Slot, io: std.Io, read_len: *usize) EffectFileOutcome {
            const cwd = std.Io.Dir.cwd();
            const file_path = slot.filePath();
            switch (slot.file_op) {
                .write => {
                    if (std.fs.path.dirname(file_path)) |parent| {
                        cwd.createDirPath(io, parent) catch return .io_failed;
                    }
                    cwd.writeFile(io, .{
                        .sub_path = file_path,
                        .data = slot.fetchPayload(),
                    }) catch return .io_failed;
                    return .ok;
                },
                .read => {
                    var file = cwd.openFile(io, file_path, .{}) catch |err| {
                        return if (err == error.FileNotFound) .not_found else .io_failed;
                    };
                    defer file.close(io);
                    // The buffer has one byte past the delivery bound:
                    // filling it proves the file is over-bound.
                    const buffer = slot.fetch_buffer.?;
                    const len = file.readPositionalAll(io, buffer, 0) catch return .io_failed;
                    if (len > max_effect_file_bytes) {
                        read_len.* = max_effect_file_bytes;
                        return .truncated;
                    }
                    read_len.* = len;
                    return .ok;
                },
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

test "fetch errors map onto the documented taxonomy" {
    try std.testing.expectEqual(EffectFetchOutcome.cancelled, classifyFetchError(error.Canceled));
    try std.testing.expectEqual(EffectFetchOutcome.connect_failed, classifyFetchError(error.ConnectionRefused));
    try std.testing.expectEqual(EffectFetchOutcome.connect_failed, classifyFetchError(error.UnknownHostName));
    try std.testing.expectEqual(EffectFetchOutcome.tls_failed, classifyFetchError(error.TlsInitializationFailed));
    try std.testing.expectEqual(EffectFetchOutcome.rejected, classifyFetchError(error.UnsupportedUriScheme));
    try std.testing.expectEqual(EffectFetchOutcome.protocol_failed, classifyFetchError(error.HttpHeadersInvalid));
}
