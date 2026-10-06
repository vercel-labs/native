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
const canvas_limits = @import("canvas_limits.zig");
const core = @import("core.zig");
const journal = @import("session_journal.zig");
const platform = @import("../platform/root.zig");
const runtime_effects = @import("effects.zig");
const replay_policy = @import("replay_policy.zig");
const replay_reference = @import("replay_policy_reference.zig");
const session_blobs = @import("session_blobs.zig");

pub const ReplayError = error{
    /// The journal was recorded on a different platform; v1 replay is
    /// same-platform only (font metrics and scale behavior differ).
    ReplayPlatformMismatch,
    /// The journal's automation protocol fingerprint differs from this
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
    /// A record's fields contradict each other in a way the recorder
    /// can never produce (an image record claiming `.loaded` with a
    /// zero-length blob: the recorder journals `.loaded` only after the
    /// bytes decoded and registered, and empty bytes cannot decode; or
    /// decoded dimensions no conforming recording could have accepted
    /// — zero or over the SDK hard ceiling on `.loaded`, nonzero on any other
    /// outcome) — the journal is damaged or hand-edited.
    /// `JournalCorrupt` is the structural sibling (payloads that fail
    /// to decode at all); this class is for records that decode fine
    /// but lie.
    ReplayDamagedRecord,
    /// The replayed event consumed different synchronous OS queries.
    ReplayChromeDivergence,
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
    protocol_fingerprint: u64 = 0,
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
    runtime.replay_window_chrome_active = true;
    runtime.replay_window_chrome_failed = false;
    runtime.replay_window_chrome_count = 0;
    runtime.replay_window_chrome_index = 0;
    defer {
        runtime.replay_window_chrome_active = false;
        runtime.replay_window_chrome_source = .native_queries;
        runtime.replay_window_chrome_failed = false;
        runtime.replay_window_chrome_count = 0;
        runtime.replay_window_chrome_index = 0;
    }

    while (try reader.next()) |record| {
        switch (record) {
            .header => |header| {
                runtime.replay_window_chrome_source = header.window_chrome_source;
                report.protocol_fingerprint = header.protocol_fingerprint;
                const header_action = replay_policy.coordinate(app.replay_policy, .header, @intFromBool(header.protocol_fingerprint == automation_protocol.fingerprint), options.require_same_platform, std.mem.eql(u8, header.platform_name, currentPlatformName()));
                if (header_action == .protocol_refusal) {
                    std.debug.print(
                        "replay refused: the journal was recorded by a build whose automation protocol differs from this build's (journal 0x{x:0>16}, this build 0x{x:0>16}) - re-record with this build\n",
                        .{ header.protocol_fingerprint, automation_protocol.fingerprint },
                    );
                    return error.ReplayProtocolMismatch;
                }
                if (header_action == .platform_refusal) {
                    std.debug.print(
                        "replay refused: the journal was recorded on \"{s}\" but this host is \"{s}\" - v1 replay is same-platform only (font metrics and scale behavior differ across platforms)\n",
                        .{ header.platform_name, currentPlatformName() },
                    );
                    return error.ReplayPlatformMismatch;
                }
            },
            .window_chrome => |fact| {
                if (replay_policy.coordinate(app.replay_policy, .chrome_admission, @intFromBool(runtime.replay_window_chrome_source == .unavailable), runtime.replay_window_chrome_count == journal.max_session_window_chrome_queries, false) == .damage) return error.ReplayDamagedRecord;
                runtime.replay_window_chrome[runtime.replay_window_chrome_count] = fact;
                runtime.replay_window_chrome_count += 1;
            },
            .event => |event| {
                if (replay_policy.coordinate(app.replay_policy, .arm, @intFromBool(armed), false, false) == .arm) {
                    armed = true;
                    app.replayControl(.arm) catch {
                        // Apps without the hook still replay when the
                        // journal carries no effect results; a feed
                        // below fails loudly instead.
                    };
                }
                if (event == .window_frame_changed and !event.window_frame_changed.open) {
                    // Live hosts remove a user-closed window before reporting
                    // this event. Reproduce that native teardown on the replay
                    // host before on_close can declare the same label again.
                    // Do not flip runtime state here: dispatch must observe the
                    // open -> closed edge and deliver the app's close Msg.
                    var windows: [platform.max_windows]platform.WindowInfo = undefined;
                    for (runtime.listWindows(&windows)) |window| {
                        if (window.id != event.window_frame_changed.id or !window.open) continue;
                        runtime.options.platform.services.closeWindow(window.id) catch |err| switch (err) {
                            // An adopted startup window may have no native owner
                            // in a headless replay host.
                            error.WindowNotFound => {},
                            else => return err,
                        };
                        break;
                    }
                }
                try runtime.dispatchPlatformEvent(app, event);
                if (replay_policy.coordinate(app.replay_policy, .chrome_consumed, @intFromBool(runtime.replay_window_chrome_failed), runtime.replay_window_chrome_index != runtime.replay_window_chrome_count, false) == .chrome_divergence) return error.ReplayChromeDivergence;
                runtime.replay_window_chrome_count = 0;
                runtime.replay_window_chrome_index = 0;
                report.events_replayed += 1;
            },
            .effect => |effect_record| {
                var effect = effect_record;
                const admission = replay_policy.plan(app.replay_policy, effect);
                if (admission.damaged(0)) {
                    std.debug.print(
                        "replay refused after event {d}: file record for key {d} has an invalid stream/stat payload shape\n",
                        .{ report.events_replayed, effect.key },
                    );
                    return error.ReplayDamagedRecord;
                }
                // A `.loaded` image record ALWAYS names source bytes:
                // the recorder journals `.loaded` only after those
                // exact bytes decoded and registered (a failed decode
                // rewrites the outcome before it journals, and empty
                // bytes cannot decode), so a zero-length blob here is
                // journal damage, not a session shape. Refuse before
                // any skip/feed decision — resolving blobs only for
                // records that claim bytes would otherwise let the
                // damaged record sail past the blob-integrity gate and
                // deliver a pixel-less "loaded" the recording never
                // produced.
                if (admission.damaged(1)) {
                    std.debug.print(
                        "replay refused after event {d}: image record for id {d} claims .loaded with a zero-length blob - a recorded .loaded always carries its source bytes, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key },
                    );
                    return error.ReplayDamagedRecord;
                }
                // Decoded dimensions obey the recorder the same way: a
                // live `.loaded` journals only after the canvas registry
                // accepted the pixels (nonzero width and height, and
                // width * height * 4 bytes within that recording's
                // runtime-frozen app image budget), and every other
                // outcome journals 0x0. Refuse out-of-bound dims HERE:
                // the fed values flow verbatim into the app's Msg — and,
                // on the TS core host, through `@intCast` into
                // i64-classed arm fields, a safety panic on absurd
                // values — before any decode could disprove them.
                // `status` needs no twin gate: it is u16 at the journal
                // codec, in the completion entry, and in
                // `EffectImageResult`, so every downstream cast
                // (i64/f64 arm fields) holds by type.
                // Channel records obey the recorder the same way: a
                // post can never exceed `max_effect_channel_bytes`
                // (`ChannelHandle.post` refuses the bound before
                // staging), and only `.data` events carry bytes at all
                // — `.closed` and `.rejected` are payload-free
                // terminals. A record that decodes fine but claims
                // otherwise is damaged or hand-edited, and the fed
                // bytes would flow verbatim into the app's Msg (and
                // into a fixed-size feed buffer) before anything could
                // disprove them — refuse HERE, before the feed.
                if (admission.damaged(2)) {
                    std.debug.print(
                        "replay refused after event {d}: channel record for key {d} claims .{s} with {d} payload bytes - a recorded post is bounded at {d} bytes and only .data events carry bytes, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.channel_kind), effect.payload.len, runtime_effects.max_effect_channel_bytes },
                    );
                    return error.ReplayDamagedRecord;
                }
                // Provenance consistency, gated BEFORE the regeneration
                // skip below: a `.data` or `.closed` channel record
                // stamped with `.rejected` provenance would be skipped
                // there and its event silently omitted from the Msg
                // stream (see `channelRecordProvenanceDamaged` for the
                // recorder-truth analysis of exactly which pairs a
                // recording can produce).
                if (admission.damaged(3)) {
                    std.debug.print(
                        "replay refused after event {d}: channel record for key {d} claims a .{s} event stamped with .{s} provenance - the recorder stamps .rejected only on regenerating .rejected admission refusals and every other channel record keeps .exited, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.channel_kind), @tagName(effect.exit_reason) },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(4)) {
                    std.debug.print(
                        "replay refused after event {d}: image record for id {d} claims .{s} with dimensions {d}x{d} - a recorded .loaded always carries nonzero decoded dimensions within the SDK's registered-image ceiling and every other outcome records 0x0, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.image_outcome), effect.image_width, effect.image_height },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(5)) {
                    std.debug.print(
                        "replay refused after event {d}: video record for key {d} carries a millisecond or dimension value at or past 2^53 - recorded playback scalars ride the exact-integer window every delivery tier can carry, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key },
                    );
                    return error.ReplayDamagedRecord;
                }
                // Audio scalars obey the recorder the same way (the
                // delivery boundary clamps them into the exact-integer
                // window before anything journals), so an out-of-window
                // value is journal damage — refuse it rather than
                // silently reshaping the recorded stream at the feed.
                if (admission.damaged(6)) {
                    std.debug.print(
                        "replay refused after event {d}: audio record for key {d} carries a millisecond value at or past 2^53 - recorded playback scalars ride the exact-integer window every delivery tier can carry, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key },
                    );
                    return error.ReplayDamagedRecord;
                }
                // Provenance consistency, gated BEFORE the regeneration
                // skip below: a `.rejected` stamped onto a delivered
                // record (nonzero token) would be skipped there and its
                // handler Msg silently omitted from the stream.
                if (admission.damaged(7)) {
                    std.debug.print(
                        "replay refused after event {d}: video record for key {d} claims .{s} with load token {d} - the recorder stamps token 0 exactly on loop-side rejections and a minted token on every delivery, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.video_kind), effect.video_token },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(8)) {
                    std.debug.print(
                        "replay refused after event {d}: video record for key {d} claims .{s} with motion or geometry the recorder never writes on that kind - terminals deliver with playing and buffering false and no dimensions, and a completion pins position to the duration, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.video_kind) },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(9)) {
                    std.debug.print(
                        "replay refused after event {d}: video load record for key {d} claims outcome .{s} - the recorder stamps .loaded on a resolved cascade and .failed on a refusal, nothing else, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.video_kind) },
                    );
                    return error.ReplayDamagedRecord;
                }
                // Pty records obey the recorder the same way: output
                // batches journal their bytes OUT OF LINE (an output
                // record's payload is always empty on disk, its blob
                // bounded by the chunk size), and exits carry neither
                // payload nor blob. Refuse contradictions before the
                // feed, like the channel gate above.
                if (admission.damaged(10)) {
                    std.debug.print(
                        "replay refused after event {d}: pty record for key {d} claims .{s} with {d} payload bytes and a {d}-byte blob - a recorded output batch rides the blob store bounded at {d} bytes and an exit carries neither, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.pty_kind), effect.payload.len, effect.pty_blob_len, runtime_effects.max_effect_pty_chunk_bytes },
                    );
                    return error.ReplayDamagedRecord;
                }
                // Provenance, gated before the regeneration skip (the
                // channel argument): the recorder stamps `.rejected`
                // only on regenerating admission refusals, which are
                // always `.exit` events; an output record wearing exit
                // provenance would be silently omitted below.
                if (admission.damaged(11)) {
                    std.debug.print(
                        "replay refused after event {d}: pty record for key {d} claims a .{s} event stamped with .{s} provenance - only .exit records carry a non-.exited reason, so the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key, @tagName(effect.pty_kind), @tagName(effect.exit_reason) },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(12)) {
                    std.debug.print(
                        "replay refused after event {d}: model-restore record claims .{s} with {d} inline bytes and a {d}-byte blob - only .ok may carry canonical snapshot bytes, always out of line and bounded at {d}; re-record the session\n",
                        .{ report.events_replayed, @tagName(effect.persist_outcome), effect.payload.len, effect.persist_blob_len, runtime_effects.max_effect_persist_snapshot_bytes },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(13)) {
                    std.debug.print(
                        "replay refused after event {d}: relational record for key {d} has a kind, outcome, payload, blob, or provenance shape the recorder never writes - the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.damaged(14)) {
                    std.debug.print(
                        "replay refused after event {d}: credential record for key {d} has a payload or redaction shape the recorder never writes - the journal is damaged or hand-edited; re-record the session\n",
                        .{ report.events_replayed, effect.key },
                    );
                    return error.ReplayDamagedRecord;
                }
                if (admission.regenerates) {
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
                if (admission.blob == .pty) {
                    const bytes = resolveBlob(effect.pty_blob_hash, effect.pty_blob_len, runtime_effects.max_effect_pty_chunk_bytes, options.blobs, &blob_scratch) catch |err| {
                        std.debug.print(
                            "replay refused after event {d}: pty record for key {d} references blob {s} ({d} bytes) that could not be resolved ({s}) - replay needs the journal's blobs/ directory beside it\n",
                            .{ report.events_replayed, effect.key, session_blobs.hexName(effect.pty_blob_hash), effect.pty_blob_len, @errorName(err) },
                        );
                        return error.ReplayMissingBlob;
                    };
                    effect.payload = bytes;
                }
                if (admission.blob == .file) {
                    const bytes = resolveBlob(effect.file_blob_hash, effect.file_blob_len, runtime_effects.effect_file_stream_chunk_bytes, options.blobs, &blob_scratch) catch |err| {
                        std.debug.print(
                            "replay refused after event {d}: file stream for key {d} references blob {s} ({d} bytes) that could not be resolved ({s})\n",
                            .{ report.events_replayed, effect.key, session_blobs.hexName(effect.file_blob_hash), effect.file_blob_len, @errorName(err) },
                        );
                        return error.ReplayMissingBlob;
                    };
                    effect.payload = bytes;
                }
                if (admission.blob == .image) {
                    const bytes = resolveBlob(effect.image_blob_hash, effect.image_blob_len, runtime_effects.max_effect_image_bytes, options.blobs, &blob_scratch) catch |err| {
                        std.debug.print(
                            "replay refused after event {d}: image record for id {d} references blob {s} ({d} bytes) that could not be resolved ({s}) - replay needs the journal's blobs/ directory beside it\n",
                            .{ report.events_replayed, effect.key, session_blobs.hexName(effect.image_blob_hash), effect.image_blob_len, @errorName(err) },
                        );
                        return error.ReplayMissingBlob;
                    };
                    effect.payload = bytes;
                }
                if (admission.blob == .persist) {
                    const bytes = resolveBlob(effect.persist_blob_hash, effect.persist_blob_len, runtime_effects.max_effect_persist_snapshot_bytes, options.blobs, &blob_scratch) catch |err| {
                        std.debug.print(
                            "replay refused after event {d}: model restore references blob {s} ({d} bytes) that could not be resolved ({s}) - replay needs the journal's blobs/ directory beside it\n",
                            .{ report.events_replayed, session_blobs.hexName(effect.persist_blob_hash), effect.persist_blob_len, @errorName(err) },
                        );
                        return error.ReplayMissingBlob;
                    };
                    effect.payload = bytes;
                }
                if (admission.blob == .db) {
                    const bytes = resolveBlob(effect.db_blob_hash, effect.db_blob_len, runtime_effects.max_effect_db_page_bytes, options.blobs, &blob_scratch) catch |err| {
                        std.debug.print(
                            "replay refused after event {d}: relational page for key {d} references blob {s} ({d} bytes) that could not be resolved ({s}) - replay needs the journal's blobs/ directory beside it\n",
                            .{ report.events_replayed, effect.key, session_blobs.hexName(effect.db_blob_hash), effect.db_blob_len, @errorName(err) },
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
                    app.replayControl(.{ .feed = effect }) catch |err| switch (replay_policy.coordinate(app.replay_policy, .feed_error, switch (err) {
                        error.EffectQueueFull => 0,
                        error.EffectNotFound => 1,
                        error.ReplayUnsupported => 2,
                        else => return err,
                    }, drained_for_room, false)) {
                        .propagate => return err,
                        .drain => {
                            drained_for_room = true;
                            try runtime.dispatchPlatformEvent(app, .wake);
                            continue :feed;
                        },
                        .effect_divergence => {
                            std.debug.print(
                                "replay diverged after event {d}: journaled {s} result for effect key {d} has no matching pending request - the replayed updates issued different effects than the recording (nondeterminism outside the effect boundary?)\n",
                                .{ report.events_replayed, @tagName(effect.kind), effect.key },
                            );
                            return error.ReplayEffectDivergence;
                        },
                        .unsupported => {
                            std.debug.print(
                                "replay refused: the journal carries effect results but this app registered no replay hook (App.replay_fn - UiApp wires it automatically)\n",
                                .{},
                            );
                            return error.ReplayUnsupportedApp;
                        },
                        else => @panic("invalid replay feed action"),
                    };
                    break :feed;
                }
                report.effects_fed += 1;
            },
            .checkpoint => |checkpoint| {
                if (replay_policy.coordinate(app.replay_policy, .verify, @intFromBool(options.verify), false, false) != .verify) continue;
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
                if (replay_policy.coordinate(app.replay_policy, .verify, @intFromBool(options.verify), false, false) != .verify) continue;
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
            .end => {
                if (replay_policy.coordinate(app.replay_policy, .end, @intFromBool(runtime.replay_window_chrome_count != 0), false, false) == .chrome_divergence) return error.ReplayChromeDivergence;
            },
        }
    }
    // End-of-journal consistency: every fed-but-queued record must have
    // been consumed by the load it named, and nothing the replayed
    // timeline did may have latched a divergence
    // (`Effects.finishReplay`). Unconditional — a recording with ZERO
    // effect records still fails here when the replayed updates issued
    // a load the recording never journaled. Apps without a replay hook
    // have no armed channel to check and answer ReplayUnsupported,
    // which is fine: nothing was fed and nothing could have latched.
    app.replayControl(.finish) catch |err| switch (err) {
        error.ReplayUnsupported => {},
        else => {
            std.debug.print(
                "replay diverged at the journal's end: {s} - the replayed updates issued different effects than the recording (nondeterminism outside the effect boundary?)\n",
                .{@errorName(err)},
            );
            return error.ReplayEffectDivergence;
        },
    };
    return report;
}

/// Read one journal-referenced blob into fresh scratch (handed to the
/// caller through `scratch_out` for freeing) and verify it against the
/// record: present, exact length, and hashing to its address — the
/// same hostile-input honesty the journal reader keeps.
fn resolveBlob(
    blob_hash: [runtime_effects.effect_image_blob_hash_len]u8,
    blob_len_field: u64,
    max_bytes: usize,
    blobs: ?session_blobs.SessionBlobSource,
    scratch_out: *?[]u8,
) anyerror![]const u8 {
    const blob_source = blobs orelse return error.BlobMissing;
    if (blob_len_field > max_bytes) return error.BlobOverBudget;
    const blob_len: usize = @intCast(blob_len_field);
    // One spare byte proves the stored blob is not LONGER than the
    // record claims (the source reads at most the buffer).
    const scratch = try std.heap.page_allocator.alloc(u8, blob_len + 1);
    scratch_out.* = scratch;
    const bytes = try blob_source.read_fn(blob_source.context, blob_hash, scratch);
    if (bytes.len != blob_len) return error.BlobCorrupt;
    return bytes;
}

test "only admission-tagged file results regenerate" {
    try std.testing.expect(replay_reference.effectRegeneratesUnderReplay(.{
        .kind = .file,
        .key = 1,
        .file_outcome = .rejected,
        .file_rejected_admission = true,
    }));
    try std.testing.expect(!replay_reference.fileRecordDamaged(.{
        .kind = .file,
        .key = 2,
        .file_op = .write_stream_chunk,
        .file_outcome = .sink_missing,
        .file_rejected_admission = true,
    }));
    try std.testing.expect(replay_reference.fileRecordDamaged(.{
        .kind = .file,
        .key = 2,
        .file_op = .write_stream_chunk,
        .file_outcome = .ok,
        .file_rejected_admission = true,
    }));
    try std.testing.expect(!replay_reference.effectRegeneratesUnderReplay(.{
        .kind = .file,
        .key = 1,
        .file_op = .read_stream,
        .file_outcome = .rejected,
    }));
    try std.testing.expect(replay_reference.effectRegeneratesUnderReplay(.{
        .kind = .file,
        .key = 2,
        .file_op = .write_stream_chunk,
        .file_outcome = .sink_missing,
        .file_rejected_admission = true,
    }));
    try std.testing.expect(replay_reference.effectRegeneratesUnderReplay(.{
        .kind = .file,
        .key = 3,
        .file_op = .write_stream_close,
        .file_outcome = .out_of_order,
        .file_rejected_admission = true,
    }));
    try std.testing.expect(!replay_reference.fileRecordDamaged(.{
        .kind = .file,
        .key = 4,
        .file_op = .write_stream_chunk,
        .file_outcome = .ok,
    }));
    try std.testing.expect(replay_reference.fileRecordDamaged(.{
        .kind = .file,
        .key = 4,
        .file_op = .write_stream_chunk,
        .file_outcome = .ok,
        .file_total = 1,
    }));
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

test "exit records outside the transport's producible ranges are damaged" {
    // Every code waitpid can produce passes: 0..255, plus the
    // documented -1 sentinel for a child reaped outside the toolkit.
    var record: journal.EffectResultRecord = .{
        .kind = .pty,
        .key = 1,
        .pty_kind = .exit,
        .exit_reason = .exited,
        .code = 0,
    };
    try std.testing.expect(!replay_reference.ptyRecordDamaged(record));
    record.code = 255;
    try std.testing.expect(!replay_reference.ptyRecordDamaged(record));
    record.code = runtime_effects.effect_error_exit_code;
    try std.testing.expect(!replay_reference.ptyRecordDamaged(record));

    // Hand-edited codes no status word can carry are refused.
    record.code = 256;
    try std.testing.expect(replay_reference.ptyRecordDamaged(record));
    record.code = -2;
    try std.testing.expect(replay_reference.ptyRecordDamaged(record));

    // Signals: waitpid's status word carries 1..127.
    record = .{
        .kind = .pty,
        .key = 1,
        .pty_kind = .exit,
        .exit_reason = .signaled,
        .code = runtime_effects.effect_error_exit_code,
        .pty_signal = 9,
    };
    try std.testing.expect(!replay_reference.ptyRecordDamaged(record));
    record.pty_signal = 127;
    try std.testing.expect(!replay_reference.ptyRecordDamaged(record));
    record.pty_signal = 128;
    try std.testing.expect(replay_reference.ptyRecordDamaged(record));
    record.pty_signal = -9;
    try std.testing.expect(replay_reference.ptyRecordDamaged(record));
}

test "audio records outside the exact-integer scalar window are damaged" {
    // The delivery boundary clamps positions and durations below 2^53
    // before anything journals, so every in-window value passes and
    // every out-of-window value can only be journal damage.
    var record: journal.EffectResultRecord = .{
        .kind = .audio,
        .key = 1,
        .audio_kind = .position,
        .audio_position_ms = 0,
        .audio_duration_ms = 183_000,
    };
    try std.testing.expect(!replay_reference.audioScalarsDamaged(record));
    record.audio_position_ms = runtime_effects.max_effect_video_scalar_exclusive - 1;
    try std.testing.expect(!replay_reference.audioScalarsDamaged(record));
    record.audio_position_ms = runtime_effects.max_effect_video_scalar_exclusive;
    try std.testing.expect(replay_reference.audioScalarsDamaged(record));
    record.audio_position_ms = 0;
    record.audio_duration_ms = std.math.maxInt(u64);
    try std.testing.expect(replay_reference.audioScalarsDamaged(record));
}

test "relational rejection provenance distinguishes admission from executor truth" {
    var record: journal.EffectResultRecord = .{
        .kind = .db,
        .key = 1,
        .code = runtime_effects.dbJournalCode(.done, .rejected),
        .exit_reason = .exited,
    };

    // A bounded executor result is a real terminal which replay must feed.
    try std.testing.expect(!replay_reference.dbRecordDamaged(record));

    // A deterministic admission refusal regenerates instead and uses the
    // same outcome with explicit rejected provenance.
    record.exit_reason = .rejected;
    try std.testing.expect(!replay_reference.dbRecordDamaged(record));

    // Rejected provenance cannot decorate a successful result, and DB
    // records never carry process-only exit reasons.
    record.code = runtime_effects.dbJournalCode(.done, .ok);
    try std.testing.expect(replay_reference.dbRecordDamaged(record));
    record.code = runtime_effects.dbJournalCode(.done, .rejected);
    record.exit_reason = .cancelled;
    try std.testing.expect(replay_reference.dbRecordDamaged(record));
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
