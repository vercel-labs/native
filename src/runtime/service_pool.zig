//! In-process TypeScript service carrier.
//!
//! The service modules compile into a library-mode archive (thread-instanced,
//! runtime-localized) that links into the app binary; this pool owns a small
//! fixed set of worker threads, and each worker thread initializes and owns
//! one complete archive instance for its whole lifetime. HostCallBinding
//! callbacks only copy/enqueue on the loop thread; completions are polled
//! back onto that thread by Effects, so the journaling/replay boundary is
//! byte-identical to the child-process carrier's. Nothing starts before the
//! first real request, so replay never spawns a pool thread and never enters
//! the archive.
//!
//! Dispatch and ordering:
//! - Requests queue centrally; a worker takes the oldest request whose key
//!   has no earlier queued twin and no active twin. Same-key requests
//!   therefore run strictly FIFO and never concurrently; different keys run
//!   in parallel across instances. A poisoned instance retains its key until
//!   its detached dispatch physically returns, so replacement work cannot
//!   overlap side effects from an operation that ignored cancellation.
//! - Fire-and-forget sends share key 0 and serialize among themselves.
//!
//! Cancellation and deadlines ride the same cooperative token the child
//! carrier publishes: a marker file at the request's cancellation path,
//! polled by the generated service code. A deadline (or an app cancel)
//! publishes the marker and grants `cooperative_cancel_grace_ms`; an
//! operation that returns inside the grace keeps its instance warm, exactly
//! like the child process staying alive after a cooperative unwind. There is
//! no process to kill past the grace, so an operation that ignores its token
//! POISONS its instance instead: the worker thread is abandoned (detached;
//! its instance memory is reclaimed only at process exit), the request
//! routes `kind: "timeout"`, and a replacement worker with a fresh instance
//! joins the pool. A detected runtime trap routes `kind: "service_trap"` the
//! same way: the per-instance panic sink stages the error, poisons exactly
//! the instance it fired in, parks the trapped thread, and the pool spawns a
//! replacement — other instances keep answering throughout. Hardware faults
//! (stack overflow above all) are process-wide on any in-process carrier;
//! the child-process carrier remains the fully isolated option.
//!
//! Streaming operations emit interim chunks through a per-request relay
//! file ([len u32 LE][bytes] frames appended by the generated facade); the
//! pool's supervisor thread tails the file while the operation runs and
//! posts each frame to the request's external channel, so chunks stay live
//! mid-operation and always precede the typed terminal.

const std = @import("std");
const builtin = @import("builtin");
const effects = @import("effects.zig");
const platform = @import("../platform/root.zig");
const service_host = @import("service_host.zig");

const transport_error = "{\"kind\":\"service_host\",\"message\":\"service archive rejected the request\"}";
const timeout_error = "{\"kind\":\"timeout\",\"message\":\"service request timed out\"}";

/// Same budget discipline as the child carrier: bound the whole request
/// from admission through queueing and dispatch.
pub const default_request_timeout_ms: u32 = service_host.default_request_timeout_ms;
pub const cooperative_cancel_grace_ms: u32 = service_host.cooperative_cancel_grace_ms;

/// Ceiling on configured pool width; the default stays far below it.
pub const max_pool_workers: usize = 16;

/// The default pool width: enough parallelism for independent keys without
/// paying an instance heap per core on wide machines.
pub fn defaultWorkerCount() usize {
    const cores = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(4, cores));
}

/// How often the supervisor tails active stream-relay files.
const stream_poll_ms: u32 = 2;

/// Detached dispatches expose one atomic returned flag. The supervisor polls
/// it at the same low cadence as stream relays so it can release the key and
/// the request resources without letting the abandoned thread touch the pool.
const abandoned_poll_ms: u32 = 2;

pub const PoolOptions = struct {
    /// Worker-thread count; null resolves `defaultWorkerCount()` on first use.
    max_workers: ?usize = null,
};

/// Test-only synchronization at the completion ownership handoff. Production
/// pool layouts contain no pointer to this barrier (`builtin.is_test` gates
/// the field); the end-to-end suite uses it to make grace-boundary races
/// deterministic instead of depending on scheduler timing.
pub const TestCompletionBarrier = struct {
    claimed: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
};

pub fn ServicePool(comptime Registry: type) type {
    return struct {
        const Self = @This();

        const abi = struct {
            const prefix = Registry.inproc_symbol_prefix;
            const PanicSinkFn = *const fn (?*anyopaque, [*]const u8, usize, u64) callconv(.c) void;
            const init_fn = @extern(*const fn () callconv(.c) void, .{ .name = prefix ++ "init" });
            const set_panic_sink_fn = @extern(*const fn (PanicSinkFn, ?*anyopaque) callconv(.c) void, .{ .name = prefix ++ "set_panic_sink" });
            const collect_fn = @extern(*const fn () callconv(.c) void, .{ .name = prefix ++ "collect" });
            const dispatch_fn = @extern(*const fn (u32, [*]const u8, usize, [*]const u8, usize, [*]const u8, usize, *[*]const u8, *usize) callconv(.c) void, .{ .name = prefix ++ "dispatch" });
            const contract_fingerprint_fn = @extern(*const fn (*[*]const u8, *usize) callconv(.c) void, .{ .name = prefix ++ "contract_fingerprint" });
        };

        const Request = struct {
            key: u64,
            request_id: u32,
            operation: u16,
            payload: []u8,
            answer: bool,
            deadline: std.Io.Clock.Timestamp,
            channel: ?effects.ChannelHandle,
        };
        const Result = struct { key: u64, ok: bool, bytes: []u8 };

        const Stream = struct {
            path: []u8,
            channel: effects.ChannelHandle,
            file: ?std.Io.File = null,
            /// Partial-frame carry between supervisor polls.
            pending: std.ArrayList(u8) = .empty,
            /// Set by the worker when the operation returned; the supervisor
            /// answers with one final drain and `drained`.
            finishing: bool = false,
            drained: std.Io.Event = .unset,
            /// The supervisor is reading this stream outside the pool mutex.
            in_poll: bool = false,
            /// The owner retired while the supervisor was mid-poll; the
            /// supervisor destroys the stream when its poll completes.
            orphaned: bool = false,
        };

        const Active = struct {
            key: u64,
            request_id: u32,
            payload: []u8,
            answer: bool,
            deadline: std.Io.Clock.Timestamp,
            cancelled: bool = false,
            /// A terminal outcome was already decided (timeout staged, trap
            /// staged, or cancel discarded); any later result is dropped.
            retired: bool = false,
            timed_out: bool = false,
            cancel_published: bool = false,
            grace_deadline: ?std.Io.Clock.Timestamp = null,
            /// Allocated after the pick (the slot installs atomically with
            /// the dequeue, under the pool mutex, so a same-key twin can
            /// never double-pick); a cancellation published before the path
            /// exists writes its marker when the path attaches.
            cancel_path: ?[]u8 = null,
            stream: ?*Stream = null,
        };

        const WorkerState = enum { idle, busy, poisoned, exited };
        const ExecutionState = enum(u8) { running, completing, trapping, poisoned };

        const Worker = struct {
            pool: *Self,
            /// Process-lifetime executor handle copied out of the pool. A
            /// poisoned thread may need to park after the pool itself was
            /// destroyed (for example when an abandoned dispatch traps).
            io: std.Io,
            thread: std.Thread = undefined,
            /// Guarded by pool.mutex.
            state: WorkerState = .idle,
            active: ?Active = null,
            exited_event: std.Io.Event = .unset,
            /// Atomic ownership handoff around the archive call. Completion
            /// and the supervisor race to claim `running`; a trap can preempt
            /// either execution or completion. Only the winner may touch
            /// request teardown. The Worker struct itself is leaked on poison
            /// so this stays readable after the pool is gone.
            execution_state: std.atomic.Value(ExecutionState) = .init(.running),
            /// A poisoned dispatch sets this after it physically stops. The
            /// supervisor then releases its key/resources; until then a
            /// same-key replacement remains queued.
            returned_flag: std.atomic.Value(bool) = .init(false),
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        options: PoolOptions,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,
        /// Supervisor wake latch (deadline/grace/stream state changed).
        supervisor_event: std.Io.Event = .unset,
        supervisor_thread: ?std.Thread = null,
        queue: std.ArrayList(Request) = .empty,
        results: std.ArrayList(Result) = .empty,
        last_polled: ?[]u8 = null,
        services: ?platform.PlatformServices = null,
        channels: ?effects.HostChannelBinding = null,
        workers: std.ArrayList(*Worker) = .empty,
        shutting_down: bool = false,
        next_request_id: u32 = 1,
        request_timeout_ms: u32 = default_request_timeout_ms,
        fingerprint_state: enum { unchecked, ok, rejected } = .unchecked,
        /// Wakes in flight outside the mutex; shutdown waits for zero so a
        /// worker can never call a severed PlatformServices handle.
        waking: usize = 0,
        waking_condition: std.Io.Condition = .init,
        poisoned_total: u64 = 0,
        test_completion_barrier: if (builtin.is_test) ?*TestCompletionBarrier else void = if (builtin.is_test) null else {},

        pub fn init(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, options: PoolOptions) Self {
            return .{ .allocator = allocator, .io = io, .cwd = cwd, .options = options };
        }

        pub fn binding(self: *Self) effects.HostCallBinding {
            return .{
                .context = self,
                .send_fn = send,
                .request_fn = request,
                .cancel_fn = cancel,
                .reject_duplicate_keys = true,
                .poll_fn = poll,
                .pending_fn = pending,
                .bind_services_fn = bindServices,
                .bind_channels_fn = bindChannels,
                .shutdown_fn = shutdown,
            };
        }

        /// Configure the carrier for deterministic timeout tests; production
        /// uses the conservative default.
        pub fn setRequestTimeoutMs(self: *Self, timeout_ms: u32) void {
            std.debug.assert(timeout_ms > 0);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.request_timeout_ms = timeout_ms;
        }

        /// Pause after a dispatch claims `.completing`, before its final stream
        /// drain. Tests install this before the first request; it is unavailable
        /// in production builds and adds no field to their pool layout.
        pub fn setCompletionBarrierForTesting(self: *Self, barrier: *TestCompletionBarrier) void {
            if (comptime !builtin.is_test) @compileError("completion barriers are test-only");
            self.test_completion_barrier = barrier;
        }

        /// Diagnostic visibility: whether any pool thread was ever started.
        /// The replay suites pin this false — replay must never initialize
        /// the archive.
        pub fn started(self: *Self) bool {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.workers.items.len > 0;
        }

        /// Diagnostic visibility: instances abandoned to traps or ignored
        /// cancellation tokens over this pool's lifetime.
        pub fn poisonedCount(self: *Self) u64 {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.poisoned_total;
        }

        /// Live worker threads (poisoned and exited instances excluded).
        pub fn workerCount(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var count: usize = 0;
            for (self.workers.items) |worker| {
                if (worker.state == .idle or worker.state == .busy) count += 1;
            }
            return count;
        }

        /// Safe after Effects shutdown; repeated shutdown is inert.
        pub fn deinit(self: *Self) void {
            shutdown(self);
            self.mutex.lockUncancelable(self.io);
            for (self.queue.items) |entry| self.allocator.free(entry.payload);
            self.queue.deinit(self.allocator);
            for (self.results.items) |entry| self.allocator.free(entry.bytes);
            self.results.deinit(self.allocator);
            if (self.last_polled) |bytes| self.allocator.free(bytes);
            self.last_polled = null;
            for (self.workers.items) |worker| {
                if (worker.state == .poisoned and worker.returned_flag.load(.acquire)) {
                    _ = self.reapReturnedPoisonedLocked(worker);
                }
                // Poisoned workers' structs stay allocated: their abandoned
                // threads may still read the atomic re-entry flag. Bounded
                // by the poison count.
                if (worker.state == .exited) self.allocator.destroy(worker);
            }
            self.workers.deinit(self.allocator);
            self.mutex.unlock(self.io);
        }

        // ------------------------------------------------------ admission

        fn send(context: *anyopaque, name: []const u8, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const operation_index = Registry.indexOf(name) orelse return;
            const operation = Registry.operationAt(operation_index) orelse return;
            if (operation.streaming) return;
            self.enqueue(0, operation.index, payload, false, operation.deadline_ms orelse self.request_timeout_ms, null);
        }

        fn request(context: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(context));
            const operation_index = Registry.indexOf(name) orelse {
                self.stageStatic(key, false, transport_error);
                return;
            };
            const operation = Registry.operationAt(operation_index) orelse {
                self.stageStatic(key, false, transport_error);
                return;
            };
            var request_payload = payload;
            var channel: ?effects.ChannelHandle = null;
            if (operation.streaming) {
                if (payload.len < 8) {
                    self.stageStatic(key, false, transport_error);
                    return;
                }
                const channel_number = @as(f64, @bitCast(readU64(payload, 0)));
                if (!std.math.isFinite(channel_number) or channel_number < 1 or channel_number >= 9_007_199_254_740_992 or @floor(channel_number) != channel_number) {
                    self.stageStatic(key, false, transport_error);
                    return;
                }
                const channel_key: u64 = @intFromFloat(channel_number);
                const channel_binding = self.channels orelse {
                    self.stageStatic(key, false, transport_error);
                    return;
                };
                channel = channel_binding.acquire_fn(channel_binding.context, channel_key) orelse {
                    self.stageStatic(key, false, transport_error);
                    return;
                };
                request_payload = payload[8..];
            }
            self.enqueue(key, operation.index, request_payload, true, operation.deadline_ms orelse self.request_timeout_ms, channel);
        }

        fn cancel(context: *anyopaque, key: u64) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            var index: usize = 0;
            while (index < self.queue.items.len) {
                if (self.queue.items[index].answer and self.queue.items[index].key == key) {
                    const removed = self.queue.orderedRemove(index);
                    self.allocator.free(removed.payload);
                } else index += 1;
            }
            index = 0;
            while (index < self.results.items.len) {
                if (self.results.items[index].key == key) {
                    const removed = self.results.orderedRemove(index);
                    self.allocator.free(removed.bytes);
                } else index += 1;
            }
            for (self.workers.items) |worker| {
                if (worker.state != .busy) continue;
                if (worker.active) |*active| {
                    if (!active.answer or active.key != key or active.retired) continue;
                    active.cancelled = true;
                    self.publishCancellationLocked(active);
                }
            }
            // Wake workers so queue removals and newly published cancellation
            // state are observed. The active request keeps its key reserved
            // until its dispatch physically returns.
            self.condition.broadcast(self.io);
            self.supervisor_event.set(self.io);
            self.mutex.unlock(self.io);
        }

        fn bindServices(context: *anyopaque, services: *const platform.PlatformServices) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            self.services = services.*;
            self.mutex.unlock(self.io);
        }

        fn bindChannels(context: *anyopaque, channels: effects.HostChannelBinding) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.channels = channels;
        }

        fn pending(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.results.items.len > 0;
        }

        fn poll(context: *anyopaque) ?effects.HostCallCompletion {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.last_polled) |bytes| self.allocator.free(bytes);
            self.last_polled = null;
            if (self.results.items.len == 0) return null;
            const result = self.results.orderedRemove(0);
            self.last_polled = result.bytes;
            return .{ .key = result.key, .ok = result.ok, .bytes = result.bytes };
        }

        fn shutdown(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(self.io);
            if (self.shutting_down) {
                self.mutex.unlock(self.io);
                return;
            }
            self.shutting_down = true;
            // Every busy operation gets the cooperative token; the exit wait
            // below is the grace. The supervisor keeps running until no
            // worker is busy — it drains finishing streams and poisons
            // token-ignoring operations at their grace deadline.
            for (self.workers.items) |worker| {
                if (worker.state != .busy) continue;
                if (worker.active) |*active| {
                    if (!active.retired) self.publishCancellationLocked(active);
                }
            }
            self.condition.broadcast(self.io);
            self.supervisor_event.set(self.io);

            const exit_deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
                .raw = std.Io.Duration.fromMilliseconds(2 * cooperative_cancel_grace_ms + 200),
                .clock = .awake,
            });
            var index: usize = 0;
            while (index < self.workers.items.len) : (index += 1) {
                const worker = self.workers.items[index];
                if (worker.state == .poisoned) continue; // detached at poison time
                if (worker.state == .exited) {
                    self.mutex.unlock(self.io);
                    worker.thread.join();
                    self.mutex.lockUncancelable(self.io);
                    continue;
                }
                self.mutex.unlock(self.io);
                const timed_out = timed_out: {
                    worker.exited_event.waitTimeout(self.io, .{ .deadline = exit_deadline }) catch break :timed_out true;
                    break :timed_out false;
                };
                self.mutex.lockUncancelable(self.io);
                if (worker.state == .poisoned) continue; // trapped or abandoned meanwhile
                if (timed_out and worker.state != .exited) {
                    // The operation ignored its token even at shutdown:
                    // abandon the instance like every other hard timeout.
                    if (self.poisonWorkerLocked(worker, .running)) continue;

                    // Completion or the trap sink claimed teardown first.
                    // Let that owner finish while the pool is still alive;
                    // both paths signal the same state-change latch.
                    if (worker.execution_state.load(.acquire) == .poisoned) continue;
                    self.mutex.unlock(self.io);
                    worker.exited_event.waitUncancelable(self.io);
                    self.mutex.lockUncancelable(self.io);
                    if (worker.state == .poisoned) continue;
                }
                self.mutex.unlock(self.io);
                worker.thread.join();
                self.mutex.lockUncancelable(self.io);
            }
            const supervisor = self.supervisor_thread;
            self.supervisor_thread = null;
            self.supervisor_event.set(self.io);
            self.mutex.unlock(self.io);
            if (supervisor) |thread| thread.join();
            self.mutex.lockUncancelable(self.io);
            self.services = null;
            while (self.waking > 0) self.waking_condition.waitUncancelable(self.io, &self.mutex);
            self.mutex.unlock(self.io);
        }

        // ------------------------------------------------------- staging

        fn stageStatic(self: *Self, key: u64, ok: bool, bytes: []const u8) void {
            const copy = self.allocator.dupe(u8, bytes) catch return;
            self.stageOwned(.{ .key = key, .ok = ok, .bytes = copy });
        }

        fn stageOwned(self: *Self, result: Result) void {
            self.mutex.lockUncancelable(self.io);
            self.stageOwnedLocked(result);
            const services = self.takeWakeLocked();
            self.mutex.unlock(self.io);
            self.finishWake(services);
        }

        fn stageOwnedLocked(self: *Self, result: Result) void {
            if (self.shutting_down) {
                self.allocator.free(result.bytes);
                return;
            }
            self.results.append(self.allocator, result) catch {
                self.allocator.free(result.bytes);
                return;
            };
        }

        /// Reserve the right to wake after unlocking. Shutdown waits for
        /// every reservation to finish before the platform handle is severed.
        fn takeWakeLocked(self: *Self) ?platform.PlatformServices {
            const services = self.services orelse return null;
            self.waking += 1;
            return services;
        }

        fn finishWake(self: *Self, services: ?platform.PlatformServices) void {
            const bound = services orelse return;
            bound.wake() catch {};
            self.mutex.lockUncancelable(self.io);
            self.waking -= 1;
            self.waking_condition.broadcast(self.io);
            self.mutex.unlock(self.io);
        }

        // ------------------------------------------------------- enqueue

        fn enqueue(self: *Self, key: u64, operation: u16, payload: []const u8, answer: bool, timeout_ms: u32, channel: ?effects.ChannelHandle) void {
            const copy = self.allocator.dupe(u8, payload) catch {
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            };
            const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
                .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
                .clock = .awake,
            });
            self.mutex.lockUncancelable(self.io);
            if (self.shutting_down) {
                self.mutex.unlock(self.io);
                self.allocator.free(copy);
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            }
            const request_id = self.next_request_id;
            self.next_request_id +%= 1;
            if (self.next_request_id == 0) self.next_request_id = 1;
            self.queue.append(self.allocator, .{
                .key = key,
                .request_id = request_id,
                .operation = operation,
                .payload = copy,
                .answer = answer,
                .deadline = deadline,
                .channel = channel,
            }) catch {
                self.mutex.unlock(self.io);
                self.allocator.free(copy);
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            };
            if (!self.ensureCapacityLocked()) {
                const removed = self.queue.pop().?;
                self.mutex.unlock(self.io);
                self.allocator.free(removed.payload);
                if (answer) self.stageStatic(key, false, transport_error);
                return;
            }
            // A newly admitted deadline may be earlier than every deadline
            // the supervisor observed before parking. Wake both schedulers:
            // a worker may be able to run it now, while the supervisor owns
            // expiry if every eligible worker remains occupied.
            self.condition.signal(self.io);
            self.supervisor_event.set(self.io);
            self.mutex.unlock(self.io);
        }

        /// Lazily grow the pool toward its width: the supervisor plus one
        /// worker on first use, another worker whenever the queued backlog
        /// exceeds the idle set and capacity remains. Returns false only
        /// when the pool has no worker at all and cannot start one.
        fn ensureCapacityLocked(self: *Self) bool {
            const target = @min(max_pool_workers, @max(1, self.options.max_workers orelse defaultWorkerCount()));
            if (self.supervisor_thread == null) {
                self.supervisor_thread = std.Thread.spawn(.{}, supervisorMain, .{self}) catch null;
                if (self.supervisor_thread == null) return false;
            }
            var live: usize = 0;
            var idle: usize = 0;
            for (self.workers.items) |worker| {
                switch (worker.state) {
                    .idle => {
                        live += 1;
                        idle += 1;
                    },
                    .busy => live += 1,
                    .poisoned, .exited => {},
                }
            }
            if (live >= target or idle >= self.queue.items.len) return true;
            const spawned = self.spawnWorkerLocked();
            return spawned or live > 0;
        }

        fn spawnWorkerLocked(self: *Self) bool {
            const worker = self.allocator.create(Worker) catch return false;
            worker.* = .{ .pool = self, .io = self.io };
            self.workers.append(self.allocator, worker) catch {
                self.allocator.destroy(worker);
                return false;
            };
            worker.thread = std.Thread.spawn(.{}, workerMain, .{worker}) catch {
                _ = self.workers.pop();
                self.allocator.destroy(worker);
                return false;
            };
            return true;
        }

        // --------------------------------------------------------- worker

        fn keyBusyLocked(self: *Self, key: u64) bool {
            for (self.workers.items) |worker| {
                const active = worker.active orelse continue;
                if (active.key != key) continue;
                if (worker.state == .busy) return true;
                if (worker.state == .poisoned and !worker.returned_flag.load(.acquire)) return true;
            }
            return false;
        }

        /// The oldest queue entry whose key has no active/abandoned twin —
        /// FIFO per key follows directly from the queue-order scan, while a
        /// busy key never hides later independent work from an idle worker.
        fn pickRequestLocked(self: *Self) ?Request {
            var index: usize = 0;
            while (index < self.queue.items.len) : (index += 1) {
                const key = self.queue.items[index].key;
                if (!self.keyBusyLocked(key)) return self.queue.orderedRemove(index);
            }
            return null;
        }

        fn workerMain(worker: *Worker) void {
            const self = worker.pool;
            // The calling thread is the instance: one deterministic init and
            // one per-instance sink registration for this thread's lifetime.
            abi.init_fn();
            abi.set_panic_sink_fn(&trapSink, worker);
            self.verifyFingerprint();
            self.mutex.lockUncancelable(self.io);
            while (!self.shutting_down) {
                const work = self.pickRequestLocked() orelse {
                    worker.state = .idle;
                    self.condition.waitUncancelable(self.io, &self.mutex);
                    continue;
                };
                worker.state = .busy;
                if (self.fingerprint_state == .rejected) {
                    worker.state = .idle;
                    self.mutex.unlock(self.io);
                    self.allocator.free(work.payload);
                    if (work.answer) self.stageStatic(work.key, false, transport_error);
                    self.mutex.lockUncancelable(self.io);
                    continue;
                }
                // The active slot installs atomically with the dequeue:
                // from here a same-key twin is blocked and a cancel or
                // deadline finds this request supervisable.
                worker.execution_state.store(.running, .release);
                worker.returned_flag.store(false, .release);
                worker.active = .{
                    .key = work.key,
                    .request_id = work.request_id,
                    .payload = work.payload,
                    .answer = work.answer,
                    .deadline = work.deadline,
                };
                self.supervisor_event.set(self.io);
                self.mutex.unlock(self.io);
                self.executeRequest(worker, work);
                // A hard-timed-out request abandoned this worker. The
                // request path set `returned_flag` without touching the pool;
                // the supervisor owns resource/key retirement from here.
                if (worker.execution_state.load(.acquire) == .poisoned) return;
                self.mutex.lockUncancelable(self.io);
                worker.state = .idle;
            }
            worker.state = .exited;
            worker.exited_event.set(self.io);
            self.supervisor_event.set(self.io);
            self.mutex.unlock(self.io);
        }

        fn executeRequest(self: *Self, worker: *Worker, work: Request) void {
            const cancel_path = self.cancellationPath(work.request_id) catch null;
            var stream: ?*Stream = null;
            if (cancel_path != null) {
                if (work.channel) |channel| {
                    stream = self.createStream(work.request_id, channel);
                }
            }
            const setup_failed = cancel_path == null or (work.channel != null and stream == null);
            self.mutex.lockUncancelable(self.io);
            if (worker.active) |*active| {
                active.cancel_path = cancel_path;
                active.stream = stream;
                // A cancellation or deadline published before the marker
                // path existed writes its marker now.
                if (active.cancel_published) {
                    if (std.Io.Dir.cwd().createFile(self.io, cancel_path.?, .{ .truncate = true })) |file| {
                        file.close(self.io);
                    } else |_| {}
                }
                // The supervisor may be parked on a distant deadline; an
                // attached stream needs its 2 ms tailing cadence now.
                if (stream != null) self.supervisor_event.set(self.io);
            }
            if (worker.state == .poisoned) {
                if (worker.active) |*active| active.retired = true;
                worker.returned_flag.store(true, .release);
                self.supervisor_event.set(self.io);
                self.mutex.unlock(self.io);
                return;
            }
            if (setup_failed) {
                if (worker.active) |*active| active.retired = true;
                self.retireActiveLocked(worker);
                self.mutex.unlock(self.io);
                if (work.answer) self.stageStatic(work.key, false, transport_error);
                return;
            }
            const already_expired = std.Io.Clock.Timestamp.compare(
                std.Io.Clock.Timestamp.now(self.io, .awake),
                .gte,
                work.deadline,
            );
            if (already_expired) {
                // Deadlines include queue time: an expired request never
                // enters the archive (parity with the child carrier).
                const active = &worker.active.?;
                active.retired = true;
                active.timed_out = true;
                var expired_staged = false;
                if (work.answer and !active.cancelled) {
                    if (self.allocator.dupe(u8, timeout_error)) |copy| {
                        self.stageOwnedLocked(.{ .key = work.key, .ok = false, .bytes = copy });
                        expired_staged = true;
                    } else |_| {}
                }
                const services = if (expired_staged) self.takeWakeLocked() else null;
                self.retireActiveLocked(worker);
                self.mutex.unlock(self.io);
                self.finishWake(services);
                return;
            }
            self.mutex.unlock(self.io);

            var out_ptr: [*]const u8 = undefined;
            var out_len: usize = 0;
            const empty = [_]u8{0};
            const payload_ptr: [*]const u8 = if (work.payload.len > 0) work.payload.ptr else &empty;
            const marker_path: []const u8 = cancel_path.?;
            const stream_path: []const u8 = if (stream) |value| value.path else "";
            const stream_ptr: [*]const u8 = if (stream_path.len > 0) stream_path.ptr else &empty;
            abi.dispatch_fn(
                work.operation,
                payload_ptr,
                work.payload.len,
                marker_path.ptr,
                marker_path.len,
                stream_ptr,
                stream_path.len,
                &out_ptr,
                &out_len,
            );
            // Atomically claim completion before touching any pool-owned
            // request resource. If the supervisor won the race, the Worker
            // is process-lived but the pool may already be gone: publish the
            // one safe returned bit and leave everything else to the
            // supervisor (or leak it at process teardown).
            if (worker.execution_state.cmpxchgStrong(.running, .completing, .acq_rel, .acquire)) |actual| {
                std.debug.assert(actual == .poisoned);
                worker.returned_flag.store(true, .release);
                return;
            }
            if (comptime builtin.is_test) {
                if (self.test_completion_barrier) |barrier| {
                    barrier.claimed.set(self.io);
                    barrier.release.waitUncancelable(self.io);
                }
            }

            var completion: ?Result = null;
            if (work.answer) {
                if (out_len >= 1) {
                    if (self.allocator.dupe(u8, out_ptr[1..out_len])) |copy| {
                        completion = .{ .key = work.key, .ok = out_ptr[0] == 0, .bytes = copy };
                    } else |_| {}
                }
                if (completion == null) {
                    if (self.allocator.dupe(u8, transport_error)) |copy| {
                        completion = .{ .key = work.key, .ok = false, .bytes = copy };
                    } else |_| {}
                }
            }
            // Reference-cycle collection between requests keeps a long-lived
            // instance's heap bounded; the returned bytes were copied above.
            abi.collect_fn();

            // Chunks precede the terminal: the supervisor drains the relay
            // file completely before the result stages.
            if (stream) |value| self.finishStream(value);

            self.mutex.lockUncancelable(self.io);
            var staged = false;
            if (worker.active) |*active| {
                if (completion) |result| {
                    if (active.retired or active.cancelled or self.shutting_down) {
                        self.allocator.free(result.bytes);
                    } else if (active.timed_out) {
                        // Cooperative timeout: the operation honored the
                        // token inside the grace; the instance stays warm
                        // and the request routes the timeout kind.
                        self.allocator.free(result.bytes);
                        active.retired = true;
                        if (self.allocator.dupe(u8, timeout_error)) |copy| {
                            self.stageOwnedLocked(.{ .key = work.key, .ok = false, .bytes = copy });
                            staged = true;
                        } else |_| {}
                    } else {
                        active.retired = true;
                        self.stageOwnedLocked(result);
                        staged = true;
                    }
                }
            } else if (completion) |result| {
                self.allocator.free(result.bytes);
            }
            const services = if (staged) self.takeWakeLocked() else null;
            self.retireActiveLocked(worker);
            self.mutex.unlock(self.io);
            self.finishWake(services);
        }

        /// Clear the worker's active slot and release its request-scoped
        /// resources. Pool mutex held.
        fn retireActiveLocked(self: *Self, worker: *Worker) void {
            const active = worker.active orelse return;
            self.allocator.free(active.payload);
            if (active.cancel_path) |path| {
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                self.allocator.free(path);
            }
            if (active.stream) |stream| self.releaseStreamLocked(stream);
            worker.active = null;
            // A completed request may unblock a queued same-key twin.
            self.condition.broadcast(self.io);
            self.supervisor_event.set(self.io);
        }

        // ------------------------------------------------------ poisoning

        /// Abandon a worker whose operation ignored its cooperative token
        /// (or trapped): detach the thread, retain the request's resources and
        /// key until dispatch physically stops, and refill the pool. Pool mutex
        /// held.
        fn poisonWorkerLocked(self: *Self, worker: *Worker, expected: ExecutionState) bool {
            if (worker.execution_state.cmpxchgStrong(expected, .poisoned, .acq_rel, .acquire) != null) return false;
            std.debug.assert(worker.state != .poisoned);
            worker.state = .poisoned;
            worker.thread.detach();
            // This is a state-change latch too: shutdown waiters re-check
            // `worker.state` and skip joining a detached poisoned thread.
            worker.exited_event.set(self.io);
            self.poisoned_total += 1;
            // Keep the active slot and all request storage alive: the detached
            // archive call may still be reading those bytes/paths. Its key
            // remains reserved until `returned_flag`; then the supervisor can
            // reclaim the resources because the dispatch physically stopped.
            self.condition.broadcast(self.io);
            self.supervisor_event.set(self.io);
            if (!self.shutting_down) _ = self.spawnWorkerLocked();
            return true;
        }

        /// Reclaim a poisoned request only after its detached dispatch has
        /// physically stopped. Pool mutex held.
        fn reapReturnedPoisonedLocked(self: *Self, worker: *Worker) bool {
            if (worker.state != .poisoned or !worker.returned_flag.load(.acquire) or worker.active == null) return false;
            self.retireActiveLocked(worker);
            return true;
        }

        /// The per-instance trap sink: runs on the trapping worker thread,
        /// stages the error, poisons exactly this instance, and parks the
        /// thread forever (the sink must not return).
        fn trapSink(context: ?*anyopaque, msg: [*]const u8, msg_len: usize, address: u64) callconv(.c) void {
            _ = address;
            const worker: *Worker = @ptrCast(@alignCast(context.?));
            var state = worker.execution_state.load(.acquire);
            while (state != .poisoned) {
                const claimable = state == .running or state == .completing;
                std.debug.assert(claimable);
                if (worker.execution_state.cmpxchgWeak(state, .trapping, .acq_rel, .acquire)) |actual| {
                    state = actual;
                    continue;
                }
                break;
            }
            if (state == .poisoned) {
                // The supervisor already detached this instance. A later
                // trap must never follow Worker.pool into freed pool memory.
                worker.returned_flag.store(true, .release);
                parkWorker(worker);
            }
            const self = worker.pool;
            const message = msg[0..msg_len];
            self.mutex.lockUncancelable(self.io);
            var staged = false;
            if (worker.active) |*active| {
                if (active.answer and !active.retired and !active.cancelled and !self.shutting_down) {
                    active.retired = true;
                    if (trapErrorJson(self.allocator, message)) |bytes| {
                        self.stageOwnedLocked(.{ .key = active.key, .ok = false, .bytes = bytes });
                        staged = true;
                    } else |_| {}
                } else {
                    active.retired = true;
                }
            }
            const poisoned = self.poisonWorkerLocked(worker, .trapping);
            std.debug.assert(poisoned);
            // A trapped dispatch can never resume past the sink, so it has
            // physically stopped for same-key serialization purposes.
            worker.returned_flag.store(true, .release);
            self.supervisor_event.set(self.io);
            const services = if (staged) self.takeWakeLocked() else null;
            self.mutex.unlock(self.io);
            self.finishWake(services);
            parkWorker(worker);
        }

        fn parkWorker(worker: *Worker) noreturn {
            // The instance is poisoned and this thread IS the instance; only
            // its stack and process-lived Worker remain resident.
            var park: std.Io.Event = .unset;
            while (true) park.waitUncancelable(worker.io);
        }

        // ------------------------------------------------------ supervisor

        /// One thread supervises every in-flight request: deadline expiry,
        /// the cooperative-cancel grace, and stream-relay tailing. It exits
        /// only when the pool is shutting down AND no worker is busy, so a
        /// worker draining its stream at shutdown is never stranded.
        fn supervisorMain(self: *Self) void {
            while (true) {
                self.supervisor_event.reset();
                var staged_wake = false;
                var streams_buffer: [max_pool_workers]*Stream = undefined;
                var streams_len: usize = 0;
                var next_deadline: ?std.Io.Clock.Timestamp = null;

                self.mutex.lockUncancelable(self.io);
                var any_busy = false;
                var any_abandoned = false;
                const now = std.Io.Clock.Timestamp.now(self.io, .awake);
                // Queue time belongs to the request deadline. Expire queued
                // work here as well as at pick time, including a same-key
                // replacement waiting for an abandoned predecessor.
                var queue_index: usize = 0;
                while (queue_index < self.queue.items.len) {
                    const queued = self.queue.items[queue_index];
                    if (!std.Io.Clock.Timestamp.compare(now, .gte, queued.deadline)) {
                        next_deadline = earlier(next_deadline, queued.deadline);
                        queue_index += 1;
                        continue;
                    }
                    const expired = self.queue.orderedRemove(queue_index);
                    self.allocator.free(expired.payload);
                    if (expired.answer) {
                        if (self.allocator.dupe(u8, timeout_error)) |copy| {
                            self.stageOwnedLocked(.{ .key = expired.key, .ok = false, .bytes = copy });
                            staged_wake = true;
                        } else |_| {}
                    }
                }
                // Index-based: poisoning refills the pool, which appends to
                // this list mid-iteration.
                var worker_index: usize = 0;
                while (worker_index < self.workers.items.len) : (worker_index += 1) {
                    const worker = self.workers.items[worker_index];
                    if (worker.state == .poisoned) {
                        if (!self.reapReturnedPoisonedLocked(worker) and worker.active != null) any_abandoned = true;
                        continue;
                    }
                    if (worker.state != .busy) continue;
                    any_busy = true;
                    if (worker.active) |*active| {
                        if (active.grace_deadline) |grace| {
                            if (std.Io.Clock.Timestamp.compare(now, .gte, grace) and !active.retired) {
                                // The token was ignored through the grace:
                                // abandon this instance only while dispatch
                                // still owns `.running`.
                                if (self.poisonWorkerLocked(worker, .running)) {
                                    if (active.timed_out and active.answer and !active.cancelled) {
                                        if (self.allocator.dupe(u8, timeout_error)) |copy| {
                                            self.stageOwnedLocked(.{ .key = active.key, .ok = false, .bytes = copy });
                                            staged_wake = true;
                                        } else |_| {}
                                    }
                                    active.retired = true;
                                    any_abandoned = true;
                                    continue;
                                }
                                // Completion (or the trap sink) claimed the
                                // request first. It owns teardown now; fall
                                // through so a completing stream is still
                                // tailed and can finish its final-drain wait.
                                // Its owner signals the supervisor again when
                                // finishing/retirement changes state.
                            } else if (!active.retired) {
                                next_deadline = earlier(next_deadline, grace);
                            }
                        } else if (!active.cancel_published) {
                            if (std.Io.Clock.Timestamp.compare(now, .gte, active.deadline)) {
                                active.timed_out = true;
                                self.publishCancellationLocked(active);
                                next_deadline = earlier(next_deadline, active.grace_deadline.?);
                            } else {
                                next_deadline = earlier(next_deadline, active.deadline);
                            }
                        }
                        if (active.stream) |stream| {
                            if (streams_len < streams_buffer.len) {
                                stream.in_poll = true;
                                streams_buffer[streams_len] = stream;
                                streams_len += 1;
                            }
                        }
                    }
                }
                const exit_now = self.shutting_down and !any_busy;
                const services = if (staged_wake) self.takeWakeLocked() else null;
                self.mutex.unlock(self.io);
                self.finishWake(services);
                if (exit_now) return;

                for (streams_buffer[0..streams_len]) |stream| self.pollStream(stream);

                if (streams_len > 0) {
                    const poll_deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
                        .raw = std.Io.Duration.fromMilliseconds(stream_poll_ms),
                        .clock = .awake,
                    });
                    next_deadline = earlier(next_deadline, poll_deadline);
                }
                if (any_abandoned and !self.shutting_down) {
                    const poll_deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
                        .raw = std.Io.Duration.fromMilliseconds(abandoned_poll_ms),
                        .clock = .awake,
                    });
                    next_deadline = earlier(next_deadline, poll_deadline);
                }
                if (next_deadline) |deadline| {
                    self.supervisor_event.waitTimeout(self.io, .{ .deadline = deadline }) catch {};
                } else {
                    self.supervisor_event.waitUncancelable(self.io);
                }
            }
        }

        fn earlier(current: ?std.Io.Clock.Timestamp, candidate: std.Io.Clock.Timestamp) std.Io.Clock.Timestamp {
            const existing = current orelse return candidate;
            return if (std.Io.Clock.Timestamp.compare(candidate, .lt, existing)) candidate else existing;
        }

        /// Publish the cooperative token (marker file) and start the grace
        /// clock. Pool mutex held. A request whose marker path is not yet
        /// attached writes the marker when the path arrives.
        fn publishCancellationLocked(self: *Self, active: *Active) void {
            if (!active.cancel_published) {
                active.cancel_published = true;
                active.grace_deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{
                    .raw = std.Io.Duration.fromMilliseconds(cooperative_cancel_grace_ms),
                    .clock = .awake,
                });
                if (active.cancel_path) |path| {
                    if (std.Io.Dir.cwd().createFile(self.io, path, .{ .truncate = true })) |file| {
                        file.close(self.io);
                    } else |_| {}
                }
            }
            self.supervisor_event.set(self.io);
        }

        // -------------------------------------------------------- streams

        fn createStream(self: *Self, request_id: u32, channel: effects.ChannelHandle) ?*Stream {
            const path = self.streamPath(request_id) catch return null;
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            const stream = self.allocator.create(Stream) catch {
                self.allocator.free(path);
                return null;
            };
            stream.* = .{ .path = path, .channel = channel };
            return stream;
        }

        /// Worker side of stream completion: hand the relay to the
        /// supervisor for the final drain and wait for it, so every chunk
        /// precedes the typed terminal. The supervisor keeps running while
        /// any worker is busy, including through shutdown, so the wait is
        /// bounded.
        fn finishStream(self: *Self, stream: *Stream) void {
            self.mutex.lockUncancelable(self.io);
            stream.finishing = true;
            self.supervisor_event.set(self.io);
            self.mutex.unlock(self.io);
            stream.drained.waitUncancelable(self.io);
        }

        /// Release a stream whose owner retired: destroy it immediately, or
        /// mark it orphaned when the supervisor is mid-poll and let the
        /// supervisor destroy it as its poll completes. Pool mutex held.
        fn releaseStreamLocked(self: *Self, stream: *Stream) void {
            if (stream.in_poll) {
                stream.orphaned = true;
                return;
            }
            self.destroyStreamLocked(stream);
        }

        fn destroyStreamLocked(self: *Self, stream: *Stream) void {
            if (stream.file) |file| file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, stream.path) catch {};
            self.allocator.free(stream.path);
            stream.pending.deinit(self.allocator);
            self.allocator.destroy(stream);
        }

        /// Tail one relay file: read whatever new frames the operation has
        /// appended and post each to the external channel. Runs on the
        /// supervisor thread with the pool mutex released; the `in_poll`
        /// mark keeps the stream alive until this poll completes.
        fn pollStream(self: *Self, stream: *Stream) void {
            self.readStreamFrames(stream);
            self.mutex.lockUncancelable(self.io);
            const finished = stream.finishing;
            self.mutex.unlock(self.io);
            if (finished) {
                // The operation returned before `finishing` was set, so
                // every chunk byte is already in the file: one more read
                // pass makes the drain complete.
                self.readStreamFrames(stream);
            }
            self.mutex.lockUncancelable(self.io);
            stream.in_poll = false;
            if (stream.orphaned) {
                self.destroyStreamLocked(stream);
                self.mutex.unlock(self.io);
                return;
            }
            if (finished) stream.finishing = false;
            self.mutex.unlock(self.io);
            if (finished) stream.drained.set(self.io);
        }

        fn readStreamFrames(self: *Self, stream: *Stream) void {
            if (stream.file == null) {
                stream.file = std.Io.Dir.cwd().openFile(self.io, stream.path, .{}) catch null;
            }
            const file = stream.file orelse return;
            var buffer: [16 * 1024]u8 = undefined;
            read: while (true) {
                const slices: [1][]u8 = .{&buffer};
                const count = file.readStreaming(self.io, &slices) catch break :read;
                if (count == 0) break :read;
                stream.pending.appendSlice(self.allocator, buffer[0..count]) catch break :read;
            }
            while (stream.pending.items.len >= 4) {
                const frame_len = readU32(stream.pending.items, 0);
                if (stream.pending.items.len < 4 + frame_len) break;
                _ = stream.channel.post(stream.pending.items[4 .. 4 + frame_len]);
                stream.pending.replaceRange(self.allocator, 0, 4 + frame_len, &.{}) catch break;
            }
        }

        // ---------------------------------------------------------- fence

        /// The pairing check between the linked archive and this registry:
        /// the facade's fingerprint export against the registry's constant.
        /// A mismatch rejects every request rather than dispatching under a
        /// skewed contract — the in-process analog of the child's hello
        /// fence.
        fn verifyFingerprint(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            if (self.fingerprint_state != .unchecked) {
                self.mutex.unlock(self.io);
                return;
            }
            self.mutex.unlock(self.io);
            var ptr: [*]const u8 = undefined;
            var len: usize = 0;
            abi.contract_fingerprint_fn(&ptr, &len);
            const matches = len == Registry.contract_fingerprint.len and
                std.mem.eql(u8, ptr[0..len], &Registry.contract_fingerprint);
            self.mutex.lockUncancelable(self.io);
            if (self.fingerprint_state == .unchecked) {
                self.fingerprint_state = if (matches) .ok else .rejected;
            }
            self.mutex.unlock(self.io);
        }

        // ---------------------------------------------------------- paths

        fn cancellationPath(self: *Self, request_id: u32) ![]u8 {
            return self.markerPath("cancel", request_id);
        }

        fn streamPath(self: *Self, request_id: u32) ![]u8 {
            return self.markerPath("stream", request_id);
        }

        fn markerPath(self: *Self, comptime kind: []const u8, request_id: u32) ![]u8 {
            const root = if (self.cwd.len > 0) self.cwd else ".";
            const absolute_root = if (std.fs.path.isAbsolute(root))
                null
            else
                try std.Io.Dir.cwd().realPathFileAlloc(self.io, root, self.allocator);
            defer if (absolute_root) |path| self.allocator.free(path);
            const resolved_root = absolute_root orelse root;
            const pid: u32 = switch (builtin.os.tag) {
                .windows => std.os.windows.GetCurrentProcessId(),
                .wasi, .freestanding, .emscripten => 0,
                else => @intCast(@max(0, std.posix.system.getpid())),
            };
            return std.fmt.allocPrint(
                self.allocator,
                "{s}{c}.native-service-" ++ kind ++ "-{d}-{x}-{d}",
                .{ resolved_root, std.fs.path.sep, pid, @intFromPtr(self), request_id },
            );
        }
    };
}

/// One trap error payload: the structured trap-teaching message's text
/// field as JSON. The encoding is [0x01]text[0x1F]code[0x1F]symbol
/// ([0x1F]remediation); a plain message rides whole.
fn trapErrorJson(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var text = message;
    var code: []const u8 = "";
    if (text.len > 0 and text[0] == 0x01) {
        text = text[1..];
        if (std.mem.indexOfScalar(u8, text, 0x1f)) |sep| {
            const rest = text[sep + 1 ..];
            text = text[0..sep];
            code = if (std.mem.indexOfScalar(u8, rest, 0x1f)) |next| rest[0..next] else rest;
        }
    }
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"kind\":\"service_trap\",\"message\":");
    try appendJsonString(w, std.mem.trimEnd(u8, text, "\n"));
    if (code.len > 0) {
        try w.writeAll(",\"code\":");
        try appendJsonString(w, code);
    }
    try w.writeAll("}");
    return out.toOwnedSlice();
}

fn appendJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (byte < 0x20)
            try w.print("\\u00{x:0>2}", .{byte})
        else
            try w.writeByte(byte),
    };
    try w.writeByte('"');
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

fn readU64(bytes: []const u8, at: usize) u64 {
    return @as(u64, readU32(bytes, at)) | (@as(u64, readU32(bytes, at + 4)) << 32);
}

test "trap errors carry the structured teaching's text and code as JSON" {
    const structured = "\x01scriptc: RangeError: pop() on an empty array\n\x1fSC4014\x1fnsc_svc_dispatch";
    const encoded = try trapErrorJson(std.testing.allocator, structured);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"service_trap\",\"message\":\"scriptc: RangeError: pop() on an empty array\",\"code\":\"SC4014\"}",
        encoded,
    );

    const plain = try trapErrorJson(std.testing.allocator, "plain \"quoted\" failure");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings(
        "{\"kind\":\"service_trap\",\"message\":\"plain \\\"quoted\\\" failure\"}",
        plain,
    );
}

test "pool defaults stay within the documented bounds" {
    const workers = defaultWorkerCount();
    try std.testing.expect(workers >= 1 and workers <= 4);
    try std.testing.expectEqual(service_host.default_request_timeout_ms, default_request_timeout_ms);
    try std.testing.expectEqual(service_host.cooperative_cancel_grace_ms, cooperative_cancel_grace_ms);
}
