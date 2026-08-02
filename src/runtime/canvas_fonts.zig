//! Runtime canvas font registry: TrueType faces apps register at startup
//! under a caller-chosen `FontId` (the image-registry spirit — store the
//! id in the model/tokens, no handles to leak) and reference from
//! everywhere a font id rides: `TypographyTokenOverrides.font_id` /
//! `mono_font_id`, draw commands, glyph atlas keys, and render
//! fingerprints.
//!
//! Validation is loud and registration-time only: the bytes must parse as
//! a TrueType face (`canvas.font_ttf.Face.parse`) under the registry
//! bounds — including the glyph-outline budget gate on the face's
//! declared `maxp` maxima (`error.FontExceedsGlyphBudgets` when a face
//! declares denser glyphs than `canvas.font_ttf`'s budgets; the budgets
//! are sized from real CJK faces, so this refuses only outliers) — or
//! registration fails with a recoverable error. A registered id
//! therefore ALWAYS resolves at render time, and the only per-glyph
//! fallback is the same notdef block built-in faces use for codepoints a
//! face does not cover. `canvas.font_ttf.parseFailureReason` turns a
//! rejected file into a teaching sentence, and
//! `canvas.font_ttf.declaredGlyphMaxima` names a budget-refused face's
//! declared numbers, for callers that know the file's name (UiApp's
//! `fonts` option uses both).
//!
//! Both renderers resolve registered ids exactly like built-ins:
//! - The frame planner threads the registered set into
//!   `CanvasFrameOptions.font_resources` for every view, so the CPU
//!   reference paths (presentation, screenshots, goldens) ink the
//!   registered outlines.
//! - Platforms that measure and draw text host-side (`measure_text_fn`
//!   present — macOS) receive the raw bytes through
//!   `registerGpuSurfaceFont` at registration time, before any layout can
//!   measure the id, so host measurement and packet text drawing resolve
//!   the same face. A host that measures text but cannot learn a
//!   registered face fails the registration loudly
//!   (`error.FontHostRegistrationUnsupported`) instead of silently
//!   substituting the default family.
//! - Platforms without host-side text measure through the runtime's
//!   font-aware provider: registered ids charge the parsed face's own
//!   `cmap`/`hmtx` advances (`canvas.estimateTextWidthForFace`), built-in
//!   ids keep the deterministic estimator — measured layout and reference
//!   ink stay in lockstep.
//!
//! Registration is permanent for the runtime's lifetime: glyph atlas and
//! text-layout caches key glyphs by (font id, glyph id) with no content
//! fingerprint, so replacing an id's bytes would serve stale glyphs from
//! retained caches. Re-using a registered id fails with
//! `error.FontIdInUse`; there is deliberately no unregister.
//!
//! Byte storage is on-demand: registration copies the file into an
//! exact-size heap allocation from the runtime's init-frozen
//! `owned_allocator` (captured from `Options.allocator`), so
//! a runtime with no registered fonts carries zero font bytes (embedding
//! hosts create a Runtime per surface — a reservation-shaped pool at the
//! 24 MiB CJK bound would embed 192 MiB in every one). Permanence makes
//! ownership trivial: the bytes live until `Runtime.deinit`, and the
//! parsed `Face` views, the gpu-surface host copy, and the measure
//! provider all borrow them for exactly that lifetime.
//!
//! Capacities follow `canvas_limits` as VALIDATION bounds, not storage
//! reservations: at most `max_registered_canvas_fonts` registrations of
//! at most `max_registered_canvas_font_bytes` each, overflow is
//! `error.FontRegistryFull` / `error.FontTooLarge` — never silent.

const std = @import("std");
const canvas = @import("canvas");
const canvas_frame_module = @import("canvas_frame.zig");
const canvas_limits = @import("canvas_limits.zig");

pub const max_registered_canvas_fonts = canvas_limits.max_registered_canvas_fonts;
pub const max_registered_canvas_font_bytes = canvas_limits.max_registered_canvas_font_bytes;

/// One registered font: its id and the exact-size heap copy of its
/// TrueType bytes (owned by the runtime's init-frozen `owned_allocator`,
/// freed at `Runtime.deinit`); the parsed face view lives in the parallel
/// face array at the same index and points into these bytes.
pub const CanvasFontEntry = struct {
    id: canvas.FontId = 0,
    bytes: []const u8 = &.{},
    /// The host-side unregistration owner — the platform's
    /// `unregister_gpu_surface_font_fn` and its context, captured from
    /// the services in effect when THIS registration was pushed to the
    /// host. Captured precisely because `Runtime.options` is public and
    /// mutable while registration and teardown can be a whole runtime
    /// lifetime apart: the registration must be returned to the host
    /// that received it, so `Runtime.deinit` unregisters through this
    /// captured pair and mutating `options.platform` on a live runtime
    /// retargets nothing (the `owned_allocator` identity-freeze
    /// doctrine, applied to the host seam — a deinit that read the live
    /// options would unregister against whatever platform the option
    /// points at by teardown time, stranding the original host's
    /// descriptor and caches). Null when the platform at registration
    /// time had no unregister seam: it retained nothing to return.
    host_unregister_fn: ?*const fn (context: ?*anyopaque, id: u64, token: u64) anyerror!void = null,
    host_unregister_context: ?*anyopaque = null,
    /// The host's ownership token for THIS registration, returned by
    /// `registerGpuSurfaceFont` and passed back through the owner above
    /// at deinit. Host font state is per-process while ids are only
    /// permanent per-runtime, so a later runtime may re-register this
    /// entry's id (last wins, the documented lifecycle); the host
    /// removes an id's state only while its current registration still
    /// carries the presented token, which keeps an older runtime's
    /// deinit from tearing down a newer runtime's live face. 0 when the
    /// platform returned no token (a stateless accept, or no register
    /// seam at all): nothing was installed for this registration, and
    /// an unregister carrying 0 removes nothing.
    host_registration_token: u64 = 0,
};

/// Placeholder measure fn for the runtime's font-aware provider field
/// before any font registers (the provider is never handed out in that
/// state — `textMeasureProvider` returns it only when fonts exist — but
/// the field needs a well-defined default for in-place construction).
pub fn unboundCanvasFontMeasure(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
    _ = context;
    return canvas.estimateTextWidthForFont(font_id, text, size);
}

pub fn RuntimeCanvasFonts(comptime Runtime: type) type {
    return struct {
        /// Register the TrueType face in `ttf` under `id` (an app-chosen
        /// id at or above `canvas.min_registered_font_id`). The runtime
        /// copies the bytes, so the caller's buffer is free when this
        /// returns; the id resolves everywhere a `FontId` rides, for the
        /// rest of the runtime's lifetime. Startup-shaped: register before
        /// (or on) the installing frame so the first layout already
        /// measures with the face.
        ///
        /// Errors — all at registration, never at render time:
        /// `error.InvalidFontId` (id 0 is the "inherit run font"
        /// sentinel), `error.ReservedFontId` (below
        /// `canvas.min_registered_font_id` — reserved for built-in
        /// faces), `error.FontTooLarge` (over the per-font bound
        /// `canvas_limits.max_registered_canvas_font_bytes`),
        /// `error.FontIdInUse` (ids are permanent; see the module doc),
        /// `error.FontRegistryFull` (all
        /// `canvas_limits.max_registered_canvas_fonts` registrations
        /// hold other ids), `error.FontParseFailed` (not a parseable TrueType face —
        /// `canvas.font_ttf.parseFailureReason(ttf)` names what is wrong),
        /// `error.FontExceedsGlyphBudgets` (the face's `maxp` declares
        /// glyphs denser than `canvas.font_ttf`'s outline budgets, so its
        /// densest glyphs could not render as outlines —
        /// `canvas.font_ttf.declaredGlyphMaxima(ttf)` names the declared
        /// maxima), `error.FontHostRegistrationUnsupported` (the platform measures
        /// and draws text host-side but has no font registration seam, so
        /// the face could not be honored pixel-honestly).
        pub fn registerCanvasFont(self: *Runtime, id: canvas.FontId, ttf: []const u8) anyerror!void {
            if (id == 0) return error.InvalidFontId;
            if (id < canvas.min_registered_font_id) return error.ReservedFontId;
            if (ttf.len > max_registered_canvas_font_bytes) return error.FontTooLarge;
            if (findCanvasFontIndex(self, id) != null) return error.FontIdInUse;
            if (self.canvas_font_count >= max_registered_canvas_fonts) return error.FontRegistryFull;

            const index = self.canvas_font_count;
            // Exact-size heap copy, owned by the runtime until deinit
            // (registration is permanent — no unregister — so this is
            // the only allocation and the only free the registry ever
            // makes). On-demand allocation instead of a slot pool keeps
            // a fontless Runtime at zero font bytes.
            // Alloc and every free (the refusal paths below, the deinit
            // free) go through the runtime's init-frozen ownership
            // allocator: `options.allocator` is publicly mutable and a
            // swap between registration and teardown must never split
            // the alloc/free identity.
            const pooled = try self.owned_allocator.alloc(u8, ttf.len);
            errdefer self.owned_allocator.free(pooled);
            @memcpy(pooled, ttf);
            const face = canvas.font_ttf.Face.parse(pooled) catch |err| switch (err) {
                // The registration-time glyph-budget gate: refusing the
                // face here (loudly, with its declared numbers available
                // via `declaredGlyphMaxima`) is what keeps render-time
                // glyph resolution total for registered ids.
                error.FontGlyphTooComplex => return error.FontExceedsGlyphBudgets,
                else => return error.FontParseFailed,
            };

            // Host sync BEFORE committing the slot: platforms with
            // host-side text (measure_text_fn) must learn the face or the
            // whole registration fails — a committed id the host cannot
            // resolve would measure and draw as the default family, the
            // exact silent fallback this seam forbids. Platforms without
            // host-side text may lack the seam (`UnsupportedService`):
            // the engine measures with the parsed face and inks it
            // through the reference renderer, so nothing is lost. ONE
            // services read serves both the sync and the captured return
            // path below, so the host that hears the registration is the
            // host the entry's unregister owner names.
            const services = self.options.platform.services;
            // The returned token is the host's ownership handle for THIS
            // registration (0 when the host retained nothing); it rides
            // the entry beside the captured owner so deinit can tell the
            // host which registration to remove — see
            // `CanvasFontEntry.host_registration_token`.
            const host_token: u64 = services.registerGpuSurfaceFont(.{ .id = id, .ttf = pooled }) catch |err| switch (err) {
                error.UnsupportedService => blk: {
                    if (services.measure_text_fn != null) return error.FontHostRegistrationUnsupported;
                    break :blk 0;
                },
                else => return err,
            };

            self.canvas_font_faces[index] = face;
            // The entry carries its own host unregistration owner,
            // captured now (see `CanvasFontEntry.host_unregister_fn`):
            // `options.platform` is publicly mutable, and the teardown
            // return must land on the host that received this
            // registration, never on whatever platform the option holds
            // by `Runtime.deinit` time.
            self.canvas_font_entries[index] = .{
                .id = id,
                .bytes = pooled,
                .host_unregister_fn = services.unregister_gpu_surface_font_fn,
                .host_unregister_context = services.context,
                .host_registration_token = host_token,
            };
            self.canvas_font_count = index + 1;
            // Bind the font-aware measure provider on first registration.
            // The runtime address is stable from here on (registration
            // happens through a settled *Runtime), so the provider
            // pointer stamped into tokens stays valid for the runtime's
            // lifetime, matching the platform provider's contract.
            if (index == 0) {
                self.canvas_font_measure_provider = .{
                    .context = self,
                    .measure_fn = canvasFontMeasure,
                    .measure_advances_fn = canvasFontMeasureAdvances,
                };
            }
            noteCanvasFontsChanged(self);
        }

        /// The registered set as the `ReferenceFont` slice both renderers
        /// consume, rebuilt into runtime scratch (faces borrow each
        /// entry's heap-owned bytes; with no unregister they stay valid
        /// for the runtime's lifetime).
        pub fn registeredCanvasFonts(self: *Runtime) []const canvas.ReferenceFont {
            for (self.canvas_font_entries[0..self.canvas_font_count], 0..) |entry, index| {
                self.canvas_font_resources_scratch[index] = .{
                    .id = entry.id,
                    .face = &self.canvas_font_faces[index],
                };
            }
            return self.canvas_font_resources_scratch[0..self.canvas_font_count];
        }

        /// The parsed face registered under `id`, or null when `id` is
        /// not registered.
        pub fn registeredCanvasFontFace(self: *const Runtime, id: canvas.FontId) ?*const canvas.font_ttf.Face {
            const index = findCanvasFontIndex(self, id) orelse return null;
            return &self.canvas_font_faces[index];
        }

        pub fn registeredCanvasFontCount(self: *const Runtime) usize {
            return self.canvas_font_count;
        }

        /// Measure fn for the runtime's font-aware provider (installed on
        /// platforms without host-side text measurement): registered ids
        /// charge the parsed face's own advances so measured layout
        /// matches the outlines the reference renderer inks; every other
        /// id keeps the deterministic estimator, bit-identical to the
        /// provider-less path.
        fn canvasFontMeasure(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
            const runtime: *Runtime = @ptrCast(@alignCast(context));
            if (findCanvasFontIndex(runtime, font_id)) |index| {
                return canvas.estimateTextWidthForFace(&runtime.canvas_font_faces[index], text, size);
            }
            return canvas.estimateTextWidthForFont(font_id, text, size);
        }

        /// Batched twin of `canvasFontMeasure`: per-cluster advances from
        /// the same face (or estimator) tables, cluster advance at the
        /// lead byte and 0 at continuation bytes. Both underlying width
        /// functions are plain per-cluster sums, so a slice's width is
        /// exactly the sum of these advances — line breaks from the
        /// batched path are bit-identical to the per-prefix path, and the
        /// registered-face provider drops from O(L²) cluster walks per
        /// line to O(L) per run like the host providers.
        fn canvasFontMeasureAdvances(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8, advances: []f32) bool {
            const runtime: *Runtime = @ptrCast(@alignCast(context));
            const face = if (findCanvasFontIndex(runtime, font_id)) |index| &runtime.canvas_font_faces[index] else null;
            var index: usize = 0;
            while (index < text.len) {
                const next = @min(text.len, index + canvas.utf8SequenceLength(text[index]));
                advances[index] = if (face) |value|
                    canvas.estimateTextWidthForFace(value, text[index..next], size)
                else
                    canvas.estimateTextAdvanceForBytes(font_id, text[index..next], size);
                @memset(advances[index + 1 .. next], 0);
                index = next;
            }
            return true;
        }

        fn findCanvasFontIndex(self: *const Runtime, id: canvas.FontId) ?usize {
            for (self.canvas_font_entries[0..self.canvas_font_count], 0..) |entry, index| {
                if (entry.id == id) return index;
            }
            return null;
        }

        /// A face joined the registry: force every gpu_surface view to
        /// re-render its next frame (text referencing the id may already
        /// be retained) and request frames so the repaint is not gated on
        /// other input — the image-registry choreography. Re-rendering
        /// alone re-inks RETAINED geometry; installed UiApps complete the
        /// late-registration story by comparing the registered count on
        /// each presented frame and rebuilding every surface so layout
        /// re-measures with the new face (ui_app.zig,
        /// `rebuildForRegisteredFonts`).
        fn noteCanvasFontsChanged(self: *Runtime) void {
            // A new face changes what the measurement seam answers for
            // its id (host providers just learned the face; the engine
            // provider now charges its real advances): invalidate every
            // cached advance batch and retained wrap result.
            canvas.bumpTextMeasureGeneration();
            const frame_methods = canvas_frame_module.RuntimeCanvasFrames(Runtime);
            for (self.views[0..self.view_count], 0..) |*view, index| {
                if (!view.open or view.kind != .gpu_surface) continue;
                view.presented_canvas_valid = false;
                self.invalidateFor(.state, view.frame);
                frame_methods.requestCanvasFrameForView(self, index) catch {};
            }
        }
    };
}
