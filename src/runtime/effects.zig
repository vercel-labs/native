//! The effect system: TEA's `Cmd` half for `UiApp`.
//!
//! `Effects(Msg)` runs subprocesses on worker threads owned by the app
//! loop, streams stdout lines back as typed `Msg` values, and reports
//! process exits the same way. The model is never touched off-thread:
//! workers post fixed-size completion records into a bounded MPSC queue,
//! nudge the platform loop through `PlatformServices.wake_fn`, and the
//! loop thread drains the queue and dispatches Msgs through the app's
//! `update`.
//!
//! Design points, mirroring the framework's fixed-capacity philosophy:
//!
//! - Caller-chosen `u64` keys identify effects (store them in the model);
//!   there are no handles to leak. `cancel(key)` kills and reaps.
//! - Execution is thread-per-spawn with a hard cap (`max_effects` slots).
//!   Subprocess streaming is blocking-read-dominated, so a shared pool
//!   would need pipe multiplexing for zero gain at this scale; one thread
//!   whose lifetime equals its process keeps cancellation and reaping
//!   local to a slot.
//! - Overflow is NEVER silent: a spawn that cannot run surfaces as an
//!   `on_exit` Msg with reason `.rejected`; a line dropped on a full
//!   queue is counted into the next delivered line's `dropped_before`
//!   and the exit's `dropped_lines`; an over-long line is delivered
//!   truncated with `truncated = true`.
//! - Cancel semantics: after `cancel(key)` returns, no further `on_line`
//!   Msgs for that spawn are dispatched (already-queued lines are
//!   discarded at drain), and exactly one `on_exit` Msg with reason
//!   `.cancelled` follows once the process is reaped. No zombies: the
//!   worker always waits on its child.
//!
//! Payload lifetime: `EffectLine.line` points into drain scratch that is
//! recycled on the next drained Msg — `update` must copy what it keeps,
//! exactly like `canvas.TextInputEvent` payloads.

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

pub fn Effects(comptime Msg: type) type {
    return struct {
        const Self = @This();

        pub const LineMsgFn = *const fn (line: EffectLine) Msg;
        pub const ExitMsgFn = *const fn (exit: EffectExit) Msg;

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

        const SlotState = enum(u8) { idle, running, done };

        const EntryKind = enum(u8) { line, exit };

        const Entry = struct {
            kind: EntryKind = .line,
            slot_index: u16 = 0,
            generation: u32 = 0,
            key: u64 = 0,
            line_len: u32 = 0,
            truncated: bool = false,
            dropped_before: u32 = 0,
            code: i32 = 0,
            reason: EffectExitReason = .exited,
            dropped_lines: u32 = 0,
            line_fn: ?LineMsgFn = null,
            exit_fn: ?ExitMsgFn = null,
            line_bytes: [max_effect_line_bytes]u8 = undefined,
        };

        const PendingExit = struct {
            exit: EffectExit,
            exit_fn: ?ExitMsgFn,
        };

        const Slot = struct {
            state: std.atomic.Value(SlotState) = std.atomic.Value(SlotState).init(.idle),
            generation: u32 = 0,
            key: u64 = 0,
            fake: bool = false,
            on_line: ?LineMsgFn = null,
            on_exit: ?ExitMsgFn = null,
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

            fn argv(slot: *const Slot) []const []const u8 {
                return slot.argv_slices[0..slot.argv_count];
            }

            fn stdinBytes(slot: *const Slot) []const u8 {
                return slot.stdin_storage[0..slot.stdin_len];
            }
        };

        allocator: std.mem.Allocator,
        executor: EffectExecutor = .real,
        /// Set once from the loop thread before the first dispatch;
        /// workers call `services.wake()` through it (the one
        /// thread-safe PlatformServices entry).
        services: ?*const platform.PlatformServices = null,
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
        /// Loop-thread-only ring: spawn rejections and fake-executor
        /// exits that found the queue full. Drained before the queue.
        pending_exits: [max_effect_pending_exits]PendingExit = undefined,
        pending_exit_head: usize = 0,
        pending_exit_len: usize = 0,
        /// Scratch the drained entry is copied into so its line slice
        /// stays valid while `update` runs (recycled per drained Msg).
        drain_scratch: Entry = .{},

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
                    self.killPublishedChild(slot);
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
        }

        /// Point workers at the platform's wake service. Loop-thread
        /// only; the first bind sticks (the services value lives on the
        /// runtime and is stable for its lifetime).
        pub fn bindServices(self: *Self, services: *const platform.PlatformServices) void {
            if (self.services == null) self.services = services;
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
            slot.on_line = options.on_line;
            slot.on_exit = options.on_exit;
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
            self.killPublishedChild(slot);
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
                if (self.takePendingExit()) |pending| {
                    const exit_fn = pending.exit_fn orelse continue;
                    return exit_fn(pending.exit);
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
                }
            }
        }

        // --------------------------------------------------- fake executor

        /// Number of recorded (still-active) fake spawn requests.
        pub fn pendingSpawnCount(self: *Self) usize {
            var count: usize = 0;
            for (&self.slots) |*slot| {
                if (slot.fake and slot.state.load(.acquire) == .running) count += 1;
            }
            return count;
        }

        /// The `index`-th recorded fake spawn request (slot order).
        pub fn pendingSpawnAt(self: *Self, index: usize) ?SpawnRequest {
            var seen: usize = 0;
            for (&self.slots) |*slot| {
                if (!(slot.fake and slot.state.load(.acquire) == .running)) continue;
                if (seen == index) {
                    return .{ .key = slot.key, .argv = slot.argv(), .stdin = slot.stdinBytes() };
                }
                seen += 1;
            }
            return null;
        }

        /// Feed one synthetic stdout line to the fake effect with `key`.
        /// Mirrors real overflow behavior: a full queue counts a drop
        /// instead of delivering.
        pub fn feedLine(self: *Self, key: u64, bytes: []const u8) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key) orelse return error.EffectNotFound;
            const slot = &self.slots[slot_index];
            self.produceLine(slot, @intCast(slot_index), slot.generation, bytes, bytes.len > max_effect_line_bytes);
        }

        /// Feed the synthetic exit for the fake effect with `key`,
        /// retiring its slot.
        pub fn feedExit(self: *Self, key: u64, code: i32) error{EffectNotFound}!void {
            const slot_index = self.findActiveFakeSlot(key) orelse return error.EffectNotFound;
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

        // ---------------------------------------------------------- internals

        fn ensureIo(self: *Self) !std.Io {
            if (self.io_threaded == null) {
                const threaded = try self.allocator.create(std.Io.Threaded);
                threaded.* = std.Io.Threaded.init(self.allocator, .{});
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

        /// Queue an exit produced on the loop thread (rejections, fake
        /// cancel/exit fallbacks) for the next drain. When the ring is
        /// full the oldest entry is replaced and the replacement carries
        /// the loss in `dropped_lines` — overflow stays visible.
        fn deliverLoopExit(self: *Self, exit: EffectExit, exit_fn: ?ExitMsgFn) void {
            if (exit_fn == null) return;
            if (self.pending_exit_len == max_effect_pending_exits) {
                const oldest = &self.pending_exits[self.pending_exit_head];
                self.pending_exit_head = (self.pending_exit_head + 1) % max_effect_pending_exits;
                self.pending_exit_len -= 1;
                var replacement = exit;
                replacement.dropped_lines +|= oldest.exit.dropped_lines +| 1;
                const tail = (self.pending_exit_head + self.pending_exit_len) % max_effect_pending_exits;
                self.pending_exits[tail] = .{ .exit = replacement, .exit_fn = exit_fn };
                self.pending_exit_len += 1;
            } else {
                const tail = (self.pending_exit_head + self.pending_exit_len) % max_effect_pending_exits;
                self.pending_exits[tail] = .{ .exit = exit, .exit_fn = exit_fn };
                self.pending_exit_len += 1;
            }
            self.wakeHost();
        }

        fn takePendingExit(self: *Self) ?PendingExit {
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

        fn findActiveFakeSlot(self: *Self, key: u64) ?usize {
            const index = self.findActiveSlot(key) orelse return null;
            if (!self.slots[index].fake) return null;
            return index;
        }

        fn reclaimSlots(self: *Self) void {
            for (&self.slots) |*slot| {
                if (slot.state.load(.acquire) == .done) slot.state.store(.idle, .release);
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
}
