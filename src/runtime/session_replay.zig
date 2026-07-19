//! Session replay: drive a recorded journal back through the dispatch
//! choke point, deterministically, and verify equivalence.
//!
//! The journal is the world: the app's effects channel is armed into
//! replay mode FIRST (fake executor — `fx.spawn`/`fx.fetch`/file/
//! clipboard requests park in their slots; no process, network, file, or
//! pasteboard is ever touched), then records replay in file order —
//! effect results feed the parked requests, events dispatch through
//! `Runtime.dispatchPlatformEvent` exactly as the platform once did, and
//! checkpoints compare the live state fingerprint (and screenshot pixel
//! hashes) against what the recording saw.
//!
//! Replay hosts on the null platform: window creates, presents, and
//! timers are inert there, and every input that matters arrives from the
//! journal (timer fires and effect wakes are platform events, so they
//! ride the event stream like everything else).
//!
//! THE INIT CONTRACT (see session_journal.zig): replay re-runs the app's
//! own model init and `init_fx` rather than restoring a serialized
//! model, so both must be deterministic. A violation shows up here as
//! the first mismatching checkpoint.
//!
//! Divergence is loud and specific: a fed effect result whose key has no
//! parked request (`ReplayEffectDivergence`) means update spawned
//! different effects than the recording — usually nondeterminism outside
//! the effect boundary; a fingerprint mismatch names the event ordinal
//! and frame where state first differed.

const std = @import("std");
const canvas = @import("canvas");
const automation_protocol = @import("../automation/protocol.zig");
const core = @import("core.zig");
const journal = @import("session_journal.zig");
const session_blobs = @import("session_blobs.zig");

pub const ReplayError = error{
    /// The journal was recorded on a different platform; v1 replay is
    /// same-platform only (font metrics and scale behavior differ).
    ReplayPlatformMismatch,
    /// The journal's automation protocol version differs from this
    /// build's — the recording binary and this one are skewed.
    ReplayProtocolMismatch,
    /// A journaled effect result found no parked request with its key:
    /// the replayed updates issued different effects than the recorded
    /// ones did.
    ReplayEffectDivergence,
    /// The app registered no replay hook (`App.replay_fn`), but the
    /// journal carries effect results that need one.
    ReplayUnsupportedApp,
    /// The journal references a session blob (an image record's source
    /// bytes) but no blob source was provided, the blob is missing, or
    /// its bytes fail their content hash — the journal directory was
    /// moved without its `blobs/`, or the store was damaged.
    ReplayMissingBlob,
};

/// Bounded mismatch detail (first N are kept; the count keeps counting).
pub const max_replay_mismatches: usize = 16;

pub const ReplayMismatchKind = enum { fingerprint, screenshot };

pub const ReplayMismatch = struct {
    kind: ReplayMismatchKind,
    event_ordinal: u64,
    frame_index: u64 = 0,
    expected: u64,
    actual: u64,
};

pub const ReplayOptions = struct {
    /// Compare fingerprint checkpoints and screenshot marks. Off, replay
    /// only proves the journal drives cleanly end to end.
    verify: bool = true,
    /// Refuse a journal recorded on another platform (the v1 bar).
    /// Tests recording under the null platform disable this.
    require_same_platform: bool = true,
    /// Where journal records' out-of-line payloads resolve from (the
    /// `blobs/` directory beside the journal — see session_blobs.zig).
    /// Only consulted when a record references a blob; a journal
    /// without image records replays fine with none.
    blobs: ?session_blobs.SessionBlobSource = null,
};

pub const ReplayReport = struct {
    protocol_version: u32 = 0,
    events_replayed: u64 = 0,
    effects_fed: u64 = 0,
    effects_skipped: u64 = 0,
    checkpoints_verified: u64 = 0,
    screenshots_verified: u64 = 0,
    mismatch_count: u64 = 0,
    mismatches: [max_replay_mismatches]ReplayMismatch = undefined,

    pub fn ok(self: *const ReplayReport) bool {
        return self.mismatch_count == 0;
    }

    fn recordMismatch(self: *ReplayReport, mismatch: ReplayMismatch) void {
        if (self.mismatch_count < max_replay_mismatches) {
            self.mismatches[self.mismatch_count] = mismatch;
        }
        self.mismatch_count += 1;
    }
};

/// The platform name this build records into headers and replay
/// compares against — the OS, not the hosting platform value (replay
/// hosts on the null platform on purpose).
pub fn currentPlatformName() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        .ios => "ios",
        else => "other",
    };
}

/// Replay `journal_bytes` into `runtime`/`app`. The runtime must be
/// freshly initialized (no events dispatched yet) over the null
/// platform, with no automation server (live automation commands would
/// interleave with the journal). The journal bytes must outlive the
/// call — decoded event payloads reference them.
pub fn replaySession(
    runtime: *core.Runtime,
    app: core.App,
    journal_bytes: []const u8,
    options: ReplayOptions,
) anyerror!ReplayReport {
    var reader = try journal.Reader.init(journal_bytes);
    var report: ReplayReport = .{};
    var armed = false;

    while (try reader.next()) |record| {
        switch (record) {
            .header => |header| {
                report.protocol_version = header.protocol_version;
                if (header.protocol_version != automation_protocol.version) {
                    std.debug.print(
                        "replay refused: the journal was recorded at automation protocol v{d} but this build speaks v{d} - re-record with this build\n",
                        .{ header.protocol_version, automation_protocol.version },
                    );
                    return error.ReplayProtocolMismatch;
                }
                if (options.require_same_platform and !std.mem.eql(u8, header.platform_name, currentPlatformName())) {
                    std.debug.print(
                        "replay refused: the journal was recorded on \"{s}\" but this host is \"{s}\" - v1 replay is same-platform only (font metrics and scale behavior differ across platforms)\n",
                        .{ header.platform_name, currentPlatformName() },
                    );
                    return error.ReplayPlatformMismatch;
                }
            },
            .event => |event| {
                if (!armed) {
                    armed = true;
                    app.replayControl(.arm) catch {
                        // Apps without the hook still replay when the
                        // journal carries no effect results; a feed
                        // below fails loudly instead.
                    };
                }
                try runtime.dispatchPlatformEvent(app, event);
                report.events_replayed += 1;
            },
            .effect => |effect_record| {
                var effect = effect_record;
                if (effectRegeneratesUnderReplay(effect)) {
                    report.effects_skipped += 1;
                    continue;
                }
                // Resolve out-of-line payloads: an image record's
                // source bytes come from the blob store, verified
                // against the journaled address and length, and feed
                // as `payload` — the recorded bytes, byte-identical,
                // no network. The scratch lives until the feed below
                // returns (the fed bytes are copied into the stub
                // executor's slot buffer).
                var blob_scratch: ?[]u8 = null;
                defer if (blob_scratch) |scratch| std.heap.page_allocator.free(scratch);
                if (effect.kind == .image and effect.image_blob_len > 0) {
                    const bytes = resolveBlob(effect, options.blobs, &blob_scratch) catch |err| {
                        std.debug.print(
                            "replay refused after event {d}: image record for id {d} references blob {s} ({d} bytes) that could not be resolved ({s}) - replay needs the journal's blobs/ directory beside it\n",
                            .{ report.events_replayed, effect.key, session_blobs.hexName(effect.image_blob_hash), effect.image_blob_len, @errorName(err) },
                        );
                        return error.ReplayMissingBlob;
                    };
                    effect.payload = bytes;
                }
                // Feed with back-pressure: results journal in delivery
                // order, so one recorded drain pass can carry more
                // results than the completion queue holds (a live
                // recording's workers keep refilling the queue while
                // the loop drains it). A feed that reports the queue
                // full drains the loop through the same `.wake`
                // dispatch the platform delivers live — the parked
                // request keeps its bytes, and delivery stays
                // queue-ordered — then feeds once more. That one drain
                // empties the whole queue, so a second refusal is a
                // real fault and propagates.
                var drained_for_room = false;
                feed: while (true) {
                    app.replayControl(.{ .feed = effect }) catch |err| switch (err) {
                        error.EffectQueueFull => {
                            if (drained_for_room) return err;
                            drained_for_room = true;
                            try runtime.dispatchPlatformEvent(app, .wake);
                            continue :feed;
                        },
                        error.EffectNotFound => {
                            std.debug.print(
                                "replay diverged after event {d}: journaled {s} result for effect key {d} has no matching pending request - the replayed updates issued different effects than the recording (nondeterminism outside the effect boundary?)\n",
                                .{ report.events_replayed, @tagName(effect.kind), effect.key },
                            );
                            return error.ReplayEffectDivergence;
                        },
                        error.ReplayUnsupported => {
                            std.debug.print(
                                "replay refused: the journal carries effect results but this app registered no replay hook (App.replay_fn - UiApp wires it automatically)\n",
                                .{},
                            );
                            return error.ReplayUnsupportedApp;
                        },
                        else => return err,
                    };
                    break :feed;
                }
                report.effects_fed += 1;
            },
            .checkpoint => |checkpoint| {
                if (!options.verify) continue;
                const actual = runtime.sessionStateFingerprint();
                report.checkpoints_verified += 1;
                if (actual != checkpoint.fingerprint) {
                    report.recordMismatch(.{
                        .kind = .fingerprint,
                        .event_ordinal = checkpoint.event_ordinal,
                        .frame_index = checkpoint.frame_index,
                        .expected = checkpoint.fingerprint,
                        .actual = actual,
                    });
                }
            },
            .screenshot => |mark| {
                if (!options.verify) continue;
                report.screenshots_verified += 1;
                const actual = renderScreenshotHash(runtime, mark.view_label, mark.scale) catch 0;
                if (actual != mark.png_hash) {
                    report.recordMismatch(.{
                        .kind = .screenshot,
                        .event_ordinal = mark.event_ordinal,
                        .expected = mark.png_hash,
                        .actual = actual,
                    });
                }
            },
            .end => {},
        }
    }
    return report;
}

/// Read one journal-referenced blob into fresh scratch (handed to the
/// caller through `scratch_out` for freeing) and verify it against the
/// record: present, exact length, and hashing to its address — the
/// same hostile-input honesty the journal reader keeps.
fn resolveBlob(
    record: journal.EffectResultRecord,
    blobs: ?session_blobs.SessionBlobSource,
    scratch_out: *?[]u8,
) anyerror![]const u8 {
    const blob_source = blobs orelse return error.BlobMissing;
    if (record.image_blob_len > session_blobs.max_blob_bytes) return error.BlobOverBudget;
    const blob_len: usize = @intCast(record.image_blob_len);
    // One spare byte proves the stored blob is not LONGER than the
    // record claims (the source reads at most the buffer).
    const scratch = try std.heap.page_allocator.alloc(u8, blob_len + 1);
    scratch_out.* = scratch;
    const bytes = try blob_source.read_fn(blob_source.context, record.image_blob_hash, scratch);
    if (bytes.len != blob_len) return error.BlobCorrupt;
    return bytes;
}

/// Journaled results that regenerate deterministically from the
/// replayed updates themselves — feeding them would double-deliver:
/// rejections (the same over-capacity/duplicate-key validation refuses
/// again, loop-side) and fx-timer Msgs (real fires replay through the
/// journaled platform `.timer` events; rejections regenerate).
fn effectRegeneratesUnderReplay(record: journal.EffectResultRecord) bool {
    return switch (record.kind) {
        .timer => true,
        .exit => record.exit_reason == .rejected,
        .response => record.fetch_outcome == .rejected,
        .file => record.file_outcome == .rejected,
        .clipboard => record.clipboard_outcome == .rejected,
        // Audio rejections are loop-side validation (path bounds) that
        // refuses again; everything else — loaded acknowledgments,
        // position ticks, completions, platform failures — is an
        // external input and must be fed.
        .audio => record.audio_kind == .rejected,
        // Host-request rejections mark themselves with the exit reason
        // (the `.host` record encoding); host answers must be fed.
        .host => record.exit_reason == .rejected,
        // Image `.rejected` terminals journal from BOTH sides of the
        // executor seam, so the outcome alone is not provenance: only
        // loop-side validation refusals — which the replayed
        // `loadImage` regenerates — mark themselves with the exit
        // reason (the `.host` records' convention, above). Worker-side
        // rejections (a URL that passes the loop's scheme check but
        // cannot become a request, an executor that could not start a
        // cancelable load) keep `.exited`: the fake executor parks
        // those requests, so the journaled record is the ONLY terminal
        // and must be fed like every other worker truth.
        .image => record.exit_reason == .rejected,
        // Launch-env deliveries are exactly what must NOT regenerate:
        // the recorded values feed the replayed envMsgs dispatch so the
        // replay launch's environment is never consulted.
        .line, .clock, .env => false,
    };
}

/// Re-render a journaled screenshot mark through the same deterministic
/// reference renderer the automation `screenshot` verb used at record
/// time, and hash the PNG.
fn renderScreenshotHash(runtime: *core.Runtime, view_label: []const u8, scale: f32) anyerror!u64 {
    const window_id = blk: {
        for (runtime.views[0..runtime.view_count]) |*view| {
            if (view.open and view.kind == .gpu_surface and std.mem.eql(u8, view.label, view_label)) {
                break :blk view.window_id;
            }
        }
        return error.ViewNotFound;
    };
    const allocator = std.heap.page_allocator;
    const pixel_size = try runtime.canvasScreenshotPixelSize(window_id, view_label, scale);
    const pixels = try allocator.alloc(u8, pixel_size.byte_len);
    defer allocator.free(pixels);
    const scratch = try allocator.alloc(u8, pixel_size.byte_len);
    defer allocator.free(scratch);
    const screenshot = try runtime.renderCanvasScreenshot(window_id, view_label, scale, pixels, scratch);
    var writer = try std.Io.Writer.Allocating.initCapacity(
        allocator,
        try canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height),
    );
    defer writer.deinit();
    try canvas.png.writeRgba8(&writer.writer, screenshot.width, screenshot.height, screenshot.rgba8);
    dumpReplayScreenshot(view_label, writer.written());
    return std.hash.Wyhash.hash(0, writer.written());
}

/// Debug aid: `NATIVE_SDK_SESSION_REPLAY_DUMP=<dir>` writes each
/// replay-rendered screenshot PNG so a mismatching pixel mark can be
/// diffed against the recording's artifact.
fn dumpReplayScreenshot(view_label: []const u8, png_bytes: []const u8) void {
    const builtin = @import("builtin");
    if (!builtin.link_libc) return;
    const dir = std.c.getenv("NATIVE_SDK_SESSION_REPLAY_DUMP") orelse return;
    var path_buffer: [1024]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "{s}/replay-screenshot-{s}.png", .{ std.mem.span(dir), view_label }, 0) catch return;
    const file = std.c.fopen(path, "wb") orelse return;
    defer _ = std.c.fclose(file);
    _ = std.c.fwrite(png_bytes.ptr, 1, png_bytes.len, file);
}
