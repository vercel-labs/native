//! Native replay oracle retained for legacy Zig apps and parity tests.
const std = @import("std");
const runtime_effects = @import("effects.zig");
const journal = @import("session_journal.zig");
const platform = @import("../platform/root.zig");
const canvas_limits = @import("canvas_limits.zig");

pub fn ptyRecordDamaged(record: journal.EffectResultRecord) bool {
    if (record.payload.len > 0) return true;
    if (record.pty_blob_len > runtime_effects.max_effect_pty_chunk_bytes) return true;
    switch (record.pty_kind) {
        // The recorder journals output ONLY for a non-empty batch, so
        // its blob is always non-empty — a zero-length output blob is
        // damage that would otherwise replay a synthetic empty output
        // event and diverge the fingerprint. The scalar fields are
        // canonical (-1 code sentinel, no signal, no drops): replay
        // delivers those exact defaults regardless, so a record claiming
        // anything else would be silently rewritten — refuse it instead.
        .output => {
            if (record.pty_blob_len == 0) return true;
            if (record.code != runtime_effects.effect_error_exit_code) return true;
            if (record.pty_signal != 0 or record.pty_dropped_writes != 0) return true;
        },
        // Exits carry neither payload nor blob, and their code/signal
        // must obey the delivered contract (`signal != 0` iff the reason
        // is `.signaled`; `code == -1` for every reason but `.exited`).
        // A hand-edited `.cancelled` with code 0 or signal 9 would
        // otherwise dispatch an event violating that contract. The
        // values are also RANGE-gated to what the transport can produce:
        // `waitpid`'s status word yields exit codes 0..255 (plus the
        // documented -1 for a child reaped outside the toolkit) and
        // signals 1..127 — anything else is hand-editing, refused
        // rather than replayed into an event no live run can emit.
        .exit => {
            if (record.pty_blob_len > 0) return true;
            const signaled = record.exit_reason == .signaled;
            if (signaled != (record.pty_signal != 0)) return true;
            if (record.exit_reason != .exited and record.code != runtime_effects.effect_error_exit_code) return true;
            if (record.exit_reason == .exited and
                record.code != runtime_effects.effect_error_exit_code and
                (record.code < 0 or record.code > 255)) return true;
            if (signaled and (record.pty_signal < 1 or record.pty_signal > 127)) return true;
        },
        // A write-admission verdict carries only the accepted bit in
        // `code` (1/0) — no blob, no signal, no drop count.
        .write => {
            if (record.pty_blob_len > 0) return true;
            if (record.code != 0 and record.code != 1) return true;
            if (record.pty_signal != 0 or record.pty_dropped_writes != 0) return true;
        },
    }
    return false;
}

pub fn persistRecordDamaged(record: journal.EffectResultRecord) bool {
    if (record.payload.len > 0) return true;
    if (record.persist_blob_len > runtime_effects.max_effect_persist_snapshot_bytes) return true;
    return record.persist_outcome != .ok and record.persist_blob_len > 0;
}

pub fn dbRecordDamaged(record: journal.EffectResultRecord) bool {
    const kind = runtime_effects.dbKindFromJournalCode(record.code) orelse return true;
    const outcome = runtime_effects.dbOutcomeFromJournalCode(record.code) orelse return true;
    if (record.code != runtime_effects.dbJournalCode(kind, outcome)) return true;
    // `.rejected` provenance identifies an admission refusal that replay
    // regenerates. An executor may also return the closed `.rejected`
    // outcome (for example when a result crosses its total bound); that
    // terminal is external truth and correctly keeps `.exited` provenance.
    if (record.exit_reason != .exited and record.exit_reason != .rejected) return true;
    if (record.exit_reason == .rejected and outcome != .rejected) return true;
    if (record.db_blob_len > runtime_effects.max_effect_db_page_bytes) return true;
    return switch (kind) {
        .page => outcome != .ok or
            (record.payload.len == 0) == (record.db_blob_len == 0) or
            record.payload.len > runtime_effects.max_effect_db_page_bytes,
        .done, .exec => record.payload.len > 0 or record.db_blob_len > 0,
    };
}

pub fn fileRecordDamaged(record: journal.EffectResultRecord) bool {
    if (record.file_rejected_admission) switch (record.file_outcome) {
        .rejected => {},
        .sink_missing, .out_of_order => if (record.file_op != .write_stream_chunk and record.file_op != .write_stream_close) return true,
        else => return true,
    };
    if (record.file_blob_len > runtime_effects.effect_file_stream_chunk_bytes) return true;
    if (record.file_event == .chunk) {
        return record.file_op != .read_stream or record.file_outcome != .ok or
            record.payload.len != 0 or record.file_blob_len == 0;
    }
    if (record.file_blob_len != 0) return true;
    if (record.file_event == .done) {
        return record.file_op != .read_stream or record.file_outcome != .ok or record.payload.len != 0;
    }
    if (record.file_op == .stat and record.file_outcome == .ok) return record.payload.len != 0;
    return record.file_total != 0 or record.file_mtime_ms != 0 or record.file_exists;
}

pub fn credentialsRecordDamaged(record: journal.EffectResultRecord) bool {
    if (record.payload.len != 0 or record.exit_reason != .exited) return true;
    const redacted_get = record.credentials_operation == .get and record.credentials_outcome == .ok;
    if (redacted_get) return record.credentials_secret_len > runtime_effects.max_effect_credentials_secret_bytes or
        std.mem.allEqual(u8, &record.credentials_salt, 0) or
        std.mem.allEqual(u8, &record.credentials_digest, 0);
    if (record.credentials_secret_len != 0) return true;
    return !std.mem.allEqual(u8, &record.credentials_salt, 0) or
        !std.mem.allEqual(u8, &record.credentials_digest, 0);
}

/// Recorder truth for pty provenance: output records always carry
/// `.exited` (the live drain never touches the exit reason on an
/// output); every reason is legal on an `.exit` record (`.rejected` =
/// regenerating admission refusal, `.spawn_failed` = executor-truth
/// start failure, the rest = real endings).
pub fn ptyRecordProvenanceDamaged(record: journal.EffectResultRecord) bool {
    // Output and write-verdict records always carry `.exited` (neither
    // journal site ever touches the reason).
    if (record.pty_kind != .exit and record.exit_reason != .exited) return true;
    // The regenerating-provenance bit only ever rides an admission
    // refusal — an `.exit` record whose reason is `.rejected`.
    if (record.truncated and (record.pty_kind != .exit or record.exit_reason != .rejected)) return true;
    return false;
}

pub fn channelRecordDamaged(record: journal.EffectResultRecord) bool {
    if (record.payload.len > runtime_effects.max_effect_channel_bytes) return true;
    return record.channel_kind != .data and record.payload.len > 0;
}

/// Whether a channel record's provenance stamp contradicts its event
/// kind — RECORDER TRUTH: channel records journal from exactly two
/// sites. The live drain (staged posts and the close marker) journals
/// `.data` and `.closed` events and never touches `exit_reason`, so
/// they always carry `.exited`; the pending-terminal ring journals only
/// `.rejected` events, stamped `.rejected` when the refusal is
/// regenerating loop-side admission validation and left `.exited` when
/// it is executor truth (an open that could not stage its channel). The
/// legal pairs are therefore exactly (.data, .exited),
/// (.closed, .exited), (.rejected, .exited), (.rejected, .rejected).
/// The forward mismatch is the dangerous one: a `.data` or `.closed`
/// record stamped `.rejected` sails into the regeneration skip and is
/// silently OMITTED — with verification disabled, replay succeeds with
/// a different Msg stream. The reverse direction needs no twin gate
/// beyond the range check: `.rejected` with `.exited` is exactly the
/// executor-truth rejection and must feed; and no recorder site can
/// write any other exit reason on a channel record, so a decoded
/// `.signaled`/`.cancelled`/`.spawn_failed` (valid members for SPAWN
/// records) is hand-editing.
pub fn channelRecordProvenanceDamaged(record: journal.EffectResultRecord) bool {
    if (record.exit_reason == .rejected) return record.channel_kind != .rejected;
    return record.exit_reason != .exited;
}

/// A structurally valid u64 in a video record is not automatically an
/// HONEST one: the engine clamps every video scalar into the
/// exact-integer delivery window at the delivery boundary
/// (`Effects.takeVideoMsg`, `max_effect_video_scalar_exclusive`), so no
/// recorder can write a position, duration, or dimension at or past
/// 2^53 whatever a host or embedder reports — and the TS delivery tier
/// carries these scalars through the subset's exact-integer number
/// window, where feeding a larger value would trap in the bridge's
/// numeric widening instead of refusing the hostile file at the gate.
pub fn videoScalarsDamaged(record: journal.EffectResultRecord) bool {
    const max_exact: u64 = runtime_effects.max_effect_video_scalar_exclusive;
    return record.video_position_ms >= max_exact or
        record.video_duration_ms >= max_exact or
        record.video_width >= max_exact or
        record.video_height >= max_exact;
}

/// The audio twin: positions and durations clamp into the exact-integer
/// window at every delivery entry before they journal, so a recorded
/// value at or past 2^53 can only be a damaged or hand-edited journal.
pub fn audioScalarsDamaged(record: journal.EffectResultRecord) bool {
    const max_exact: u64 = runtime_effects.max_effect_video_scalar_exclusive;
    return record.audio_position_ms >= max_exact or
        record.audio_duration_ms >= max_exact;
}

/// A `.video_load` record's `video_kind` is the load's OUTCOME, and the
/// recorder writes exactly two values: `.loaded` on a resolved cascade
/// and `.failed` on a synchronous refusal. Any other kind steers
/// nothing honestly (a `.position` would leave the replayed fake load
/// active where nothing is known), so it refuses at the gate.
/// A `.video` record's kind and token are recorder-coupled: loop-side
/// rejections never minted a token (they stamp 0) and every DELIVERY —
/// position ticks, terminals, acknowledgments — carries the minted
/// token of the load that produced it. A `.rejected` with a nonzero
/// token would silently skip a real delivery through the regeneration
/// gate; a delivery with token 0 could never have routed. Both are
/// damage.
pub fn videoRecordProvenanceDamaged(record: journal.EffectResultRecord) bool {
    if (record.video_kind == .rejected) return record.video_token != 0;
    return record.video_token == 0;
}

/// Recorder truth for a `.video` record's payload SHAPE, per kind:
/// `.failed` and `.rejected` deliver with playing and buffering false
/// (the terminal resolution forces the flags) and no dimensions (no
/// failure path ever measured a frame); `.completed` pins position to
/// the duration with the flags false. A record violating these can
/// only be hand-edited — and a synchronously failed load's record has
/// no platform event behind it to cross-check at the pairing, so the
/// gate is where the impossible payload refuses.
pub fn videoRecordShapeDamaged(record: journal.EffectResultRecord) bool {
    return switch (record.video_kind) {
        .failed, .rejected => record.video_playing or record.video_buffering or
            record.video_width != 0 or record.video_height != 0,
        .completed => record.video_playing or record.video_buffering or
            record.video_position_ms != record.video_duration_ms,
        .loaded, .position => false,
    };
}

pub fn videoLoadOutcomeDamaged(record: journal.EffectResultRecord) bool {
    return record.video_kind != .loaded and record.video_kind != .failed;
}

pub fn imageDimsDamaged(record: journal.EffectResultRecord) bool {
    if (record.image_outcome != .loaded) {
        return record.image_width != 0 or record.image_height != 0;
    }
    if (record.image_width == 0 or record.image_height == 0) return true;
    if (record.image_width > platform.max_decoded_image_dimension or record.image_height > platform.max_decoded_image_dimension) return true;
    const pixels = std.math.mul(u64, record.image_width, record.image_height) catch return true;
    const pixel_bytes = std.math.mul(u64, pixels, 4) catch return true;
    // The journal does not carry the recording's manifest budget. Validate
    // against the SDK-wide ceiling: a result above the replay runtime's
    // current (possibly lowered) budget is still valid recorder truth. Its
    // Msg feeds verbatim; best-effort pixel re-registration may fit smaller.
    return pixel_bytes > canvas_limits.max_registered_canvas_image_pixel_bytes_ceiling;
}

/// Journaled results that regenerate deterministically from the
/// replayed updates themselves — feeding them would double-deliver:
/// rejections (the same over-capacity/duplicate-key validation refuses
/// again, loop-side) and fx-timer Msgs (real fires replay through the
/// journaled platform `.timer` events; rejections regenerate).
pub fn effectRegeneratesUnderReplay(record: journal.EffectResultRecord) bool {
    return switch (record.kind) {
        .timer => true,
        .exit => record.exit_reason == .rejected,
        // Only DETERMINISTIC admission/protocol results regenerate — marked
        // by each effect family's provenance bit. Executor-truth terminals —
        // start failures, platform refusals, output, and real exits — are
        // external inputs and must be fed, even when their reason is rejected.
        .pty => record.pty_kind == .exit and record.truncated,
        .response => record.fetch_outcome == .rejected,
        .file => record.file_rejected_admission,
        .clipboard => record.clipboard_outcome == .rejected,
        // Audio rejections are loop-side validation (path bounds) that
        // refuses again; everything else — loaded acknowledgments,
        // position ticks, completions, platform failures — is an
        // external input and must be fed.
        .audio => record.audio_kind == .rejected,
        // Video rejections are the same loop-side validation (source
        // bounds, scheme, surface-id shape) and regenerate; failures —
        // including a claim or platform load the recording host
        // refused — are executor truth the replayed fake never
        // reproduces, so they feed like every other kind.
        .video => record.video_kind == .rejected,
        // The cascade resolution is the recording host's filesystem
        // truth — the replayed fake load cannot re-run the local
        // probe, so the record must feed.
        .video_load => false,
        // Host-request rejections mark themselves with the exit reason
        // (the `.host` record encoding); host answers must be fed.
        .host => record.exit_reason == .rejected,
        .db => record.exit_reason == .rejected,
        .credentials => false,
        .window_execution => false,
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
        // Channel `.rejected` terminals follow the image convention
        // exactly: admission refusals (occupied key, full channel
        // table) mark themselves with the exit reason and regenerate —
        // the replayed `openChannel` re-runs the same deterministic
        // gates against re-derived occupancy windows and stages its
        // own. An executor-truth rejection (the open that could not
        // stage its channel) keeps `.exited` and FEEDS, retiring the
        // slot the replayed open parked. `.data` and `.closed` are
        // executor truth by definition — the source thread never
        // re-runs at replay, so the journaled events are the ONLY
        // delivery.
        .channel => record.exit_reason == .rejected,
        // Launch-env deliveries are exactly what must NOT regenerate:
        // the recorded values feed the replayed envMsgs dispatch so the
        // replay launch's environment is never consulted.
        .line, .clock, .env, .persist => false,
    };
}

pub fn damage(record: journal.EffectResultRecord) u16 {
    var bits: u16 = 0;
    const checks = [_]bool{
        record.kind == .file and fileRecordDamaged(record),
        record.kind == .image and record.image_outcome == .loaded and record.image_blob_len == 0,
        record.kind == .channel and channelRecordDamaged(record),
        record.kind == .channel and channelRecordProvenanceDamaged(record),
        record.kind == .image and imageDimsDamaged(record),
        record.kind == .video and videoScalarsDamaged(record),
        record.kind == .audio and audioScalarsDamaged(record),
        record.kind == .video and videoRecordProvenanceDamaged(record),
        record.kind == .video and videoRecordShapeDamaged(record),
        record.kind == .video_load and videoLoadOutcomeDamaged(record),
        record.kind == .pty and ptyRecordDamaged(record),
        record.kind == .pty and ptyRecordProvenanceDamaged(record),
        record.kind == .persist and persistRecordDamaged(record),
        record.kind == .db and dbRecordDamaged(record),
        record.kind == .credentials and credentialsRecordDamaged(record),
    };
    for (checks, 0..) |value, i| if (value) {
        bits |= @as(u16, 1) << @intCast(i);
    };
    return bits;
}
