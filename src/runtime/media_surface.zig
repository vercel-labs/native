//! The media-surface texture channel: the dynamic-texture primitive
//! under video playback, camera preview, and external renderers (mpv).
//!
//! A `media_surface` widget binds a model-owned u64 SURFACE id (markup
//! `<media-surface surface={id}>`, builder `ui.mediaSurface(.{ .image =
//! id })`). A producer — typically living on its own thread: a decoder,
//! a capture pipeline, an engine's render loop — acquires a handle for
//! that id (`Runtime.acquireMediaSurfaceProducer`) and pushes
//! tightly-packed straight-alpha RGBA8 frames. Pushes are LATEST-WINS:
//! an unpresented staged frame is replaced, never queued, so a fast
//! producer can never build a backlog. The compositor's presented-frame
//! clock paces consumption: staged frames are adopted at frame dispatch
//! (`adoptMediaSurfaceFrames`), and adoption is damage-tracked — a
//! frame whose content fingerprint matches the adopted texture costs no
//! copy and no invalidation, and repeat pushes of identical bytes
//! short-circuit at the push boundary too.
//!
//! THREAD CONTRACT. `acquireMediaSurfaceProducer` is loop-thread-only
//! (it touches the runtime); `MediaSurfaceProducer.pushFrame` and
//! `.release` are callable from ANY thread. The cross-thread half is a
//! mailbox of process-lifetime slots (the effects executor's storage
//! doctrine): everything a producer thread can ever reach — the slot
//! struct and its staging buffer — is allocated from the process-lived
//! page allocator at first claim and NEVER freed, holds no pointer to
//! the runtime or the platform, and is fenced by a per-slot spin mutex
//! plus owner-tag/generation stamps. A producer that outlives its view,
//! its runtime, or the whole app therefore cannot use-after-free by
//! construction: a push after teardown lands in inert process-lived
//! memory that no loop ever adopts again.
//!
//! WAKE CONTRACT. Adoption rides the compositor's frame clock (the
//! 60 Hz host timer, a prompt requested frame, a test-driven frame
//! event) — but native hosts are demand-driven one-shot schedulers, so
//! an IDLE app has no clock at all: a 24/30 fps video in an app nobody
//! touches would stall the moment the scheduler slept, and a producer
//! that starts after the last frame would never be adopted. A push that
//! stages NEW bytes therefore requests one frame itself, through the
//! platform's thread-safe cross-thread frame request (`PlatformServices
//! .request_frame_fn` — the automation arrival watcher's wake path;
//! requests coalesce at the platform AND at the slot's `pending` flag,
//! so a burst of pushes costs at most one). The binding lives in the
//! slot's `wake` half behind its OWN spin mutex, and the platform call
//! happens UNDER that mutex — the effects executor's abandon-fence
//! doctrine: the runtime disarms the binding at teardown under the same
//! mutex (`disarmMediaSurfaceWakes`, called from the run loop's exit
//! path and `Runtime.deinit`/TestHarness destroy), so after disarm
//! returns no producer is inside the call and none can start one — a
//! stale handle's push can never wake a dead host. Damage-skipped
//! pushes and pushes through a released/stale generation wake nothing.
//!
//! FORMAT AXIS. Slice 0 is tightly-packed RGBA8 only. The push call is
//! shaped so later formats (BGRA, planar YUV, zero-copy GPU handles)
//! can join as new entry points without disturbing this one.
//!
//! REPLAY POLICY. Texture CONTENTS are presentation chrome: adopted
//! textures enter the frame pipeline as `presentation_only` image
//! resources, so the deterministic reference renderer (goldens,
//! screenshots, replay pixel marks) never sees them — it renders the
//! surface's id-derived placeholder — and session fingerprints (hashed
//! over the a11y tree) never contained them to begin with. A recorded
//! session replays fingerprint-identical with NO producer attached.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("canvas");
const canvas_limits = @import("canvas_limits.zig");
const runtime_canvas_images = @import("canvas_images.zig");

pub const max_media_surface_channels = canvas_limits.max_media_surface_channels;
pub const max_media_surface_pixel_bytes = canvas_limits.max_media_surface_pixel_bytes;

/// Process-lifetime allocator for everything a producer thread can
/// still reach after its runtime died: page_allocator is process-lived
/// by construction (no deinit), thread-safe, and available on every
/// target — the effects executor's storage doctrine exactly.
const process_allocator = std.heap.page_allocator;

/// Atomic accessors for the slot ownership triple the reclaim scan
/// reads WITHOUT a lock (`mediaSurfaceHasActiveSlot`): on threaded
/// targets a plain access racing an atomic one is a data race in the
/// Zig/LLVM memory model, so both sides go through these. On
/// single-threaded targets (the docs wasm preview's
/// wasm32-freestanding, which also lacks 64-bit atomics) there is no
/// second thread to race and the plain access is exact.
inline fn ownershipStore(comptime T: type, ptr: *T, value: T, comptime ordering: std.builtin.AtomicOrder) void {
    if (builtin.single_threaded) {
        ptr.* = value;
    } else {
        @atomicStore(T, ptr, value, ordering);
    }
}

inline fn ownershipLoad(comptime T: type, ptr: *const T, comptime ordering: std.builtin.AtomicOrder) T {
    if (builtin.single_threaded) return ptr.*;
    return @atomicLoad(T, ptr, ordering);
}

/// Debug-only lock-discipline sentinel: how many media-surface spin
/// mutexes (slot data or wake) THIS thread currently holds. The
/// invariant `lock` asserts — a thread never holds two — is what makes
/// every spin mutex in this module deadlock-free BY CONSTRUCTION: with
/// no nesting there is no lock order to violate, on one runtime or
/// across several adopting concurrently. The invariant died once
/// exactly here: the retained-entry reclaim scan locked OTHER slots
/// while the adoption loop held the drained one — self-deadlock on one
/// runtime (the spin mutex is not reentrant), ABBA between two runtimes
/// draining different slots and scanning each other's. The scan now
/// snapshots ownership lock-free (`mediaSurfaceHasActiveSlot`), and
/// this assertion turns any reintroduction of nested slot locking into
/// an immediate loud failure in every Debug test run instead of a
/// stress-timing deadlock.
threadlocal var debug_held_media_surface_mutexes: usize = 0;

/// Tiny spin lock over `std.atomic.Mutex` (0.16 has no blocking thread
/// mutex outside `Io`). Guarded sections are bounded: a memcpy of at
/// most one staged frame (data half) or one enqueue-only platform call
/// (wake half); a colliding push spins for one of those, never blocks
/// on I/O. In Debug builds, `lock` asserts the module's no-nesting
/// discipline (see `debug_held_media_surface_mutexes`).
const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        if (std.debug.runtime_safety) {
            std.debug.assert(debug_held_media_surface_mutexes == 0);
        }
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
        if (std.debug.runtime_safety) debug_held_media_surface_mutexes += 1;
    }

    fn unlock(self: *SpinMutex) void {
        if (std.debug.runtime_safety) debug_held_media_surface_mutexes -= 1;
        self.inner.unlock();
    }
};

/// The producer-to-compositor wake binding, one per slot, guarded by
/// its OWN spin mutex — never the slot's data mutex, whose guarded
/// sections must stay bounded memcpys (the thread contract): the wake
/// path calls into the platform, and holding the data mutex across
/// that call would make every colliding push spin behind a host call.
///
/// Ownership story (the effects executor's abandon-fence doctrine,
/// matched exactly): `request_frame_fn`/`context` point into the
/// claiming runtime's PLATFORM host — the same pair the automation
/// arrival watcher carries to its own thread — and the platform call
/// happens UNDER `mutex`. Teardown disarms under the same mutex before
/// the host dies (`disarmMediaSurfaceWakes`, from the run loop's exit
/// defer, `TestHarness.destroy`, and the embed host's destroy), so
/// after disarm returns no producer thread is inside the call and none
/// can start one. The implementations behind `request_frame_fn` are
/// enqueue-only (macOS: main-queue dispatch, GTK: `g_idle_add`, Win32:
/// `PostMessage`, null platform: an atomic counter), so the section
/// stays bounded — a colliding push spins for one enqueue, never I/O.
const MediaSurfaceWake = struct {
    mutex: SpinMutex = .{},
    /// The claim generation this binding serves (see the slot's
    /// `generation`): a push wakes only when its handle's generation
    /// matches, so a stale producer of a released — or re-claimed —
    /// slot can never wake the slot's new owner spuriously.
    generation: u64 = 0,
    /// The arming runtime's process-unique tag, for the teardown
    /// disarm sweep (`disarmMediaSurfaceWakes` disarms exactly the
    /// bindings its runtime armed).
    owner_tag: u64 = 0,
    /// The platform's thread-safe cross-thread frame request, or null
    /// when the host has none (then pacing stays purely demand-driven,
    /// the pre-wake behavior) or the binding is disarmed.
    request_frame_fn: ?*const fn (context: ?*anyopaque) anyerror!void = null,
    context: ?*anyopaque = null,
    /// A requested frame has not yet reached adoption: the wake
    /// coalescer. Set when a push requests a frame, cleared by
    /// `adoptMediaSurfaceFrames` BEFORE it samples the slot, so a burst
    /// of pushes costs at most one platform call and a push landing
    /// after the clear requests the next frame itself.
    pending: bool = false,
};

/// One process-lived mailbox slot: the ONLY memory a producer handle
/// ever touches. Claimed by a runtime at acquire (owner tag + fresh
/// generation), staged into by producer pushes, drained by loop-thread
/// adoption, reusable after release. The staging buffer is allocated
/// once and kept for the life of the process, so a stale handle's push
/// can never touch freed memory — it is fenced off by the generation
/// check instead.
const MediaSurfaceSlot = struct {
    mutex: SpinMutex = .{},
    /// The claiming runtime's process-unique tag (see
    /// `media_surface_runtime_tag`); adoption scans match on it, so a
    /// recycled runtime address can never inherit a dead runtime's
    /// frames. 0 = never claimed.
    owner_tag: u64 = 0,
    surface_id: u64 = 0,
    /// Bumped on every claim AND every release: a handle carries the
    /// claim's generation, so pushes through a released handle (or a
    /// copy of one) are refused loudly instead of landing in a slot
    /// some other producer now owns.
    generation: u64 = 0,
    /// Claimed and not yet released.
    active: bool = false,
    /// Process-lived staging buffer (capacity
    /// `max_media_surface_pixel_bytes`), allocated at first claim,
    /// never freed.
    staging: []u8 = &.{},
    /// A staged frame awaits adoption (latest-wins: a new push
    /// overwrites it in place).
    staged: bool = false,
    staged_width: usize = 0,
    staged_height: usize = 0,
    staged_byte_len: usize = 0,
    staged_fingerprint: u64 = 0,
    /// Fingerprint of the most recent push (staged or already adopted):
    /// the push-boundary damage short-circuit — identical bytes pushed
    /// again cost one hash, no copy, no staging, no invalidation.
    last_push_fingerprint: u64 = 0,
    /// The idle-compositor wake binding (its own mutex; see
    /// `MediaSurfaceWake` for the ownership story).
    wake: MediaSurfaceWake = .{},
};

var media_surface_slots: [max_media_surface_channels]MediaSurfaceSlot =
    [_]MediaSurfaceSlot{.{}} ** max_media_surface_channels;

/// Process-wide monotonic runtime tags: unique per runtime instance for
/// the life of the process, so slot ownership survives allocator
/// address reuse across test harnesses.
var media_surface_tag_counter = std.atomic.Value(u64).init(1);

/// Adopted-texture entry on the RUNTIME (the loop-thread half); pixels
/// live in the runtime's lazily allocated per-entry buffer at the same
/// index (`media_surface_pixels`, one frame-budget block at first
/// adoption from the runtime's `owned_allocator` — the ownership
/// identity frozen from `Options.allocator` at init — freed by
/// `Runtime.deinit`).
pub const MediaSurfaceTextureEntry = struct {
    surface_id: u64 = 0,
    width: usize = 0,
    height: usize = 0,
    byte_len: usize = 0,
    /// Content fingerprint of the adopted pixels (never 0 once
    /// adopted): the adoption damage gate, and the precomputed
    /// `ReferenceImage.content_fingerprint` the GPU cache planner keys
    /// uploads by — so a pushed frame is hashed exactly once, on the
    /// producer's thread.
    fingerprint: u64 = 0,
};

/// Content fingerprint of a frame: dims + pixel bytes, computed on the
/// PRODUCER's thread at push. Mapped away from 0 so 0 stays the "no
/// content" sentinel everywhere.
fn frameFingerprint(width: usize, height: usize, rgba8: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0x6d65646961); // "media"
    hasher.update(std.mem.asBytes(&width));
    hasher.update(std.mem.asBytes(&height));
    hasher.update(rgba8);
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

/// The producer handle: a slot pointer plus the claim generation.
/// Copyable; every copy dies with the generation when any copy calls
/// `release`. Both methods are callable from any thread and touch only
/// process-lived slot memory (see the module header's thread contract).
pub const MediaSurfaceProducer = struct {
    slot: *MediaSurfaceSlot,
    generation: u64,
    surface_id: u64,

    /// Stage one tightly-packed straight-alpha RGBA8 frame,
    /// latest-wins. The pixels are copied before this returns; the
    /// caller's buffer is immediately reusable. Pushing bytes identical
    /// to the previous push is free past the hash (no copy, no
    /// staging). Errors: `error.InvalidFrameDimensions` (zero or
    /// overflowing dims, or a slice that is not exactly
    /// width*height*4), `error.FrameTooLarge` (over
    /// `max_media_surface_pixel_bytes`), `error.MediaSurfaceReleased`
    /// (the handle's claim was released).
    pub fn pushFrame(self: MediaSurfaceProducer, width: usize, height: usize, rgba8: []const u8) anyerror!void {
        if (width == 0 or height == 0) return error.InvalidFrameDimensions;
        const row_len = std.math.mul(usize, width, 4) catch return error.InvalidFrameDimensions;
        const byte_len = std.math.mul(usize, row_len, height) catch return error.InvalidFrameDimensions;
        if (rgba8.len != byte_len) return error.InvalidFrameDimensions;
        if (byte_len > max_media_surface_pixel_bytes) return error.FrameTooLarge;
        const fingerprint = frameFingerprint(width, height, rgba8);

        const slot = self.slot;
        {
            slot.mutex.lock();
            defer slot.mutex.unlock();
            if (!slot.active or slot.generation != self.generation) return error.MediaSurfaceReleased;
            // Push-boundary damage short-circuit: same bytes as the last
            // push (adopted or still staged) change nothing downstream —
            // including the wake below: unchanged pixels never stir an
            // idle compositor.
            if (slot.last_push_fingerprint == fingerprint) return;
            @memcpy(slot.staging[0..byte_len], rgba8);
            slot.staged = true;
            slot.staged_width = width;
            slot.staged_height = height;
            slot.staged_byte_len = byte_len;
            slot.staged_fingerprint = fingerprint;
            slot.last_push_fingerprint = fingerprint;
        }
        // NEW bytes are staged: make sure a frame is coming to adopt
        // them, even in an idle app whose demand-driven scheduler is
        // asleep (the wake contract in the module header). Outside the
        // data mutex — the wake half has its own lock — and gated on the
        // handle's generation again, so a release/re-claim racing this
        // gap wakes nobody spuriously.
        requestWake(slot, self.generation);
    }

    /// Request ONE coalesced frame from the claiming runtime's platform
    /// loop. Any-thread; touches only the slot's process-lived wake
    /// half. The platform call runs UNDER the wake mutex (the abandon-
    /// fence doctrine — see `MediaSurfaceWake`): teardown's disarm takes
    /// the same mutex, so it can never complete while a call into the
    /// host is in flight, and after it returns no call can start.
    fn requestWake(slot: *MediaSurfaceSlot, generation: u64) void {
        const wake = &slot.wake;
        wake.mutex.lock();
        defer wake.mutex.unlock();
        // Stale claim (released, re-claimed, or torn down): no wake.
        if (wake.generation != generation) return;
        // Coalesce: a burst of pushes rides the one already-requested
        // frame; `adoptMediaSurfaceFrames` clears the flag before it
        // samples, so nothing staged after the clear is left frameless.
        if (wake.pending) return;
        // Unarmed: no thread-safe frame request on this host (or the
        // binding was disarmed) — pacing stays purely demand-driven.
        const request_fn = wake.request_frame_fn orelse return;
        // A refused request leaves `pending` clear so the next push
        // retries instead of latching a wake that never comes.
        request_fn(wake.context) catch return;
        wake.pending = true;
    }

    /// End this claim: later pushes through this handle (or any copy)
    /// report `error.MediaSurfaceReleased`, and the slot becomes
    /// claimable again. The runtime keeps the last ADOPTED texture — a
    /// paused player keeps showing its final frame — and never touches
    /// the slot after this. Idempotent.
    pub fn release(self: MediaSurfaceProducer) void {
        const slot = self.slot;
        {
            slot.mutex.lock();
            defer slot.mutex.unlock();
            if (!slot.active or slot.generation != self.generation) return;
            // Atomic for the lock-free reclaim scan's benefit, exactly
            // like the claim stores in acquire.
            ownershipStore(bool, &slot.active, false, .release);
            slot.staged = false;
            slot.last_push_fingerprint = 0;
            slot.generation +%= 1;
        }
        // The ended claim's wake binding is already fenced off by the
        // generation bump above; clearing it too keeps no host pointer
        // parked in process-lived memory longer than its claim. Taken
        // AFTER the data mutex dropped — the two locks never nest.
        const wake = &slot.wake;
        wake.mutex.lock();
        defer wake.mutex.unlock();
        if (wake.generation != self.generation) return;
        wake.generation = 0;
        wake.owner_tag = 0;
        wake.request_frame_fn = null;
        wake.context = null;
        wake.pending = false;
    }
};

pub fn RuntimeMediaSurfaces(comptime Runtime: type) type {
    return struct {
        /// Claim the texture channel for `surface_id` and hand back the
        /// producer handle. Loop-thread-only (the runtime is touched);
        /// the returned handle's methods are any-thread. One live
        /// producer per (runtime, surface id): a second acquire while
        /// one is unreleased reports `error.MediaSurfaceInUse`. Errors:
        /// `error.InvalidSurfaceId` (0, or the reserved namespace bit
        /// `canvas.media_surface_image_id_bit` set),
        /// `error.MediaSurfaceChannelsExhausted` (all
        /// `max_media_surface_channels` process-wide slots hold live
        /// claims).
        pub fn acquireMediaSurfaceProducer(self: *Runtime, surface_id: u64) anyerror!MediaSurfaceProducer {
            if (surface_id == 0 or (surface_id & canvas.media_surface_image_id_bit) != 0) {
                return error.InvalidSurfaceId;
            }
            if (self.media_surface_runtime_tag == 0) {
                self.media_surface_runtime_tag = media_surface_tag_counter.fetchAdd(1, .monotonic);
            }
            const tag = self.media_surface_runtime_tag;
            for (&media_surface_slots) |*slot| {
                slot.mutex.lock();
                const duplicate = slot.active and slot.owner_tag == tag and slot.surface_id == surface_id;
                slot.mutex.unlock();
                if (duplicate) return error.MediaSurfaceInUse;
            }
            for (&media_surface_slots) |*slot| {
                slot.mutex.lock();
                if (slot.active) {
                    slot.mutex.unlock();
                    continue;
                }
                if (slot.staging.len == 0) {
                    // First claim of this slot in the process: the
                    // staging buffer is allocated once and kept forever
                    // (process-lived, like everything a producer thread
                    // can reach).
                    slot.staging = process_allocator.alloc(u8, max_media_surface_pixel_bytes) catch {
                        slot.mutex.unlock();
                        return error.OutOfMemory;
                    };
                }
                // The ownership triple is written atomically (still
                // under the data mutex, which serializes WRITERS): the
                // reclaim scan reads it lock-free from other threads
                // (`mediaSurfaceHasActiveSlot`), and the Zig/LLVM
                // memory model calls a plain store racing an atomic
                // load a data race — atomic on both sides is what it
                // honestly supports. `active` is stored LAST so a
                // lock-free reader that sees it true sees a fully
                // stamped claim on this slot's other two fields (the
                // .release/.acquire pair orders them).
                ownershipStore(u64, &slot.owner_tag, tag, .monotonic);
                ownershipStore(u64, &slot.surface_id, surface_id, .monotonic);
                slot.generation +%= 1;
                ownershipStore(bool, &slot.active, true, .release);
                slot.staged = false;
                slot.last_push_fingerprint = 0;
                const generation = slot.generation;
                slot.mutex.unlock();
                // Arm the wake binding for this claim (after the data
                // mutex dropped — the locks never nest). No producer of
                // THIS generation exists before we return the handle,
                // so nothing races the arm; a stale generation taking
                // the wake mutex fails its generation gate.
                const services = &self.options.platform.services;
                const wake = &slot.wake;
                wake.mutex.lock();
                wake.generation = generation;
                wake.owner_tag = tag;
                wake.request_frame_fn = services.request_frame_fn;
                wake.context = if (services.request_frame_fn != null) services.context else null;
                wake.pending = false;
                wake.mutex.unlock();
                return .{ .slot = slot, .generation = generation, .surface_id = surface_id };
            }
            return error.MediaSurfaceChannelsExhausted;
        }

        /// Adopt staged producer frames, paced by the compositor: the
        /// gpu-surface frame dispatch calls this once per frame event,
        /// so a burst of pushes between presents collapses to ONE
        /// adoption of the newest frame (latest-wins made observable).
        /// Damage-tracked: a staged frame whose fingerprint matches the
        /// adopted texture is dropped without a copy or an invalidation;
        /// a changed frame is copied into the runtime's texture pool and
        /// repaints exactly like a registered-image swap.
        pub fn adoptMediaSurfaceFrames(self: *Runtime) void {
            const tag = self.media_surface_runtime_tag;
            if (tag == 0) return;
            var changed = false;
            for (&media_surface_slots) |*slot| {
                // Drain the wake coalescer BEFORE sampling the staged
                // flag: a push that staged bytes before this clear is
                // adopted by this very pass (its stage happened before
                // its wake attempt, which is what we are answering); a
                // push landing after the clear requests its own frame.
                // Either way nothing staged is ever left frameless.
                slot.wake.mutex.lock();
                if (slot.wake.owner_tag == tag) slot.wake.pending = false;
                slot.wake.mutex.unlock();

                slot.mutex.lock();
                if (!slot.active or slot.owner_tag != tag or !slot.staged) {
                    slot.mutex.unlock();
                    continue;
                }
                var reclaimed_texture_id: u64 = 0;
                const entry_index = mediaSurfaceEntryIndex(self, slot.surface_id, &reclaimed_texture_id) orelse {
                    // Registry saturated by retained textures of
                    // released channels; loud, never silent. Dropping
                    // the stage must also forget the push-boundary
                    // fingerprint (0 = no previous push, unreachable
                    // by frameFingerprint): a producer re-pushing the
                    // SAME bytes — a paused video's frame, album art —
                    // must stage and wake again so the retry can adopt
                    // once the registry heals, not die in the
                    // push-boundary dedup gate.
                    slot.staged = false;
                    slot.last_push_fingerprint = 0;
                    slot.mutex.unlock();
                    // No stderr on freestanding targets (the docs' wasm
                    // preview host): analyzing the print would drag
                    // `std.Io.Threaded` in — the session recorder's
                    // fail() guard, mirrored.
                    if (comptime builtin.os.tag != .freestanding) {
                        std.debug.print(
                            "[native-sdk] media-surface texture registry full: dropping frames for surface {d} (max_media_surface_channels = {d})\n",
                            .{ slot.surface_id, max_media_surface_channels },
                        );
                    }
                    continue;
                };
                if (self.media_surface_entries[entry_index].fingerprint == slot.staged_fingerprint) {
                    // Adoption-boundary damage short-circuit: the staged
                    // frame IS the adopted texture.
                    slot.staged = false;
                    slot.mutex.unlock();
                    continue;
                }
                if (self.media_surface_pixels[entry_index].len == 0) {
                    // The entry's texture buffer, allocated LAZILY at
                    // first adoption (one frame-budget block from the
                    // runtime's FROZEN `owned_allocator` — never the
                    // live `options.allocator`, which is public and
                    // mutable, so a swap between this allocation and
                    // `Runtime.deinit`'s free must not split the
                    // alloc/free pair across allocators): a runtime
                    // that never adopts a producer frame carries zero
                    // media-texture bytes — an embedded pool at this
                    // budget was 32 MiB in every Runtime, the
                    // registered-font-pool regression's twin.
                    self.media_surface_pixels[entry_index] = self.owned_allocator.alloc(u8, max_media_surface_pixel_bytes) catch {
                        // OOM degrades like the saturated registry:
                        // this frame drops loudly, the channel stays
                        // healthy, and the producer's NEXT PUSH stages
                        // and wakes a retry — even a byte-identical
                        // one, because the fingerprint reset below
                        // (0 = no previous push, unreachable by
                        // frameFingerprint) reopens the push-boundary
                        // dedup gate a static frame would otherwise
                        // die in. An entry reclaim that already
                        // happened still removes the reclaimed host
                        // texture (below, outside the lock) — the
                        // entry now names the new surface either way.
                        slot.staged = false;
                        slot.last_push_fingerprint = 0;
                        slot.mutex.unlock();
                        if (comptime builtin.os.tag != .freestanding) {
                            std.debug.print(
                                "[native-sdk] media-surface texture buffer allocation failed: dropping frames for surface {d} ({d} bytes requested)\n",
                                .{ slot.surface_id, max_media_surface_pixel_bytes },
                            );
                        }
                        if (reclaimed_texture_id != 0) {
                            self.options.platform.services.removeGpuSurfaceImage(reclaimed_texture_id) catch {};
                        }
                        continue;
                    };
                }
                @memcpy(
                    self.media_surface_pixels[entry_index][0..slot.staged_byte_len],
                    slot.staging[0..slot.staged_byte_len],
                );
                self.media_surface_entries[entry_index] = .{
                    .surface_id = slot.surface_id,
                    .width = slot.staged_width,
                    .height = slot.staged_height,
                    .byte_len = slot.staged_byte_len,
                    .fingerprint = slot.staged_fingerprint,
                };
                slot.staged = false;
                slot.mutex.unlock();
                // The reclaimed texture's host-side removal runs OUTSIDE
                // the slot lock: guarded sections stay bounded memcpys
                // (the thread contract), never platform calls a pushing
                // producer would spin behind.
                if (reclaimed_texture_id != 0) {
                    self.options.platform.services.removeGpuSurfaceImage(reclaimed_texture_id) catch {};
                }
                changed = true;
            }
            if (changed) {
                // Same repaint contract as a registered-image swap: the
                // content fingerprint changed, caches re-upload, views
                // re-render their next frame.
                runtime_canvas_images.RuntimeCanvasImages(Runtime).noteCanvasImagesChanged(self);
            }
        }

        /// Disarm every wake binding this runtime armed: after this
        /// returns, no producer push can call into the runtime's
        /// platform host — not even one already past its generation
        /// check, because the platform call happens under the wake
        /// mutex this sweep takes (the abandon-fence doctrine; see
        /// `MediaSurfaceWake`). MUST run before the platform host dies
        /// when a producer may still hold an unreleased handle: the run
        /// loop's exit defer covers real apps (the same ordering that
        /// stops the automation arrival watcher), `TestHarness.destroy`
        /// covers tests, and the embed host's destroy covers embedded
        /// runtimes. Idempotent; a pending (already requested) frame is
        /// simply never answered — the host may still deliver or drop
        /// it, and an unclaimed `frame_requested` on a dying loop is a
        /// no-op, so teardown loses nothing. The slots' DATA halves are
        /// deliberately untouched: pushes keep landing in inert
        /// process-lived memory, the existing UAF-safety story.
        pub fn disarmMediaSurfaceWakes(self: *Runtime) void {
            const tag = self.media_surface_runtime_tag;
            if (tag == 0) return;
            for (&media_surface_slots) |*slot| {
                const wake = &slot.wake;
                wake.mutex.lock();
                defer wake.mutex.unlock();
                if (wake.owner_tag != tag) continue;
                wake.generation = 0;
                wake.owner_tag = 0;
                wake.request_frame_fn = null;
                wake.context = null;
                wake.pending = false;
            }
        }

        /// The adopted textures as `presentation_only` ReferenceImages
        /// (the frame planner appends them to the registered-image set):
        /// GPU/packet hosts upload and composite them, the deterministic
        /// reference renderer skips them (the placeholder policy in
        /// canvas.reference.findReferenceImage).
        pub fn adoptedMediaSurfaceTextures(self: *Runtime, scratch: []canvas.ReferenceImage) []const canvas.ReferenceImage {
            var len: usize = 0;
            for (self.media_surface_entries[0..self.media_surface_count], 0..) |entry, index| {
                if (entry.fingerprint == 0) continue;
                scratch[len] = .{
                    .id = canvas.mediaSurfaceTextureImageId(entry.surface_id),
                    .width = entry.width,
                    .height = entry.height,
                    .pixels = self.media_surface_pixels[index][0..entry.byte_len],
                    .content_fingerprint = entry.fingerprint,
                    .presentation_only = true,
                };
                len += 1;
            }
            return scratch[0..len];
        }

        /// Dimensions of the adopted texture for `surface_id`, or null
        /// while no producer frame has been adopted (the placeholder
        /// state). Test and diagnostics seam.
        pub fn adoptedMediaSurfaceTexture(self: *const Runtime, surface_id: u64) ?MediaSurfaceTextureEntry {
            for (self.media_surface_entries[0..self.media_surface_count]) |entry| {
                if (entry.surface_id == surface_id and entry.fingerprint != 0) return entry;
            }
            return null;
        }

        /// Find or claim the runtime texture entry for `surface_id`.
        /// When every entry is live, entries whose surface no longer has
        /// an ACTIVE slot on this runtime are reclaimed oldest-first (a
        /// released player's retained last frame yields to a live one).
        /// Called by the adoption loop with the drained slot's data
        /// mutex HELD — the ownership scan is lock-free (see
        /// `mediaSurfaceHasActiveSlot`) so this never takes a second
        /// slot lock. When a retained entry is reclaimed,
        /// `reclaimed_texture_id` receives its derived texture id so the
        /// CALLER can remove the host-side image after the slot lock
        /// drops (hosts that retain copied side-channel textures — the
        /// AppKit NSImage store — hold one per uploaded id, and this
        /// reclaim is the only live-runtime path where a retained
        /// texture's id leaves the resource set for good: without the
        /// removal the host store grows unboundedly as surface ids
        /// rotate, and a widget still drawing the reclaimed id could
        /// resolve the stale host image instead of its placeholder).
        fn mediaSurfaceEntryIndex(self: *Runtime, surface_id: u64, reclaimed_texture_id: *u64) ?usize {
            for (self.media_surface_entries[0..self.media_surface_count], 0..) |entry, index| {
                if (entry.surface_id == surface_id) return index;
            }
            if (self.media_surface_count < max_media_surface_channels) {
                const index = self.media_surface_count;
                self.media_surface_count += 1;
                self.media_surface_entries[index] = .{ .surface_id = surface_id };
                return index;
            }
            for (self.media_surface_entries[0..self.media_surface_count], 0..) |entry, index| {
                if (!mediaSurfaceHasActiveSlot(self.media_surface_runtime_tag, entry.surface_id)) {
                    // Mirror unregisterCanvasImage's teardown: hand the
                    // reclaimed texture id up for a best-effort host
                    // removal (hosts without the seam report
                    // UnsupportedService, hosts that never uploaded the
                    // id treat it as a no-op — both are swallowed at
                    // the call, exactly like unregister).
                    reclaimed_texture_id.* = canvas.mediaSurfaceTextureImageId(entry.surface_id);
                    self.media_surface_entries[index] = .{ .surface_id = surface_id };
                    return index;
                }
            }
            return null;
        }

        /// Whether `surface_id` has a live claim on this runtime — a
        /// LOCK-FREE snapshot, taking NO slot mutex, because the caller
        /// (the adoption loop, via `mediaSurfaceEntryIndex`) holds the
        /// drained slot's data mutex and this module's locks never
        /// nest. Both failure modes of the locking scan it replaced
        /// were real: relocking the HELD slot self-deadlocked the
        /// moment one runtime's entry table filled (the spin mutex is
        /// not reentrant), and locking OTHER slots deadlocked ABBA when
        /// two runtimes with full tables drained different slots and
        /// scanned each other's. The `SpinMutex.lock` debug assertion
        /// now enforces the no-nesting discipline module-wide.
        ///
        /// Memory-model honesty: each field is read with a monotonic
        /// atomic load (tear-free per field; the claim/release stores
        /// are atomic under the data mutex, so no access is a data
        /// race), but the TRIPLE is not a consistent snapshot — a claim
        /// or release racing this scan may show a half-stamped state.
        /// That is acceptable BY the caller's contract: this feeds only
        /// the retained-entry reclaim heuristic, whose worst raced
        /// outcomes are reclaiming a texture whose surface is being
        /// re-claimed this very instant (the next adoption of that
        /// surface re-creates the entry and re-uploads) or keeping a
        /// retained texture one extra frame (it re-qualifies on the
        /// next full-table adoption). `active` is stored last with
        /// .release on claim and checked first with .acquire here, so
        /// an observed-true claim reads its own tag and surface id,
        /// never a predecessor's torn remains.
        fn mediaSurfaceHasActiveSlot(tag: u64, surface_id: u64) bool {
            for (&media_surface_slots) |*slot| {
                if (!ownershipLoad(bool, &slot.active, .acquire)) continue;
                if (ownershipLoad(u64, &slot.owner_tag, .monotonic) != tag) continue;
                if (ownershipLoad(u64, &slot.surface_id, .monotonic) != surface_id) continue;
                return true;
            }
            return false;
        }
    };
}
