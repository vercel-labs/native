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
//! memory that no loop ever adopts again. There is no wake channel on
//! purpose — the compositor's own frame clock (the 60 Hz host timer, a
//! prompt requested frame, a test-driven frame event) is what samples
//! the mailbox, which is exactly the pacing the channel promises.
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

/// Tiny spin lock over `std.atomic.Mutex` (0.16 has no blocking thread
/// mutex outside `Io`). Guarded sections are bounded memcpys of at most
/// one staged frame; a push colliding with an adoption spins for one
/// bounded copy, never blocks on I/O.
const SpinMutex = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinMutex) void {
        while (!self.inner.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinMutex) void {
        self.inner.unlock();
    }
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
};

var media_surface_slots: [max_media_surface_channels]MediaSurfaceSlot =
    [_]MediaSurfaceSlot{.{}} ** max_media_surface_channels;

/// Process-wide monotonic runtime tags: unique per runtime instance for
/// the life of the process, so slot ownership survives allocator
/// address reuse across test harnesses.
var media_surface_tag_counter = std.atomic.Value(u64).init(1);

/// Adopted-texture entry on the RUNTIME (the loop-thread half); pixels
/// live in the runtime's slot pool at the same index.
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
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (!slot.active or slot.generation != self.generation) return error.MediaSurfaceReleased;
        // Push-boundary damage short-circuit: same bytes as the last
        // push (adopted or still staged) change nothing downstream.
        if (slot.last_push_fingerprint == fingerprint) return;
        @memcpy(slot.staging[0..byte_len], rgba8);
        slot.staged = true;
        slot.staged_width = width;
        slot.staged_height = height;
        slot.staged_byte_len = byte_len;
        slot.staged_fingerprint = fingerprint;
        slot.last_push_fingerprint = fingerprint;
    }

    /// End this claim: later pushes through this handle (or any copy)
    /// report `error.MediaSurfaceReleased`, and the slot becomes
    /// claimable again. The runtime keeps the last ADOPTED texture — a
    /// paused player keeps showing its final frame — and never touches
    /// the slot after this. Idempotent.
    pub fn release(self: MediaSurfaceProducer) void {
        const slot = self.slot;
        slot.mutex.lock();
        defer slot.mutex.unlock();
        if (!slot.active or slot.generation != self.generation) return;
        slot.active = false;
        slot.staged = false;
        slot.last_push_fingerprint = 0;
        slot.generation +%= 1;
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
                slot.owner_tag = tag;
                slot.surface_id = surface_id;
                slot.generation +%= 1;
                slot.active = true;
                slot.staged = false;
                slot.last_push_fingerprint = 0;
                const generation = slot.generation;
                slot.mutex.unlock();
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
                slot.mutex.lock();
                if (!slot.active or slot.owner_tag != tag or !slot.staged) {
                    slot.mutex.unlock();
                    continue;
                }
                const entry_index = mediaSurfaceEntryIndex(self, slot.surface_id) orelse {
                    // Registry saturated by retained textures of
                    // released channels; loud, never silent.
                    slot.staged = false;
                    slot.mutex.unlock();
                    std.debug.print(
                        "[native-sdk] media-surface texture registry full: dropping frames for surface {d} (max_media_surface_channels = {d})\n",
                        .{ slot.surface_id, max_media_surface_channels },
                    );
                    continue;
                };
                if (self.media_surface_entries[entry_index].fingerprint == slot.staged_fingerprint) {
                    // Adoption-boundary damage short-circuit: the staged
                    // frame IS the adopted texture.
                    slot.staged = false;
                    slot.mutex.unlock();
                    continue;
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
                changed = true;
            }
            if (changed) {
                // Same repaint contract as a registered-image swap: the
                // content fingerprint changed, caches re-upload, views
                // re-render their next frame.
                runtime_canvas_images.RuntimeCanvasImages(Runtime).noteCanvasImagesChanged(self);
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
        fn mediaSurfaceEntryIndex(self: *Runtime, surface_id: u64) ?usize {
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
                    self.media_surface_entries[index] = .{ .surface_id = surface_id };
                    return index;
                }
            }
            return null;
        }

        fn mediaSurfaceHasActiveSlot(tag: u64, surface_id: u64) bool {
            for (&media_surface_slots) |*slot| {
                slot.mutex.lock();
                const live = slot.active and slot.owner_tag == tag and slot.surface_id == surface_id;
                slot.mutex.unlock();
                if (live) return true;
            }
            return false;
        }
    };
}
