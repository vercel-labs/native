//! The effect system: TEA's `Cmd` half for `UiApp`.
//!
//! `Effects(Msg)` runs subprocesses and HTTP fetches on worker threads
//! owned by the app loop, streams subprocess stdout lines back as typed
//! `Msg` values, reports process exits the same way, and delivers each
//! fetch's terminal outcome as exactly one `Msg`. The model is never
//! touched off-thread: workers post fixed-size completion records into a
//! bounded MPSC queue, nudge the platform loop through
//! `PlatformServices.wake_fn`, and the loop thread drains the queue and
//! dispatches Msgs through the app's `update`.
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
//!   `max_effect_body_bytes` arrives truncated with `truncated = true`.
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
//! Payload lifetime: `EffectLine.line` and `EffectResponse.body` point
//! into drain scratch that is recycled on the next drained Msg — `update`
//! must copy what it keeps, exactly like `canvas.TextInputEvent`
//! payloads.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform/root.zig");

/// Maximum in-flight effects (spawn slots / worker threads).
pub const max_effects: usize = 16;
/// Maximum argv entries per spawn.
pub const max_effect_argv: usize = 16;
/// Maximum total bytes across all argv entries of one spawn.
pub const max_effect_argv_bytes: usize = 2048;
/// Maximum stdin payload per spawn (written once, then closed).
pub const max_effect_stdin_bytes: usize = 4096;
/// Maximum bytes per delivered stdout line; longer lines are truncated
/// (delivered with `truncated = true`, the remainder discarded).
pub const max_effect_line_bytes: usize = 4096;
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

/// The exit `code` reported for every non-`.exited` reason.
pub const effect_error_exit_code: i32 = -1;

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
    /// The source line exceeded `max_effect_line_bytes`; this is its
    /// first `max_effect_line_bytes` bytes and the rest was discarded.
    truncated: bool = false,
    /// Whole lines dropped on a full completion queue immediately before
    /// this one. Never silently zero when drops happened: undelivered
    /// drops also accumulate into the exit's `dropped_lines`.
    dropped_before: u32 = 0,
};

/// Payload for `on_exit` Msg constructors. Exactly one is delivered per
/// accepted spawn, and one per rejected spawn (reason `.rejected`).
pub const EffectExit = struct {
    key: u64,
    code: i32 = effect_error_exit_code,
    reason: EffectExitReason = .exited,
    /// Total stdout lines dropped over the effect's lifetime (full
    /// completion queue). Zero means every line was delivered.
    dropped_lines: u32 = 0,
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
    /// room before this one (only under extreme rejection bursts).
    /// Never silently zero when a notice was lost.
    dropped_before: u32 = 0,
};

/// Executor selection: `.real` spawns processes on worker threads;
/// `.fake` records spawn requests for tests to inspect and answer with
/// `feedLine`/`feedExit` — fully deterministic, no processes, no threads.
pub const EffectExecutor = enum { real, fake };

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

        /// Comptime Msg constructor for `on_line`, following
        /// `canvas.Ui(Msg).inputMsg`: `lineMsg(.agent_line)` builds
        /// `Msg{ .agent_line = line }` — the variant's payload type must
        /// be `zero_native.EffectLine`.
        pub fn lineMsg(comptime tag: std.meta.Tag(Msg)) LineMsgFn {
            return struct {
                fn make(line: EffectLine) Msg {
                    return @unionInit(Msg, @tagName(tag), line);
                }
            }.make;
        }

        /// Comptime Msg constructor for `on_exit`: `exitMsg(.agent_done)`
        /// builds `Msg{ .agent_done = exit }` — the variant's payload
        /// type must be `zero_native.EffectExit`.
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
        /// type must be `zero_native.EffectResponse`.
        pub fn responseMsg(comptime tag: std.meta.Tag(Msg)) ResponseMsgFn {
            return struct {
                fn make(response: EffectResponse) Msg {
                    return @unionInit(Msg, @tagName(tag), response);
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
            /// the terminal Msg with outcome `.timed_out`.
            timeout_ms: u32 = default_effect_fetch_timeout_ms,
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
        };

        /// `draining` is fetch-only: the worker is done and the terminal
        /// response entry is queued, but the slot still owns the body
        /// buffer until the drain delivers (and thereby retires) it.
        const SlotState = enum(u8) { idle, running, done, draining };

        const SlotKind = enum(u8) { spawn, fetch };

        const EntryKind = enum(u8) { line, exit, response };

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
            line_fn: ?LineMsgFn = null,
            exit_fn: ?ExitMsgFn = null,
            response_fn: ?ResponseMsgFn = null,
            line_bytes: [max_effect_line_bytes]u8 = undefined,
        };

        /// A loop-thread-produced terminal Msg awaiting drain: a spawn
        /// rejection or fake exit (`.exit`) or a fetch rejection or fake
        /// cancel (`.response`). Response bodies are always empty here.
        const PendingMsg = union(enum) {
            exit: struct { exit: EffectExit, exit_fn: ?ExitMsgFn },
            response: struct { response: EffectResponse, response_fn: ?ResponseMsgFn },

            fn addDropped(pending: *PendingMsg, count: u32) void {
                switch (pending.*) {
                    .exit => |*entry| entry.exit.dropped_lines +|= count,
                    .response => |*entry| entry.response.dropped_before +|= count,
                }
            }

            fn droppedCount(pending: *const PendingMsg) u32 {
                return switch (pending.*) {
                    .exit => |entry| entry.exit.dropped_lines,
                    .response => |entry| entry.response.dropped_before,
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
            // ---- fetch-only fields (kind == .fetch) ----
            method: std.http.Method = .GET,
            url_storage: [max_effect_url_bytes]u8 = undefined,
            url_len: usize = 0,
            header_storage: [max_effect_fetch_header_bytes]u8 = undefined,
            header_slices: [max_effect_fetch_headers]std.http.Header = undefined,
            header_count: usize = 0,
            timeout_ms: u32 = default_effect_fetch_timeout_ms,
            /// Heap buffer per accepted fetch: request payload copy
            /// followed by `max_effect_body_bytes` of response space.
            /// Owned by the slot until the drain delivers the response
            /// (taken into `drain_fetch_body`) or `deinit` sweeps it.
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
        };

        allocator: std.mem.Allocator,
        executor: EffectExecutor = .real,
        /// Set once from the loop thread before the first dispatch;
        /// workers call `services.wake()` through it (the one
        /// thread-safe PlatformServices entry).
        services: ?*const platform.PlatformServices = null,
        /// The environment spawned children inherit and fetch honors
        /// (PATH for `spawnPath`-style lookups, proxy variables).
        /// Bound once from the loop thread before the first real
        /// spawn/fetch; `null` means "resolve a fallback at first use"
        /// (see `fallbackEnviron`).
        environ: ?std.process.Environ = null,
        io_threaded: ?*std.Io.Threaded = null,
        shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        next_generation: u32 = 1,
        slots: [max_effects]Slot = [_]Slot{.{}} ** max_effects,
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
        /// The fetch buffer of the most recently delivered response,
        /// keeping `EffectResponse.body` valid while `update` runs
        /// (freed when the next response drains, or at `deinit`).
        drain_fetch_body: ?[]u8 = null,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Kill every running effect, wait for the workers to finish
        /// (draining their final queue posts), and release the executor
        /// io. Bounded: gives up waiting after ~5s.
        pub fn deinit(self: *Self) void {
            self.shutdown.store(true, .release);
            for (&self.slots) |*slot| {
                if (slot.state.load(.acquire) == .running and !slot.fake) {
                    slot.cancel_requested.store(true, .release);
                    // Fetch workers poll `cancel_requested`/`shutdown`
                    // and cancel their blocking task themselves.
                    if (slot.kind == .spawn) self.killPublishedChild(slot);
                }
            }
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
                    self.queue_mutex.lock();
                    self.queue_head = 0;
                    self.queue_len = 0;
                    self.queue_count.store(0, .release);
                    self.queue_mutex.unlock();
                    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch break;
                }
            }
            if (self.io_threaded) |threaded| {
                threaded.deinit();
                self.allocator.destroy(threaded);
                self.io_threaded = null;
            }
            for (&self.slots) |*slot| {
                if (slot.fetch_buffer) |buffer| {
                    self.allocator.free(buffer);
                    slot.fetch_buffer = null;
                }
            }
            if (self.drain_fetch_body) |buffer| {
                self.allocator.free(buffer);
                self.drain_fetch_body = null;
            }
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

        // ------------------------------------------------------------- API

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
            slot.fake = self.executor == .fake;
            slot.state.store(.running, .release);

            if (slot.fake) return;

            const io = self.ensureIo() catch {
                slot.state.store(.idle, .release);
                return self.reject(options);
            };
            const thread = std.Thread.spawn(.{}, workerMain, .{ self, slot_index, slot.generation, io }) catch {
                slot.state.store(.idle, .release);
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
            if (self.findActiveSlot(options.key) != null) return self.rejectFetch(options);
            const slot_index = self.findIdleSlot() orelse return self.rejectFetch(options);

            const slot = &self.slots[slot_index];
            const buffer = self.allocator.alloc(u8, payload.len + max_effect_body_bytes) catch {
                return self.rejectFetch(options);
            };
            slot.generation = self.next_generation;
            self.next_generation +%= 1;
            if (self.next_generation == 0) self.next_generation = 1;
            slot.key = options.key;
            slot.kind = .fetch;
            slot.on_line = null;
            slot.on_exit = null;
            slot.on_response = options.on_response;
            slot.method = options.method;
            slot.timeout_ms = options.timeout_ms;
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
                if (slot.kind == .fetch) {
                    // No exchange: retire the slot and surface the
                    // terminal response now.
                    const response_fn = slot.on_response;
                    const key_copy = slot.key;
                    self.releaseFetchSlot(slot);
                    self.deliverLoopResponse(.{ .key = key_copy, .outcome = .cancelled }, response_fn);
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
                slot.state.store(.idle, .release);
                self.deliverLoopExit(exit, exit_fn);
                return;
            }
            // A real fetch is interrupted by its supervising worker,
            // which polls `cancel_requested`; there is no child to kill.
            if (slot.kind == .spawn) self.killPublishedChild(slot);
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
                            return exit_fn(entry.exit);
                        },
                        .response => |entry| {
                            const response_fn = entry.response_fn orelse continue;
                            return response_fn(entry.response);
                        },
                    }
                }
                if (!self.dequeueInto(&self.drain_scratch)) return null;
                const entry = &self.drain_scratch;
                const slot = &self.slots[entry.slot_index];
                const cancelled = slot.cancelled_generation == entry.generation and entry.generation != 0;
                switch (entry.kind) {
                    .line => {
                        if (cancelled) continue;
                        const line_fn = entry.line_fn orelse continue;
                        return line_fn(.{
                            .key = entry.key,
                            .line = entry.line_bytes[0..entry.line_len],
                            .truncated = entry.truncated,
                            .dropped_before = entry.dropped_before,
                        });
                    },
                    .exit => {
                        const exit_fn = entry.exit_fn orelse continue;
                        return exit_fn(.{
                            .key = entry.key,
                            .code = if (cancelled) effect_error_exit_code else entry.code,
                            .reason = if (cancelled) .cancelled else entry.reason,
                            .dropped_lines = entry.dropped_lines,
                        });
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
                        if (cancelled) {
                            return response_fn(.{ .key = entry.key, .outcome = .cancelled });
                        }
                        const body: []const u8 = if (self.drain_fetch_body) |buffer|
                            buffer[payload_len .. payload_len + entry.line_len]
                        else
                            "";
                        return response_fn(.{
                            .key = entry.key,
                            .outcome = entry.outcome,
                            .status = entry.status,
                            .body = body,
                            .truncated = entry.truncated,
                        });
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
                    return .{ .key = slot.key, .argv = slot.argv(), .stdin = slot.stdinBytes() };
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
                    };
                }
                seen += 1;
            }
            return null;
        }

        /// Feed one synthetic stdout line to the fake effect with `key`.
        /// Mirrors real overflow behavior: a full queue counts a drop
        /// instead of delivering.
        pub fn feedLine(self: *Self, key: u64, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .spawn) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            self.produceLine(slot, @intCast(slot_index), slot.generation, bytes, bytes.len > max_effect_line_bytes);
        }

        /// Feed the synthetic exit for the fake effect with `key`,
        /// retiring its slot.
        pub fn feedExit(self: *Self, key: u64, code: i32) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .spawn) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            var entry: Entry = .{
                .kind = .exit,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .code = code,
                .reason = .exited,
                .dropped_lines = slot.dropped_total,
                .exit_fn = slot.on_exit,
            };
            const exit_fn = slot.on_exit;
            const delivered = self.enqueue(&entry);
            slot.state.store(.idle, .release);
            if (!delivered) {
                self.deliverLoopExit(.{
                    .key = entry.key,
                    .code = code,
                    .reason = .exited,
                    .dropped_lines = entry.dropped_lines,
                }, exit_fn);
            }
            self.wakeHost();
        }

        /// Feed the synthetic response for the fake fetch with `key`,
        /// retiring its slot. Mirrors real truncation: bodies over
        /// `max_effect_body_bytes` are cut with `truncated = true`. If
        /// the completion queue is somehow full, the terminal still
        /// lands through the pending ring — with an empty body and
        /// `truncated = true`, never silently.
        pub fn feedResponse(self: *Self, key: u64, status: u16, body: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key, .fetch) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            const buffer = slot.fetch_buffer orelse return error.EffectNotFound;
            const capacity = buffer.len - slot.payload_len;
            const len = @min(body.len, capacity);
            @memcpy(buffer[slot.payload_len..][0..len], body[0..len]);
            slot.body_len = len;
            slot.fetch_truncated = body.len > capacity;
            slot.fetch_status = status;
            slot.fetch_outcome = .ok;
            var entry: Entry = .{
                .kind = .response,
                .slot_index = @intCast(slot_index),
                .generation = slot.generation,
                .key = slot.key,
                .line_len = @intCast(len),
                .truncated = slot.fetch_truncated,
                .status = status,
                .outcome = .ok,
                .response_fn = slot.on_response,
            };
            slot.state.store(.draining, .release);
            if (!self.enqueue(&entry)) {
                const response_fn = slot.on_response;
                self.releaseFetchSlot(slot);
                self.deliverLoopResponse(.{
                    .key = entry.key,
                    .outcome = .ok,
                    .status = status,
                    .truncated = true,
                }, response_fn);
            }
            self.wakeHost();
        }

        // ---------------------------------------------------------- internals

        fn ensureIo(self: *Self) !std.Io {
            if (self.io_threaded == null) {
                const threaded = try self.allocator.create(std.Io.Threaded);
                // `environ` defaults to `.empty` in `InitOptions`, which
                // would hand every spawned child a blank environment (no
                // HOME, no PATH) — always pass the host environment.
                threaded.* = std.Io.Threaded.init(self.allocator, .{
                    .environ = self.environ orelse fallbackEnviron(),
                });
                self.io_threaded = threaded;
            }
            return self.io_threaded.?.io();
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

        /// Free a fetch slot's body buffer and return it to `.idle`
        /// (spawn-time failures and fake cancels). Loop-thread only.
        fn releaseFetchSlot(self: *Self, slot: *Slot) void {
            if (slot.fetch_buffer) |buffer| {
                self.allocator.free(buffer);
                slot.fetch_buffer = null;
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
                    // A draining fetch slot is reusable once the drain
                    // took its body buffer (the response was delivered).
                    .draining => if (slot.fetch_buffer == null) slot.state.store(.idle, .release),
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

        /// Producer-side line delivery with drop accounting. `truncated`
        /// callers pass at most `max_effect_line_bytes` in `bytes`.
        fn produceLine(self: *Self, slot: *Slot, slot_index: u16, generation: u32, bytes: []const u8, truncated: bool) void {
            const len = @min(bytes.len, max_effect_line_bytes);
            var entry: Entry = .{
                .kind = .line,
                .slot_index = slot_index,
                .generation = generation,
                .key = slot.key,
                .line_len = @intCast(len),
                .truncated = truncated or bytes.len > max_effect_line_bytes,
                .dropped_before = slot.dropped_pending,
                .line_fn = slot.on_line,
            };
            @memcpy(entry.line_bytes[0..len], bytes[0..len]);
            if (self.enqueue(&entry)) {
                slot.dropped_pending = 0;
            } else {
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
            slot.state.store(.done, .release);
            self.wakeHost();
        }

        fn runChild(self: *Self, slot: *Slot, slot_index: u16, generation: u32, io: std.Io, exit: *EffectExit) void {
            var child = std.process.spawn(io, .{
                .argv = slot.argv(),
                .stdin = if (slot.stdin_len > 0) .pipe else .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            }) catch return;

            slot.child_mutex.lock();
            slot.child_id = child.id;
            slot.child_mutex.unlock();
            // A cancel that raced the spawn still lands.
            if (slot.cancel_requested.load(.acquire)) self.killPublishedChild(slot);

            if (child.stdin) |stdin_file| {
                stdin_file.writeStreamingAll(io, slot.stdinBytes()) catch {};
                stdin_file.close(io);
                child.stdin = null;
            }

            if (child.stdout) |stdout_file| {
                self.streamLines(slot, slot_index, generation, io, stdout_file);
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
            var line_buffer: [max_effect_line_bytes]u8 = undefined;
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
                    } else if (line_len < max_effect_line_bytes) {
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

        // ------------------------------------------------------ fetch worker

        /// Supervises one fetch: runs the blocking HTTP exchange as a
        /// cancelable `Io` task and polls for completion, cancel, and
        /// the timeout deadline. Ends by posting exactly one `.response`
        /// entry and parking the slot in `.draining` (the drain retires
        /// it after taking the body buffer).
        fn fetchWorkerMain(self: *Self, slot_index: usize, generation: u32, io: std.Io) void {
            const slot = &self.slots[slot_index];
            supervise: {
                var future = std.Io.concurrent(io, fetchTask, .{ self, slot, io }) catch {
                    // No concurrent capacity: run the exchange inline.
                    // Cancels can no longer interrupt mid-transfer and
                    // the timeout is not enforced, but the terminal Msg
                    // still lands (a raced cancel is rewritten at drain).
                    fetchTask(self, slot, io);
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
        fn fetchTask(self: *Self, slot: *Slot, io: std.Io) void {
            defer slot.fetch_done.store(true, .release);
            self.runFetch(slot, io) catch |err| {
                slot.fetch_status = 0;
                slot.body_len = 0;
                slot.fetch_truncated = false;
                slot.fetch_outcome = classifyFetchError(err);
            };
        }

        fn runFetch(self: *Self, slot: *Slot, io: std.Io) !void {
            const uri = try std.Uri.parse(slot.fetchUrl());
            var client: std.http.Client = .{ .allocator = self.allocator, .io = io };
            defer client.deinit();
            var request = try client.request(slot.method, uri, .{
                .keep_alive = false,
                .extra_headers = slot.fetchHeaders(),
                // Mirrors `std.http.Client.fetch`: payloads cannot be
                // replayed across redirects.
                .redirect_behavior = if (slot.payload_len > 0) .unhandled else @enumFromInt(3),
            });
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

            const buffer = slot.fetch_buffer.?;
            var body_writer = std.Io.Writer.fixed(buffer[slot.payload_len..]);
            const decompress_buffer: []u8 = switch (response.head.content_encoding) {
                .identity => &.{},
                .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
                .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
                .compress => return error.UnsupportedCompressionMethod,
            };
            defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);
            var transfer_buffer: [64]u8 = undefined;
            var decompress: std.http.Decompress = undefined;
            const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
            _ = reader.streamRemaining(&body_writer) catch |err| switch (err) {
                // The bounded body space filled: deliver the first
                // `max_effect_body_bytes` bytes with the flag set.
                error.WriteFailed => slot.fetch_truncated = true,
                error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            };
            slot.body_len = body_writer.end;
            slot.fetch_outcome = .ok;
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
    const response: EffectResponse = .{ .key = 7 };
    try std.testing.expectEqual(EffectFetchOutcome.ok, response.outcome);
    try std.testing.expectEqual(@as(u16, 0), response.status);
    try std.testing.expectEqualStrings("", response.body);
    try std.testing.expect(!response.truncated);
    try std.testing.expectEqual(@as(u32, 0), response.dropped_before);
}

test "fetch errors map onto the documented taxonomy" {
    try std.testing.expectEqual(EffectFetchOutcome.cancelled, classifyFetchError(error.Canceled));
    try std.testing.expectEqual(EffectFetchOutcome.connect_failed, classifyFetchError(error.ConnectionRefused));
    try std.testing.expectEqual(EffectFetchOutcome.connect_failed, classifyFetchError(error.UnknownHostName));
    try std.testing.expectEqual(EffectFetchOutcome.tls_failed, classifyFetchError(error.TlsInitializationFailed));
    try std.testing.expectEqual(EffectFetchOutcome.rejected, classifyFetchError(error.UnsupportedUriScheme));
    try std.testing.expectEqual(EffectFetchOutcome.protocol_failed, classifyFetchError(error.HttpHeadersInvalid));
}
